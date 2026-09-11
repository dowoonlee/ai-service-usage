#!/usr/bin/env bash
# Build all standard macOS icon representations using system tools only.
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT="${1:-dist/AppIcon.icns}"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET="${ICON_WORK_DIR}/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/AppIcon.png \
    --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" assets/AppIcon.png \
    --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
