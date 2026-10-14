#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo 'Usage: sign-app.sh OCloudSync.app' >&2; exit 2
fi
APP="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_IDENTITY="${OCLOUD_SIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_OPTIONS+=(--options runtime --timestamp)
fi
if [ -n "${OCLOUD_KEYCHAIN_PATH:-}" ]; then
  SIGN_OPTIONS+=(--keychain "$OCLOUD_KEYCHAIN_PATH")
fi
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/MacOS/OCloudLivePhoto"
codesign "${SIGN_OPTIONS[@]}" --entitlements "$SCRIPT_DIR/OCloudSync.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
python3 "$SCRIPT_DIR/validate-photo-permission.py" "$APP"
