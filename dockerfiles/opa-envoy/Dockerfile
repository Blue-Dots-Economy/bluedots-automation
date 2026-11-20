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

# Upstream OPA 1.21.1, Envoy-plugin build, static. Pinned by digest (the
# multi-arch index) so a rebuild cannot pull a different binary than the one
# validated here.
ARG OPA_ENVOY=openpolicyagent/opa:1.21.1-envoy-1-static@sha256:c1f40d815a15c4ca0ccbdf300e0a3515fccf1d30fbd92e69917ab96bad83811d
# The hardened base: DHI OPA 1.21.1 from this repo's GHCR mirror. Tag only, like
# the other mirrored images, so a rebuild picks up DHI's security refreshes.
ARG BASE=ghcr.io/blue-dots-economy/dhi/open-policy-agent:1.21.1

FROM ${OPA_ENVOY} AS opa-envoy

FROM ${BASE}
COPY --from=opa-envoy /opa /usr/bin/opa
# The base's own non-root user, stated so the image never runs as root even if
# a base default changes (the pod sets uid 1000 on top of this).
USER 65532:65532
# Kubernetes ignores a Docker HEALTHCHECK; the chart's startup, readiness and
# liveness probes on OPA's diagnostic port check this container.
HEALTHCHECK NONE
