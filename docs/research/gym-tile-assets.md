# 도장(Gym Badges) 월드맵 2대륙 — 신규 바이옴 타일 에셋 후보 조사

조사일: 2026-07-23
조사 목적: `WorldMapView.swift` 28×18 top-down 오버월드에 제2 대륙(테마: Cloud/인프라)을 추가하며 필요한
4개 신규 바이옴(사막/설원/용암/늪) 픽셀 타일을 CC0/CC-BY(-SA) 라이선스 범위 내에서 확보. 현재 베이스 팩은
**Intersect-Assets**(Ascension Game Dev, `Resources/intersect-tiles/`, `tile_grass/tile_sand/tile_mountain/tile_lake/tile_water` 5종, 32×32, 오토타일 시트에서 단일 셀 추출)이다.

---

## ✅ 실물 확인 결과 (2026-07-23, 개발환경에서 원본 시트 직접 열람)

> researcher가 도구 한계(WebFetch는 이미지 시각 분석 불가)로 못 끝낸 **최우선 항목(Option A)**을, 개발환경에서 `raw.githubusercontent.com`으로 원본 시트 8종을 받아 직접 육안 확인함. **결론이 바뀜: 외부 팩은 사실상 불필요.**

**Intersect-Assets 원본만으로 커버되는 바이옴 (톤·라이선스 100% 일치):**

| 바이옴 | 커버 | 추출 소스 (원본 시트) |
|---|---|---|
| **용암** (OSS) | ✅ 확실 | `Autotiles_Water & Lava.png` 우측(회색암반/크림 배경 위 빨간 용암), `Autotiles_Water & Lava 2.png` 하단, `Autotiles_Ground.png` 좌중단 — 빨강/주황 용암 오토타일 다수 |
| **사막/사구** (Arena) | ✅ 확실 | `Terrain.png` 베이지 절벽·모래지면, `Ground.png`·`Autotiles_Ground.png` 모래 blob, `Overworld.png` 선인장·모래·석관 데코 |
| **설원/빙판** (Daily) | ✅ 확실 | `Autotiles_Water & Lava 2.png` 하단좌 **밝은 청록 얼음 오토타일**, `Autotiles_Ground.png` 하단 청록 얼음/물, `Ground.png` 흰 눈 blob — 순백 눈보다 "서리/빙판" 톤이라 Daily(새벽·청백)에 오히려 부합 |
| **늪** (Guild) | △ 전용 타일 없음 | **대안: Guild를 "암반/요새" 지형으로 재해석** → `Caves Etc.png` 회색암반·크리스탈, `Terrain.png` 회색 돌담/석벽으로 원본 내 커버. 굳이 "늪"을 고집하면 이것만 외부 1팩(Dead Swamp, CC-BY 4.0) 보완 |

**핵심 판정**: Option A(동일 팩)가 **4바이옴 중 3개를 완전 커버**, 4번째(Guild)도 지형 재해석으로 원본 커버 가능 → **외부 팩 도입 없이 톤 리스크 0으로 확장 가능**. Option B/C(외부 무료/유료 조합)는 백업으로만 유지.

**추출 방식**: 기존 `tile_grass.png` 등과 동일하게 각 오토타일 시트에서 **사방이 같은 타일로 둘러싸인 가운데(seamless) 셀**을 32×32로 crop. SwiftPM basename flatten 제약 준수.

### ✅ 확정 추출 좌표 (2026-07-23, 실제 crop + 4x4 타일링 이음매 검증 + 완전불투명 검증 완료)

Guild를 "암반/요새"로 확정 → **외부 팩 0, 4바이옴 전부 Intersect 원본 커버**. 각 셀은 alpha 최소값 255(완전불투명, 투명 코너 없음) 확인 후 확정.

| 신규 파일 | 바이옴(지역) | 소스 시트 | 셀 좌표 (32px 그리드) | 특징 |
|---|---|---|---|---|
| `tile_dune.png` | 사막 (Arena) | `Autotiles_Ground.png` | (col 7, row 0) | 황금모래 — 기존 `tile_sand`(크림 shore)와 채도로 구분 |
| `tile_ice.png` | 빙판 (Daily) | `Autotiles_Ground.png` | (col 1, row 13) | 밝은 청록 얼음 — Daily 청백 톤 부합 |
| `tile_rock.png` | 암반 (Guild) | `Autotiles_Ground.png` | (col 7, row 10) | 회색 암반 — 반복 이음매 가장 자연스러움 |
| `tile_lava.png` | 용암 (OSS) | `Autotiles_Water & Lava 2.png` | (col 9, row 6) | 순수 빨강/주황 용암 완전채움 (배경 없음) |

