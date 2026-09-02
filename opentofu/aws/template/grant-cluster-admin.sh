#!/usr/bin/env bash
# grant-cluster-admin.sh — give an IAM principal cluster-admin on this EKS
# cluster via an ACCESS ENTRY, AFTER the cluster exists.
#
# Replaces the manual "add my role to the cluster's access entries in the
# console" step. Defaults to whoever is running it, so the common case is a bare
# `./grant-cluster-admin.sh` right after `install.sh create_tf_resources`.
#
# WHY A SCRIPT AND NOT TERRAFORM: the bastion's access entry IS terraform
# (modules/bastion/main.tf) because its principal is a role terraform itself
# creates — stable, and part of the cluster's desired state. A human's principal
# is neither: it changes with whoever runs the apply, and encoding "the caller"
# in state means the next engineer's apply revokes the previous one's access.
# Kept imperative and idempotent instead.
#
# ── The ARN conversion is the whole point ────────────────────────────────────
# `aws sts get-caller-identity` on an SSO session returns an STS *session* ARN:
#
#     arn:aws:sts::931110358895:assumed-role/AWSReservedSSO_DevOpsEngineer_42f5…/you@example.com
#
# EKS access entries take an IAM *role* ARN. Pasting the session ARN is the
# usual mistake — the API rejects it (InvalidParameterException), or worse the
# console accepts a hand-retyped variant that never matches at authentication
# time and the entry silently does nothing. Two transformations are needed:
#
#   sts -> iam, assumed-role -> role   drop the trailing session name
#   KEEP the path                      SSO roles really live at
#                                      /aws-reserved/sso.amazonaws.com/<region>/.
#                                      CreateAccessEntry validates principalArn
#                                      against IAM, so a hand-built PATHLESS ARN
#                                      names a role that does not exist and the
#                                      call fails with InvalidParameterException.
#                                      (Stripping the path is the rule for the
#                                      aws-auth ConfigMap — the opposite API.
#                                      Do not carry that habit over here.)
#
# Rather than reconstruct the path — the region segment is the Identity Center
# instance's, not necessarily the cluster's — the role name is looked up with
# `aws iam get-role`, which returns the real ARN whatever its path.
#
# ── Idempotency ──────────────────────────────────────────────────────────────
# Both halves tolerate already existing: create-access-entry treats
# ResourceInUseException as success, and associate-access-policy is an upsert
# for the same (principal, policy, scope). Safe to re-run, and safe to run
# against a cluster where the entry was already added by hand — which is the
# state most existing clusters are in.
#
# Usage:
#   ./grant-cluster-admin.sh                        # grant the current caller
#   ./grant-cluster-admin.sh <principal-arn>        # grant someone else
#   ./grant-cluster-admin.sh --list                 # show existing entries
#   ./grant-cluster-admin.sh --dry-run              # print what it would do
#
# Overridable via env: CLUSTER_NAME, AWS_REGION, ACCESS_POLICY_ARN, ACCESS_SCOPE
#
# Set CLUSTER_NAME explicitly to bypass detection (e.g. before a kubeconfig
# exists, or to target a cluster other than the current context).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_VALUES="${GLOBAL_VALUES:-$SCRIPT_DIR/global-values.yaml}"

# AmazonEKSClusterAdminPolicy = full admin, matching what the bastion gets and
# what the manual step granted. AmazonEKSAdminPolicy (no "Cluster") is the
# namespace-scoped one — override if you want to hand out something narrower.
ACCESS_POLICY_ARN="${ACCESS_POLICY_ARN:-arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy}"
ACCESS_SCOPE="${ACCESS_SCOPE:-cluster}"

log() { echo "$*" >&2; }

command -v aws >/dev/null || { log "ERROR: aws CLI not installed"; exit 1; }

DRY_RUN=""
LIST_ONLY=""
PRINCIPAL_ARN=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=yes ;;
    --list)    LIST_ONLY=yes ;;
    -h|--help) sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        log "ERROR: unknown flag: $arg"; exit 1 ;;
    *)         PRINCIPAL_ARN="$arg" ;;
  esac
done

# ── Which cluster ────────────────────────────────────────────────────────────
# Order: explicit override -> current kubeconfig context (which `aws eks
# update-kubeconfig` sets to the cluster ARN, so it carries the name, region AND
# account in one string) -> the <building_block>-<environment> the eks module
# builds its cluster_name from.
if [[ -n "${CLUSTER_NAME:-}" ]]; then
  log "cluster: $CLUSTER_NAME (from CLUSTER_NAME)"
