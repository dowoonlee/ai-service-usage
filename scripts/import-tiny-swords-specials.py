#!/usr/bin/env python3
"""Tiny Swords(Mythic 펫)의 Idle/Run/특수 모션 strip을 재생성한다.

ZieIony/TinySwords 미러(Pixel Frog Tiny Swords, 에셋은 CC0)에서 원본 시트를 받아
세로 공통·가로 모션별로 트림해 Sources/.../mythic/{unit}/*.png 로 출력한다.
(mythic 펫은 일반 펫과 분리된 Resources/mythic/ 디렉토리로 관리한다.)

트림 정책:
- 세로 상단 Y0 = '모든 모션 프레임' alpha 합집합의 top (무기를 위로 든 프레임까지 포함).
- 세로 하단 Y1 = 'idle 프레임'의 alpha bottom (= 서 있는 발). 이게 셀 바닥이 되어
  차트 라인에 발이 닿는다. 전체 합집합으로 하단을 잡으면 공격 시 검/뻗은 다리가
  idle보다 아래로 내려가 cellH가 커지고, 평소 idle/run이 그만큼 공중에 떠 보인다.
  → 공격 프레임이 Y1 아래로 나가는 부분은 잘리지만(가끔·잠깐), 평소 정렬을 우선한다.
- cellH(=Y1-Y0)는 모션 간 동일 → WalkingCat의 height 정규화에서 캐릭터 크기 일관.
- 가로(X0..X1)는 그룹별: idle+run은 공통('ir'), 특수 모션은 각자 → 무기 휘두름 폭 보존.

빌드 밖 일회성 스크립트. 의존: gh(인증됨), Pillow. 사내망에서 itch.io 직접 다운은
막히지만 gh api는 동작한다(메모리: pet-asset-sourcing 참조).

실행: python3 scripts/import-tiny-swords-specials.py
"""
import base64
import os
import subprocess
from PIL import Image

REPO = "ZieIony/TinySwords"
BASE = "Assets/Art/Units/Blue%20Units"  # 경로 공백은 %20
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, "Sources/ClaudeUsage/Resources/mythic")

# unit -> (cell, [(outfile, src 상대경로, hgroup)])
# hgroup: 같은 문자열끼리 가로 bbox 공유. idle/run='ir', 특수 모션은 각자.
UNITS = {
    "Warrior": (192, [
        ("Warrior_Idle", "Warrior/Warrior_Idle.png", "ir"),
        ("Warrior_Run", "Warrior/Warrior_Run.png", "ir"),
        ("Warrior_Attack1", "Warrior/Warrior_Attack1.png", "a1"),
        ("Warrior_Attack2", "Warrior/Warrior_Attack2.png", "a2"),
    ]),
    "Lancer": (320, [
        ("Lancer_Idle", "Lancer/Lancer_Idle.png", "ir"),
        ("Lancer_Run", "Lancer/Lancer_Run.png", "ir"),
        ("Lancer_Attack", "Lancer/Lancer_Right_Attack.png", "a1"),  # 측면 찌르기
    ], "helmet"),   # 창이 아니라 투구(본체) 기준으로 크기 산정 (창 위쪽은 잘림)
    "Monk": (192, [
        ("Monk_Idle", "Monk/Idle.png", "ir"),
        ("Monk_Run", "Monk/Run.png", "ir"),
        ("Monk_Heal", "Monk/Heal.png", "a1"),
    ]),
}


def fetch(rel_path):
    """gh api로 raw PNG를 받아 PIL Image(RGBA)로."""
    out = subprocess.check_output(
        ["gh", "api", f"repos/{REPO}/contents/{BASE}/{rel_path}", "--jq", ".content"])
    import io
    return Image.open(io.BytesIO(base64.b64decode(out))).convert("RGBA")


def split(img, cell):
    w, _ = img.size
    return [img.crop((i * cell, 0, i * cell + cell, cell)) for i in range(w // cell)]


def union(frames):
    bs = [b for b in (f.getbbox() for f in frames) if b]
    return (min(b[0] for b in bs), min(b[1] for b in bs),
            max(b[2] for b in bs), max(b[3] for b in bs))


def helmet_top(frames, ratio=0.5):
    """idle 프레임에서 '본체(투구/몸)' 상단 y를 찾는다 — 창처럼 위로 솟은 얇은 돌출물은 제외.
    각 행의 alpha 가로폭이 본체 최대폭의 ratio 이상이 되는 최상단 행(프레임 간 가장 위값)."""
    tops = []
    for f in frames:
        W, H = f.size
        px = f.load()
        rows = []
        for y in range(H):
            xs = [x for x in range(W) if px[x, y][3] > 0]
            rows.append((max(xs) - min(xs) + 1) if xs else 0)
        th = max(rows) * ratio if rows else 0
        tops.append(next((y for y in range(H) if rows[y] >= th), 0))
    return min(tops)


def build(unit, cell, anims, top_ref="full"):
    loaded = {out: split(fetch(src), cell) for out, src, _ in anims}
    idle = next(loaded[o] for o, _, _ in anims if o.endswith("Idle"))
    # 상단 Y0: 기본은 전체 모션 합집합(무기 위로 포함). 'helmet'이면 창 등 세로 돌출물을 빼고
    # 투구(본체) 상단 기준 — 창기병처럼 긴 무기가 본체를 작아 보이게 하는 걸 막는다(창 위쪽은 잘림).
    if top_ref == "helmet":
        Y0 = helmet_top(idle)
    else:
        Y0 = union([f for frs in loaded.values() for f in frs])[1]
    Y1 = union(idle)[3]                                          # 하단: idle 발(차트 라인 기준)
    groups = {}
    for out, _, g in anims:
        groups.setdefault(g, []).extend(loaded[out])
    hbox = {g: (union(frs)[0], union(frs)[2]) for g, frs in groups.items()}
    os.makedirs(os.path.join(DST, unit), exist_ok=True)
    print(f"--- {unit}: cellH={Y1 - Y0}")
    for out, _, g in anims:
        X0, X1 = hbox[g]
        W = X1 - X0
        frs = loaded[out]
        strip = Image.new("RGBA", (W * len(frs), Y1 - Y0), (0, 0, 0, 0))
        for i, f in enumerate(frs):
            strip.paste(f.crop((X0, Y0, X1, Y1)), (i * W, 0))
        strip.save(os.path.join(DST, unit, out + ".png"))
        print(f"  {out}.png: {W}x{Y1 - Y0} ({len(frs)}f)")


if __name__ == "__main__":
    for unit, conf in UNITS.items():
        top_ref = conf[2] if len(conf) > 2 else "full"
        build(unit, conf[0], conf[1], top_ref)
    print("DONE")
