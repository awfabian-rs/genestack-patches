#!/usr/bin/env bash

# https://chatgpt.com/g/g-p-69950a2a75ac8191be47f8cc0fba2d47-kube-ovn-upgrade/c/699f6410-2c90-832b-a2ab-97bd61c9d8f6
# This does:
# - discovers ovn-central pods
# - collects pod IPs (and also shows node name for context)
# - from each source pod, tries:
#     - TLS list-dbs to every destination IP on NB port 6641
#     - TLS list-dbs to every destination IP on SB port 6642

prints a clear PASS/FAIL matrix
set -euo pipefail

NS="kube-system"
LABEL="app=ovn-central"
CONTAINER="ovn-central"

NB_PORT=6641
SB_PORT=6642
TIMEOUT=5

# Discover pods
mapfile -t PODS < <(kubectl -n "$NS" get pod -l "$LABEL" -o name)

if [[ ${#PODS[@]} -lt 1 ]]; then
  echo "No ovn-central pods found in namespace $NS with label $LABEL" >&2
  exit 1
fi

# Collect pod metadata: name, podIP, nodeName
declare -A POD_IP POD_NODE POD_SHORT
for p in "${PODS[@]}"; do
  short="${p#pod/}"
  POD_SHORT["$p"]="$short"
  POD_IP["$p"]="$(kubectl -n "$NS" get "$p" -o jsonpath='{.status.podIP}')"
  POD_NODE["$p"]="$(kubectl -n "$NS" get "$p" -o jsonpath='{.spec.nodeName}')"
done

echo "Discovered ovn-central pods:"
for p in "${PODS[@]}"; do
  echo "  ${POD_SHORT[$p]}  podIP=${POD_IP[$p]}  node=${POD_NODE[$p]}"
done
echo

# Helper to run ovsdb-client from inside a pod
run_list_dbs() {
  local src_pod="$1"
  local dst_ip="$2"
  local port="$3"

  kubectl -n "$NS" exec -c "$CONTAINER" "$src_pod" -- \
    ovsdb-client \
      -C /var/run/tls/cacert \
      -p /var/run/tls/key \
      -c /var/run/tls/cert \
      -t "$TIMEOUT" \
      list-dbs "ssl:${dst_ip}:${port}"
}

check_one() {
  local src_pod="$1"
  local dst_ip="$2"
  local port="$3"
  local expect_db="$4"

  local out rc
  set +e
  out="$(run_list_dbs "$src_pod" "$dst_ip" "$port" 2>&1)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "FAIL rc=$rc"
    echo "  $out" | sed 's/^/  /'
    return 1
  fi

  # Basic sanity: ensure expected DB is listed (OVN_Northbound or OVN_Southbound)
  if echo "$out" | tr -d '\r' | grep -qE "(^|[[:space:]])${expect_db}([[:space:]]|$)"; then
    echo "PASS"
    return 0
  else
    echo "WARN (connected, but did not see ${expect_db})"
    echo "  Output:"
    echo "  $out" | sed 's/^/  /'
    return 2
  fi
}

print_header() {
  local title="$1"
  local port="$2"
  echo "=============================="
  echo "$title (port $port)"
  echo "=============================="
}

# Build list of destination IPs (pod IPs)
DEST_IPS=()
for p in "${PODS[@]}"; do
  DEST_IPS+=("${POD_IP[$p]}")
done

# NB matrix
print_header "OVN NB SSL connectivity (list-dbs should include OVN_Northbound)" "$NB_PORT"
for src in "${PODS[@]}"; do
  echo
  echo "From ${POD_SHORT[$src]} (${POD_IP[$src]} on ${POD_NODE[$src]}):"
  for dst_ip in "${DEST_IPS[@]}"; do
    printf "  -> %-15s : " "$dst_ip"
    check_one "$src" "$dst_ip" "$NB_PORT" "OVN_Northbound" || true
  done
done
echo

# SB matrix
print_header "OVN SB SSL connectivity (list-dbs should include OVN_Southbound)" "$SB_PORT"
for src in "${PODS[@]}"; do
  echo
  echo "From ${POD_SHORT[$src]} (${POD_IP[$src]} on ${POD_NODE[$src]}):"
  for dst_ip in "${DEST_IPS[@]}"; do
    printf "  -> %-15s : " "$dst_ip"
    check_one "$src" "$dst_ip" "$SB_PORT" "OVN_Southbound" || true
  done
done
echo

echo "Done."