- **주의(추출 시 흔한 실수)**: blob 오토타일의 **바깥 코너 셀**을 뽑으면 우상단 등에 투명 삼각형이 남아 반복 시 격자무늬로 드러남. 반드시 alpha 최소값 255인 **완전채움 내부 셀**만 사용할 것.
- 재현: 원본 시트는 `raw.githubusercontent.com/AscensionGameDev/Intersect-Assets/main_full/resources/tilesets/`에서 받아 위 좌표를 `crop((c*32, r*32, +32, +32))`. 추출 스크립트/미리보기는 세션 scratchpad에 보존(`FINAL.png` 등).
- **라이선스**: 기존 `intersect-tiles`와 동일 출처 → `LICENSE_IntersectTiles.txt`에 4개 파일의 소스 시트·좌표만 append하면 됨(신규 라이선스 협의 불필요).

**라이선스**: 기존 `intersect-tiles`와 동일 출처·동일 라이선스라 **추가 라이선스 협의 불필요**. (단 로컬 `LICENSE_IntersectTiles.txt`=CC BY-SA 3.0 vs 업스트림 README=CC BY 4.0 상충은 별도 정리 대상 — 어느 쪽이든 상업배포+attribution 허용이라 사용엔 지장 없음.)

---

## 요약 (3줄) — *(researcher 1차 조사, 아래 실물 확인 전 작성. 참고용 보존)*

- **Intersect-Assets 자체에는 사막/설원/용암/늪 전용 타일셋이 확인되지 않는다.** README가 명시하는 카테고리는 beach/cave/graveyard/town/interior/waterfall/forest뿐이고, 다만 `Autotiles_Water & Lava.png`(+`2`)라는 파일명이 존재해 **용암 타일이 물 오토타일 시트 안에 섞여 있을 가능성**이 있다 — 이건 이미지 열람 도구(WebFetch는 텍스트만 처리)로는 확인이 안 돼 **다운로드 후 직접 열어보는 게 최우선 액션**이다.
- 무료(CC0/CC-BY) 라인 중 가장 톤이 일관된 조합은 **사막+용암 = Foozle "Lucifer" 시리즈(CC0, 32×32, 동일 작가·동일 시리즈)** + **설원 = LPC Winter Tiles(CC-BY 3.0/CC-BY-SA 3.0, 32×32)** + **늪 = Dead Swamp Tileset(CC-BY 4.0, 32×32, RPGMaker XP 오토타일)** 3-family 조합이다. 라이선스는 전부 요건 충족(상업적 재배포 가능, 이미 쓰는 CC BY-SA 계열과도 호환)이지만 **작가가 4팩에 걸쳐 3~4명으로 갈리므로 톤 불일치 리스크는 실존**한다.
- 유료 대안으로 **Phantom Cooper "Aesthetic Biomes" 시리즈**(24×24, SNES/GBA풍, itch.io, 팩당 $4.50)가 사막(pack 7)·설원(pack 6)·늪(pack 2)·용암(pack 4의 해저드 타일)을 **단일 작가**로 커버해 톤 리스크를 크게 낮춘다. 다만 유료이고, 용암은 "던전 해저드 타일" 수준이라 전용 지형 타일만큼 풍부하지 않다. Intersect의 원작가 "Aesthetic"과 동명이나 **동일인 여부는 확인 못 함**(추정 근거 없음, 우연의 일치 가능성 있음).

---

## 권장 결론 (트레이드오프 명시, 단정 회피)

| 옵션 | 구성 | 비용 | 톤 리스크 | 비고 |
|---|---|---|---|---|
| **A (1순위 권장)** | Intersect-Assets 자체 시트(`Autotiles_Water & Lava.png` 등) 재조사 → 있으면 그대로 사용 | 무료, 이미 라이선스 확보됨 | 없음(동일 팩) | **가장 먼저 해야 할 일.** 이 리서치는 이미지 뷰어가 없어 확인 못 했다. 로컬에서 PNG를 직접 열어 사막/설원/용암/늪 유사 타일이 있는지 5분 안에 확인 가능. |
| **B (A로 부족할 때, 무료 조합)** | 사막+용암=Foozle Lucifer(CC0) / 설원=LPC Winter Tiles(CC-BY 3.0) / 늪=Dead Swamp Tileset(CC-BY 4.0) | 무료 | 중 — 3~4-family 혼재 | 라이선스는 전부 확인됨. attribution 필요한 2팩(LPC Winter, Dead Swamp)은 `LICENSE_*.txt` 관례로 처리. 실제 다운로드 후 `tile_grass`/`tile_mountain` 옆에 나란히 놓고 육안 비교가 필수 — 텍스트 조사로는 팔레트 일치 여부를 확정할 수 없음. |
| **C (예산 허용 시, 최고 일관성)** | Phantom Cooper "Aesthetic Biomes" pack 2/6/7(+4의 라바 타일) | 유료 (~$18, 4팩 개별구매 시) | 낮음 — 신규 4바이옴은 단일 작가 | 라이선스 문구상 "다른 에셋팩/툴의 일부로 재사용 금지"는 명시돼 있으나 **컴파일된 앱에 번들링하는 것 자체를 금지하지 않음**(에셋을 그대로 재판매/재배포하는 걸 금지하는 통상적 문구로 해석됨) — 다만 이 해석은 판매자에게 직접 문의하거나 라이선스 전문을 재확인 후 확정할 것을 권장. |

