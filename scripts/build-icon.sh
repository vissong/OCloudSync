#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ] || [ ! -f "$1" ]; then
  echo 'Usage: build-icon.sh source.png output.icns' >&2; exit 2
fi
# Package the generated raster artwork using Apple's standard icon tools.
ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ocloud-icon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICONSET="$ICON_TEMP/OCloudSync.iconset"
mkdir -p "$ICONSET" "$(dirname "$2")"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$1" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$1" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$2"
