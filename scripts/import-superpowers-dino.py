#!/usr/bin/env python3
"""Superpowers Asset Packs(prehistoric-platformer, CC0)의 공룡 9종 Idle/Run strip을 추출한다.

각 공룡은 `{name}-1.png` 한 장에 여러 동작이 격자(그리드)로 담긴 멀티애니 시트다(Calciumtrice
슬라임과 유사). 투명 밴드로 행/열을 자동 탐지해 grid를 구하고, 행0=idle·행1=walk를 잘라
캐릭터 bbox로 트림한다. 공룡은 전부 좌향이라 렌더는 defaultFacingLeft: true.

소싱: GitHub 네이티브 CC0 저장소라 `gh api contents`로 raw PNG를 바로 받는다(itch 없음).

빌드 밖 일회성 스크립트. 의존: gh(인증됨), Pillow.
실행: python3 scripts/import-superpowers-dino.py
"""
import base64
import io
import os
import subprocess
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "sparklinlabs/superpowers-asset-packs"
BASE = "prehistoric-platformer/monsters"
DEST = os.path.join(ROOT, "Sources/ClaudeUsage/Resources/superpowers-dino")

# (원본 파일명, 출력 prefix) — prefix는 Resources 전역 basename 유일해야 함
# (기존 bat/plant/turtle과 충돌 회피: Dino* / *Rex).
CHARS = [
    ("bat", "DinoBat"), ("dragon", "DinoDragon"), ("insect", "DinoBug"),
    ("lizard", "DinoLizard"), ("mini-tyrannosaurus", "MiniRex"), ("plant", "DinoPlant"),
    ("pterodactyl", "Pterodactyl"), ("turtle", "DinoTurtle"), ("tyrannosaurus", "TRex"),
]


def gh_png(path):
    b64 = subprocess.check_output(
        ["gh", "api", f"repos/{REPO}/contents/{path}", "--jq", ".content"], text=True)
    return Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGBA")


def bands(mask):
    out, run, s = [], False, 0
    for i, v in enumerate(mask):
        if v and not run:
            run, s = True, i
        if not v and run:
            run = False
            out.append((s, i - 1))
    if run:
        out.append((s, len(mask) - 1))
    return out


def ubox(frames):
    bb = None
    for fr in frames:
        b = fr.getbbox()
        if not b:
            continue
        bb = b if not bb else (min(bb[0], b[0]), min(bb[1], b[1]), max(bb[2], b[2]), max(bb[3], b[3]))
    return bb


def main():
    os.makedirs(DEST, exist_ok=True)
    for name, prefix in CHARS:
        im = gh_png(f"{BASE}/{name}-1.png")
        W, H = im.size
        px = im.load()
        rows = bands([any(px[x, y][3] > 16 for x in range(W)) for y in range(H)])
        y0, y1 = rows[0]
        cols = bands([any(px[x, y][3] > 16 for y in range(y0, y1 + 1)) for x in range(W)])
        n, ch = len(cols), H // len(rows)
        cw = W // n

        def row_frames(r):
            return [im.crop((i * cw, r * ch, i * cw + cw, r * ch + ch)) for i in range(n)]

        idle = row_frames(0)
        walk = row_frames(1) if len(rows) >= 2 else idle
        ub, ib = ubox(idle + walk), ubox(idle)          # 좌우·상단=합집합, 하단(발)=idle
        x0, x1, yt, yb = ub[0], ub[2], ub[1], ib[3]
        tw, th = x1 - x0, yb - yt
        d = os.path.join(DEST, prefix)
        os.makedirs(d, exist_ok=True)

        def strip(frames):
            c = Image.new("RGBA", (tw * len(frames), th), (0, 0, 0, 0))
            for k, fr in enumerate(frames):
                c.paste(fr.crop((x0, yt, x1, yb)), (k * tw, 0))
            return c

        strip(idle).save(os.path.join(d, f"{prefix}_Idle.png"))
        strip(walk).save(os.path.join(d, f"{prefix}_Run.png"))
        print(f"{prefix:12s} cell {tw}x{th}  idle {len(idle)}f run {len(walk)}f")

    open(os.path.join(DEST, "LICENSE_Superpowers.txt"), "w").write(
        "Superpowers Asset Packs (prehistoric-platformer) — by pixel-boy / Sparklin Labs\n"
        "Source: https://github.com/sparklinlabs/superpowers-asset-packs\n"
        "License: CC0 1.0 Universal.\n")


if __name__ == "__main__":
    main()
