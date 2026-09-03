#!/usr/bin/env bash
# create-permissions-boundary.sh — create the IAM permissions-boundary policy
# this repo's roles attach to, ONCE per AWS account.
#
# ── Who runs this ────────────────────────────────────────────────────────────
# An account ADMIN, once, when baselining a new account. NOT part of install.sh
# and not runnable by the deploy principal: Sanketika's `DevOpsEngineer`
# permission set explicitly denies editing the boundary, which is the point —
# a role capped by a boundary must not be able to raise its own ceiling.
#
# ── Pick your own name ───────────────────────────────────────────────────────
# --name is REQUIRED and has no default, deliberately. Every organisation uses
# its own (`SanketikaWorkloadBoundary`, `AcmeWorkloadBoundary`, …) so two teams
# sharing these modules can never collide on one policy, and nobody creates a
# second copy of somebody else's. Whatever you pass here goes verbatim into
# `global.permissions_boundary_policy_name` in <env>/global-values.yaml.
#
# ── What the policy does ─────────────────────────────────────────────────────
# Deny-only: it allows `*` and denies just the privilege-escalation set (IAM
# user/credential creation, organizations/sso/identitystore/account control
# planes, sts:AssumeRoot, and tampering with the boundary itself). A boundary
# GRANTS nothing — it is a ceiling on what an attached role can ever do — so a
# role that later needs a new AWS service needs no change here.
#
# Document lives in scripts/permissions-boundary.json next to this script, so it
# is reviewable in git rather than buried in a heredoc. __BOUNDARY_POLICY_ARN__
# in it is substituted with the policy's own ARN at create time (the
# self-tampering Deny has to name itself).
#
# ── Safety ───────────────────────────────────────────────────────────────────
# CREATE-ONLY. If a policy with that name already exists the script reports and
# exits 0 without touching it — existing accounts already carry a reviewed
# version and silently publishing a new default version would change the ceiling
# under every running role. Use --verify to diff instead, or --update to publish
# a new version deliberately.
#
# Usage:
#   ./create-permissions-boundary.sh --name AcmeWorkloadBoundary
#   ./create-permissions-boundary.sh --name AcmeWorkloadBoundary --dry-run
#   ./create-permissions-boundary.sh --name AcmeWorkloadBoundary --verify
#   ./create-permissions-boundary.sh --name AcmeWorkloadBoundary --update
#
# Needs: iam:GetPolicy, iam:CreatePolicy (+ iam:GetPolicyVersion for --verify,
#        iam:CreatePolicyVersion / ListPolicyVersions / DeletePolicyVersion for
#        --update, which prunes the oldest non-default version at the 5-version cap).
#
# --update asks for a typed confirmation. Set BOUNDARY_UPDATE_YES=1 to skip it in
# automation — deliberately not a flag, so it cannot be added by reflex.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DOC="${POLICY_DOC:-$SCRIPT_DIR/permissions-boundary.json}"

log() { echo "$*" >&2; }

command -v aws >/dev/null     || { log "ERROR: aws CLI not installed"; exit 1; }
command -v python3 >/dev/null || { log "ERROR: python3 not installed (used to normalise JSON)"; exit 1; }

NAME=""; DRY_RUN=""; VERIFY=""; UPDATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    NAME="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=yes; shift ;;
    --verify)  VERIFY=yes;  shift ;;
    --update)  UPDATE=yes;  shift ;;
    # Print the leading comment block, however long it grows. A hardcoded line
    # range silently truncates (or spills into code) the moment the header changes.
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         log "ERROR: unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  log "ERROR: --name is required."
  log "       Choose a name for YOUR organisation, e.g.:"
  log "         $0 --name AcmeWorkloadBoundary"
  log "       There is deliberately no default: each account owns its own policy,"
  log "       so two teams sharing these modules cannot collide on one."
  exit 1
fi
[[ -f "$POLICY_DOC" ]] || { log "ERROR: policy document not found: $POLICY_DOC"; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PARTITION="$(aws sts get-caller-identity --query 'Arn' --output text | cut -d: -f2)"
POLICY_ARN="arn:${PARTITION}:iam::${ACCOUNT_ID}:policy/${NAME}"

log "account:  $ACCOUNT_ID"
log "policy:   $POLICY_ARN"
log "document: $POLICY_DOC"

# The self-tampering Deny has to name the policy it lives in, which is not known
# until the ARN is composed above. Substituted here rather than templated at
# apply time so the committed file stays valid, reviewable JSON.
RENDERED="$(python3 - "$POLICY_DOC" "$POLICY_ARN" <<'PY'
import json, sys
doc = open(sys.argv[1]).read().replace("__BOUNDARY_POLICY_ARN__", sys.argv[2])
parsed = json.loads(doc)                       # fail loudly on malformed JSON
leftover = [t for t in json.dumps(parsed).split('"') if t.startswith("__") and t.endswith("__")]
if leftover:
    sys.exit(f"unsubstituted placeholder(s) in the policy document: {sorted(set(leftover))}")
print(json.dumps(parsed, sort_keys=True, separators=(",", ":")))
PY
)"

