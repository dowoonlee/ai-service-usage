#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AIUsage"              # 번들 파일명(공백 없이)
DISPLAY_NAME="AI Usage"         # Finder 표시명
BUNDLE_ID="com.dwlee.AIUsage"
EXECUTABLE="AIUsage"            # 실행 파일명 (SwiftPM 산출물은 ClaudeUsage이지만 복사 시 이 이름으로)
SPM_PRODUCT="ClaudeUsage"       # SwiftPM 타깃 이름 (내부 유지)
VERSION="${VERSION:-0.1.2}"
MIN_OS="14.0"

# Sparkle 자동 업데이트
SU_FEED_URL="${SU_FEED_URL:-https://raw.githubusercontent.com/dowoonlee/ai-service-usage/main/appcast.xml}"
SU_PUBLIC_KEY="${SU_PUBLIC_KEY:-}"   # EdDSA public key (bin/generate_keys로 생성). 비어 있으면 Sparkle 키 검증 실패.

echo "==> swift build -c release"
swift build -c release >/dev/null

DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
rm -rf "${APP_DIR}" "${DIST_DIR}/${APP_NAME}.zip"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

echo "==> assembling bundle at ${APP_DIR}"
cp ".build/release/${SPM_PRODUCT}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"

# Sparkle.framework 임베드: SPM이 .build/release(또는 arch별 release)/Sparkle.framework로 복사함.
SPARKLE_FW=""
for cand in \
  ".build/release/Sparkle.framework" \
  ".build/arm64-apple-macosx/release/Sparkle.framework" \
  ".build/x86_64-apple-macosx/release/Sparkle.framework"; do
  if [ -d "$cand" ]; then SPARKLE_FW="$cand"; break; fi
done
if [ -z "$SPARKLE_FW" ]; then
  SPARKLE_FW="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos-arm64*' 2>/dev/null | head -1)"
fi
if [ -z "$SPARKLE_FW" ] || [ ! -d "$SPARKLE_FW" ]; then
  echo "ERROR: Sparkle.framework not found under .build/" >&2
  exit 1
fi
mkdir -p "${APP_DIR}/Contents/Frameworks"
ditto "$SPARKLE_FW" "${APP_DIR}/Contents/Frameworks/Sparkle.framework"
echo "    embedded $SPARKLE_FW"

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
    <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SU_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

if [ -z "${SU_PUBLIC_KEY}" ]; then
  echo "WARNING: SU_PUBLIC_KEY not set — auto-update signature verification will fail." >&2
  echo "         Generate keys with Sparkle's bin/generate_keys, set SU_PUBLIC_KEY=..., re-run." >&2
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "${APP_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
codesign --force --sign - "${APP_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
codesign --force --deep --sign - "${APP_DIR}" >/dev/null

echo "==> zipping via ditto"
(cd "${DIST_DIR}" && ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip")

SIZE=$(du -sh "${DIST_DIR}/${APP_NAME}.zip" | cut -f1)
echo
echo "✓ built ${APP_DIR}"
echo "✓ zip   ${DIST_DIR}/${APP_NAME}.zip  (${SIZE})"
echo
echo "run locally:  open \"${APP_DIR}\""
