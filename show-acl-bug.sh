#!/usr/bin/env bash
# This script demonstrates loss of ACLs on affected Kube-OVN versions
# This appears to include the v1.13 line >= 1.13.15, and
# The entire v1.14.x line
# It does NOT include the v1.15.x line, which should have gotten this
# fixed by Kube-OVN PR 5995
# https://github.com/kubeovn/kube-ovn/issues/5995
#
# I tested it on Kube-OVN v1.13.14, which doesn't have the bug
# v1.13.14 shows (PRESENT) for ACLs after run
# v1.13.15 shows (ABSENT) for ACLs after run

set -euo pipefail

# Namespace / container / DB socket for ovn-nbctl
NS="${NS:-kube-system}"
OVN_CENTRAL_CONTAINER="${OVN_CENTRAL_CONTAINER:-ovn-central}"
OVN_NB_DB="${OVN_NB_DB:-unix:/var/run/ovn/ovnnb_db.sock}"
TIMEOUT="${TIMEOUT:-10}"

# Artifacts
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/ovn-gc-repro-$(date +%s)}"
mkdir -p "$ARTIFACT_DIR"

# Restart behavior
RESTART_COMPONENT="${RESTART_COMPONENT:-kube-ovn-controller}"   # kube-ovn-controller or ovn-central
RESTART_NS="${RESTART_NS:-$NS}"
RESTART_KIND="${RESTART_KIND:-deployment}"                      # deployment is typical
RESTART_TIMEOUT="${RESTART_TIMEOUT:-300s}"

# ACL characteristics
ACL_PRIORITY="${ACL_PRIORITY:-100}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
need_cmd kubectl

nbctl() {
  local pod="$1"; shift
  kubectl -n "$NS" exec -c "$OVN_CENTRAL_CONTAINER" "$pod" -- \
    ovn-nbctl --db="$OVN_NB_DB" --timeout="$TIMEOUT" "$@"
}

pod_ready() {
  local pod="$1"
  kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | grep -q '^True$'
}

select_nb_pod() {
  local pod=""
  pod="$(kubectl -n "$NS" get pod -l app=ovn-central,ovn-nb-leader=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    kubectl -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout=180s >/dev/null 2>&1 || true
    if pod_ready "$pod" && nbctl "$pod" show >/dev/null 2>&1; then
      echo "$pod"
      return 0
    fi
  fi

  local candidates
  candidates="$(kubectl -n "$NS" get pod -l app=ovn-central \
              -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "$candidates" ]] || die "no ovn-central pods found (label app=ovn-central) in ns=$NS"

  local p
  for p in $candidates; do
    if ! pod_ready "$p"; then
      continue
    fi
    if nbctl "$p" show >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done

  die "could not find a usable ovn-central pod for NB"
}

# Snapshot helpers

snapshot_port_groups() {
  local pod="$1"
  local out="$2"
  nbctl "$pod" --format=csv --no-heading --columns=_uuid,name,acls,external_ids list Port_Group | sort > "$out"
  log "saved Port_Group snapshot: $out (lines=$(wc -l < "$out" | tr -d ' '))"
}

snapshot_neutron_acls() {
  local pod="$1"
  local out="$2"
  # grep for both styles: neutron:security_group_rule_id or neutron_security_group_rule_id
  nbctl "$pod" --format=csv --no-heading --columns=_uuid,priority,direction,action,match,external_ids list ACL \
    | egrep -i 'neutron:security_group_rule_id|neutron_security_group_rule_id' | sort > "$out" || true
  log "saved neutron-owned ACL snapshot: $out (lines=$(wc -l < "$out" | tr -d ' '))"
}

# Read Port_Group.<pg>.acls and output bare UUIDs one per line.
pg_acl_uuids() {
  local pod="$1"
  local pg="$2"
  local raw
  raw="$(nbctl "$pod" --data=bare --no-heading get Port_Group "$pg" acls 2>/dev/null || true)"
  raw="${raw//[\r\n]/}"
  echo "$raw" | sed -e 's/^\[//' -e 's/\]$//' -e 's/,/ /g' | tr ' ' '\n' | sed '/^$/d'
}

