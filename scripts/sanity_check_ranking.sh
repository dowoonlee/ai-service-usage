#!/usr/bin/env bash
# 랭킹 시스템 서버 sanity check.
#
# 사용법: bash scripts/sanity_check_ranking.sh
#
# 동작:
#   1. scripts/ranking.env load + 필수 변수 검증
#   2. 테스트 device 정리 (이전 실행이 중단된 경우 대비)
#   3. register / leaderboard / 중복 register 3개 endpoint 테스트
#   4. 테스트 device 정리
#   5. pass/fail 요약
#
# 종료 코드: 0 = 모두 통과, 1 = 하나라도 실패

set -uo pipefail
cd "$(dirname "$0")/.."

# ---------- 색상 ----------
if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi
pass() { echo "  ${GREEN}✓${RESET} $1"; }
fail() { echo "  ${RED}✗${RESET} $1"; FAILED=1; }
info() { echo "${BOLD}==>${RESET} $1"; }
warn() { echo "${YELLOW}!${RESET} $1"; }

FAILED=0
TEST_DEVICE_ID="00000000-0000-0000-0000-000000000001"
TEST_NICKNAME="SanityCheckUser"

# macOS 시스템 curl을 강제 — Anaconda/conda/Homebrew curl이 자체 cacert.pem을 쓰면서
# 최신 root CA가 빠져 "self-signed certificate in certificate chain" 에러를 내는 환경 대응.
# /usr/bin/curl은 macOS Security framework + 시스템 Keychain을 사용해 root가 항상 최신.
if [ -x /usr/bin/curl ]; then
  CURL="/usr/bin/curl"
else
  CURL="curl"
fi

# INSECURE=1 → curl -k 모드. HTTPS inspection 환경 (회사망 등)에서 self-signed cert chain
# 에러 우회. sanity check는 endpoint 존재 확인용이라 SSL 검증 생략 무방. 실제 클라이언트
# 앱은 macOS 시스템 trust store를 쓰므로 영향 없음.
CURL_INSECURE=""
if [ "${INSECURE:-0}" = "1" ]; then
  CURL_INSECURE="-k"
  warn "INSECURE=1 — TLS 검증 생략 모드 (sanity check만)"
fi

# ---------- env load ----------
if [ ! -f scripts/ranking.env ]; then
  echo "${RED}scripts/ranking.env 가 없습니다.${RESET}" >&2
  exit 1
fi
# shellcheck disable=SC1091
source scripts/ranking.env

for var in SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY; do
  if [ -z "${!var:-}" ]; then
    echo "${RED}${var} 가 비어 있습니다.${RESET}" >&2
    exit 1
  fi
done

# URL 정규화 — 사용자가 Data API URL을 통째로 복사한 경우(끝에 /rest/v1/ 붙음) 자동 보정.
# `${var%pat}`은 suffix 제거. 여러 번 적용해 trailing slash + /rest/v1 + slash 순으로 떼냄.
ORIG_URL="${SUPABASE_URL}"
SUPABASE_URL="${SUPABASE_URL%/}"
SUPABASE_URL="${SUPABASE_URL%/rest/v1}"
SUPABASE_URL="${SUPABASE_URL%/}"
if [ "$SUPABASE_URL" != "$ORIG_URL" ]; then
  warn "SUPABASE_URL 정규화: ${ORIG_URL} → ${SUPABASE_URL}"
  warn "scripts/ranking.env 값을 수정해두시면 다음부터 경고 안 뜹니다."
fi

# 기본 연결 검증 — DNS + TLS 단계에서 끊기면 다음 단계 의미 없음.
# curl 에러 메시지를 stderr로 캡처해 사용자가 원인 파악 가능하게.
preflight_err=$("$CURL" $CURL_INSECURE -sS -o /dev/null --max-time 10 "${SUPABASE_URL}/auth/v1/health" 2>&1)
preflight_status=$?
if [ "$preflight_status" != "0" ]; then
  echo "${RED}${SUPABASE_URL} 에 연결 실패 (curl exit ${preflight_status})${RESET}" >&2
  echo "${RED}curl: ${preflight_err}${RESET}" >&2
  echo "" >&2
  echo "직접 검증: ${BOLD}curl -v ${SUPABASE_URL}/auth/v1/health${RESET}" >&2
  exit 1
fi

info "Endpoint: ${SUPABASE_URL} (preflight OK)"
echo

