#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${OCLOUD_BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${OCLOUD_OUTPUT_DIR:-$PROJECT_DIR/../OCloudSync-App}"
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
APP="$OUTPUT_DIR/OCloudSync.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OCloudSync" "$APP/Contents/MacOS/OCloudSync"
cp "$BIN_DIR/OCloudLivePhoto" "$APP/Contents/MacOS/OCloudLivePhoto"
# Bundle resources live in Contents/Resources for a sealed macOS app.
ditto "$BIN_DIR/OCloudSync_OCloudSync.bundle" "$APP/Contents/Resources/OCloudSync_OCloudSync.bundle"
cp "$PROJECT_DIR/LICENSE" "$PROJECT_DIR/NOTICE.md" "$APP/Contents/Resources/"
bash "$PROJECT_DIR/scripts/build-icon.sh" "$PROJECT_DIR/assets/AppIcon.png" "$APP/Contents/Resources/OCloudSync.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OCloudSync</string>
<key>CFBundleIdentifier</key><string>dev.local.ocloudsync</string>
<key>CFBundleName</key><string>OCloudSync</string>
<key>CFBundleDisplayName</key><string>OPPO 照片同步</string>
<key>CFBundleIconFile</key><string>OCloudSync.icns</string>
<key>CFBundleIconName</key><string>OCloudSync</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.3</string>
<key>CFBundleVersion</key><string>19</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>读取原片以核对重复文件，并将你选择同步的 OPPO 新增照片和视频导入系统照片图库。</string>
<key>NSPhotoLibraryAddUsageDescription</key><string>将 OPPO 云相册新增照片和视频原文件导入系统照片图库，由系统 iCloud 照片同步。</string>
</dict></plist>
PLIST
bash "$PROJECT_DIR/scripts/sign-app.sh" "$APP"
printf '%s\n' "$APP"
