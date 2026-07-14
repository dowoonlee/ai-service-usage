#!/usr/bin/env python3
"""LuizMelo itch.io 무료 팩(CC0)에서 히어로/몬스터/반려동물의 Idle/Run strip을 추출한다.

LuizMelo itch 페이지는 data-upload_id를 본문 HTML에 노출하지 않아 직다운이 까다롭다.
무료(name-your-price) 다운로드 흐름:
  GET 페이지 → csrf → POST /{slug}/download_url → 다운로드 페이지 URL
  → GET 다운로드 페이지 → data-upload_id + csrf2 → POST /{slug}/file/{upload_id} → 서명 URL → zip

프레임은 가로 strip이며 캔버스 여백이 커서 캐릭터 bbox로 트림한다. 프레임 폭은 정사각이
아닐 수 있어 n=round(W/H), frame_w=W/n 으로 분할한다(일부 팩은 프레임이 미세하게 직사각).

빌드 밖 일회성 스크립트. 의존: Pillow (표준 urllib). 사내망에서 itch 차단 시 개인망 필요.
실행: python3 scripts/import-luizmelo-itch.py
"""
import io
import json
import os
import re
import time
import urllib.parse
import urllib.request
import zipfile
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Sources/ClaudeUsage/Resources")
UA = {"User-Agent": "Mozilla/5.0"}


def _opener():
    o = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
    o.addheaders = [("User-Agent", "Mozilla/5.0")]
    return o


def _get(o, url, data=None, tries=6):
    for i in range(tries):
        try:
            return o.open(urllib.request.Request(url, data=data), timeout=35)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(7 * (i + 1))
                continue
            raise
    raise SystemExit("429 " + url)


def download_zip(slug):
    o = _opener()
    base = f"https://luizmelo.itch.io/{slug}"
    html = _get(o, base).read().decode("utf-8", "replace")
    csrf = re.search(r'csrf_token" value="([^"]+)"', html).group(1)
    body = urllib.parse.urlencode({"csrf_token": csrf}).encode()
    dl_page = json.load(_get(o, f"{base}/download_url", data=body))["url"]
    dl = _get(o, dl_page).read().decode("utf-8", "replace")
    uid = re.search(r'data-upload_id="(\d+)"', dl).group(1)
    csrf2 = re.search(r'csrf_token" value="([^"]+)"', dl).group(1)
    b = urllib.parse.urlencode({"csrf_token": csrf2}).encode()
    furl = json.load(_get(o, f"{base}/file/{uid}", data=b))["url"]
    return _get(o, furl).read()


def _frames(img):
    W, H = img.size
    n = max(1, round(W / H))
    fw = W / n
    return [img.crop((round(i * fw), 0, round((i + 1) * fw), H)) for i in range(n)]


def _ubox(fs):
    bb = None
    for fr in fs:
        b = fr.getbbox()
        if not b:
            continue
        bb = b if not bb else (min(bb[0], b[0]), min(bb[1], b[1]), max(bb[2], b[2]), max(bb[3], b[3]))
    return bb


def extract(idle_img, run_img, dest, prefix):
    idle, run = _frames(idle_img), _frames(run_img)
    ub, ib = _ubox(idle + run), _ubox(idle)
    x0, x1, yt, yb = ub[0], ub[2], ub[1], ib[3]
    tw, th = x1 - x0, yb - yt
    d = os.path.join(dest, prefix)
    os.makedirs(d, exist_ok=True)

    def strip(fs):
        c = Image.new("RGBA", (tw * len(fs), th), (0, 0, 0, 0))
        for k, fr in enumerate(fs):
            c.paste(fr.crop((x0, yt, x1, yb)), (k * tw, 0))
        return c

    strip(idle).save(os.path.join(d, f"{prefix}_Idle.png"))
    strip(run).save(os.path.join(d, f"{prefix}_Run.png"))
    print(f"{prefix:16s} ({tw}, {th})")


def _img(zf, endswith):
    n = [x for x in zf.namelist() if x.endswith(endswith)][0]
    return Image.open(io.BytesIO(zf.read(n))).convert("RGBA")


def _img_base(zf, base):
    n = [x for x in zf.namelist() if os.path.basename(x).lower() == base.lower()][0]
    return Image.open(io.BytesIO(zf.read(n))).convert("RGBA")


# (slug, prefix, idle_endswith, run_endswith) — ArcaneWizard/MedievalWarrior는 idle 내 캐릭터
# 이동으로 union bbox가 넓어져 제외함.
HEROES = [
    ("hero-knight", "HeroKnight", "/Idle.png", "/Run.png"),
    ("huntress", "Huntress", "/Idle.png", "/Run.png"),
    ("evil-wizard-2", "EvilWizard", "/Idle.png", "/Run.png"),
    ("medieval-king-pack", "MedievalKing", "/Idle.png", "/Run.png"),
    ("martial-hero", "MartialHero", "/Idle.png", "/Run.png"),
    ("fantasy-warrior", "FantasyWarrior", "/Idle.png", "/Run.png"),
    ("fire-worm", "FireWorm", "/Idle.png", "/Walk.png"),
]
DOGS = [("Akita", "Akita"), ("Golden-Retriever", "GoldenRetriever"), ("Great-Dane", "GreatDane"),
        ("Saint-Bernard", "SaintBernard"), ("Schnauzer", "Schnauzer"), ("Siberian-Husky", "Husky")]
MCF2 = [("Bat", "VampireBat", "fly.png", "fly.png"), ("Mimic", "Mimic", "Idle_closed.png", "walk.png"),
        ("Rat", "GiantRat", "idle.png", "run.png"), ("Slime", "KingSlime", "idle.png", "walk.png")]


def main():
    dh = os.path.join(RES, "luizmelo-heroes")
    for slug, prefix, i, r in HEROES:
        zf = zipfile.ZipFile(io.BytesIO(download_zip(slug)))
        extract(_img(zf, i), _img(zf, r), dh, prefix)
        time.sleep(2)
    open(os.path.join(dh, "LICENSE_LuizMelo_Heroes.txt"), "w").write("LuizMelo hero packs (CC0) — https://luizmelo.itch.io/\n")

    dp = os.path.join(RES, "luizmelo-pets")
    zc = zipfile.ZipFile(io.BytesIO(download_zip("pet-cat-pack")))
    for i in range(1, 7):
        extract(_img(zc, f"Cat-{i}-Idle.png"), _img(zc, f"Cat-{i}-Run.png"), dp, f"Cat{i}")
    zd = zipfile.ZipFile(io.BytesIO(download_zip("pet-dogs-pack")))
    for fn, prefix in DOGS:
        extract(_img_base(zd, f"{fn}-Idle.png"), _img_base(zd, f"{fn}-run.png"), dp, prefix)
    open(os.path.join(dp, "LICENSE_LuizMelo_Pets.txt"), "w").write("LuizMelo Pet Cat/Dogs Pack (CC0) — https://luizmelo.itch.io/\n")

    dm = os.path.join(RES, "luizmelo-mcf2")
    zm = zipfile.ZipFile(io.BytesIO(download_zip("monsters-creatures-fantasy-2")))
    for folder, prefix, i, r in MCF2:
        extract(_img(zm, f"/{folder}/{i}"), _img(zm, f"/{folder}/{r}"), dm, prefix)
    open(os.path.join(dm, "LICENSE_LuizMelo_MCF2.txt"), "w").write(
        "LuizMelo Monsters Creatures Fantasy 2 (CC0) — https://luizmelo.itch.io/monsters-creatures-fantasy-2\n")


if __name__ == "__main__":
    main()
