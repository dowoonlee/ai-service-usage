#!/usr/bin/env python3
"""GrafxKid Sprite Pack(CC0)의 캐릭터별 Idle/Run strip을 Resources/grafxkid-N/ 로 추출한다.

GrafxKid 팩은 itch.io에서 "Sprite Pack N.zip"으로 배포되며, zip 안에 캐릭터별 폴더 +
동작별 개별 strip PNG(파일명에 셀 크기 "(W x H)" 명시)가 들어있다. 0x72 통짜 시트와 달리
셀 측정/슬라이싱이 불필요하고, idle/run 파일을 그대로 복사하면 된다. 정지/이동 애니메이션이
literal "Idle"/"Run"이 아닌 종은 Standing/Swimming/Rolling/Flapping 등을 alias로 지정한다.

itch.io "name your own price" 무료 다운로드 흐름:
  GET 페이지 → csrf_token + data-upload_id 파싱 → POST /{slug}/file/{upload_id} → 서명 URL → 다운로드.
사내망에서 itch 접근이 막히면 개인망에서 zip을 받아 --zip 로 넘겨도 된다.

빌드 밖 일회성 스크립트. 의존: requests(또는 urllib), Pillow.
실행: python3 scripts/import-grafxkid.py            # Pack 1 다운로드+추출
     python3 scripts/import-grafxkid.py --zip a.zip # 이미 받은 zip에서 추출
"""
import argparse
import io
import os
import re
import shutil
import sys
import urllib.request
import urllib.parse
import zipfile
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UA = {"User-Agent": "Mozilla/5.0"}

# 팩별 설정: (itch slug, 출력 dir 접미, zip 내 루트 폴더, [(폴더, prefix, idle_anim, run_anim)])
# 정지/이동 애니메이션이 없는 종은 Standing/Swimming/Rolling/Flapping을 idle/run으로 alias.
PACK1 = {
    "slug": "sprite-pack-1",
    "outdir": "grafxkid-1",
    "root": "Sprite Pack 1",
    # SwiftPM는 Resources 경로를 flatten하므로 LICENSE basename도 팩마다 유일해야 한다.
    "license_name": "LICENSE_GrafxKid1.txt",
    "chars": [
        ("1 - Mr. Man", "MrMan", "Idle", "Run"),
        ("2 - Bumpy the Robot", "BumpyBot", "Idle", "Running"),
        ("3 - Princess Sera", "PrincessSera", "Idle", "Running"),
        ("4 - Bushly", "Bushly", "Idle", "Running"),
        ("5 - Devo the Devil", "DevoDevil", "Standing", "Running"),
        ("6 - Rolling Nero", "RollingNero", "Rolling", "Rolling"),
        ("7 - Gloppy Slime", "GloppySlime", "Idle", "Idle"),
        ("8 - Chi Chi the Bird", "ChiChiBird", "Standing", "Flapping_Wings"),
        ("9 - Diver the Fish", "DiverFish", "Swimming", "Swimming"),
        ("10 - Bub", "Bub", "Idle", "Running"),
        ("11 - Spikey Bub", "SpikeyBub", "Idle", "Running"),
        ("12 - Pokey Bub", "PokeyBub", "Idle", "Running"),
        ("13 - Blocky Bub", "BlockyBub", "Idle", "Running"),
    ],
    "credit": "Sprite Pack 1 — by GrafxKid\nSource: https://grafxkid.itch.io/sprite-pack-1\n"
              "License: CC0 (Public Domain). Crediting is optional (author).\n",
}

# 셀 크기가 애니메이션마다 다른 종은 idle/run을 같은 크기 애니메이션으로 골라야 한다
# (RoboTotem=Armored 통일, CheesePuff=Tank 통일, SnipCrab=32x32 통일).
PACK2 = {
    "slug": "sprite-pack-2",
    "outdir": "grafxkid-2",
    "root": "Sprite Pack 2",
    "license_name": "LICENSE_GrafxKid2.txt",
    "chars": [
        ("1 - Onion Lad", "OnionLad", "Idle", "Run_&_Jump"),
        ("2 - Mr. Mochi", "MrMochi", "Idle", "Running"),
        ("3 - Octi", "Octi", "Idle_&_Movement", "Idle_&_Movement"),
        ("4 - Robo Pumpkin", "RoboPumpkin", "Standing", "Walking"),
        ("5 - Daikon", "Daikon", "Hopping", "Hopping"),
        ("6 - Robo Totem", "RoboTotem", "Armored_Standing", "Armored_Walking"),
        ("7 - Rocket Cherry", "RocketCherry", "Hopping", "Flying"),
        ("8 - Comrade Cheese Puff", "CheesePuff", "Tank_Movement", "Tank_Movement"),
        ("9 - Snip Snap Crab", "SnipCrab", "Reaching_to_Pinch", "Movement_(Flip_image_back_and_forth)"),
    ],
    "credit": "Sprite Pack 2 — by GrafxKid\nSource: https://grafxkid.itch.io/sprite-pack-2\n"
              "License: CC0 (Public Domain). Crediting is optional (author).\n",
}

