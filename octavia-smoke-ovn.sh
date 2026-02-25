#!/usr/bin/env bash
# Minimal Octavia “smoke test” via the openstack-admin-client pod.
#
# What this does (minimum path):
#   1) Creates a tenant network + subnet
#   2) Creates a load balancer (VIP on that subnet)
#   3) Creates a listener + pool (+ optional health monitor)
#
# Optional (off by default):
#   - Create 1–2 backend servers on that subnet and add them as pool members.
#
# Requirements:
#   - openstack-admin-client pod exists in namespace "openstack"
#   - OpenStack CLI is configured inside the pod (clouds.yaml or env vars)
#   - Octavia is deployed and functional
#
# Usage:
#   chmod +x octavia-basic-lb.sh
#   ./octavia-basic-lb.sh
#
# To enable backend servers:
#   CREATE_BACKENDS=1 EXT_NET=public IMAGE="cirros" FLAVOR="m1.small" ./octavia-basic-lb.sh

set -euo pipefail

########################################
# Where/how we run openstack
########################################
OPENSTACK_NS="${OPENSTACK_NS:-openstack}"
OPENSTACK_POD="${OPENSTACK_POD:-openstack-admin-client}"
OPENSTACK_CMD_DEFAULT=(kubectl -n "${OPENSTACK_NS}" exec "${OPENSTACK_POD}" -- openstack)
# Allow override, but keep sane default.
OPENSTACK_CMD=("${OPENSTACK_CMD[@]:-${OPENSTACK_CMD_DEFAULT[@]}}")

os() { "${OPENSTACK_CMD[@]}" "$@"; }

########################################
# Names + basic network settings
########################################
NAME_PREFIX="${NAME_PREFIX:-octavia-smoke-$(date +%Y%m%d%H%M%S)}"

NET_NAME="${NET_NAME:-${NAME_PREFIX}-net}"
SUBNET_NAME="${SUBNET_NAME:-${NAME_PREFIX}-subnet}"

# Pick a CIDR unlikely to collide with your environment.
CIDR="${CIDR:-192.168.245.0/24}"
GATEWAY="${GATEWAY:-192.168.245.1}"
DNS="${DNS:-1.1.1.1}"
ALLOC_START="${ALLOC_START:-192.168.245.10}"
ALLOC_END="${ALLOC_END:-192.168.245.200}"

LB_NAME="${LB_NAME:-${NAME_PREFIX}-lb}"
LISTENER_NAME="${LISTENER_NAME:-${NAME_PREFIX}-listener}"
POOL_NAME="${POOL_NAME:-${NAME_PREFIX}-pool}"
HM_NAME="${HM_NAME:-${NAME_PREFIX}-hm}"

# Listener protocol/port
LB_PROTOCOL="${LB_PROTOCOL:-TCP}"
LB_PORT="${LB_PORT:-80}"
LB_ALGO="${LB_ALGO:-SOURCE_IP_PORT}"

# Health monitor (created unless DISABLE_HM=1)
DISABLE_HM="${DISABLE_HM:-0}"
HM_TYPE="${HM_TYPE:-TCP}"
HM_DELAY="${HM_DELAY:-5}"
HM_TIMEOUT="${HM_TIMEOUT:-3}"
HM_RETRIES="${HM_RETRIES:-3}"

# Optional backend creation
CREATE_BACKENDS="${CREATE_BACKENDS:-0}"
BACKEND_COUNT="${BACKEND_COUNT:-2}"
IMAGE="${IMAGE:-cirros}"
FLAVOR="${FLAVOR:-m1.small}"
KEY_NAME="${KEY_NAME:-${NAME_PREFIX}-key}"
SECGRP="${SECGRP:-${NAME_PREFIX}-sg}"
EXT_NET="${EXT_NET:-public}" # only needed if CREATE_BACKENDS=1 and you want a router to external

########################################
# Cleanup handling
########################################
DO_CLEANUP="${DO_CLEANUP:-0}" # set to 1 to auto-delete on exit
cleanup() {
  if [[ "${DO_CLEANUP}" != "1" ]]; then
    return 0
  fi
  set +e
  echo ">> Cleanup enabled; deleting resources (best effort)..."

  # Delete LB first (it owns sub-resources)
  if os loadbalancer show "${LB_NAME}" >/dev/null 2>&1; then
    os loadbalancer delete --cascade "${LB_NAME}" >/dev/null 2>&1 || true
  fi

  # Delete servers if created
  if [[ "${CREATE_BACKENDS}" == "1" ]]; then
    for i in $(seq 1 "${BACKEND_COUNT}"); do
      os server delete "${NAME_PREFIX}-backend-${i}" >/dev/null 2>&1 || true
    done
    os security group delete "${SECGRP}" >/dev/null 2>&1 || true
    os keypair delete "${KEY_NAME}" >/dev/null 2>&1 || true
  fi

  # Delete subnet + net
  os subnet delete "${SUBNET_NAME}" >/dev/null 2>&1 || true
  os network delete "${NET_NAME}" >/dev/null 2>&1 || true

  echo ">> Cleanup done."
}
trap cleanup EXIT

