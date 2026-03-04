#!/usr/bin/env bash
set -euo pipefail

# This script creates the minimum Neutron-owned OVN objects (Port_Group + ACLs)
# that are known to disappear in the kube-ovn-controller restart bug, and that
# neutron-ovn-db-sync-util can later recreate.
#
# I (Adam) verified this works. I can:
# 1. Run the script
# 2. Run `kubectl ko nbctl list acl | \
#         grep neutron:security_group_rule_id`
#    and see the ACLs on a new installation
# 3. Run `kubectl -n kube-system rollout restart deployment/kube-ovn-controller`
# 4. Run the grep again and see the ACLs gone on Kube-OVN v1.13.15
#    (The first affected version.)
# 5. Run:
#    kubectl -n openstack exec -c neutron-server \
#    $(kubectl -n openstack get pod -l application=neutron,component=server -o name | shuf -n 1) \
#    -- /var/lib/openstack/bin/neutron-ovn-db-sync-util \
#    --config-file /etc/neutron/neutron.conf \
#    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini  --ovn-neutron_sync_mode add
#    and they come back.
#
# It assumes you run OpenStack CLI via:
#   kubectl -n openstack exec openstack-admin-client -- openstack <args...>
#
# Usage:
#   ./neutron-ovn-acl-repro.sh
#
# Optional env overrides:
#   OS_NS=openstack
#   OS_POD=openstack-admin-client
#   NET_NAME=ko-bug-net
#   SUBNET_NAME=ko-bug-subnet
#   SUBNET_CIDR=10.200.0.0/24
#   SG_NAME=ko-bug-sg
#   PORT_NAME=ko-bug-port
#   RULE_PROTO=tcp
#   RULE_DST_PORT=80

OS_NS="${OS_NS:-openstack}"
OS_POD="${OS_POD:-openstack-admin-client}"

NET_NAME="${NET_NAME:-ko-bug-net}"
SUBNET_NAME="${SUBNET_NAME:-ko-bug-subnet}"
SUBNET_CIDR="${SUBNET_CIDR:-10.200.0.0/24}"
SG_NAME="${SG_NAME:-ko-bug-sg}"
PORT_NAME="${PORT_NAME:-ko-bug-port}"

RULE_PROTO="${RULE_PROTO:-tcp}"
RULE_DST_PORT="${RULE_DST_PORT:-80}"

OS() {
  kubectl -n "${OS_NS}" exec "${OS_POD}" -- openstack "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

need_cmd kubectl

get_id() {
  # $1: resource type (e.g., network, subnet, security group, port)
  # $2: name
  OS "$1" show -f value -c id "$2" 2>/dev/null || true
}

ensure_network() {
  local id
  id="$(get_id network "${NET_NAME}")"
  if [[ -n "${id}" ]]; then
    echo "Network exists: ${NET_NAME} (${id})"
    return
  fi
  echo "Creating network: ${NET_NAME}"
  OS network create "${NET_NAME}" -f value -c id >/dev/null
  id="$(get_id network "${NET_NAME}")"
  echo "Created network: ${NET_NAME} (${id})"
}

ensure_subnet() {
  local id
  id="$(get_id subnet "${SUBNET_NAME}")"
  if [[ -n "${id}" ]]; then
    echo "Subnet exists: ${SUBNET_NAME} (${id})"
    return
  fi
  echo "Creating subnet: ${SUBNET_NAME} (${SUBNET_CIDR}) on ${NET_NAME}"
  OS subnet create \
    --network "${NET_NAME}" \
    --subnet-range "${SUBNET_CIDR}" \
    "${SUBNET_NAME}" \
    -f value -c id >/dev/null
  id="$(get_id subnet "${SUBNET_NAME}")"
  echo "Created subnet: ${SUBNET_NAME} (${id})"
}

ensure_sg() {
  local id
  id="$(get_id "security group" "${SG_NAME}")"
  if [[ -n "${id}" ]]; then
    echo "Security group exists: ${SG_NAME} (${id})"
    return
  fi
  echo "Creating security group: ${SG_NAME}"
  OS security group create "${SG_NAME}" -f value -c id >/dev/null
  id="$(get_id "security group" "${SG_NAME}")"
  echo "Created security group: ${SG_NAME} (${id})"
}

ensure_rule() {
  # Create a single rule. We'll check for an existing matching rule first.
  echo "Ensuring SG rule exists on ${SG_NAME}: ${RULE_PROTO} dst-port ${RULE_DST_PORT}"
  local existing
  existing="$(OS security group rule list "${SG_NAME}" -f value -c ID \
    --protocol "${RULE_PROTO}" 2>/dev/null | head -n1 || true)"

  # The CLI filter options vary across versions; to keep it simple and robust,
  # if *any* rule exists, we won't add another unless you want strict matching.
  if [[ -n "${existing}" ]]; then
    echo "At least one SG rule already exists on ${SG_NAME} (e.g. ${existing}); skipping create."
    return
  fi

  OS security group rule create \
    --protocol "${RULE_PROTO}" \
    --dst-port "${RULE_DST_PORT}" \
    "${SG_NAME}" \
    -f value -c id >/dev/null

  echo "Created SG rule on ${SG_NAME}"
}

ensure_port() {
  local id
  id="$(get_id port "${PORT_NAME}")"
  if [[ -n "${id}" ]]; then
    echo "Port exists: ${PORT_NAME} (${id})"
    return
  fi
  echo "Creating port: ${PORT_NAME} on ${NET_NAME} with SG ${SG_NAME}"
  OS port create \
    --network "${NET_NAME}" \
    --security-group "${SG_NAME}" \
    "${PORT_NAME}" \
    -f value -c id >/dev/null
  id="$(get_id port "${PORT_NAME}")"
  echo "Created port: ${PORT_NAME} (${id})"
}

print_summary() {
  echo
  echo "=== Summary ==="
  echo "Network:        ${NET_NAME}   (id: $(get_id network "${NET_NAME}"))"
  echo "Subnet:         ${SUBNET_NAME} (id: $(get_id subnet "${SUBNET_NAME}"))"
  echo "Security group: ${SG_NAME}    (id: $(get_id "security group" "${SG_NAME}"))"
  echo "Port:           ${PORT_NAME}  (id: $(get_id port "${PORT_NAME}"))"
  echo
  echo "Next steps (manual):"
  echo "  1) Verify Neutron-owned ACLs exist in OVN NB:"
  echo "       kubectl ko nbctl list acl | grep neutron:security_group_rule_id"
  echo
  echo "  2) Restart kube-ovn-controller (the repro trigger):"
  echo "       kubectl rollout restart deployment kube-ovn-controller -n kube-system"
  echo
  echo "  3) Verify the ACLs disappeared (if the bug exists):"
  echo "       kubectl ko nbctl list acl | grep neutron:security_group_rule_id"
  echo
  echo "  4) Recreate missing OVN objects from Neutron DB:"
  echo "       neutron-ovn-db-sync-util \\"
  echo "         --config-file /etc/neutron/neutron.conf \\"
  echo "         --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \\"
  echo "         --ovn-neutron_sync_mode add"
  echo
}

main() {
  echo "Using OpenStack CLI via: kubectl -n ${OS_NS} exec ${OS_POD} -- openstack ..."
  echo

  ensure_network
  ensure_subnet
  ensure_sg
  ensure_rule
  ensure_port
  print_summary
}

main "$@"
