#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${OCLOUD_BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${OCLOUD_OUTPUT_DIR:-$PROJECT_DIR/dist}"
BUILD_ARCH="$(uname -m)"

swift --version
node --version
python3 --version

swift test --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR"
node "$PROJECT_DIR/scripts/test-bridge.mjs"
node "$PROJECT_DIR/scripts/test-session.mjs"
python3 "$PROJECT_DIR/scripts/test-session-cancellation.py"
python3 "$PROJECT_DIR/scripts/test-scan-retirement.py"
python3 "$PROJECT_DIR/scripts/test-list-wait.py"
python3 "$PROJECT_DIR/scripts/test-video-import.py"
python3 "$PROJECT_DIR/scripts/test-filename-date.py"
python3 "$PROJECT_DIR/scripts/test-date-repair.py"
python3 "$PROJECT_DIR/scripts/test-range-import.py"
python3 "$PROJECT_DIR/scripts/test-import-pipeline.py"
python3 "$PROJECT_DIR/scripts/test-cleanup.py"

OCLOUD_BUILD_DIR="$BUILD_DIR" OCLOUD_OUTPUT_DIR="$OUTPUT_DIR" \
  bash "$PROJECT_DIR/scripts/build-app.sh"

APP="$OUTPUT_DIR/OCloudSync.app"
python3 "$PROJECT_DIR/scripts/test-livephoto.py" "$APP/Contents/MacOS/OCloudLivePhoto"
test "$(lipo -archs "$APP/Contents/MacOS/OCloudSync")" = "$BUILD_ARCH"
test "$(lipo -archs "$APP/Contents/MacOS/OCloudLivePhoto")" = "$BUILD_ARCH"
codesign --verify --deep --strict "$APP"

ARCHIVE_NAME="OCloudSync-macOS-$BUILD_ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$ARCHIVE_NAME"
unzip -tq "$OUTPUT_DIR/$ARCHIVE_NAME"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
printf 'Packaged %s\n' "$OUTPUT_DIR/$ARCHIVE_NAME"