PACK3 = {
    "slug": "sprite-pack-3",
    "outdir": "grafxkid-3",
    "root": "Sprite Pack 3",
    "license_name": "LICENSE_GrafxKid3.txt",
    "chars": [
        ("1 - Gum Bot", "GumBot", "Idle", "Walking"),
        ("2 - Twiggy", "Twiggy", "Idle", "Running"),
        ("3 - Robot J5", "RobotJ5", "Idle", "Running"),
        ("4 - Tommy", "Tommy", "Idle_Poses", "Running"),
        ("5 - Geralt", "Geralt", "Idle", "Running"),
    ],
    "credit": "Sprite Pack 3 — by GrafxKid\nSource: https://grafxkid.itch.io/sprite-pack-3\n"
              "License: CC0 (Public Domain). Crediting is optional (author).\n",
}

def _pack(pk, flat=False, chars=None):
    return {
        "slug": f"sprite-pack-{pk}", "outdir": f"grafxkid-{pk}", "root": f"Sprite Pack {pk}",
        "license_name": f"LICENSE_GrafxKid{pk}.txt", "flat": flat, "chars": chars,
        "credit": f"Sprite Pack {pk} — by GrafxKid\nSource: https://grafxkid.itch.io/sprite-pack-{pk}\n"
                  "License: CC0 (Public Domain). Crediting is optional (author).\n",
    }

# Pack 4는 하위폴더 없는 flat 구조(root/N - Char_Anim (WxH).png) — chars의 1번째 필드가 캐릭터명.
PACK4 = _pack(4, flat=True, chars=[
    ("Agent_Mike", "AgentMike", "Idle", "Running"), ("Martian_Red", "MartianRed", "Idle", "Running"),
    ("Hermie", "Hermie", "Idle", "Crawling"), ("Ballooney", "Ballooney", "Flying", "Flying"),
    ("Robot_Walky", "RobotWalky", "Idle", "Movement"), ("Jumpy_Lumpy", "JumpyLumpy", "Idle", "Leaping_&_Falling"),
    ("Orchid_Owl", "OrchidOwl", "Idle", "Flying"), ("Roach", "Roach", "Idle", "Running"),
    ("Mr._Circuit", "MrCircuit", "Idle", "Running"), ("Blankey", "Blankey", "Floating", "Floating"),
])
PACK5 = _pack(5, chars=[
    ("1 - Robo Retro", "RoboRetro", "Idle", "Walking"), ("2 - Lil Wiz", "LilWiz", "Idle", "Running"),
    ("3 - Big Red", "BigRed", "Idle", "Running"), ("4 - Squirmy Wormy", "SquirmyWormy", "Movement", "Movement"),
    ("5 - Moe Scotty", "MoeScotty", "Flying", "Flying"), ("6 - Mr. Chomps", "MrChomps", "Crawl_&_Blink", "Crawling"),
    ("7 - Grizzly", "Grizzly", "Idle", "Walking"), ("8 - Orc", "Orc", "Idle", "Walking"),
    ("9 - Wispy Fire", "WispyFire", "Idle_Flicker", "Idle_Flicker"),
])
PACK6 = _pack(6, chars=[
    ("1 - Penguin", "Penguin", "Idle", "Swimming"), ("2 - Fairy", "Fairy", "Idle_Ground", "Flying_Forward_Movement"),
    ("3 - Skeleton", "Skeleton", "Standing_Idle", "Standing_Idle"), ("4 - Orange", "Orange", "Idle", "Walking"),
])
PACK7 = _pack(7, chars=[
    ("1 - Diego", "Diego", "Idle", "Running"), ("2 - Holly", "Holly", "Idle", "Running"),
    ("3 - Gordon", "Gordon", "Idle", "Running"),
])
PACK8 = _pack(8, chars=[
    ("1 - Toggle", "Toggle", "Idle", "Run"), ("2 - Tracy", "Tracy", "Idle_1", "Run"),
    ("3 - Armand", "Armand", "Idle", "Walking"), ("4 - Percy", "Percy", "Idle", "Running"),
    ("5 - Vessa", "Vessa", "Idle_Dance", "Idle_Dance"), ("6 - Angie", "Angie", "Idle_1", "Running"),
    ("7 - Barry Cherry", "BarryCherry", "Idle", "Running"),
])

