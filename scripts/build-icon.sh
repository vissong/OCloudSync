#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ] || [ ! -f "$1" ]; then
  echo 'Usage: build-icon.sh source.png output.icns' >&2; exit 2
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_MAJOR="$(xcodebuild -version | awk '/^Xcode / { split($2, v, "."); print v[1] }')"
if [ "${XCODE_MAJOR:-0}" -lt 26 ]; then
  echo 'App icon compilation requires Xcode 26 or later; select it with DEVELOPER_DIR or xcode-select.' >&2
  exit 1
fi
# Feed full-bleed artwork to the native icon compiler. It applies the macOS
# mask once and emits both the modern icon stack and older macOS renditions.
ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ocloud-icon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICON_DOCUMENT="$ICON_TEMP/OCloudSync.icon"
mkdir -p "$ICON_DOCUMENT/Assets" "$ICON_TEMP/compiled" "$(dirname "$2")"
cp "$1" "$ICON_DOCUMENT/Assets/Artwork.png"
cp "$PROJECT_DIR/assets/AppIcon.icon.json" "$ICON_DOCUMENT/icon.json"
xcrun --sdk macosx actool "$ICON_DOCUMENT" --compile "$ICON_TEMP/compiled" \
  --platform macosx --minimum-deployment-target 13.0 --app-icon OCloudSync \
  --standalone-icon-behavior all \
  --output-partial-info-plist "$ICON_TEMP/icon-info.plist" --output-format human-readable-text
cp "$ICON_TEMP/compiled/OCloudSync.icns" "$2"
cp "$ICON_TEMP/compiled/Assets.car" "$(dirname "$2")/Assets.car"