# ---------- 헬퍼 ----------
# 호출 → status code + body. 사용: call_json METHOD PATH '<json body or empty>'
call_json() {
  local method=$1 path=$2 body=${3:-}
  local args=(-s -o /tmp/sanity_resp.json -w "%{http_code}")
  [ -n "$CURL_INSECURE" ] && args+=("$CURL_INSECURE")
  args+=(-X "$method")
  args+=(-H "Authorization: Bearer ${SUPABASE_ANON_KEY}")
  args+=(-H "apikey: ${SUPABASE_ANON_KEY}")
  args+=(-H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  "$CURL" "${args[@]}" "${SUPABASE_URL}${path}"
}

# REST API 직접 호출 (service_role) — 테스트 row 정리용
rest_delete() {
  local table=$1 filter=$2
  "$CURL" -s -o /dev/null -w "%{http_code}" $CURL_INSECURE \
    -X DELETE \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    "${SUPABASE_URL}/rest/v1/${table}?${filter}"
}

# JSON 필드 추출 — jq 우선, 없으면 grep
json_field() {
  local key=$1 file=$2
  if command -v jq >/dev/null 2>&1; then
    jq -r ".${key} // empty" "$file"
  else
    grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" \
      | head -1 | sed -E "s/^.*:[[:space:]]*\"([^\"]*)\".*$/\1/"
  fi
}

# ---------- 사전 정리 ----------
info "사전 정리 (이전 실행 잔여물 제거)"
status=$(rest_delete users "device_id=eq.${TEST_DEVICE_ID}")
if [ "$status" = "204" ] || [ "$status" = "200" ]; then
  pass "users 테이블 정리 (HTTP $status)"
else
  warn "정리 응답 HTTP $status — 처음 실행이면 정상"
fi
echo

# ---------- 5-1. register ----------
info "5-1. register 호출"
http=$(call_json POST /functions/v1/register "{\"deviceId\":\"${TEST_DEVICE_ID}\",\"nickname\":\"${TEST_NICKNAME}\"}")
if [ "$http" = "200" ]; then
  hmac_key=$(json_field hmacKey /tmp/sanity_resp.json)
  recovery=$(json_field recoveryCode /tmp/sanity_resp.json)
  if [ -n "$hmac_key" ] && [ -n "$recovery" ]; then
    pass "200 OK + hmacKey + recoveryCode (${recovery})"
  else
    fail "200이지만 hmacKey/recoveryCode 누락"
    cat /tmp/sanity_resp.json
  fi
else
  fail "예상 200, 실제 ${http}"
  cat /tmp/sanity_resp.json
fi
echo

# ---------- 5-2. leaderboard ----------
info "5-2. leaderboard 호출"
http=$(call_json GET /functions/v1/leaderboard "")
if [ "$http" = "200" ]; then
  # Schema 키 존재 확인만 — 실 사용자 data가 있으면 entries 비어있지 않을 수 있음.
  if grep -q '"entries":' /tmp/sanity_resp.json \
     && grep -q '"total":' /tmp/sanity_resp.json \
     && grep -q '"period":' /tmp/sanity_resp.json \
     && grep -q '"periodResetAt":' /tmp/sanity_resp.json; then
    pass "200 OK + valid leaderboard schema"
  else
    fail "200이지만 schema 예상과 다름"
    cat /tmp/sanity_resp.json
  fi
else
  fail "예상 200, 실제 ${http}"
  cat /tmp/sanity_resp.json
fi
echo

# ---------- 5-3. 중복 register ----------
info "5-3. 같은 deviceId로 register 재시도 (409 기대)"
http=$(call_json POST /functions/v1/register "{\"deviceId\":\"${TEST_DEVICE_ID}\",\"nickname\":\"AnotherName\"}")
if [ "$http" = "409" ]; then
  reason=$(json_field error /tmp/sanity_resp.json)
  if [ "$reason" = "device_already_registered" ]; then
    pass "409 + device_already_registered"
  else
    fail "409이지만 error reason 예상과 다름 (${reason})"
  fi
else
  fail "예상 409, 실제 ${http}"
  cat /tmp/sanity_resp.json
fi
echo

# ---------- 사후 정리 ----------
info "사후 정리"
status=$(rest_delete users "device_id=eq.${TEST_DEVICE_ID}")
if [ "$status" = "204" ] || [ "$status" = "200" ]; then
  pass "users 테이블 정리 (HTTP $status)"
else
  warn "정리 응답 HTTP $status — 대시보드에서 수동 확인 권장"
fi
echo

# ---------- 결과 ----------
if [ "$FAILED" = "0" ]; then
  echo "${GREEN}${BOLD}모든 sanity check 통과 — 서버 정상.${RESET}"
  echo "다음: ${BOLD}bash scripts/package.sh${RESET} 로 클라이언트 빌드"
  exit 0
else
  echo "${RED}${BOLD}일부 check 실패 — 위 출력 확인 후 docs/DEPLOY_RANKING.md 트러블슈팅 참고.${RESET}"
  exit 1
fi
