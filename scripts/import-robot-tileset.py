#!/usr/bin/env python3
"""0x72 16x16+ Robot Tileset(CC0)에서 "CI Runners" 로봇 9종의 Idle/Run strip을 재생성한다.

원본은 단일 512×512 타일시트로, 오른쪽에 로봇들이 IDLE(4프레임)/WALK(8프레임)/BROKEN 3열로
행마다 한 종씩 배치돼 있다. 왼쪽 절반은 환경 타일이라 무시한다. 각 로봇 행을 잘라
Sources/.../Resources/robot-tileset/{Prefix}/{Prefix}_{Idle,Run}.png 로 출력한다.
(기존 dungeon-tileset과 동일한 "시트 슬라이싱" 방식 — Pixel Frog 팩들의 종별 strip과 달리
0x72 팩은 한 시트에 다 들어있어 이 전처리가 필요하다.)

트림 정책 (import-tiny-swords-specials.py와 동일 계열):
- 가로(x0..x1) = idle+walk 전 프레임 alpha 합집합 → 팔/다리 뻗음까지 보존.
- 세로 상단 = idle 프레임 union top, 하단 = idle 프레임 union bottom(= 서 있는 발).
  walk의 상하 흔들림으로 cellH가 커지지 않게 idle 기준으로 고정 → 발이 차트 라인에 닿는다.
- idle/run 두 strip은 같은 (cw, ch)로 잘려 PetDefinition.cellSize 하나로 렌더된다.

소싱: itch.io 직접 다운로드가 막히는 사내망에서도, 이 CC0 시트를 커밋해 둔 GitHub repo가
많아(gh code search) `gh api contents`로 base64 추출이 가능하다(메모: pet-asset-sourcing).

빌드 밖 일회성 스크립트. 의존: gh(인증됨), Pillow.
실행: python3 scripts/import-robot-tileset.py
"""
import base64
import io
import os
import subprocess
from PIL import Image

# CC0 시트를 커밋해 둔 공개 repo (원본 파일명 0x72_16x16RobotTileset.v1.png).
SRC_REPO = "omn0mn0m/Scrap-Repair"
SRC_PATH = "assets/0x72_16x16RobotTileset.v1.png"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, "Sources/ClaudeUsage/Resources/robot-tileset")

# 행 = 종. y 밴드(마지막 큰 밴드는 세로로 붙은 두 종이라 반으로 분리).
BANDS = [(21, 47), (54, 79), (86, 111), (118, 143), (152, 177),
         (190, 239), (247, 271), (279, 303)]
# 출력 prefix (행 순서대로). PetKind/PetDefinition의 prefix와 일치해야 한다.
PREFIX = ["ScrapBot", "AntennaBot", "PixelBot", "SpiderBot", "SentryBot",
          "MiniBot", "VisorBot", "BatBot", "BeaconBot"]

CW = 16                                   # 원본 셀 폭
IDLE_X = [208 + CW * i for i in range(4)]  # IDLE 4프레임 시작 x
WALK_X = [288 + CW * i for i in range(8)]  # WALK 8프레임 시작 x


def load_sheet() -> Image.Image:
    b64 = subprocess.check_output(
        ["gh", "api", f"repos/{SRC_REPO}/contents/{SRC_PATH}", "--jq", ".content"],
        text=True)
    return Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGBA")


def split_rows():
    rows = []
    for y0, y1 in BANDS:
        if y1 - y0 + 1 > 34:            # 붙어있는 두 종 → 반으로
            mid = (y0 + y1) // 2
            rows += [(y0, mid), (mid + 1, y1)]
        else:
            rows.append((y0, y1))
    return rows


def ubox(frames):
    bb = None
    for f in frames:
        b = f.getbbox()
        if b is None:
            continue
        bb = b if bb is None else (min(bb[0], b[0]), min(bb[1], b[1]),
                                   max(bb[2], b[2]), max(bb[3], b[3]))
    return bb


def main():
    im = load_sheet()
    rows = split_rows()
    assert len(rows) == len(PREFIX), f"행 {len(rows)} != prefix {len(PREFIX)}"

    def crop(xs, y0, y1):
        return [im.crop((x, y0, x + CW, y1 + 1)) for x in xs]

    for (y0, y1), prefix in zip(rows, PREFIX):
        idle, walk = crop(IDLE_X, y0, y1), crop(WALK_X, y0, y1)
        ub, ib = ubox(idle + walk), ubox(idle)
        x0, x1, yt, yb = ub[0], ub[2], ib[1], ib[3]
        cw, ch = x1 - x0, yb - yt
        outdir = os.path.join(DST, prefix)
        os.makedirs(outdir, exist_ok=True)

        def strip(frames):
            canvas = Image.new("RGBA", (cw * len(frames), ch), (0, 0, 0, 0))
            for k, f in enumerate(frames):
                canvas.paste(f.crop((x0, yt, x1, yb)), (k * cw, 0))
            return canvas

        strip(idle).save(os.path.join(outdir, f"{prefix}_Idle.png"))
        strip(walk).save(os.path.join(outdir, f"{prefix}_Run.png"))
        print(f"{prefix}: cellSize ({cw}, {ch})  idle4 walk8")


if __name__ == "__main__":
    main()