else
  _ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$_ctx" =~ ^arn:aws[a-z-]*:eks:([a-z0-9-]+):([0-9]+):cluster/(.+)$ ]]; then
    CLUSTER_NAME="${BASH_REMATCH[3]}"
    : "${AWS_REGION:=${BASH_REMATCH[1]}}"
    log "cluster: $CLUSTER_NAME (from the current kubeconfig context)"
  elif [[ -f "$GLOBAL_VALUES" ]]; then
    # Anchors at the top of global-values.yaml; the eks module composes
    # cluster_name as "${building_block}-${environment}". Quotes optional in YAML,
    # so strip both. Not a YAML parser — these two lines are fixed by convention
    # and a mismatch fails loudly at the describe-cluster check below.
    _bb="$(sed -n 's/^_building_block:[[:space:]]*&building_block[[:space:]]*//p' "$GLOBAL_VALUES" | tr -d '"'"'" | head -1)"
    _env="$(sed -n 's/^_environment:[[:space:]]*&environment[[:space:]]*//p' "$GLOBAL_VALUES" | tr -d '"'"'" | head -1)"
    if [[ -n "$_bb" && -n "$_env" ]]; then
      CLUSTER_NAME="${_bb}-${_env}"
      log "cluster: $CLUSTER_NAME (derived from $(basename "$GLOBAL_VALUES") anchors)"
    fi
  fi
fi

if [[ -z "${CLUSTER_NAME:-}" ]]; then
  log "ERROR: could not determine the cluster name."
  log "       No CLUSTER_NAME set, no EKS kubeconfig context, and no readable"
  log "       $GLOBAL_VALUES. Pass it explicitly:"
  log "         CLUSTER_NAME=<name> $0"
  exit 1
fi

# Region: explicit env -> the context ARN parsed above -> global-values.yaml ->
# whatever the CLI resolves on its own (profile / AWS_DEFAULT_REGION).
#
# `global.cloud_storage_region` is a YAML ALIAS (*cloud_storage_region), not a
# literal — everything under `global:` references the anchors at the top of the
# file. So read the ANCHOR definition, which is the only place the real string
# lives. Sanity-checked against the region shape rather than trusted blindly:
# a stray `*alias` reaching the AWS CLI produces a confusing endpoint error
# instead of a clean fall-through to the CLI's own region resolution.
if [[ -z "${AWS_REGION:-}" && -f "$GLOBAL_VALUES" ]]; then
  _r="$(sed -n 's/^_cloud_storage_region:[[:space:]]*&cloud_storage_region[[:space:]]*//p' \
          "$GLOBAL_VALUES" | tr -d '"'"'"'' | head -1)"
  if [[ "$_r" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]]; then
    AWS_REGION="$_r"
    log "region:  $AWS_REGION (from $(basename "$GLOBAL_VALUES"))"
  fi
fi
if [[ -n "${AWS_REGION:-}" ]]; then
  AWS_ARGS=(--region "$AWS_REGION")
else
  AWS_ARGS=()
fi

# Skipped under --dry-run: previewing the ARN conversion is most useful BEFORE
# the cluster exists, and that is exactly when describe-cluster cannot succeed.
if [[ -z "$DRY_RUN" ]]; then
  aws eks describe-cluster --name "$CLUSTER_NAME" "${AWS_ARGS[@]}" >/dev/null 2>&1 \
    || { log "ERROR: cluster '$CLUSTER_NAME' not found (or no eks:DescribeCluster)."
         log "       Region resolved to: ${AWS_REGION:-<from aws cli config>}"
         exit 1; }
fi

if [[ -n "$LIST_ONLY" ]]; then
  log "Access entries on $CLUSTER_NAME:"
  aws eks list-access-entries --cluster-name "$CLUSTER_NAME" "${AWS_ARGS[@]}" \
    --query 'accessEntries[]' --output text | tr '\t' '\n'
  exit 0
fi

