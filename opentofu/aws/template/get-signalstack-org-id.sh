#!/usr/bin/env bash
# get-signalstack-org-id.sh — fetch the signal-stack network_service org id
# from the dpg Postgres, AFTER the signals stack is deployed.
#
# This id is the aggregator's `global.signalstack.actingOrgId`
# (organization row of type 'network_service').
#
# Works against BOTH backends:
#
#   in-cluster  the Bitnami Postgres StatefulSet in common-services. The query
#               runs via `kubectl exec` into that pod, as it always has.
#   RDS         a managed Postgres reachable only from inside the VPC. There is
#               no pod to exec into — with RDS the Bitnami subchart is disabled
#               (postgresql.enabled=false), so the StatefulSet does not exist.
#               The query instead runs in a short-lived pod scheduled onto an EKS
#               node, which is the same path the common-services postgres
#               bootstrap Job uses to reach RDS.
#
# The backend is chosen from the host the signals API is ACTUALLY configured
# with, not from what happens to be deployed. That distinction matters during a
# migration: if the in-cluster StatefulSet is still up while the API has already
# been repointed at RDS, keying off "does the StatefulSet exist" would query the
# old database and return a stale or missing id — wrong, and silently so.
#
# Usage:
#   ./get-signalstack-org-id.sh                 # prints the org id to stdout
#   ORG_ID=$(./get-signalstack-org-id.sh)       # capture it
#
# stdout is only ever the bare id; all progress goes to stderr, so the capture
# form above is unchanged.
#
# Overridable via env: SIGNALS_NS, CS_NS, CS_REL, PG_STS, PG_HOST, PG_PORT,
#                      PG_DB, PG_USER, PG_SECRET, PG_SECRET_KEY, ORG_TYPE,
#                      PSQL_IMAGE
#
# Set PG_HOST explicitly to bypass detection entirely (e.g. to query a database
# the charts do not know about).
set -euo pipefail

SIGNALS_NS="${SIGNALS_NS:-signals}"           # ns holding the dpg-postgres secret
CS_NS="${CS_NS:-common-services}"             # ns holding the shared Postgres
CS_REL="${CS_REL:-common-services}"           # helm release name in CS_NS
PG_STS="${PG_STS:-common-services-postgresql}"
PG_PORT="${PG_PORT:-5432}"
PG_DB="${PG_DB:-dpg}"
PG_USER="${PG_USER:-dpg}"
PG_SECRET="${PG_SECRET:-dpg-postgres}"
PG_SECRET_KEY="${PG_SECRET_KEY:-password}"
ORG_TYPE="${ORG_TYPE:-network_service}"
# Matches common-services' postgresBootstrap.image, so RDS deployments already
# pull this image and no new dependency is introduced.
PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"

log() { echo "$*" >&2; }