PACKS = {1: PACK1, 2: PACK2, 3: PACK3, 4: PACK4, 5: PACK5, 6: PACK6, 7: PACK7, 8: PACK8}


def itch_download_zip(slug: str) -> bytes:
    base = f"https://{'grafxkid'}.itch.io/{slug}"
    html = urllib.request.urlopen(urllib.request.Request(base, headers=UA), timeout=25).read().decode("utf-8", "replace")
    csrf = re.search(r'name="csrf_token" value="([^"]+)"', html).group(1)
    upload_id = re.search(r'data-upload_id="(\d+)"', html).group(1)
    body = urllib.parse.urlencode({"csrf_token": csrf}).encode()
    req = urllib.request.Request(f"{base}/file/{upload_id}?source=game_download", data=body, headers=UA)
    import json
    url = json.load(urllib.request.urlopen(req, timeout=25))["url"]
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60).read()


def _stem(basename):
    """'Idle (32 x 32).png' / 'Idle_(32 x 32).png' → 'Idle' (팩마다 공백/언더스코어 형식이 다름)."""
    return re.sub(r'[ _]?\(\d+\s*x\s*\d+\)\.png$', '', basename, flags=re.I)


def find_in_zip(zf, root, folder, anim):
    """folder 구조(pack 1~3,5~8): root/folder/Anim (WxH).png. stem 정확 매칭."""
    for n in zf.namelist():
        p = n.split("/")
        if len(p) >= 3 and p[0] == root and p[1] == folder and p[-1].endswith(".png") \
           and _stem(p[-1]).lower() == anim.lower():
            return n
    return None


def find_flat(zf, root, char, anim):
    """flat 구조(pack 4): root/N - Char_Anim (WxH).png. stem에서 'N - ' 뒤가 Char_Anim."""
    target = f"{char}_{anim}".lower()
    for n in zf.namelist():
        p = n.split("/")
        if len(p) == 2 and p[0] == root and p[1].endswith(".png"):
            body = _stem(p[1]).split(" - ", 1)
            body = body[1] if len(body) == 2 else body[0]
            if body.lower() == target:
                return n
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", type=int, default=1, choices=sorted(PACKS), help="GrafxKid 팩 번호")
    ap.add_argument("--zip", help="이미 받은 Sprite Pack zip 경로")
    args = ap.parse_args()
    cfg = PACKS[args.pack]

    data = open(args.zip, "rb").read() if args.zip else itch_download_zip(cfg["slug"])
    zf = zipfile.ZipFile(io.BytesIO(data))
    dest = os.path.join(ROOT, "Sources/ClaudeUsage/Resources", cfg["outdir"])

    def cell(name):
        return tuple(map(int, re.search(r'\((\d+)\s*x\s*(\d+)\)', name).groups()))

    finder = find_flat if cfg.get("flat") else find_in_zip
    for folder, prefix, ia, ra in cfg["chars"]:
        ip = finder(zf, cfg["root"], folder, ia)
        rp = finder(zf, cfg["root"], folder, ra)
        if not ip or not rp:
            print(f"MISSING {prefix}: idle={ip} run={rp}", file=sys.stderr)
            continue
        if cell(ip) != cell(rp):   # 렌더러는 단일 cellSize를 쓰므로 idle/run 셀이 같아야 함
            print(f"CELL MISMATCH {prefix}: idle{cell(ip)} run{cell(rp)} — 매핑 수정 필요", file=sys.stderr)
            continue
        cw, ch = cell(ip)
        d = os.path.join(dest, prefix)
        os.makedirs(d, exist_ok=True)
        with zf.open(ip) as f:
            open(os.path.join(d, f"{prefix}_Idle.png"), "wb").write(f.read())
        with zf.open(rp) as f:
            open(os.path.join(d, f"{prefix}_Run.png"), "wb").write(f.read())
        iw = Image.open(os.path.join(d, f"{prefix}_Idle.png")).size[0]
        print(f"{prefix:14s} cell {cw}x{ch}  idle {iw//cw}f  (src idle={ia}, run={ra})")

    open(os.path.join(dest, cfg["license_name"]), "w").write(cfg["credit"])


if __name__ == "__main__":
    main()