# ── Which principal ──────────────────────────────────────────────────────────
if [[ -z "$PRINCIPAL_ARN" ]]; then
  CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
  log "caller:  $CALLER_ARN"

  case "$CALLER_ARN" in
    arn:aws*:sts::*:assumed-role/*)
      # arn:aws:sts::<acct>:assumed-role/<RoleName>/<session>
      # The session name is dropped; the ROLE NAME is then resolved through IAM
      # so the path (if any) comes back correct. get-role takes a bare name and
      # returns the fully-qualified ARN, which is exactly what EKS wants.
      _rest="${CALLER_ARN#*:assumed-role/}"
      _role="${_rest%%/*}"
      _acct="$(cut -d: -f5 <<<"$CALLER_ARN")"
      if ! PRINCIPAL_ARN="$(aws iam get-role --role-name "$_role" \
                              --query 'Role.Arn' --output text 2>/dev/null)" \
         || [[ -z "$PRINCIPAL_ARN" || "$PRINCIPAL_ARN" == "None" ]]; then
        log "ERROR: could not resolve the role '$_role' via iam:GetRole."
        log "       Without it the ARN cannot be built reliably: an SSO role sits"
        log "       under /aws-reserved/sso.amazonaws.com/<sso-region>/, and that"
        log "       region is the Identity Center instance's, not the cluster's."
        log ""
        log "       Find it in the console (IAM > Roles > $_role) and pass it:"
        log "         $0 <principal-arn>"
        log "       For an SSO role it will look like:"
        log "         arn:aws:iam::${_acct}:role/aws-reserved/sso.amazonaws.com/<region>/${_role}"
        exit 1
      fi
      ;;
    arn:aws*:iam::*:role/*|arn:aws*:iam::*:user/*)
      # Already a fully-qualified principal — use it verbatim, path included.
      PRINCIPAL_ARN="$CALLER_ARN"
      ;;
    arn:aws*:sts::*:federated-user/*)
      log "ERROR: you are a federated user, which cannot hold an EKS access entry."
      log "       Assume a role first, or pass a role ARN explicitly:"
      log "         $0 arn:aws:iam::<acct>:role/<RoleName>"
      exit 1
      ;;
    *)
      log "ERROR: unrecognised caller ARN shape: $CALLER_ARN"
      log "       Pass the principal explicitly: $0 <principal-arn>"
      exit 1
      ;;
  esac
fi

log "grant:   $PRINCIPAL_ARN"
log "policy:  $ACCESS_POLICY_ARN (scope: $ACCESS_SCOPE)"

if [[ -n "$DRY_RUN" ]]; then
  log ""
  log "--dry-run: would run"
  log "  aws eks create-access-entry --cluster-name $CLUSTER_NAME \\"
  log "      --principal-arn $PRINCIPAL_ARN --type STANDARD"
  log "  aws eks associate-access-policy --cluster-name $CLUSTER_NAME \\"
  log "      --principal-arn $PRINCIPAL_ARN \\"
  log "      --policy-arn $ACCESS_POLICY_ARN --access-scope type=$ACCESS_SCOPE"
  exit 0
fi

# ── 1/2 access entry ─────────────────────────────────────────────────────────
# ResourceInUseException = the entry is already there, which is the expected
# outcome on any cluster where this was done by hand. Any OTHER failure is real
# and must not be swallowed, so the error text is matched rather than `|| true`.
_err="$(mktemp)"; trap 'rm -f "$_err"' EXIT
if aws eks create-access-entry \
     --cluster-name "$CLUSTER_NAME" "${AWS_ARGS[@]}" \
     --principal-arn "$PRINCIPAL_ARN" \
     --type STANDARD >/dev/null 2>"$_err"; then
  log "1/2 access entry created"
elif grep -q 'ResourceInUseException' "$_err"; then
  log "1/2 access entry already exists — leaving it as is"
else
  log "ERROR: create-access-entry failed:"
  sed 's/^/       /' "$_err" >&2
  if grep -q 'InvalidParameterException' "$_err"; then
    log ""
    log "       'principalArn is invalid' almost always means the ARN names a role"
    log "       that does not exist as written — most often an SSO role with its"
    log "       /aws-reserved/sso.amazonaws.com/<region>/ path removed. Check with:"
    log "         aws iam get-role --role-name <RoleName> --query Role.Arn --output text"
  fi
  exit 1
fi

# ── 2/2 policy association ───────────────────────────────────────────────────
# An upsert for the same (principal, policy, scope) triple, so re-running is a
# no-op. This is the half that actually grants anything: an access entry with no
# policy associated authenticates the principal and authorises nothing, which is
# the state a half-finished manual attempt usually leaves behind.
if ! aws eks associate-access-policy \
       --cluster-name "$CLUSTER_NAME" "${AWS_ARGS[@]}" \
       --principal-arn "$PRINCIPAL_ARN" \
       --policy-arn "$ACCESS_POLICY_ARN" \
       --access-scope "type=$ACCESS_SCOPE" >/dev/null 2>"$_err"; then
  log "ERROR: associate-access-policy failed:"
  sed 's/^/       /' "$_err" >&2
  exit 1
fi
log "2/2 policy associated"

log ""
log "Done. Verify with:"
log "  aws eks list-associated-access-policies --cluster-name $CLUSTER_NAME \\"
log "      --principal-arn $PRINCIPAL_ARN"
log "  kubectl auth can-i '*' '*' --all-namespaces"
