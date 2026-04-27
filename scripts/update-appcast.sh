#!/usr/bin/env bash
# 릴리스 zip에 EdDSA 서명을 만들고 appcast.xml에 새 <item>을 prepend합니다.
# 의존: Sparkle의 sign_update 바이너리 (.build/.../sign_update 또는 PATH 상의 sign_update).
# 사용법: SU_PRIVATE_KEY="..." VERSION=0.1.2 ZIP=dist/AIUsage.zip bash scripts/update-appcast.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?VERSION (예: 0.1.2) 필요}"
ZIP="${ZIP:-dist/AIUsage.zip}"
SU_PRIVATE_KEY="${SU_PRIVATE_KEY:?SU_PRIVATE_KEY (Sparkle EdDSA private key) 필요}"
APPCAST="${APPCAST:-appcast.xml}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/dowoonlee/ai-service-usage/releases/download/v${VERSION}/AIUsage.zip}"

# sign_update 위치 탐색
SIGN_UPDATE=""
for cand in \
  "$(find .build -name sign_update -type f 2>/dev/null | head -1)" \
  "$(command -v sign_update 2>/dev/null || true)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then SIGN_UPDATE="$cand"; break; fi
done
if [ -z "$SIGN_UPDATE" ]; then
  echo "ERROR: sign_update not found. swift build first, or install Sparkle CLI tools." >&2
  exit 1
fi

if [ ! -f "$ZIP" ]; then
  echo "ERROR: $ZIP not found. run scripts/package.sh first." >&2
  exit 1
fi

# sign_update 출력 형식: 'sparkle:edSignature="..." length="123"'
SIGNATURE_LINE="$(printf '%s' "$SU_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")"
PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

ITEM=$(cat <<EOF
    <item>
      <title>v${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${DOWNLOAD_URL}"
                 type="application/octet-stream"
                 ${SIGNATURE_LINE} />
    </item>
EOF
)

# <channel> 안 첫 번째 item으로 삽입 (없으면 channel 닫기 직전)
TMP=$(mktemp)
awk -v item="$ITEM" '
  /<\/channel>/ && !ins { print item; ins=1 }
  { print }
' "$APPCAST" > "$TMP"
mv "$TMP" "$APPCAST"
echo "✓ appcast.xml updated for v${VERSION}"