########################################
# Helpers
########################################
wait_for_lb_status() {
  local lb_id="$1"
  local want="${2:-ACTIVE}"
  local max_wait="${3:-600}"  # seconds
  local start
  start="$(date +%s)"

  while true; do
    local prov op
    prov="$(os loadbalancer show "${lb_id}" -f value -c provisioning_status 2>/dev/null || true)"
    op="$(os loadbalancer show "${lb_id}" -f value -c operating_status 2>/dev/null || true)"

    if [[ "${prov}" == "${want}" ]]; then
      echo ">> LB provisioning_status=${prov} operating_status=${op}"
      return 0
    fi

    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed > max_wait )); then
      echo "!! Timed out waiting for LB ${lb_id} provisioning_status=${want} (last: ${prov}, operating: ${op})" >&2
      os loadbalancer show "${lb_id}" || true
      return 1
    fi

    echo ">> Waiting for LB provisioning_status=${want} (current: ${prov}, operating: ${op})..."
    sleep 5
  done
}

wait_for_server_active() {
  local server_id="$1"
  local max_wait="${2:-600}"
  local start
  start="$(date +%s)"
  while true; do
    local st
    st="$(os server show "${server_id}" -f value -c status 2>/dev/null || true)"
    if [[ "${st}" == "ACTIVE" ]]; then
      return 0
    fi
    if [[ "${st}" == "ERROR" ]]; then
      echo "!! Server ${server_id} is ERROR" >&2
      os server show "${server_id}" || true
      return 1
    fi
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed > max_wait )); then
      echo "!! Timed out waiting for server ${server_id} ACTIVE (last: ${st})" >&2
      os server show "${server_id}" || true
      return 1
    fi
    sleep 5
  done
}

########################################
# Start
########################################
echo "== Octavia basic LB smoke test =="
echo ">> Using OPENSTACK_CMD: ${OPENSTACK_CMD[*]}"
echo ">> Prefix: ${NAME_PREFIX}"

echo ">> Checking access..."
os token issue >/dev/null
echo ">> OpenStack CLI is working."

########################################
# Create network + subnet
########################################
echo ">> Creating network: ${NET_NAME}"
if ! os network show "${NET_NAME}" >/dev/null 2>&1; then
  os network create "${NET_NAME}" >/dev/null
else
  echo ">> Network already exists; reusing."
fi

NET_ID="$(os network show "${NET_NAME}" -f value -c id)"

echo ">> Creating subnet: ${SUBNET_NAME} (${CIDR})"
if ! os subnet show "${SUBNET_NAME}" >/dev/null 2>&1; then
  os subnet create "${SUBNET_NAME}" \
    --network "${NET_ID}" \
    --subnet-range "${CIDR}" \
    --gateway "${GATEWAY}" \
    --dns-nameserver "${DNS}" \
    --allocation-pool start="${ALLOC_START}",end="${ALLOC_END}" >/dev/null
else
  echo ">> Subnet already exists; reusing."
fi

SUBNET_ID="$(os subnet show "${SUBNET_NAME}" -f value -c id)"

########################################
# Create LB
########################################
echo ">> Creating load balancer: ${LB_NAME}"
if ! os loadbalancer show "${LB_NAME}" >/dev/null 2>&1; then
  # You can use --vip-network-id too, but --vip-subnet-id is the common “you must have a subnet” prerequisite.
  os loadbalancer create --name "${LB_NAME}" --vip-subnet-id "${SUBNET_ID}" --provider ovn  >/dev/null
else
  echo ">> Load balancer already exists; reusing."
fi

LB_ID="$(os loadbalancer show "${LB_NAME}" -f value -c id)"
LB_VIP="$(os loadbalancer show "${LB_ID}" -f value -c vip_address)"
echo ">> LB ID: ${LB_ID}"
echo ">> LB VIP: ${LB_VIP}"

wait_for_lb_status "${LB_ID}" ACTIVE 900

########################################
# Create listener
########################################
echo ">> Creating listener: ${LISTENER_NAME} (${LB_PROTOCOL}:${LB_PORT})"
if ! os loadbalancer listener show "${LISTENER_NAME}" >/dev/null 2>&1; then
  os loadbalancer listener create \
    --name "${LISTENER_NAME}" \
    --protocol "${LB_PROTOCOL}" \
    --protocol-port "${LB_PORT}" \
    "${LB_ID}" >/dev/null
else
  echo ">> Listener already exists; reusing."
fi

LISTENER_ID="$(os loadbalancer listener show "${LISTENER_NAME}" -f value -c id)"
wait_for_lb_status "${LB_ID}" ACTIVE 900

########################################
# Create pool
########################################
echo ">> Creating pool: ${POOL_NAME} (algo=${LB_ALGO})"
if ! os loadbalancer pool show "${POOL_NAME}" >/dev/null 2>&1; then
  os loadbalancer pool create \
    --name "${POOL_NAME}" \
    --protocol "${LB_PROTOCOL}" \
    --lb-algorithm "${LB_ALGO}" \
    --listener "${LISTENER_ID}" >/dev/null
else
  echo ">> Pool already exists; reusing."
