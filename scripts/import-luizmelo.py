#!/usr/bin/env python3
"""LuizMelo 다크판타지 몬스터 팩(CC0)의 캐릭터별 Idle/Run strip을 추출한다.

LuizMelo 스프라이트는 150px(일부 200px) 정사각 캔버스에 캐릭터가 여백과 함께 중앙 배치돼
있고, 동작별 가로 strip PNG로 배포된다. 0x72/Tiny Swords처럼 캔버스 여백이 커서
캐릭터 bbox로 트림해 재스티칭해야 차트 라인에 발이 닿는다(안 그러면 공중에 작게 뜬다).

소싱: itch.io 페이지가 upload_id를 HTML에 노출하지 않아 직다운이 까다롭지만, 이 CC0 에셋은
수많은 GitHub 게임 repo에 커밋돼 있어 `gh api contents`로 base64 추출이 쉽다(메모: pet-asset-sourcing).

빌드 밖 일회성 스크립트. 의존: gh(인증됨), Pillow.
실행: python3 scripts/import-luizmelo.py
"""
import base64
import io
import os
import subprocess
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 팩 설정: 미러 repo + 팩 base 경로 + 캔버스 셀폭 + (char폴더, prefix, idle_anim, run_anim).
# prefix는 Resources 전역에서 basename 유일해야 함(기존 goblin/mushroom/skeleton과 충돌 회피).
MCF = {
    "repo": "LostinAUT/ShadowCastle",
    "base": "img/enemy/Monsters_Creatures_Fantasy",
    "outdir": "luizmelo-mcf",
    "cell": 150,
    "chars": [
        ("Flying eye", "FlyingEye", "Flight", "Flight"),   # 비행형 — Flight를 idle/run 겸용
        ("Goblin", "GoblinBrute", "Idle", "Run"),
        ("Mushroom", "Myconid", "Idle", "Run"),
        ("Skeleton", "SkeletonLord", "Idle", "Walk"),
    ],
    "credit": "Monsters Creatures Fantasy — by LuizMelo\n"
              "Source: https://luizmelo.itch.io/monsters-creatures-fantasy\n"
              "License: CC0 (Public Domain).\n",
}


def gh_png(repo, path):
    b64 = subprocess.check_output(
        ["gh", "api", f"repos/{repo}/contents/{path}", "--jq", ".content"], text=True)
    return Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGBA")


def frames(img, cell):
    n = max(1, img.width // cell)
    return [img.crop((i * cell, 0, i * cell + cell, img.height)) for i in range(n)]


def ubox(fs):
    bb = None
    for f in fs:
        b = f.getbbox()
        if not b:
            continue
        bb = b if not bb else (min(bb[0], b[0]), min(bb[1], b[1]), max(bb[2], b[2]), max(bb[3], b[3]))
    return bb


def main(cfg=MCF):
    dest = os.path.join(ROOT, "Sources/ClaudeUsage/Resources", cfg["outdir"])
    os.makedirs(dest, exist_ok=True)
    cell = cfg["cell"]
    for folder, prefix, ia, ra in cfg["chars"]:
        idle = frames(gh_png(cfg["repo"], f"{cfg['base']}/{folder}/{ia}.png"), cell)
        run = frames(gh_png(cfg["repo"], f"{cfg['base']}/{folder}/{ra}.png"), cell)
        ub, ib = ubox(idle + run), ubox(idle)          # 좌우·상단=합집합, 하단(발)=idle 기준
        x0, x1, yt, yb = ub[0], ub[2], ub[1], ib[3]
        cw, ch = x1 - x0, yb - yt
        d = os.path.join(dest, prefix)
        os.makedirs(d, exist_ok=True)

        def strip(fs):
            c = Image.new("RGBA", (cw * len(fs), ch), (0, 0, 0, 0))
            for k, f in enumerate(fs):
                c.paste(f.crop((x0, yt, x1, yb)), (k * cw, 0))
            return c

        strip(idle).save(os.path.join(d, f"{prefix}_Idle.png"))
        strip(run).save(os.path.join(d, f"{prefix}_Run.png"))
        print(f"{prefix:14s} cell {cw}x{ch}  idle {len(idle)}f run {len(run)}f")
    open(os.path.join(dest, "LICENSE_LuizMelo_MCF.txt"), "w").write(cfg["credit"])


if __name__ == "__main__":
    main()
