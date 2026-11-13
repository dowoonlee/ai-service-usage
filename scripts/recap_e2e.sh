#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
source scripts/ranking.env
set +a
export DENO_TLS_CA_STORE="${DENO_TLS_CA_STORE:-mozilla,system}"
flags=(--allow-net --allow-env)
if [ -n "${RECAP_PREVIEW_OUT:-}" ]; then flags+=("--allow-write=$RECAP_PREVIEW_OUT"); fi
exec deno run "${flags[@]}" scripts/recap_e2e.ts
