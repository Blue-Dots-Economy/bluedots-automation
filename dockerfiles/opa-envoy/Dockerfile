# =============================================================================
# Hardened OPA with the Envoy plugin: DHI OPA base + upstream opa-envoy binary.
#
# WHY THIS EXISTS
# ---------------
# The aggregator api's RBAC edge (aggregator-dpg docs/rbac/rbac-edge-enforcement.md)
# has Envoy ask OPA, over Envoy's ext_authz gRPC API, whether each request may
# reach the api. Only OPA's Envoy-plugin build answers that API, and the Docker
# Hardened Images catalog has no Envoy-plugin variant of OPA, only plain OPA.
#
# So this image is the DHI OPA image (as mirrored to GHCR, see
# .github/dhi-mirror-images.txt) with its `opa` binary replaced by the upstream
# Envoy-plugin build of the SAME OPA version. That build is a static Go binary
# (the `-static` tag), so it needs nothing from the base it lands on: the
# hardened base supplies the rest of the image (non-root user, no shell, no
# package manager, CVE-tracked layers), and its entrypoint (/usr/bin/opa) and
# user are kept unchanged. Same approach as dockerfiles/postgres, which swaps
# one known-good artifact into an otherwise untouched base.
#
# Keep the two versions in step: OPA_ENVOY's OPA version must equal the BASE
# tag's. A version bump changes both lines.
#
# BUILD
#   docker build -t <registry>/opa-envoy:<tag> dockerfiles/opa-envoy
# BASE is overridable for a local check where the GHCR mirror is not
# reachable, e.g. --build-arg BASE=gcr.io/distroless/static-debian12:nonroot.
#
# Consumed by: helm/aggregator charts/api (aggregator-api.rbac.opa.image), the
# OPA sidecar in the api pod. Built by .github/workflows/build-opa-envoy-image.yml.
# =============================================================================

# Upstream OPA 1.22.4, Envoy-plugin build, static. Pinned by digest (the
# multi-arch index) so a rebuild cannot pull a different binary than the one
# validated here. 1.23.0 has no Envoy-plugin build yet, so 1.22.4 is the
# newest version that has one.
ARG OPA_ENVOY=openpolicyagent/opa:1.22.4-envoy-5-static@sha256:2b50e57d511baf3779e7f9dd59a88db8b93ab2d36ec951ba1071836812e0ecdf
# The hardened base: DHI OPA 1.22.4 from this repo's GHCR mirror. Tag only, like
# the other mirrored images, so a rebuild picks up DHI's security refreshes.
ARG BASE=ghcr.io/blue-dots-economy/dhi/open-policy-agent:1.22.4

FROM ${OPA_ENVOY} AS opa-envoy

FROM ${BASE}
COPY --from=opa-envoy /opa /usr/bin/opa
# The base's own non-root user, stated so the image never runs as root even if
# a base default changes (the pod sets uid 1000 on top of this).
USER 65532:65532
# Kubernetes ignores a Docker HEALTHCHECK; the chart's startup, readiness and
# liveness probes on OPA's diagnostic port check this container.
HEALTHCHECK NONE
