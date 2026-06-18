#!/usr/bin/env python3
"""날씨 파티클용 픽셀 스프라이트(눈송이·빗방울)를 PIL로 생성.

itch/OGA 등 외부 자산을 받지 않고 직접 그린다 — 라이선스/사내망 다운로드 이슈 회피.
출력은 Sources/ClaudeUsage/Resources/weather/ 아래의 단일 PNG.
SwiftPM 번들은 경로를 flatten하므로 basename(raindrop/snowflake)이 전역에서 유일해야 한다.

기존 펫 스프라이트 톤과 맞추려 도트(픽셀) 1:1로 그리고, 앱에서 interpolation(.none)으로 확대한다.
"""
import os
from PIL import Image

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources", "ClaudeUsage", "Resources", "weather",
)

# 색 — 알파는 픽셀별로 지정.
SNOW = (244, 250, 255)        # 거의 흰색
RAIN = (150, 205, 240)        # 하늘색
RAIN_HI = (210, 238, 252)     # 빗방울 하이라이트


def save(name, w, h, pixels):
    """pixels: {(x, y): (r, g, b[, a])} — 누락 좌표는 투명."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    for (x, y), c in pixels.items():
        if len(c) == 3:
            c = (*c, 255)
        px[x, y] = c
    path = os.path.join(OUT_DIR, name)
    img.save(path)
    print(f"  {name}  ({w}x{h})  ->  {path}")


def snowflake():
    """9x9 6각풍 눈 결정 — 십자 + 각 팔 끝의 V자 가지 + 중심."""
    w = h = 9
    p = {}
    # 수직·수평 십자
    for i in range(h):
        p[(4, i)] = SNOW
        p[(i, 4)] = SNOW
    # 각 팔 끝의 가지 (V자)
    branches = [
        (3, 1), (5, 1),   # 위
        (3, 7), (5, 7),   # 아래
        (1, 3), (1, 5),   # 좌
        (7, 3), (7, 5),   # 우
    ]
    for b in branches:
        p[b] = SNOW
    # 중심 살짝 굵게
    for c in [(3, 4), (5, 4), (4, 3), (4, 5)]:
        p[c] = SNOW
    save("snowflake.png", w, h, p)


def raindrop():
    """3x7 물방울 — 위 뾰족, 아래 둥글게. 한 픽셀 하이라이트로 입체감."""
    w, h = 3, 7
    p = {}
    # 꼬리 (위쪽 1px)
    for y in (0, 1, 2):
        p[(1, y)] = RAIN
    # 몸통
    for y in (3, 4, 5):
        for x in (0, 1, 2):
            p[(x, y)] = RAIN
    p[(1, 6)] = RAIN  # 아래 끝 둥글게
    # 하이라이트
    p[(0, 3)] = RAIN_HI
    save("raindrop.png", w, h, p)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("날씨 스프라이트 생성:")
    snowflake()
    raindrop()
    print("완료.")


if __name__ == "__main__":
    main()