command -v kubectl >/dev/null || { log "ERROR: kubectl not installed"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { log "ERROR: cluster unreachable; check kubeconfig"; exit 1; }

SQL="SELECT id FROM organization WHERE type='${ORG_TYPE}' ORDER BY created_at LIMIT 1;"

# ── Resolve which Postgres the signals API is pointed at ─────────────────────
# Order: explicit override -> the API's own ConfigMap (authoritative: it is the
# database the app writes the organization row into) -> the common-services
# release values (RDS endpoint, injected by the opentofu output-file overlay)
# -> the in-cluster service.
if [[ -n "${PG_HOST:-}" ]]; then
  log "postgres host: $PG_HOST (from PG_HOST)"
else
  # Name-agnostic: find whichever ConfigMap in the signals ns carries the key,
  # rather than depending on the api release's fullname.
  PG_HOST="$(kubectl -n "$SIGNALS_NS" get configmap -o \
    jsonpath='{range .items[*]}{.data.POSTGRES_HOST}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' | head -n1 || true)"

  if [[ -n "$PG_HOST" ]]; then
    log "postgres host: $PG_HOST (from the signals API ConfigMap)"
  else
    PG_HOST="$(helm -n "$CS_NS" get values "$CS_REL" -a -o json 2>/dev/null \
      | sed -n 's/.*"postgres":{[^}]*"host":"\([^"]*\)".*/\1/p' | head -n1 || true)"
    if [[ -n "$PG_HOST" ]]; then
      log "postgres host: $PG_HOST (from the $CS_REL release values)"
    else
      PG_HOST="${PG_STS}.${CS_NS}.svc.cluster.local"
      log "postgres host: $PG_HOST (fallback: in-cluster default)"
    fi
  fi
fi

# In-cluster iff the host resolves to the StatefulSet's own service AND that
# StatefulSet is actually there. Anything else is treated as external (RDS).
MODE="rds"
if [[ "$PG_HOST" == "$PG_STS"* ]] \
   && kubectl -n "$CS_NS" get "statefulset/$PG_STS" >/dev/null 2>&1; then
  MODE="in-cluster"
fi
log "backend: $MODE"

if [[ "$MODE" == "in-cluster" ]]; then
  # Unchanged from the original: exec into the Postgres pod and use its local
  # socket. Kept byte-for-byte so a working in-cluster deploy cannot regress.
  PGPW="$(kubectl -n "$SIGNALS_NS" get secret "$PG_SECRET" \
            -o jsonpath="{.data.$PG_SECRET_KEY}" 2>/dev/null | base64 -d || true)"
  [[ -n "$PGPW" ]] || { log "ERROR: could not read $PG_SECRET/$PG_SECRET_KEY in ns $SIGNALS_NS"; exit 1; }

  # -tA = tuples-only, unaligned (bare value). Single row expected.
  ORG_ID="$(kubectl -n "$CS_NS" exec "statefulset/$PG_STS" -- \
    env PGPASSWORD="$PGPW" psql -U "$PG_USER" -d "$PG_DB" -tAc "$SQL" 2>/dev/null \
    | tr -d '[:space:]')"
else
  # RDS: no pod to exec into. Run psql in a throwaway pod on an EKS node, whose
  # SG is the one the RDS security group allows on 5432.
  #
  # The pod runs in SIGNALS_NS so it can read the password via secretKeyRef —
  # the password is therefore never placed in the pod spec, an argv, or this
  # shell. (Secrets cannot be referenced across namespaces, which is why this
  # does not run in CS_NS.)
  kubectl -n "$SIGNALS_NS" get secret "$PG_SECRET" >/dev/null 2>&1 \
    || { log "ERROR: secret $PG_SECRET not found in ns $SIGNALS_NS"; exit 1; }

  POD="orgid-$(date +%s)-$RANDOM"
  OVERRIDES=$(cat <<JSON
{
  "apiVersion": "v1",
  "spec": {
    "restartPolicy": "Never",
    "containers": [{
      "name": "psql",
      "image": "${PSQL_IMAGE}",
      "command": ["psql","-h","${PG_HOST}","-p","${PG_PORT}","-U","${PG_USER}","-d","${PG_DB}","-tAc","${SQL}"],
      "env": [
        {"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"${PG_SECRET}","key":"${PG_SECRET_KEY}"}}},
        {"name":"PGCONNECT_TIMEOUT","value":"10"}
      ]
    }]
  }
}
JSON
)
  # --rm deletes the pod on exit; --quiet keeps stdout to the query result only.
  ORG_ID="$(kubectl -n "$SIGNALS_NS" run "$POD" \
    --rm --attach --restart=Never --quiet \
    --pod-running-timeout=2m \
    --image="$PSQL_IMAGE" \
    --overrides="$OVERRIDES" 2>/dev/null \
    | tr -d '[:space:]')"
fi

if [[ -z "$ORG_ID" ]]; then
  log "ERROR: no organization of type '${ORG_TYPE}' found in $PG_DB on $PG_HOST."
  log "       Is the signals stack fully deployed + migrate-job complete?"
  if [[ "$MODE" == "rds" ]]; then
    log "       RDS notes: the app roles/databases must already exist (the"
    log "       common-services postgresBootstrap Job creates them), and the pod"
    log "       must be able to reach $PG_HOST:$PG_PORT. Re-run with the psql"
    log "       command by hand if you need the connection error:"
    log "         kubectl -n $SIGNALS_NS run pgtest --rm -it --restart=Never \\"
    log "           --image=$PSQL_IMAGE -- psql -h $PG_HOST -U $PG_USER -d $PG_DB"
  fi
  exit 1
fi

echo "$ORG_ID"
