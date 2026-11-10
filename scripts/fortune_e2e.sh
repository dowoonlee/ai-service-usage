#!/usr/bin/env bash
# 배포된 fortune 함수 E2E — scripts/ranking.env 를 source 하고 scripts/fortune_e2e.ts 를 실행한다.
# 사내망 TLS 검사 환경: INSECURE=1 bash scripts/fortune_e2e.sh
# 카나리 함수 대상: FORTUNE_FN=fortune-canary bash scripts/fortune_e2e.sh
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/ranking.env ] || { echo "scripts/ranking.env 가 없습니다 (ranking.env.example 참고)"; exit 2; }
# ranking.env 는 `KEY=value` 형식일 수 있어 자동 export(set -a)로 deno 환경에 넘긴다.
set -a
# shellcheck disable=SC1091
source scripts/ranking.env
set +a
# 사내망 MITM CA는 OS keychain에만 있다 — Deno 기본(mozilla) 저장소에 시스템 CA를 합친다.
export DENO_TLS_CA_STORE="${DENO_TLS_CA_STORE:-mozilla,system}"
flags=(--allow-net --allow-env)
[ "${INSECURE:-}" = "1" ] && flags+=(--unsafely-ignore-certificate-errors)
exec deno run "${flags[@]}" scripts/fortune_e2e.ts