fi

POOL_ID="$(os loadbalancer pool show "${POOL_NAME}" -f value -c id)"
wait_for_lb_status "${LB_ID}" ACTIVE 900

########################################
# Create health monitor (optional)
########################################
if [[ "${DISABLE_HM}" != "1" ]]; then
  echo ">> Creating health monitor: ${HM_NAME} (type=${HM_TYPE})"
  # There isn't a universally reliable "show by name" for health monitors in all clouds,
  # so just attempt create and ignore if it already exists by ID in your env.
  # If you want strict idempotency, set DISABLE_HM=1 or extend this to track HM_ID externally.
  if ! os loadbalancer healthmonitor list -f value -c id -c name | awk '{print $2}' | grep -qx "${HM_NAME}"; then
    os loadbalancer healthmonitor create \
      --name "${HM_NAME}" \
      --type "${HM_TYPE}" \
      --delay "${HM_DELAY}" \
      --timeout "${HM_TIMEOUT}" \
      --max-retries "${HM_RETRIES}" \
      "${POOL_ID}" >/dev/null
  else
    echo ">> Health monitor already exists (by name); reusing."
  fi
  wait_for_lb_status "${LB_ID}" ACTIVE 900
else
  echo ">> Health monitor disabled (DISABLE_HM=1)."
fi

########################################
# Optional: create backend servers and add members
########################################
if [[ "${CREATE_BACKENDS}" == "1" ]]; then
  echo "== Optional backend creation enabled =="

  echo ">> Creating keypair: ${KEY_NAME}"
  if ! os keypair show "${KEY_NAME}" >/dev/null 2>&1; then
    os keypair create "${KEY_NAME}" >/dev/null
  else
    echo ">> Keypair already exists; reusing."
  fi

  echo ">> Creating security group: ${SECGRP}"
  if ! os security group show "${SECGRP}" >/dev/null 2>&1; then
    os security group create "${SECGRP}" >/dev/null
    os security group rule create --protocol tcp --dst-port 22 "${SECGRP}" >/dev/null || true
    os security group rule create --protocol tcp --dst-port "${LB_PORT}" "${SECGRP}" >/dev/null || true
    os security group rule create --protocol icmp "${SECGRP}" >/dev/null || true
  else
    echo ">> Security group already exists; reusing."
  fi

  # NOTE: This assumes your cloud allows ports on this tenant net without extra router work.
  # If you need external reachability, you’ll need a router + external gateway; that’s environment-specific.
  # We'll *not* create a router by default to keep this “minimal”, but you can extend it.

  BACKEND_IPS=()
  for i in $(seq 1 "${BACKEND_COUNT}"); do
    SNAME="${NAME_PREFIX}-backend-${i}"
    echo ">> Creating server: ${SNAME} (image=${IMAGE}, flavor=${FLAVOR})"
    if ! os server show "${SNAME}" >/dev/null 2>&1; then
      os server create "${SNAME}" \
        --image "${IMAGE}" \
        --flavor "${FLAVOR}" \
        --key-name "${KEY_NAME}" \
        --network "${NET_ID}" \
        --security-group "${SECGRP}" >/dev/null
    else
      echo ">> Server already exists; reusing."
    fi

    SID="$(os server show "${SNAME}" -f value -c id)"
    wait_for_server_active "${SID}" 900

    # Grab a fixed IP on our subnet
    # openstack server show -c addresses prints "net=IP;..." which we parse.
    ADDRS="$(os server show "${SID}" -f value -c addresses)"
    # Take the first IPv4-looking address from the addresses field.
    IP="$(echo "${ADDRS}" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
    if [[ -z "${IP}" ]]; then
      echo "!! Could not determine fixed IP for ${SNAME}. addresses=${ADDRS}" >&2
      exit 1
    fi
    echo ">> ${SNAME} fixed IP: ${IP}"
    BACKEND_IPS+=("${IP}")
  done

  echo ">> Adding members to pool: ${POOL_NAME}"
  for ip in "${BACKEND_IPS[@]}"; do
    # Member create is usually idempotent by address+protocol-port, but name helps you spot them.
    os loadbalancer member create \
      --subnet-id "${SUBNET_ID}" \
      --address "${ip}" \
      --protocol-port "${LB_PORT}" \
      "${POOL_ID}" >/dev/null
    wait_for_lb_status "${LB_ID}" ACTIVE 900
  done
fi

########################################
# Final summary
########################################
echo
echo "== Done =="
echo "LB Name:      ${LB_NAME}"
echo "LB ID:        ${LB_ID}"
echo "LB VIP:       ${LB_VIP}"
echo "Listener ID:  ${LISTENER_ID}"
echo "Pool ID:      ${POOL_ID}"
echo
echo "Useful checks:"
echo "  os loadbalancer show ${LB_ID}"
echo "  os loadbalancer listener list --loadbalancer ${LB_ID}"
echo "  os loadbalancer pool list --loadbalancer ${LB_ID}"
echo "  os loadbalancer member list ${POOL_ID}"
echo
echo "If you want auto-cleanup:"
echo "  DO_CLEANUP=1 ./$0"
