#!/usr/bin/env python3
"""Tiny Swords(Mythic 펫)의 Idle/Run/특수 모션 strip을 재생성한다.

ZieIony/TinySwords 미러(Pixel Frog Tiny Swords, 에셋은 CC0)에서 원본 시트를 받아
세로 공통·가로 모션별로 트림해 Sources/.../tiny-swords/{unit}/*.png 로 출력한다.

트림 정책:
- 세로(Y0..Y1)는 한 펫의 '모든 모션 프레임' alpha 합집합 → 모션 간 cellH 동일.
  WalkingCat이 height 기준으로 정규화하므로 cellH가 같아야 캐릭터 크기·발 위치가 일치한다.
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
DST = os.path.join(ROOT, "Sources/ClaudeUsage/Resources/tiny-swords")

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
    ]),
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


def build(unit, cell, anims):
    loaded = {out: split(fetch(src), cell) for out, src, _ in anims}
    _, Y0, _, Y1 = union([f for frs in loaded.values() for f in frs])
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
    for unit, (cell, anims) in UNITS.items():
        build(unit, cell, anims)
    print("DONE")
