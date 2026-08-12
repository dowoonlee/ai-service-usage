#!/usr/bin/env bash
# 시각 검수용 프리뷰를 굽고 HTML 갤러리로 연다.
#
#   bash scripts/render-previews.sh            # 전부
#   bash scripts/render-previews.sh pet        # 펫 스프라이트만
#   bash scripts/render-previews.sh card       # 트레이너 카드만
#   bash scripts/render-previews.sh scene      # 화면(가챠 탭·월드맵·길드·배틀)만
#   bash scripts/render-previews.sh anim       # 애니메이션(GIF)만 — 걷기·특수모션·메뉴바·배틀·사무실
#   NO_OPEN=1 bash scripts/render-previews.sh  # 브라우저를 열지 않음(CI/원격)
#
# 산출물: dist/previews/ (gitignore 대상)
# 프리뷰 테스트는 PREVIEW_OUT_DIR이 있을 때만 돌기 때문에, 일반 `swift test`와 CI는 영향이 없다.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${PREVIEW_OUT_DIR:-dist/previews}"

case "${1:-all}" in
  pet)   FILTER="PetSpritePreviews" ;;
  card)  FILTER="TrainerCardPreviews" ;;
  scene) FILTER="ScenePreviews" ;;
  anim)  FILTER="AnimationPreviews" ;;
  all)   FILTER="Previews" ;;          # 프리뷰 클래스 이름은 모두 Previews로 끝난다
  *)     echo "알 수 없는 대상: $1 (pet|card|scene|anim|all)" >&2; exit 2 ;;
esac

# 이전 실행 잔재를 지운다 — 매니페스트는 append-only라 비우지 않으면 삭제된 프리뷰가 갤러리에 남는다.
rm -rf "$OUT"
mkdir -p "$OUT"

echo "▶ 렌더 중 (filter=$FILTER) …"
PREVIEW_OUT_DIR="$(cd "$OUT" && pwd)" swift test --filter "$FILTER" 2>&1 \
  | grep -E "error:|failed|Executed [0-9]+ tests" || true

if [ ! -f "$OUT/manifest.jsonl" ]; then
  echo "✗ 렌더된 프리뷰가 없다. 위 로그의 error를 확인할 것." >&2
  exit 1
fi

python3 scripts/build_preview_gallery.py "$OUT"

COUNT=$(wc -l < "$OUT/manifest.jsonl" | tr -d ' ')
# ${} 중괄호 필수 — "$COUNT장"은 한글이 변수명에 붙어 `COUNT장`으로 파싱된다(set -u에서 즉시 죽음).
echo "✓ ${COUNT}장 → $OUT/index.html"

if [ -z "${NO_OPEN:-}" ]; then
  open "$OUT/index.html"
fi