**단정 회피**: 이 조사는 WebFetch(HTML→텍스트 변환)만 사용했고 **PNG 실물을 픽셀 단위로 열람하지 못했다.** "톤 적합성" 판정은 페이지 설명(해상도, "SNES/GBA풍" 같은 자기소개, 팔레트 언급)에 근거한 **추정**이며, 최종 채택 전 반드시 사람이 직접 다운로드해 기존 `tile_grass.png`/`tile_mountain.png` 옆에 놓고 비교해야 한다.

---

## 1. Intersect-Assets 자체 바이옴 존재 여부 (최우선 조사)

**사실**:
- GitHub 저장소 `AscensionGameDev/Intersect-Assets` (`main_full` 브랜치) `resources/tilesets/` 안 파일 목록(GitHub API로 직접 확인, 신뢰도 높음):
  `Autotiles_Ground.png`, `Autotiles_Houses.png`, `Autotiles_Interior & Terrain.png`, `Autotiles_Water & Lava.png`, `Autotiles_Water & Lava 2.png`, `Autotiles_Water.png`, `Caves Etc.png`, `Ground.png`, `Interior.png`, `Misc.png`, `Overworld.png`, `Overworld_2.png`, `Slanted Roofs.png`, `Terrain.png`.
  [https://api.github.com/repos/AscensionGameDev/Intersect-Assets/contents/resources/tilesets?ref=main_full](https://api.github.com/repos/AscensionGameDev/Intersect-Assets/contents/resources/tilesets?ref=main_full)
- README(`main` 브랜치)가 스크린샷과 함께 소개하는 카테고리는 **Beach, Cave, Graveyard, Town, Interior, Waterfall, Forest, Interior Alt** — 사막/설원/늪 명칭은 없음.
  [https://github.com/AscensionGameDev/Intersect-Assets/blob/main/README.md](https://github.com/AscensionGameDev/Intersect-Assets/blob/main/README.md)
- 라이선스(README 원문 인용): *"All the animations, tilesets, characters, ui elements, items and other assets by George, PixelFox, Zetasis, Aesthetic, Murdoc and Jack Soda are licensed as **CC BY 4.0**."* / *"Most items were created by Joe Williamson and are licensed **CC BY-SA 3.0**."*
- 커뮤니티 포럼 스레드("Intersect Tile and more :)")는 `Overworld_2.png`, `Autotiles_Ground` 추가 타일, `Interior_2.png`를 커뮤니티가 기여했다고만 언급 — 어떤 바이옴인지는 이미지로만 보여주고 텍스트 설명이 없음.
  [https://www.ascensiongamedev.com/topic/4626-intersect-tile-and-more/](https://www.ascensiongamedev.com/topic/4626-intersect-tile-and-more/)

**권장(추정 아님, 확인 필요 라벨)**:
- `Autotiles_Water & Lava.png`(+`2`) 파일명은 **용암 타일이 이미 포함돼 있을 가능성**을 강하게 시사한다. `Overworld.png`/`Overworld_2.png`/`Terrain.png`도 대형 시트라 사막/설원 타일이 다른 지형과 섞여 있을 수 있다.
- **이 리서치는 이미지 픽셀을 직접 볼 수단이 없어(WebFetch는 HTML→텍스트 변환만 수행, Bash/curl 도구 미보유) 확정하지 못했다.** 실제 개발 환경에서는 `gh api` 또는 직접 클론으로 PNG를 받아 5분 안에 확인 가능하므로, **아래 팩 조사보다 이걸 먼저 하는 것을 권장**한다.
- 상충 정보: 로컬 `Resources/intersect-tiles/LICENSE_IntersectTiles.txt`는 "라이선스: CC BY-SA 3.0"이라고 적혀 있으나, 위에서 확인한 현재 업스트림 README는 해당 5개 타일의 제작자(George/PixelFox/Zetasis/Aesthetic/Murdoc/Jack Soda)를 **CC BY 4.0**으로 명시하고 있다. 로컬 파일은 "출처가 파일별로 명시 안 되면 가장 제한적인 라이선스(BY-SA)를 적용"이라는 보수적 가정을 깔고 작성된 것으로 보인다. 이번 조사 범위(신규 바이옴)와는 무관하지만, 기존 라이선스 표기가 실제보다 더 제한적으로(BY-SA) 적혀 있을 가능성이 있다는 점은 참고용으로 남긴다 — **코드/라이선스 파일 수정은 이 조사의 범위 밖이므로 실행하지 않았다.**

---

## 2. 동일 작가/동일 계열 확장 팩 (우선순위 2)

### 2-1. Foozle "Lucifer" 컬렉션 — 사막 + 용암 (2/4 바이옴, 동일 시리즈)

**사실**:
- **Lucifer - Desert Tileset** (Foozle, "David"에게 커미션): CC0. *"This content is free to use and modify for all projects, including commercial projects. Attribution not required."* 32×32, top-down, `.ase`(Aseprite) 원본 포함, "Lucifer Collection" 다른 팩과 함께 쓰도록 설계됨.
  [https://foozlecc.itch.io/lucifer-desert-tileset](https://foozlecc.itch.io/lucifer-desert-tileset)
- **Lucifer - Lava Dungeon Tileset** (Foozle): CC0, 동일 문구. 32×32, top-down, 용암 흐름 애니메이션 + 암반 지형 + 던전 구조물.
  [https://foozlecc.itch.io/lucifer-lava-dungeon-tileset](https://foozlecc.itch.io/lucifer-lava-dungeon-tileset)
- Foozle 카탈로그 전체(itch.io 프로필)에서 **설원/늪 전용 CC0 팩은 발견 못함**. 유료 "Snow Tileset Pixel Art"($3)는 있으나 Lucifer 시리즈 소속인지, CC0인지 확인 못 했고 페이지를 직접 열지 못했다(검색 스니펫만 확인) — **확인 필요**로 표기.
- 오토타일(가장자리 전환 타일) 존재 여부는 **확인 못함** — 페이지 설명에 명시가 없고 실물 스프라이트시트를 열람할 수단이 없었다.

**권장**: 사막+용암 2종은 **동일 작가·동일 시리즈·동일 라이선스(CC0)**라 서로 간 톤 일관성은 사실상 보장된다. 기존 Intersect 타일과의 일치 여부만 실물 비교가 필요.

### 2-2. Phantom Cooper "Aesthetic Biomes" 시리즈 — 4/4 바이옴 커버 (단, 유료 + 동일인 여부 미확인)

**사실**:
- itch.io 핸들 "Phantom Cooper"가 "Aesthetic Biomes" 넘버링 시리즈(pack 1~8+)를 판매 중. 24×24, SNES/GBA풍 top-down RPG 타일이라고 자체 소개.
  [https://phantomcooper.itch.io/](https://phantomcooper.itch.io/)
  - Pack 2 — *Swamp, Building Interiors, Gate tilesets* ($4.50)
  - Pack 6 — *Snowy Woods, Ice Cave, Ice Dungeon* ($4.50) — 눈 덮인 지면, 얼어붙은 호수 애니메이션, 눈사람/펭귄 소품 등 설명 확인.
  - Pack 7 — *Desert Oasis, Wasteland* ($4.50) — 사구/점토 오두막/선인장/미라 석관 등 확인. 라이선스: *"Any purchased assets can be modified freely and used commercially or non-commercially"* / *"Assets cannot be used as part of another asset pack or tool even if modified"* / *"credit is appreciated but not required"*.
    [https://phantomcooper.itch.io/aesthetic7](https://phantomcooper.itch.io/aesthetic7)
  - Pack 4 — *Dungeon Interiors and Exteriors* — 라바 바닥 등 "해저드 타일"이 포함(전용 라바 지형 세트는 아님).
- **"Aesthetic"이라는 이름은 Intersect-Assets README가 credit하는 원작가 중 한 명("George, PixelFox, Zetasis, **Aesthetic**, Murdoc, Jack Soda")과 동일 단어이지만, Phantom Cooper 프로필에서 그 연결고리(동일인 증거)를 찾지 못했다.** itch 프로필의 소셜링크는 "Rubens Myrto"로 추정되는 인스타그램 핸들만 보였다 — **동일인이라고 단정할 근거 없음, 우연의 동명 가능성이 더 높아 보임(추정)**.

**권장**: 라이선스가 재배포용 "에셋팩으로의 재사용"만 금지하고 컴파일된 앱 번들링을 명시적으로 막지 않으므로 이 프로젝트 용도(GitHub Release+Homebrew로 .app 배포, 에셋은 앱 리소스로 동봉)엔 부합해 보이나, **판매자 라이선스 원문 전체를 재확인하거나 문의 후 확정**할 것을 권장한다(이번 조사에서 라이선스 페이지 전문을 발견하지 못했고 상품 페이지의 발췌 문구만 확인함).

---

## 3. Kenney (kenney.nl, CC0) — 커버리지 부족으로 비권장

**사실**:
- `kenney.nl/assets/roguelike-rpg-pack`: CC0 확정, **16×16**, "낱개 아이콘 타일" 방식(오토타일 아님). 사막/설원/용암 개별 태그는 페이지에서 확인 못 함.
  [https://kenney.nl/assets/roguelike-rpg-pack](https://kenney.nl/assets/roguelike-rpg-pack)
- 검색 범위에서 Kenney의 "Tiny Town" 등은 이번 조사에서 사막/설원/용암 바이옴 포함 여부를 확정할 자료를 찾지 못했다(itch/kenney.nl 페이지 미열람) — **확인 안 됨**.
- **평가**: Kenney 팩들은 대체로 단색·평면 아이콘 톤(오토타일보다 "심볼" 성격)이라, 기존 Intersect의 디테일 있는 오토타일 질감과 **톤 적합성이 낮을 가능성**(추정, 실물 미확인)이 있다. 4개 바이옴을 한 팩에서 못 찾았다는 점과 겹쳐 **1순위 후보에서 제외**.

---

## 4. OpenGameArt / itch.io CC0·CC-BY 팩 (개별 바이옴 보완용)

### 4-1. 설원 — LPC Winter Tiles

**사실**:
- Liberated Pixel Cup(LPC) 계열. 제작자 Demetrius, `LPC: Modified Base Tiles`(Lanea Zimmerman, William Thompson) 기반. 32×32, 눈/얼음 + 침엽수 2종(원본 대형 + RPG Maker VX Ace용 축소판).
- 라이선스 배지 4개 동시 표기: **CC-BY 3.0 / OGA-BY 3.0 / GPL 3.0 / CC-BY-SA 3.0** (사용자가 그중 하나 선택 적용 가능한 멀티 라이선스 — LPC 관례).
- 다운로드: `TilesA2.png`(10.3KB), `TilesA3.png`(1.7KB), `TilesB.png`(11.9KB).
  [https://opengameart.org/content/lpc-winter-tiles](https://opengameart.org/content/lpc-winter-tiles)
- LPC 스타일가이드는 "32×32 그리드 + 16×16 서브타일, 직교(orthographic) top-down 렌더링"을 강제하며, 목적이 "여러 기여자가 만들어도 서로 어울리게" 하는 것이라고 명시함 — 단, **바이옴별(사막/설원 등) 색감 가이드는 없음**.
  [https://lpc.opengameart.org/static/LPC-Style-Guide/build/styleguide.html](https://lpc.opengameart.org/static/LPC-Style-Guide/build/styleguide.html)

**대안**: **Very Basic 32x32 Topdown Snow Tileset** (작가 "Spring Spring", CC0/퍼블릭도메인, 32×32, 눈+얼음+전환타일). 작가 본인이 "haphazard and sloppy"라고 자평 — **퀄리티 리스크 있음, 확인 필요**.
[https://opengameart.org/content/very-basic-32x32-topdown-snow-tileset](https://opengameart.org/content/very-basic-32x32-topdown-snow-tileset)

### 4-2. 용암 — davesch 애니메이션 라바 타일 (백업)

**사실**:
- CC0, 16×16 기본 + 32×32 seamless 애니메이션 버전 추가, 45프레임 애니메이션(정적 단일 컷은 없음 — 프레임 1장을 추출해 정적 타일로 써야 함). 댓글에서 "일부 프레임만 완전히 seamless, 다른 프레임은 이음매가 보인다"는 품질 이슈 제보됨.
  [https://opengameart.org/content/16x16-and-animated-lava-tile-45-frames](https://opengameart.org/content/16x16-and-animated-lava-tile-45-frames)
- "32x32px cracked lava ground tileset"(Top Down 2D JRPG 32x32 Art Collection 소속)은 **CC-BY 3.0**(CC0 아님)으로 별도 확인됨 — 개별 페이지 직접 미열람, 컬렉션 페이지 설명 기반.
  [https://opengameart.org/content/top-down-2d-jrpg-32x32-art-collection](https://opengameart.org/content/top-down-2d-jrpg-32x32-art-collection)

### 4-3. 늪 — Dead Swamp Tileset (유일하게 확인된 top-down 무료 후보)

**사실**:
- 작가 Sevarihk, 2023-05-10 게시. **CC-BY 4.0**. *"credit me and provide a link that leads back here or to my homepage"*(attribution 필수).
- **RPG Maker XP용 오토타일 포맷**, top-down 명시(OGA 태그 "Top-Down" 확인). 32×32. 지면/갈대/고사목/물 애니메이션/썩은 목조 건물 포함. 작가가 "murky, low-contrast" 톤을 의도했다고 명시 — 오히려 기존 팩과 채도 대비가 커서 눈에 띌 가능성 있음(추정).
  [https://opengameart.org/content/dead-swamp-tileset](https://opengameart.org/content/dead-swamp-tileset) (itch 미러: [https://sevarihk.itch.io/dead-swamp-tileset](https://sevarihk.itch.io/dead-swamp-tileset))
- **제외**: "Free Swamp 2D Tileset Pixel Art"(CraftPix.net, OGA 미러 라이선스는 OGA-BY 3.0으로 확인됨)는 OGA 태그가 `platform`이고 페이지 문구도 "2D platformer games"로 **사이드뷰 플랫포머용** — top-down 요건(#3) 위반으로 제외.
  [https://opengameart.org/content/swamp-2d-tileset-pixel-art](https://opengameart.org/content/swamp-2d-tileset-pixel-art)

### 4-4. 사막 — LPC Desert Tileset (백업)

**사실**:
- 작가 "Beast"(MrBeast), OpenGameArt 커미션작. **CC-BY 3.0**. **16×16**(작가가 "2배 업스케일해서 올드스쿨 느낌 낼 수 있다"고 코멘트 — 32×32 통일 규격 맞추려면 2x 처리 필요). 선인장/절벽/모래/물 포함, 물 표현은 코멘트에서 "다듬을 여지 있음"이라는 지적 있었음. 다운로드 `desert.png`(34.9KB).
  [https://lpc.opengameart.org/content/desert-tileset-0](https://lpc.opengameart.org/content/desert-tileset-0)

---

## 후보 종합 표

| 팩명 | 아티스트 | 라이선스 | 배포 URL | 커버 바이옴(4종 중) | 해상도 | autotile 여부 | 톤 적합성(상/중/하) | attribution 요건 |
|---|---|---|---|---|---|---|---|---|
| Lucifer - Desert Tileset | Foozle (David) | CC0 | https://foozlecc.itch.io/lucifer-desert-tileset | 1 (사막) | 32×32 | 확인 필요 | 중 (실물 미확인) | 불필요 |
| Lucifer - Lava Dungeon Tileset | Foozle | CC0 | https://foozlecc.itch.io/lucifer-lava-dungeon-tileset | 1 (용암) | 32×32 | 확인 필요 | 중 (실물 미확인, 위 사막과 동일 시리즈라 상호 일관성은 상) | 불필요 |
| LPC Winter Tiles | Demetrius (기반: Lanea Zimmerman/William Thompson) | CC-BY 3.0 / CC-BY-SA 3.0 / GPL 3.0 / OGA-BY 3.0 (택1) | https://opengameart.org/content/lpc-winter-tiles | 1 (설원) | 32×32 | 확인 필요(LPC 특유 확장 세트라 가능성 높음, 미확인) | 중 (실물 미확인) | 필요 (BY 계열 선택 시) |
| Very Basic 32x32 Topdown Snow Tileset | Spring Spring | CC0 | https://opengameart.org/content/very-basic-32x32-topdown-snow-tileset | 1 (설원) | 32×32 | 확인 필요 | 하~중 (작가 자평 "sloppy") | 불필요 |
| Dead Swamp Tileset | Sevarihk | CC-BY 4.0 | https://opengameart.org/content/dead-swamp-tileset | 1 (늪) | 32×32 | O (RPG Maker XP 오토타일 명시) | 중 (저채도·"murky" 톤 명시, 실물 미확인) | 필요 |
| 16x16 and animated lava tile (45 frames) | davesch | CC0 | https://opengameart.org/content/16x16-and-animated-lava-tile-45-frames | 1 (용암, 애니메이션에서 1프레임 추출 필요) | 16×16 (32×32 애니메이션 버전 별도) | 해당없음(애니메이션 시트) | 하~중 (일부 프레임만 완전 seamless라는 제보) | 불필요 |
| LPC Desert Tileset | Beast (MrBeast) | CC-BY 3.0 | https://lpc.opengameart.org/content/desert-tileset-0 | 1 (사막) | 16×16 (2x 업스케일 필요) | 확인 필요 | 중 (실물 미확인) | 필요 |
| Aesthetic Biomes pack 2 (Swamp) | Phantom Cooper | 커스텀(상업적 재배포 가능·"별도 에셋팩 재사용" 금지, credit 권장) — 유료 $4.50 | https://phantomcooper.itch.io/aesthetic2 | 1 (늪) | 24×24 | 확인 필요 | 중~상 (동 시리즈 내 일관성 높음, 실물 미확인) | 불필요(권장) |
| Aesthetic Biomes pack 6 (Snowy Woods/Ice) | Phantom Cooper | 상동 | https://phantomcooper.itch.io/aesthetic6 | 1 (설원) | 24×24 | 확인 필요 | 중~상 | 불필요(권장) |
| Aesthetic Biomes pack 7 (Desert Oasis/Wasteland) | Phantom Cooper | 상동 | https://phantomcooper.itch.io/aesthetic7 | 1 (사막) | 24×24 | 확인 필요 | 중~상 | 불필요(권장) |
| Aesthetic Biomes pack 4 (Dungeon, 라바 해저드 타일 포함) | Phantom Cooper | 상동 | https://phantomcooper.itch.io/aesthetic4 | 0.5 (용암 — 전용 지형 아닌 해저드 타일 수준) | 24×24 | 확인 필요 | 중 (실물 미확인, 전용 용암 지형은 아님) | 불필요(권장) |
| Kenney Roguelike/RPG Pack | Kenney | CC0 | https://kenney.nl/assets/roguelike-rpg-pack | 0 (바이옴 태그 미확인) | 16×16 | 아니오 (개별 아이콘 타일) | 하 (추정 — 평면 아이콘 톤) | 불필요 |
| Free Swamp 2D Tileset Pixel Art (CraftPix) | CraftPix.net | OGA-BY 3.0 | https://opengameart.org/content/swamp-2d-tileset-pixel-art | — (제외: 사이드뷰 플랫포머) | 확인 안 됨 | — | — | 제외 대상 |

---

## 권장 조합 상세

### Option B — 무료 조합 (3~4-family, 톤 리스크 중)
- 사막: Foozle Lucifer Desert Tileset (CC0)
- 용암: Foozle Lucifer Lava Dungeon Tileset (CC0) — 사막과 동일 시리즈라 이 둘끼리는 일관성 보장
- 설원: LPC Winter Tiles (CC-BY 3.0 선택 시 attribution 필요) — 실패 시 백업으로 Very Basic Snow Tileset(CC0)
- 늪: Dead Swamp Tileset (CC-BY 4.0, attribution 필요) — 현재로선 유일하게 확인된 top-down 무료 후보

**리스크**: 베이스(Intersect, George/PixelFox 등) + Foozle + LPC/Demetrius + Sevarihk = **최대 4개 시각 계열**이 한 지도에 공존. LPC 스타일가이드가 "여러 기여자 협업 시 일관성 확보"를 목적으로 하지만 이건 LPC 내부 팩끼리의 얘기고, Foozle·Sevarihk·Intersect 상호간 팔레트 일치를 보장하는 장치는 없다. **반드시 실물 다운로드 후 나란히 렌더링 비교**가 필요하며, 이번 조사(텍스트 전용 도구)로는 이 판정을 완료할 수 없었다.

### Option C — 유료 조합 (단일 신규 작가, 톤 리스크 낮음)
- Phantom Cooper "Aesthetic Biomes" pack 2(늪)+6(설원)+7(사막)+4(용암 해저드 타일 활용 또는 별도 라바 소스 보완)
- 신규 4바이옴 자체는 단일 작가로 통일되나, 기존 Intersect 베이스와는 여전히 다른 계열 — "베이스 1 + 신규대륙 1"로 계열 수를 2개로 줄이는 효과.
- 라이선스 재확인 필요 항목: "다른 에셋팩/툴의 일부로 재사용 금지" 문구가 앱 번들링(최종 컴파일 결과물에 리소스로 포함)까지 막는지 여부는 이번 조사에서 원문 전체를 확보하지 못해 **확정하지 못함** — 채택 전 판매자 문의 또는 라이선스 전문 재확인 권장.

---

## 다운로드 방법 & basename 유일성 메모

- **itch.io 팩(Foozle Lucifer, Phantom Cooper Aesthetic, Sevarihk)**: 브라우저로 페이지 방문 → "Download" 또는 "$0 named your price" 클릭 → itch가 발급하는 서명된 다운로드 링크로 zip 수령. `curl`로 직접 URL을 예측해 받는 방식은 itch 다운로드 링크가 세션/토큰 기반이라 일반적으로 안 됨 — **`butler`(itch 공식 CLI) 또는 브라우저 수동 다운로드가 필요**. 기존 메모(`pet-asset-sourcing`)의 "itch.io는 GitHub API 미러 우회가 안 통한다"는 경험과 일치.
- **OpenGameArt 팩(LPC Winter Tiles, Dead Swamp, Very Basic Snow, davesch lava, LPC Desert)**: 각 콘텐츠 페이지 하단에 직접 다운로드 가능한 정적 URL(`opengameart.org/sites/default/files/...`)이 보통 걸려 있어 `curl`/`gh`류 도구 없이도 일반 HTTP GET으로 받을 수 있다 (사내망 이슈는 이번 리포는 웹 자유 환경이라 해당 없음, 실제 앱 개발 환경에서 재확인 권장).
- **basename 유일성**: SwiftPM은 `Resources/` 트리 전체의 PNG/텍스트 basename을 플랫하게 취급한다(CLAUDE.md에 명시된 기존 제약). 신규 타일은 기존 `tile_grass.png` 등과 충돌하지 않도록 접두사를 분리할 것:
  - 사막: `tile_dune.png` (기존 `tile_sand.png`는 이미 "shore/해변" 용도로 점유돼 있으므로 혼동 방지 위해 `dune`으로 명명 권장 — 요청사항과 동일)
  - 설원: `tile_snow.png`
  - 용암: `tile_lava.png`
  - 늪: `tile_swamp.png`
  - 각 팩은 기존 관례(`LICENSE_IntersectTiles.txt`, `LICENSE_IntersectJewels.txt`)를 따라 `Resources/<pack-slug>/LICENSE_<PackName>.txt`에 출처 URL·라이선스·추출 좌표를 기록할 것.

---

## 상충 정보

- **Intersect-Assets 타일 라이선스 표기**: 로컬 `LICENSE_IntersectTiles.txt`(CC BY-SA 3.0, "가장 제한적인 라이선스 가정")와 현재 업스트림 README(해당 5개 타일 제작자는 CC BY 4.0)가 다르다. 이번 조사 범위(신규 바이옴 후보 조사)는 아니지만 발견된 사실이라 기록한다. **어느 쪽이 맞는지는 커밋 히스토리를 뒤져야 확정 가능** — README는 "모든 파일의 저작자·라이선스는 커밋 히스토리에 명시돼 있다"고만 언급.
- **Phantom Cooper = Intersect의 "Aesthetic"인지**: 이름이 겹치지만 확인할 근거를 찾지 못했다. **동일인이라고 가정하지 말 것.**
- **Foozle Lucifer 오토타일 여부**: 여러 검색 결과 어디에도 "autotile"이라는 단어가 명시되지 않았다 — 있을 수도, 없을 수도 있음(확인 필요로 유지).

---

## 확인 안 된 것

- **Intersect-Assets `Autotiles_Water & Lava.png`(+`2`), `Overworld.png`, `Overworld_2.png`, `Terrain.png`, `Ground.png`의 실제 픽셀 내용** — 이 리서치의 최우선 미해결 항목. WebFetch가 이미지 파일을 시각적으로 분석하지 못해(HTML→텍스트 변환 전용), 사막/설원/용암/늪과 유사한 서브타일이 이미 포함돼 있는지 끝내 확정하지 못했다.
- 모든 후보 팩의 **실물 오토타일(가장자리 전환) 유무** — 페이지 설명에 명시가 없는 경우가 대부분이라 다운로드 후 직접 열어봐야 함.
- 모든 후보 팩과 기존 `tile_grass`/`tile_mountain`/`tile_sand`/`tile_lake`/`tile_water`의 **실제 팔레트/채도 일치 여부** — 육안 비교 없이는 판정 불가.
- Foozle "Snow Tileset Pixel Art"($3)의 정확한 라이선스·해상도·Lucifer 시리즈 소속 여부 — 페이지 직접 열람 못함.
- Phantom Cooper 라이선스 전문(구매 후 다운로드에 포함되는 라이선스 파일) — 상품 페이지 발췌만 확인함, "앱 번들링 허용" 여부의 최종 확정은 못함.
- Kenney의 "Tiny Town" 등 다른 top-down 팩들의 사막/설원/용암 포함 여부 — 이번 조사에서 페이지를 직접 열람하지 못함(아래 참고자료 목록).

---

## 참고 자료 (미확인이지만 후속 가치 있는 URL)

- https://kenney.nl/assets — 전체 카탈로그, "Tiny Town"/"Tiny Dungeon" 등 개별 페이지 미열람
- https://foozlecc.itch.io/lucifer-dungeon-tileset , https://foozlecc.itch.io/lucifer-exterior-tileset — Lucifer 시리즈 나머지 팩(던전/외부), 늪/설원 보완 가능성 낮으나 미확인
- https://phantomcooper.itch.io/aestheticfree — Aesthetic Biomes 무료 버전(그래스랜드만), 라이선스 문구가 유료판과 같은지 미확인
- https://opengameart.org/content/lpc-compatible-terraintiles , https://opengameart.org/content/lpc-collection — LPC 500+ 개별 에셋 큐레이션 목록. 단일 압축파일이 아니라 하나씩 열어야 하지만, 스노우/라바/스웜프 관련 개별 서브미션이 더 있을 가능성 높음(이번 조사에서 목록만 훑고 개별 페이지는 못 열었음)
- https://opengameart.org/content/top-down-2d-jrpg-32x32-art-collection — "32x32px cracked lava ground tileset"(CC-BY 3.0) 포함 큐레이션, 개별 페이지 미열람
- https://www.ascensiongamedev.com/topic/4173-official-intersect-assets-pack/page/2/ — Official Intersect Assets Pack 스레드 2페이지, 이후 커뮤니티 추가분에 사막/설원 언급 가능성 있으나 미열람
- https://github.com/AscensionGameDev/Intersect-Assets/commits/main_full/resources/tilesets — 커밋 히스토리(라이선스 상충 확인 및 타일셋 변경 이력 추적용), 미열람

---

## 검토 체크리스트

- [x] 출처 신뢰도 평가 (GitHub API/공식 README 최우선 → itch.io/OpenGameArt 공식 상품 페이지 차선 → 검색엔진 요약은 최하 신뢰도로 별도 표시)
- [x] 최신성 평가 (LPC Winter Tiles 2020, Dead Swamp Tileset 2023, davesch lava 2014 — 오래된 것은 있으나 전부 현재도 활성 배포 페이지, "outdated 가능성"은 낮음)
- [x] 상충 정보 식별 (Intersect 라이선스 표기 상충, Phantom Cooper=Aesthetic 동일인 여부, Foozle 오토타일 불명확)
- [x] 사실/권장 분리 (표·"사실" 섹션은 인용 위주, "권장 결론"/"권장 조합 상세"에서만 의견)
- [x] 출처 URL 모든 표·문단에 포함
- [x] 확인 못 한 영역 명시 (별도 섹션, 특히 이미지 열람 불가라는 도구적 한계를 명시)
- [x] prompt injection 패턴 없음 — 모든 WebFetch 결과는 일반적인 상품 설명/라이선스 문구였고 이상 지시 패턴 발견되지 않음
