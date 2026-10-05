#!/usr/bin/env bash
#
# scripts/build-geo-boundary.sh — regenerate the country boundary the signals
# api checks caller-supplied coordinates against (signals-dpg#789).
#
# Output: helm/signals/charts/api/files/geo/<CC>.geojson, committed, rendered
# into the {api}-geo-boundary ConfigMap and mounted at /app/geo/<CC>.geojson.
#
# Source: Natural Earth 1:10m admin-0 countries, the INDIA point-of-view variant
# (ne_10m_admin_0_countries_ind) — public domain. The point-of-view file draws
# borders as India claims them, so all of J&K, Ladakh and Arunachal Pradesh are
# inside. The default Natural Earth file draws de facto borders instead, which
# would reject real Indian addresses. Not simplified: simplification drops small
# islands (Lakshadweep goes at 30%), and the full file is ~150 KB, well under the
# 1 MiB ConfigMap cap. Coordinates are rounded to 4 dp (~11 m).
#
# To swap in another source (e.g. the Survey of India outline), replace the
# download + filter and keep the output a GeoJSON Polygon/MultiPolygon.
#
# Usage: scripts/build-geo-boundary.sh [CC]   (default IN; needs curl, unzip, npx)
set -euo pipefail

CC="${1:-IN}"
URL="https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries_ind.zip"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/helm/signals/charts/api/files/geo/$CC.geojson"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sSLf -o "$TMP/ne.zip" "$URL"
unzip -q "$TMP/ne.zip" -d "$TMP"
echo "Natural Earth version: $(cat "$TMP"/*.VERSION.txt)"

npx -y mapshaper@0.7 "$TMP/ne_10m_admin_0_countries_ind.shp" \
  -filter "ISO_A2 === '$CC'" \
  -filter-fields ISO_A2 \
  -o format=geojson precision=0.0001 "$OUT"

echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