# Probe BEFORE reporting, so --dry-run cannot claim it would create a policy that
# already exists — a real run against that account is a no-op, and an admin
# checking first would otherwise be told the opposite.
POLICY_EXISTS=""
DEFAULT_VER=""
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  POLICY_EXISTS=yes
  DEFAULT_VER="$(aws iam get-policy --policy-arn "$POLICY_ARN" \
                   --query 'Policy.DefaultVersionId' --output text)"
fi

if [[ -n "$DRY_RUN" ]]; then
  log ""
  if [[ -n "$POLICY_EXISTS" ]]; then
    log "--dry-run: $POLICY_ARN ALREADY EXISTS (default version $DEFAULT_VER)."
    log "           A real run would change nothing. Use --verify to diff it"
    log "           against $(basename "$POLICY_DOC"), or --update to republish."
  else
    log "--dry-run: would create $POLICY_ARN with:"
    python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), indent=2))' "$RENDERED"
  fi
  exit 0
fi

# ── Does it already exist? (probed above) ────────────────────────────────────
if [[ -n "$POLICY_EXISTS" ]]; then
  log "exists:   yes (default version $DEFAULT_VER)"

  if [[ -n "$VERIFY" ]]; then
    LIVE="$(aws iam get-policy-version --policy-arn "$POLICY_ARN" \
              --version-id "$DEFAULT_VER" --query 'PolicyVersion.Document' --output json \
            | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",",":")))')"
    if [[ "$LIVE" == "$RENDERED" ]]; then
      log ""
      log "MATCH: the live policy is identical to $POLICY_DOC."
      exit 0
    fi
    log ""
    log "DIFFERS: the live policy does not match $POLICY_DOC."
    diff <(python3 -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1]),indent=2,sort_keys=True))' "$LIVE") \
         <(python3 -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1]),indent=2,sort_keys=True))' "$RENDERED") \
         && true
    log ""
    log "       < live in AWS    > this repo"
    log "       Treat the LIVE policy as authoritative unless you know otherwise:"
    log "       it is what every existing role in this account is capped by."
    exit 2
  fi

  if [[ -z "$UPDATE" ]]; then
    log ""
    log "Nothing to do — this script is create-only and will not modify an existing"
    log "policy. Every role in this account is already capped by it, so publishing a"
    log "new default version silently changes that ceiling."
    log ""
    log "  --verify   compare the live policy against $(basename "$POLICY_DOC")"
    log "  --update   publish a new default version (deliberate, admin-only)"
    log ""
    log "Nothing else to do: put the name in <env>/global-values.yaml —"
    log "  permissions_boundary_policy_name: \"$NAME\""
    exit 0
  fi

  log ""
  log "--update: publishing a new DEFAULT version of an in-use boundary."
  log "          Every role attached to it is re-capped IMMEDIATELY."
  log ""
  log "          $POLICY_DOC is maintained by hand. If it has never been"
  log "          reconciled against this account, run --verify first — otherwise"
  log "          this republishes an unreviewed ceiling over every attached role."
  log ""
  # Typed confirmation, not y/N: the cost of a wrong --update is every role in the
  # account silently re-capped, and there is no dry-run for it once published.
  if [[ -z "${BOUNDARY_UPDATE_YES:-}" ]]; then
    read -rp "Type the policy name to confirm ($NAME): " _confirm
    [[ "$_confirm" == "$NAME" ]] || { log "aborted: confirmation did not match"; exit 1; }
  fi

  # AWS caps a managed policy at 5 versions. Nothing prunes them, so repeated
  # --update eventually dies on LimitExceeded — at the worst possible moment,
  # since by then someone is mid-incident republishing a boundary. Drop the
  # oldest non-default version when at the cap. Never the default: it is what
  # every attached role is currently capped by.
  VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
                --query 'Versions[?IsDefaultVersion==`false`].[VersionId,CreateDate]' \
                --output text | sort -k2 | awk '{print $1}')"
  VERSION_COUNT="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
                     --query 'length(Versions)' --output text)"
  if [[ "$VERSION_COUNT" -ge 5 ]]; then
    OLDEST="$(printf '%s\n' "$VERSIONS" | head -n1)"
    [[ -n "$OLDEST" ]] || { log "ERROR: at the 5-version cap but no non-default version to prune"; exit 1; }
    log "          at the 5-version cap — deleting oldest non-default version $OLDEST"
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
  fi

  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "$RENDERED" --set-as-default >/dev/null
  log "done: new default version published"
  exit 0
fi

# ── Create ───────────────────────────────────────────────────────────────────
log "exists:   no — creating"
aws iam create-policy \
  --policy-name "$NAME" \
  --policy-document "$RENDERED" \
  --description "Permissions boundary for workload roles created by bluedots-automation. Deny-only: allows * and denies the privilege-escalation set." \
  >/dev/null

log "done: created $POLICY_ARN"
log ""
log "Next: set the name in <env>/global-values.yaml so the modules attach it —"
log "  _permissions_boundary_policy_name: &permissions_boundary_policy_name \"$NAME\""
log ""
log "Then grant the deploy principal iam:CreateRole (and friends) CONDITIONED on"
log "this boundary, so roles can only ever be created with it attached:"
log "  \"Condition\": { \"StringEquals\": { \"iam:PermissionsBoundary\": \"$POLICY_ARN\" } }"
