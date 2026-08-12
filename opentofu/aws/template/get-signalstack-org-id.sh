#!/usr/bin/env bash
# get-signalstack-org-id.sh — fetch the signal-stack network_service org id
# from the dpg Postgres, AFTER the signals stack is deployed.
#
# This id is the aggregator's `global.signalstack.actingOrgId`
# (organization row of type 'network_service').
#
# Usage:
#   ./get-signalstack-org-id.sh                 # prints the org id to stdout
#   ORG_ID=$(./get-signalstack-org-id.sh)       # capture it
#
# Overridable via env: SIGNALS_NS, CS_NS, PG_STS, PG_DB, PG_USER,
#                      PG_SECRET, PG_SECRET_KEY, ORG_TYPE
set -euo pipefail

SIGNALS_NS="${SIGNALS_NS:-signals}"           # ns holding the dpg-postgres secret
CS_NS="${CS_NS:-common-services}"             # ns holding the shared Postgres
PG_STS="${PG_STS:-common-services-postgresql}"
PG_DB="${PG_DB:-dpg}"
PG_USER="${PG_USER:-dpg}"
PG_SECRET="${PG_SECRET:-dpg-postgres}"
PG_SECRET_KEY="${PG_SECRET_KEY:-password}"
ORG_TYPE="${ORG_TYPE:-network_service}"

command -v kubectl >/dev/null || { echo "ERROR: kubectl not installed" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable; check kubeconfig" >&2; exit 1; }

PGPW="$(kubectl -n "$SIGNALS_NS" get secret "$PG_SECRET" \
          -o jsonpath="{.data.$PG_SECRET_KEY}" 2>/dev/null | base64 -d || true)"
[[ -n "$PGPW" ]] || { echo "ERROR: could not read $PG_SECRET/$PG_SECRET_KEY in ns $SIGNALS_NS" >&2; exit 1; }

# -tA = tuples-only, unaligned (bare value). Single row expected.
ORG_ID="$(kubectl -n "$CS_NS" exec "statefulset/$PG_STS" -- \
  env PGPASSWORD="$PGPW" psql -U "$PG_USER" -d "$PG_DB" -tAc \
  "SELECT id FROM organization WHERE type='${ORG_TYPE}' ORDER BY created_at LIMIT 1;" 2>/dev/null \
  | tr -d '[:space:]')"

if [[ -z "$ORG_ID" ]]; then
  echo "ERROR: no organization of type '${ORG_TYPE}' found in $PG_DB." >&2
  echo "       Is the signals stack fully deployed + migrate-job complete?" >&2
  exit 1
fi

echo "$ORG_ID"
