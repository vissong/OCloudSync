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
codesign --force --sign - "$APP/Contents/MacOS/OCloudLivePhoto"
# Bundle resources live in Contents/Resources for a sealed macOS app.
ditto "$BIN_DIR/OCloudSync_OCloudSync.bundle" "$APP/Contents/Resources/OCloudSync_OCloudSync.bundle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OCloudSync</string>
<key>CFBundleIdentifier</key><string>dev.local.ocloudsync</string>
<key>CFBundleName</key><string>OCloudSync</string>
<key>CFBundleDisplayName</key><string>OPPO 照片同步</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>读取原片以核对重复文件，并将你选择同步的 OPPO 新增照片导入系统照片图库。</string>
<key>NSPhotoLibraryAddUsageDescription</key><string>将 OPPO 云相册新增原图导入系统照片图库，由系统 iCloud 照片同步。</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
