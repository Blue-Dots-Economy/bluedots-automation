# =============================================================================
# Custom Keycloak image: upstream base + the OTP authenticator SPI, pre-indexed.
#
# WHY THIS EXISTS
# ---------------
# Keycloak's stock image has no login-by-OTP authenticator. The shared realm this
# repo owns (helm/keycloak/charts/keycloak/files/realm.json) binds its browser
# flows to provider ids that only exist once the OTP SPI jar is on the classpath:
# `otp-identifier-form` and `otp-channel-choice-form`. Without the jar the realm
# import fails on unknown provider ids, and so does the entitlement-gate Job
# (helm/keycloak/files/apply-portal-gate.py), which asserts those same ids.
#
# The jar cannot simply be bind-mounted the way the app repos' local-dev compose
# does it, because Kubernetes has no host to mount from. Baking it in also lets
# `kc.sh build` run at IMAGE BUILD time instead of on every pod start, so the
# Deployment can boot with `start --optimized` (the chart passes exactly that —
# see helm/keycloak/charts/keycloak/templates/deployment.yaml `args:`).
#
# WHY IT LIVES HERE
# -----------------
# Keycloak is a common service — one realm holding BOTH DPGs' clients — so its
# image belongs with the deployment system that consumes it, not inside one of
# the two consumer apps. This build previously lived in
# aggregator-dpg/infra/keycloak/Dockerfile, which meant the identity image for
# signals was released from the aggregator's repo. Moving it here closes the open
# question recorded in docs/superpowers/plans/2026-08-04-keycloak-common-service.md
# §"Gaps and follow-ups".
#
# The app repos keep their own infra/keycloak/providers/ copy of the jar for
# LOCAL DEV ONLY (stock image + bind-mount + `start-dev`, which re-indexes
# providers on every boot). Those trees are developer-local setups and are not
# upstream of this file — same relationship scripts/build-realm.sh documents for
# the realm JSON.
#
# WHAT IS *NOT* IN HERE
# ---------------------
#   * render-realm.sh — under Kubernetes the realm-renderer initContainer does
#     the placeholder substitution into a shared emptyDir before this container
#     starts. The script ships as a ConfigMap
#     (charts/keycloak/templates/configmap-render-script.yaml), not in the image.
#   * Login themes — shipped by the per-network themes-init initContainer
#     (ghcr.io/blue-dots-economy/aggregator-dpg/keycloak-theme, still built in
#     aggregator-dpg because its brand strings come from that repo's
#     config/<network>/keycloak.env tree). It writes into an emptyDir the main
#     container mounts at /opt/keycloak/themes.
#   * Realm JSON — delivered as a ConfigMap, rendered by the initContainer above.
#
# BUILD
#   docker build --platform linux/amd64 \
#     -t ghcr.io/blue-dots-economy/keycloak-server:local dockerfiles/keycloak
#
# Normally built by .github/workflows/build-keycloak-image.yml (manual dispatch)
# and consumed via the per-env opentofu/aws/<env>/global-images.yaml
# `keycloak.image` override.
#
# BUMPING THE OTP JAR: see providers/README.md.
# =============================================================================

# Pinned minor. Keycloak realm imports are not forward-compatible in general, so
# a bump here is a deliberate change to validate against the realm, not a
# floating tag. Keep in step with the app repos' local-dev compose so local and
# deployed behaviour match.
ARG KEYCLOAK_VERSION=26.5.5
FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

# Root only for the provider copy: the upstream image runs as uid 1000 and
# /opt/keycloak is not group-writable, so the COPY needs privilege. a+r because
# the runtime uid must read the jar, and Docker preserves the host's mode bits.
#
# Globbed to `*.jar` rather than the whole directory so providers/README.md does
# not end up in the runtime provider path. It also fails the build loudly if the
# directory ever ends up with no jar in it, instead of quietly producing an image
# whose realm import breaks at deploy time.
USER 0
COPY providers/*.jar /opt/keycloak/providers/
RUN chmod -R a+r /opt/keycloak/providers

USER 1000
# KC_DB is a BUILD-TIME option: `kc.sh build` below precompiles the persistence
# layer for exactly this backend, and `start --optimized` refuses to run if a
# build-time option is changed at runtime. Another database would need its own
# image. KC_HTTP_RELATIVE_PATH is likewise build-time and must match the chart's
# ingress path and health-probe paths (/auth/health/*).
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_HTTP_RELATIVE_PATH=/auth

# Index the SPI providers + persistence layer now, so the pod does not pay for
# Quarkus augmentation on every cold start.
RUN /opt/keycloak/bin/kc.sh build

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
# Overridden by the chart's `args:`; kept so `docker run` on this image behaves.
CMD ["start", "--optimized", "--import-realm"]
