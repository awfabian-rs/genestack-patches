#!/usr/bin/env bash
set -euo pipefail

# Dump a MariaDB/MySQL database from a Kubernetes Service via kubectl port-forward.
#
# Behavior:
# - Starts a background port-forward to the DB service
# - Waits until the local forwarded port is listening
# - Detects whether mysqldump supports --column-statistics
# - Uses --column-statistics=0 only when the client supports it
# - Dumps the selected database to a timestamped .sql.gz file
# - Cleans up the background port-forward on exit
#
# Defaults can be overridden with environment variables:
#   NAMESPACE=openstack
#   SERVICE=mariadb-cluster-primary
#   SECRET_NAME=mariadb
#   SECRET_KEY=root-password
#   DB_USER=root
#   DATABASE_NAME=neutron
#   LOCAL_PORT=13306
#   REMOTE_PORT=3306
#   OUTPUT_DIR=/tmp
#
# Example:
#   DATABASE_NAME=neutron ./dump-db.sh

NAMESPACE="${NAMESPACE:-openstack}"
SERVICE="${SERVICE:-mariadb-cluster-primary}"
SECRET_NAME="${SECRET_NAME:-mariadb}"
SECRET_KEY="${SECRET_KEY:-root-password}"
DB_USER="${DB_USER:-root}"
DATABASE_NAME="${DATABASE_NAME:-neutron}"
LOCAL_PORT="${LOCAL_PORT:-13306}"
REMOTE_PORT="${REMOTE_PORT:-3306}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"

PF_PID=""
PF_LOG=""

cleanup() {
  local rc=$?
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
    wait "${PF_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_LOG}" && -f "${PF_LOG}" ]]; then
    rm -f "${PF_LOG}"
  fi
  exit "${rc}"
}
trap cleanup EXIT INT TERM

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

require_cmd kubectl
require_cmd mysqldump
require_cmd gzip
require_cmd base64
require_cmd ss

mkdir -p "${OUTPUT_DIR}"

OUTPUT_FILE="${OUTPUT_DIR}/${DATABASE_NAME}-$(date +%s).sql.gz"
PF_LOG="$(mktemp /tmp/kubectl-port-forward.XXXXXX.log)"

echo "Checking local port ${LOCAL_PORT}..." >&2
if ss -ltn "( sport = :${LOCAL_PORT} )" | grep -q ":${LOCAL_PORT}"; then
  echo "ERROR: local port ${LOCAL_PORT} is already in use" >&2
  echo "Try another LOCAL_PORT, for example: LOCAL_PORT=23306 $0" >&2
  exit 1
fi

echo "Checking Service and endpoints..." >&2
kubectl -n "${NAMESPACE}" get svc "${SERVICE}" >/dev/null

if ! kubectl -n "${NAMESPACE}" get endpoints "${SERVICE}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
  echo "WARNING: Service ${SERVICE} appears to have no ready endpoints right now." >&2
  echo "The port-forward may listen locally but still not reach a database pod." >&2
fi

echo "Starting port-forward: 127.0.0.1:${LOCAL_PORT} -> ${SERVICE}:${REMOTE_PORT}" >&2
kubectl -n "${NAMESPACE}" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" --address 127.0.0.1 >"${PF_LOG}" 2>&1 &
PF_PID=$!

echo "Waiting for port-forward to become ready..." >&2
for _ in $(seq 1 30); do
  if ss -ltn "( sport = :${LOCAL_PORT} )" | grep -q ":${LOCAL_PORT}"; then
    break
  fi
  if ! kill -0 "${PF_PID}" 2>/dev/null; then
    echo "ERROR: kubectl port-forward exited early" >&2
    sed -n '1,120p' "${PF_LOG}" >&2 || true
    exit 1
  fi
  sleep 1
done

if ! ss -ltn "( sport = :${LOCAL_PORT} )" | grep -q ":${LOCAL_PORT}"; then
  echo "ERROR: port-forward did not become ready in time" >&2
  sed -n '1,120p' "${PF_LOG}" >&2 || true
  exit 1
fi

echo "Fetching database password from secret ${SECRET_NAME}/${SECRET_KEY}..." >&2
DB_PASSWORD="$(
  kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" \
    -o "jsonpath={.data.${SECRET_KEY}}" | base64 -d
)"

MYSQDUMP_EXTRA_ARGS=()

# Only pass --column-statistics=0 if this mysqldump supports it.
if mysqldump --help 2>/dev/null | grep -q -- '--column-statistics'; then
  MYSQDUMP_EXTRA_ARGS+=(--column-statistics=0)
  echo "mysqldump supports --column-statistics; using --column-statistics=0" >&2
else
  echo "mysqldump does not support --column-statistics; not using it" >&2
fi

echo "Starting dump of database '${DATABASE_NAME}' to ${OUTPUT_FILE}..." >&2

# Use MYSQL_PWD so the password is not exposed in the process list.
MYSQL_PWD="${DB_PASSWORD}" mysqldump \
  --host=127.0.0.1 \
  --port="${LOCAL_PORT}" \
  --user="${DB_USER}" \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  "${MYSQDUMP_EXTRA_ARGS[@]}" \
  "${DATABASE_NAME}" | gzip > "${OUTPUT_FILE}"

echo "Dump complete: ${OUTPUT_FILE}" >&2

# Optional sanity check: ensure the gzip contains some uncompressed bytes.
UNCOMPRESSED_BYTES="$(gzip -dc "${OUTPUT_FILE}" | wc -c | tr -d '[:space:]')"
if [[ "${UNCOMPRESSED_BYTES}" -eq 0 ]]; then
  echo "WARNING: dump file exists but contains zero uncompressed bytes" >&2
  echo "This usually means mysqldump produced no SQL on stdout." >&2
  exit 1
fi

echo "Uncompressed SQL size: ${UNCOMPRESSED_BYTES} bytes" >&2
