# =============================================================================
# keycloak-init tooling image: alpine + curl, jq, python3.
#
# WHY THIS EXISTS
# ---------------
# helm/keycloak/templates/job-keycloak-init.yaml runs the four realm-
# reconciliation steps in a plain `alpine:3.20` container and installs its own
# tools at start-up:
#
#     apk add --no-cache curl jq python3
#
# That makes Alpine's package CDN a hard runtime dependency of every keycloak
# install and upgrade. On a cluster with no outbound internet it is fatal: the
# Job is a post-install hook with backoffLimit 3 and activeDeadlineSeconds 600,
# so `apk` hangs in TCP timeout, the hook exhausts its retries, and the whole
# keycloak RELEASE is marked failed ~10 minutes later. Verified on the TCL/VKS
# cluster (2026-09-15): DNS resolves, but outbound 80 and 443 are both blocked
# from a pod, while in-cluster traffic works normally.
#
# Even where egress exists this is worth removing: a deploy that reaches out to
# a third-party CDN can fail for reasons that have nothing to do with the
# deploy, and it re-resolves package versions on every run, so two installs of
# the same chart can get different tool builds.
#
# WHAT IT IS NOT
# --------------
# Deliberately NOT built on the keycloak-server image: this Job never runs
# Keycloak, it only talks to it over HTTP. Keeping it a ~60 MB alpine rather
# than a JVM image keeps the hook fast and its attack surface small.
#
# BUILD / PUBLISH
# ---------------
# Not wired into CI (same rationale as the other dockerfiles/ images: rarely
# rebuilt, published manually). Build it wherever there IS internet access --
# the jump node, not the cluster -- then push to the environment's registry and
# pin the resulting tag in <env>/global-images.yaml under the ROOT `init:` key:
#
#     init:
#       image: <registry>/<project>/keycloak-init:alpine-3.20
#
# Note `init.image` is a different key from `keycloak.realmRenderer.image`,
# which covers only the initContainer inside the Keycloak pod. Both point at an
# alpine and both must be repointed for an air-gapped cluster.
# =============================================================================
FROM alpine:3.20

# Pinned to the same alpine minor the Job previously resolved at runtime.
# curl    - talks to the Keycloak admin API
# jq      - parses those responses in render-realm.sh
# python3 - runs apply-realm-config.py and apply-portal-gate.py
RUN apk add --no-cache curl jq python3

# No ENTRYPOINT/CMD on purpose: the Job supplies its own `sh -c` script.
