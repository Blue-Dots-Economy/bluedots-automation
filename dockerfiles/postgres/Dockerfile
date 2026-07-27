# =============================================================================
# Custom PostgreSQL 17 image: Bitnami base + PORTABLE pgvector.
#
# WHY THIS EXISTS
# ---------------
# The shared in-cluster Postgres (helm/common-services, Bitnami postgresql
# subchart) uses bitnamilegacy/postgresql:17.6.0. That image's bundled pgvector
# is compiled with AVX-512 instructions in its HNSW index-build path, so
# `CREATE INDEX ... USING hnsw (...)` crashes the server with SIGILL on any x86
# CPU without AVX-512 — e.g. the AMD EPYC (Zen 3 / m6a) nodes this cluster runs
# on. Basic vector distance operators work (they runtime-dispatch), but building
# an HNSW index kills the backend. Managed RDS was unaffected because it runs on
# Graviton (ARM), a different SIMD path.
#
# The official pgvector/pgvector:pg17 image ships a PORTABLE pgvector build
# (proper runtime CPU dispatch) that builds HNSW on AVX2-only hosts. This image
# copies that known-good vector.so + extension SQL over Bitnami's, keeping the
# rest of the image 100% Bitnami (entrypoint, uid 1001, /opt/bitnami paths,
# PostGIS, etc.). Result: a drop-in image override for the Bitnami subchart —
# only opentofu/aws/<env>/global-images.yaml `postgresql.image` changes, no chart
# templating changes — with a pgvector that builds HNSW indexes anywhere.
#
# Same PG major (17) and CPU arch, so the pgvector extension .so is load-
# compatible with the Bitnami server. Note: this bumps pgvector 0.8.0 -> 0.8.5
# (the version the official image ships); 0.8.x is backward compatible and 0.8.5
# is the version the signals-dpg app image itself uses.
#
# BUILD (multi-arch base images; build for the node arch you deploy to):
#   docker build --platform linux/amd64 \
#     -t <registry>/postgresql:17.6.0-pgvector-portable dockerfiles/postgres
#
# Consumed by: helm/common-services (postgresql subchart) via the per-env
# global-images.yaml `postgresql.image` override. Because the repo is not a
# Bitnami image, that env must also set `global.security.allowInsecureImages: true`.
# =============================================================================

# Source of the portable pgvector build. Pinned by digest (this digest is
# pgvector 0.8.5 on pg17) so a later rebuild can't silently pull a different
# pgvector than the one documented/validated for this shared base image.
FROM pgvector/pgvector:pg17@sha256:d2ef61f42ef767baa5a1475393303cc235bcd92febd9d7014eddb48b41f3bad0 AS pgv

FROM bitnamilegacy/postgresql:17.6.0

# Replace Bitnami's AVX-512 pgvector with the portable build from the official
# image. Runs as root for the file swap, then drops back to the Bitnami uid.
USER 0
RUN rm -f /opt/bitnami/postgresql/lib/vector.so \
    && rm -f /opt/bitnami/postgresql/share/extension/vector*
COPY --from=pgv /usr/lib/postgresql/17/lib/vector.so /opt/bitnami/postgresql/lib/vector.so
COPY --from=pgv /usr/share/postgresql/17/extension/vector* /opt/bitnami/postgresql/share/extension/
USER 1001