acl_fields() {
  local pod="$1"
  local uuid="$2"
  local pr dir act m ext

  pr="$(nbctl "$pod" --data=bare --no-heading get ACL "$uuid" priority 2>/dev/null || echo '')"
  dir="$(nbctl "$pod" --data=bare --no-heading get ACL "$uuid" direction 2>/dev/null || echo '')"
  act="$(nbctl "$pod" --data=bare --no-heading get ACL "$uuid" action 2>/dev/null || echo '')"
  m="$(nbctl "$pod" --data=bare --no-heading get ACL "$uuid" match 2>/dev/null || echo '' )"
  m="$(echo "$m" | sed -e 's/^"//' -e 's/"$//')"
  ext="$(nbctl "$pod" --data=bare --no-heading get ACL "$uuid" external_ids 2>/dev/null || echo '')"

  printf "%s|%s|%s|%s|%s\n" "$pr" "$dir" "$act" "$m" "$ext"
}

find_acl_uuid_in_pg() {
  local pod="$1"
  local pg="$2"
  local priority="$3"
  local direction="$4"
  local action="$5"
  local match="$6"

  local uuid
  # Normalize by removing ALL whitespace when comparing the match expression.
  local want_norm
  want_norm="$(printf '%s' "$match" | tr -d '[:space:]')"

  while read -r uuid; do
    local fields pr dir act m
    fields="$(acl_fields "$pod" "$uuid")"
    pr="${fields%%|*}"; fields="${fields#*|}"
    dir="${fields%%|*}"; fields="${fields#*|}"
    act="${fields%%|*}"; fields="${fields#*|}"
    m="${fields%%|*}"

    local m_norm
    m_norm="$(printf '%s' "$m" | tr -d '[:space:]')"

    if [[ "$pr" == "$priority" && "$dir" == "$direction" && "$act" == "$action" && "$m_norm" == "$want_norm" ]]; then
      echo "$uuid"
      return 0
    fi
  done < <(pg_acl_uuids "$pod" "$pg")

  return 1
}

create_and_tag_acl_on_pg() {
  local pod="$1"
  local pg="$2"
  local label="$3"
  local priority="$4"
  local direction="$5"
  local action="$6"
  local match="$7"

  # 1️⃣ Create ACL using the proper helper command
  nbctl "$pod" acl-add "$pg" "$direction" "$priority" "$match" "$action"

  # 2️⃣ Locate the ACL UUID (match whitespace-insensitive)
  local want_norm
  want_norm="$(printf '%s' "$match" | tr -d '[:space:]')"

  local uuid=""
  while read -r candidate; do
    fields="$(acl_fields "$pod" "$candidate")"
    pr="${fields%%|*}"; rest="${fields#*|}"
    dir="${rest%%|*}"; rest="${rest#*|}"
    act="${rest%%|*}"; rest="${rest#*|}"
    m="${rest%%|*}"

    m_norm="$(printf '%s' "$m" | tr -d '[:space:]')"

    if [[ "$pr" == "$priority" && "$dir" == "$direction" && "$act" == "$action" && "$m_norm" == "$want_norm" ]]; then
      uuid="$candidate"
      break
    fi
  done < <(pg_acl_uuids "$pod" "$pg")

  [[ -n "$uuid" ]] || die "Could not locate ACL after acl-add"

  # 3️⃣ Tag it
  nbctl "$pod" set ACL "$uuid" external_ids:test_repro="$label"

  log "created+tagged ACL $uuid label=$label on PG=$pg match=$match"
  echo "$uuid"
}

acl_present_by_uuid() {
  local pod="$1"
  local uuid="$2"

  if [[ -z "$uuid" ]]; then
    return 1
  fi
  local uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
  if ! echo "$uuid" | grep -E -q "$uuid_re"; then
    echo "WARNING: acl_present_by_uuid called with non-UUID value: '$uuid'" >&2
    return 1
  fi

  local out
  out="$(nbctl "$pod" --data=bare --no-heading -- --if-exists get ACL "$uuid" _uuid 2>/dev/null || true)"
  [[ -n "$out" ]]
}

restart_component() {
  log "restarting ${RESTART_KIND}/${RESTART_COMPONENT} in ns=${RESTART_NS}"
  kubectl -n "$RESTART_NS" rollout restart "${RESTART_KIND}/${RESTART_COMPONENT}" >/dev/null
  kubectl -n "$RESTART_NS" rollout status "${RESTART_KIND}/${RESTART_COMPONENT}" --timeout="$RESTART_TIMEOUT" >/dev/null
  log "${RESTART_COMPONENT} rollout complete"
}

