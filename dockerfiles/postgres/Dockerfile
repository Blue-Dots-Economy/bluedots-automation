# =============================================================================
# Custom PostgreSQL 17 image: Bitnami base + PORTABLE pgvector + pg_partman.
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
# compatible with the Bitnami server. Note: this bumps pgvector 0.8.0 -> 0.8.6
# (the version the official image ships); 0.8.x is backward compatible, so it also
# interoperates with the 0.8.5 pgvector the signals-dpg app image ships.
#
# pg_partman
# ----------
# notification-service partitions its tables with pg_partman: the common-services
# postgresBootstrap Job runs `CREATE EXTENSION pg_partman SCHEMA partman` and NS
# migration 0000 calls `partman.create_parent`. Bitnami does not ship it, so the
# PGDG Debian package (same PG major, same Debian 12 / glibc as the Bitnami base)
# is installed in a throwaway stage and only its extension files are copied in:
# the control file + SQL scripts, and pg_partman_bgw.so (the optional background
# worker; partitions are maintained without it unless it is put in
# shared_preload_libraries). The package version is pinned; when PGDG drops it
# from the bookworm-pgdg pool the build fails loudly, which is the cue to bump.
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
# pgvector 0.8.6 on pg17) so a later rebuild can't silently pull a different
# pgvector than the one documented/validated for this shared base image.
FROM pgvector/pgvector:pg17@sha256:cf134a767f474095eeba57e0117be8e568e011a63f33fbf252f14c9b760f8e6f AS pgv

# Source of pg_partman: the official postgres image (PGDG apt repo preconfigured),
# pinned by digest, with the PGDG package pinned to an exact version.
FROM postgres:17-bookworm@sha256:3645570cccdfa447589da9f57dd740faa29b30938e861289a5574b6ca6b03826 AS partman
ARG PG_PARTMAN_DEB_VERSION=5.5.0-1.pgdg12+1
RUN apt-get update \
    && apt-get install -y --no-install-recommends "postgresql-17-partman=${PG_PARTMAN_DEB_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

FROM bitnamilegacy/postgresql:17.6.0

# Replace Bitnami's AVX-512 pgvector with the portable build from the official
# image. Runs as root for the file swap, then drops back to the Bitnami uid.
USER 0
RUN rm -f /opt/bitnami/postgresql/lib/vector.so \
    && rm -f /opt/bitnami/postgresql/share/extension/vector*
COPY --from=pgv /usr/lib/postgresql/17/lib/vector.so /opt/bitnami/postgresql/lib/vector.so
COPY --from=pgv /usr/share/postgresql/17/extension/vector* /opt/bitnami/postgresql/share/extension/
# pg_partman: extension control/SQL + background-worker library (see header).
COPY --from=partman /usr/lib/postgresql/17/lib/pg_partman_bgw.so /opt/bitnami/postgresql/lib/pg_partman_bgw.so
COPY --from=partman /usr/share/postgresql/17/extension/pg_partman* /opt/bitnami/postgresql/share/extension/
USER 1001
