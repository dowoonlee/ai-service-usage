#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ClaudeUsage"          # 번들 파일명(공백 없이)
DISPLAY_NAME="Claude Usage"     # Finder 표시명
BUNDLE_ID="com.dwlee.ClaudeUsage"
EXECUTABLE="ClaudeUsage"
VERSION="${VERSION:-0.1.0}"
MIN_OS="14.0"

echo "==> swift build -c release"
swift build -c release >/dev/null

DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
rm -rf "${APP_DIR}" "${DIST_DIR}/${APP_NAME}.zip"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

echo "==> assembling bundle at ${APP_DIR}"
cp ".build/release/${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "${APP_DIR}" >/dev/null

echo "==> zipping via ditto"
(cd "${DIST_DIR}" && ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip")

SIZE=$(du -sh "${DIST_DIR}/${APP_NAME}.zip" | cut -f1)
echo
echo "✓ built ${APP_DIR}"
echo "✓ zip   ${DIST_DIR}/${APP_NAME}.zip  (${SIZE})"
echo
echo "run locally:  open \"${APP_DIR}\""
