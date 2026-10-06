#!/usr/bin/env bash
#
# scripts/build-geo-boundary.sh — regenerate the country boundary the signals
# api checks caller-supplied coordinates against (signals-dpg#789).
#
# Output: helm/signals/charts/api/files/geo/<CC>.geojson, committed, rendered
# into the {api}-geo-boundary ConfigMap and mounted at /app/geo/<CC>.geojson.
# Beside it, <CC>.source records the release and URL the outline came from.
#
# Source: Natural Earth 1:10m admin-0 countries, the INDIA point-of-view variant
# (ne_10m_admin_0_countries_ind) — public domain. The point-of-view file draws
# borders as India claims them, so all of J&K, Ladakh and Arunachal Pradesh are
# inside. The default Natural Earth file draws de facto borders instead, which
# would reject real Indian addresses. Not simplified: simplification drops small
# islands (Lakshadweep goes at 30%), and the full file is ~150 KB, well under the
# 1 MiB ConfigMap cap. Coordinates are rounded to 4 dp (~11 m).
#
# The release is pinned (NE_VERSION) and read from the tagged GitHub source, not
# the naciscdn.org zip, which always serves the latest release: an unpinned
# re-run could silently redraw the border. Bump it deliberately.
#
# 1:10m is coarse at the border (Petrapole, WB sits ~6 km outside the line); the
# api's BOUNDARY_TOLERANCE_METERS absorbs that. A sharper source would justify
# tightening it.
#
# To swap in another source (e.g. the Survey of India outline), replace the
# download + filter, keep the output a GeoJSON Polygon/MultiPolygon, and update
# what <CC>.source records.
#
# Usage: scripts/build-geo-boundary.sh [CC]   (default IN; needs curl, npx)
#        NE_VERSION=5.1.2 scripts/build-geo-boundary.sh   (another release)
set -euo pipefail

CC="${1:-IN}"
NE_VERSION="${NE_VERSION:-5.1.1}"
LAYER="ne_10m_admin_0_countries_ind"
BASE="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v$NE_VERSION/10m_cultural/$LAYER"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/helm/signals/charts/api/files/geo/$CC.geojson"
SOURCE="${OUT%.geojson}.source"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for ext in shp shx dbf prj; do
  curl -sSLf -o "$TMP/$LAYER.$ext" "$BASE.$ext"
done

npx -y mapshaper@0.7 "$TMP/$LAYER.shp" \
  -filter "ISO_A2 === '$CC'" \
  -filter-fields ISO_A2 \
  -o format=geojson precision=0.0001 "$OUT"

cat > "$SOURCE" <<EOF
# Provenance of $CC.geojson. Written by scripts/build-geo-boundary.sh; do not edit.
source: Natural Earth 1:10m admin-0 countries, India point of view ($LAYER)
license: public domain
version: $NE_VERSION
url: $BASE.shp
filter: ISO_A2 === '$CC'
tool: mapshaper@0.7, precision=0.0001, not simplified
EOF

echo "wrote $OUT ($(wc -c < "$OUT") bytes), Natural Earth $NE_VERSION"