main() {
  log "Artifacts: $ARTIFACT_DIR"

  local pod
  pod="$(select_nb_pod)"
  log "Selected NB-capable pod: $pod"

  # Determine Port_Group to observe
  local pg_candidate
  pg_candidate="$(nbctl "$pod" --format=csv --no-heading --columns=name list Port_Group | grep -x neutron_pg_drop || true)"
  local pg_use=""
  if [[ -n "$pg_candidate" ]]; then
    pg_use="neutron_pg_drop"
    log "Found neutron standard Port_Group: $pg_use"
  else
    # Will create temporary Port_Group for testing (if no neutron_pg_drop present)
    pg_use="test-pg-$(date +%s)"
    log "neutron_pg_drop not found; will create test Port_Group: $pg_use"
    nbctl "$pod" create Port_Group name="$pg_use" || die "failed to create Port_Group $pg_use"
  fi

  # Snapshot before
  snapshot_port_groups "$pod" "$ARTIFACT_DIR/port-groups.before.csv"
  snapshot_neutron_acls "$pod" "$ARTIFACT_DIR/neutron-acls.before.csv"

  # Unique match expressions each run to avoid duplicates.
  local base_port
  base_port="$(( ( $(date +%s) % 20000 ) + 20000 ))"

  log "creating 3 unique test ACLs (attached to Port_Group $pg_use)"
  local u1 u2 u3
  u1="$(create_and_tag_acl_on_pg "$pod" "$pg_use" "manual" "$ACL_PRIORITY" to-lport allow "ip4&&tcp&&ip4.src==203.0.113.254&&tcp.dst==${base_port}")"
  u2="$(create_and_tag_acl_on_pg "$pod" "$pg_use" "vendor-kubeovn" "$ACL_PRIORITY" to-lport allow "ip4&&tcp&&ip4.src==198.51.100.254&&tcp.dst==$((base_port+1))")"
  u3="$(create_and_tag_acl_on_pg "$pod" "$pg_use" "neutronish" "$ACL_PRIORITY" to-lport allow "ip4&&tcp&&ip4.src==192.0.2.254&&tcp.dst==$((base_port+2))")"

  printf "%s\n" "$u1" "$u2" "$u3" > "$ARTIFACT_DIR/test-acl-uuids.txt"
  log "saved test ACL UUIDs: $ARTIFACT_DIR/test-acl-uuids.txt"

  # Snapshot after create
  snapshot_port_groups "$pod" "$ARTIFACT_DIR/port-groups.after-create.csv"
  snapshot_neutron_acls "$pod" "$ARTIFACT_DIR/neutron-acls.after-create.csv"

  restart_component

  # Re-select NB-capable pod after restart (leader may change)
  pod="$(select_nb_pod)"
  log "Selected NB-capable pod after restart: $pod"

  snapshot_port_groups "$pod" "$ARTIFACT_DIR/port-groups.after-restart.csv"
  snapshot_neutron_acls "$pod" "$ARTIFACT_DIR/neutron-acls.after-restart.csv"

  diff -u "$ARTIFACT_DIR/port-groups.before.csv" "$ARTIFACT_DIR/port-groups.after-restart.csv" > "$ARTIFACT_DIR/diff-port-groups.txt" || true
  diff -u "$ARTIFACT_DIR/neutron-acls.before.csv" "$ARTIFACT_DIR/neutron-acls.after-restart.csv" > "$ARTIFACT_DIR/diff-neutron-acls.txt" || true
  log "diffs saved: $ARTIFACT_DIR/diff-port-groups.txt , $ARTIFACT_DIR/diff-neutron-acls.txt"

  # Count neutron-owned ACL rows before/after
  local before_count after_count
  before_count="$(wc -l < "$ARTIFACT_DIR/neutron-acls.before.csv" 2>/dev/null || echo 0)"
  after_count="$(wc -l < "$ARTIFACT_DIR/neutron-acls.after-restart.csv" 2>/dev/null || echo 0)"
  log "neutron-owned ACL count: before=$before_count after=$after_count"
  if [[ "$after_count" -lt "$before_count" ]]; then
    log "POTENTIAL BUG: neutron-owned ACL count decreased (${before_count} -> ${after_count})"
  fi

  # Check test ACL uuids presence
  local pair label uuid
  for pair in "manual:$u1" "vendor-kubeovn:$u2" "neutronish:$u3"; do
    label="${pair%%:*}"
    uuid="${pair##*:}"
    if acl_present_by_uuid "$pod" "$uuid"; then
      log "PRESENT after restart: $label ($uuid)"
    else
      log "MISSING after restart: $label ($uuid)"
    fi
  done

  log "Artifacts available in: $ARTIFACT_DIR"
  log "done"
}

main "$@"
