# 길드 사무실 픽셀 인테리어/가구 에셋 조사

조사일: 2026-07-03/04
관련 기획: `docs/plans/guild.md` §5-2 "사무실 씬 기술 설계" — P0 선행 리서치
목적: 길드 사무실 씬(스팟 12개, 가로 레인 배치)에 쓸 **배경(벽/바닥) + 가구 12종 내외** 픽셀 에셋 팩 조달 가능성 조사

---

## 요약 (3줄)

- **1순위 후보 확정**: `2dPig – Pixel Office Asset Pack` (CC0) — 데스크/PC/소파/책장/커피머신/의자/벤치/화이트보드/화분류/액자/시계 등 28개 가구 폴더를 16px 모듈 기반으로 제공하며, GitHub에 **파일 경로 단위로 검증된 미러**(`pixel-agents-hq/pixel-agents`, MIT 재라이선싱)가 존재해 사내망 제약을 완전히 우회할 수 있음.
- 요청한 12종 중 **서버랙·창문·스탠딩데스크 3종만 공백**이며, 이 3종은 부피가 작고 단순한 형태(수직 사각형+점등, 창틀, 책상 변형)라 코드 드로잉으로 메우거나 Kenney CC0 팩에서 보완 가능.
- LimeZu(Modern Office/Interiors)·CraftPix·Chris Perich 계열은 전부 **유료이거나 재배포 금지 커스텀 EULA**라 SwiftPM 리포에 PNG를 직접 커밋하는 이 프로젝트 구조와 맞지 않아 제외.

---

## 권장 결론

| 순위 | 구성 | 근거 |
|---|---|---|
| **1안 (권장)** | 가구 = `2dPig Pixel Office Asset Pack` (CC0, GitHub 미러 확인) + 배경(벽/바닥) = 같은 리포의 `floors/`, `walls/` 폴더 + 부족분(서버랙·창문·스탠딩데스크) 코드 드로잉 | 단일 소스로 가구 커버리지 최대, 라이선스 리스크 최소, 조달 경로 검증 완료 |
| **차선** | 1안 + `Kenney Roguelike/RPG Pack`(CC0)에서 창문·문·추가 의자류 보강 | Kenney 팩은 던전풍이라 화풍이 이질적일 수 있음 — 창문처럼 작고 눈에 덜 띄는 소품에 한해 혼용 권장 |
| **fallback (전부 부적합 시)** | 기획서(§5-2)에 이미 명시된 대로 **코드 드로잉(단색 도형 + SF Symbol) 가구로 시작**, 씬 좌표 체계만 맞추고 후속 PR에서 에셋 교체 | 1안이 유효하므로 지금은 fallback 발동 불필요. 단 2dPig 파일을 실제로 받아 시각 검증하기 전까지는 fallback을 유지하는 것이 안전 |

**트레이드오프 (단정 회피)**: 2dPig 가구는 "정면(front)/후면(back)/측면(side) 3-way 회전" 구조로 제작된, 탑다운에 가까운 "인형의 집 정면 뷰" 스타일 스프라이트다. 기획서의 "가로 레인(바닥선)" 배치와는 방향성이 맞지만(정면 뷰만 쓰면 됨), 기존 WalkingCat 계열 순수 사이드뷰 캐릭터 팩과 나란히 놓았을 때 원근감 차이가 눈에 띌 수 있음 — 실물 다운로드 후 시각 검증 필요.

---

## 후보 비교표

| 팩명 | 작가 | 해상도 | 포함 가구 커버리지 | 라이선스 | 조달 경로(미러) | 비고 |
|---|---|---|---|---|---|---|
| **Pixel Office Asset Pack** | 2dPig | 16px 모듈 (16×16~48×64 조합) | 데스크·PC(모니터)·소파·책장(단/2단)·테이블 3종·커피머신·의자 2종·벤치 2종·화이트보드·화분 6종·액자 3종·휴지통·시계 = **28개 폴더, 요청 12종 중 9종 커버** | **CC0** (2차 출처 교차검증, 원본 itch.io 직접 접근 실패) | **GitHub 미러 검증 완료** — `pixel-agents-hq/pixel-agents` repo `webview-ui/public/assets/furniture/*` (raw.githubusercontent.com으로 파일 단위 확인) | 서버랙·창문·스탠딩데스크 없음. front/back/side 방향별 PNG, manifest.json으로 크기·footprint 명시 |
| **Roguelike/RPG Pack** | Kenney | 16×16 | 침대·의자·책장·문·**창문**·주방용품 (모던 오피스 소품은 없음) | **CC0** (attribution 선택) | OGA 직접 zip 확인(`opengameart.org/sites/default/files/Roguelike%20pack.zip`). GitHub 전용 미러는 파일 경로까지 확인 못함 — Kenney 팩 특성상 다수 존재 추정(예 `arthurhp06/roguelike-prototipo-python`, 경로 미검증) | 던전풍 화풍이라 창문 등 눈에 덜 띄는 소품 보강용으로만 권장 |
| **Roguelike Indoor pack** | Kenney | 스프라이트시트(480종) | 주방용품·테이블·의자·소파·실내장식 | **CC0** | OGA 직접 zip 확인 (`opengameart.org/sites/default/files/Roguelike%20Indoor%20pack.zip`). GitHub 미러 미확인 | 2dPig와 기능 중복 — 화풍 통일성 위해 굳이 섞을 필요 낮음 |
| **Office Space Tileset** | no2games | 16×48 레이어드 | 벽/바닥 등 실내 건축 요소 (가구 종류 상세 불명) | **CC0** | OGA 직접 PNG (`opengameart.org/sites/default/files/offie-space-tileset.png`). GitHub 미러 미확인 | 2014년作 — **outdated 가능성**. "side scroller office game"용으로 설계되어 컨셉은 정확히 일치하나 볼륨이 작음(12.7KB) |
| **Pixel Art Lab/Office Tiles** | The Leafy Lemur | 32×32 | 연구실/사무실 배경 타일 | **CC-BY 3.0** (attribution 필수) | OGA 직접 PNG (`opengameart.org/sites/default/files/bgtiles_2.png`). GitHub 미러 미확인 | 다운로드 461회로 소규모. attribution 필요하나 CC-BY라 채택 가능선 안에는 있음 |
| **16x16 Industrial Tileset** | 0x72 | 16×16 | 산업/기계류 (서버랙류 소품 가능성 — **미확인**) | **CC0** | itch.io 직접 다운(사내망 차단 가능성), GitHub 미러 미확인 | 기존에 이미 채택 중인 작가(dungeon-tileset 팩)라 화풍 일관성 최고. 서버랙 보강용 1순위 후보지만 실제 내용물 미검증 |
| **16x16+ Robot Tileset** | 0x72 | 16×16 | 로봇/사이언스 소품 9종 캐릭터 위주, 가구성 소품 여부 미확인 | **CC0** (추정, 0x72 팩 공통 관례) | 미확인 | 서버랙 대체용 후보, 직접 확인 필요 |
| Modern Office / Modern Interiors [16x16] | LimeZu | 16×16 | 데스크·모니터·서버랙 포함 사무실 풀세트 (품질 최상) | **유료 + 커스텀 EULA** — GameDevMarket Pro License: "재판매·공유·재배포 금지(Media Product 밖)" 명시. itch.io 무료 버전은 "private/testing 전용", 유료 최소 $2.50~$3.90 | 사용 불가 판단이라 조달 경로 조사 생략 | **채택 불가** — 아래 상세 사유 참조 |
| CraftPix 무료 오피스 팩 | CraftPix.net | 다양 | 다양 | **독점 로열티프리, 재배포 명시적 금지** | 조사 생략 | **채택 불가** (기존 `docs/research/mythic-pet-assets.md`에서도 동일 사유로 제외된 전례) |
| Office Interior Tileset (16x16) | Donarg | 16×16 | 데스크·의자·컴퓨터/랩탑·커피머신·책장 등 (커버리지 우수) | 유료 (최소 $2), 라이선스 텍스트 CC0/CC-BY 여부 미확인 | 조사 생략 (유료·불명확) | 참고: 8.4k star 프로젝트 `pixel-agents`도 이 팩을 **번들하지 않고 "외부 디렉토리 추가" 방식으로만 안내** — 라이선스상 번들 불가라는 방증으로 해석됨 |
| Pixel Life: Office Essentials | Chris Perich | 미확인 | 노트북·모니터·PC·화분·정수기·커피머그 등 커버리지 우수 | 무료지만 **"재판매/단독 파일 재배포 제한"** 커스텀 조항 — CC0/CC-BY 아님 | 조사 생략 | 조건부 불가. "무료"와 "재배포 가능"은 별개 — 프로젝트 정책(CC0/CC-BY만)에 부합 안 함 |
| 2D Sidescroller Office Tileset | rixitic | 16×16 | 사무실 건물 인테리어 구성용 | 유료($1), 라이선스 텍스트 미확인 | 조사 생략 | 사이드스크롤러 전용으로 설계되어 컨셉은 가장 근접하나 유료+라이선스 불명 |

---

## 후보 상세 — 사실 (출처별)

### 1위 — 2dPig · Pixel Office Asset Pack (CC0)

- **원본 배포처**: https://2dpig.itch.io/pixel-office — **직접 WebFetch 접근이 이 세션에서 계속 `ECONNRESET`으로 실패**(itch.io 도메인 전반에서 동일 현상, LimeZu/rixitic/Chris Perich 페이지도 동일하게 실패). 사용자 개인망에서 직접 열람해 원문 라이선스 문구를 1차 확인하는 것을 권장.
- **라이선스 (2차 교차검증, 사실)**: "Creative Commons Public Domain Dedication License (CC0)... 저작자 표시 불필요(권장 사항)" — 이 문구는 (a) 별도 자료 정리 사이트(hackingtons.com 무료 게임 아트 목록)와 (b) 이 팩을 그대로 가져다 쓴 GitHub 프로젝트 `neomatrix25/pixel-office-openclaw`의 README Credits 섹션("Office furniture sprites by 2dPig (CC0 Public Domain)") 두 곳에서 동일하게 확인됨. [출처 A] hackingtons.com 무료 게임 아트 목록 (검색 결과 인용) [출처 B] `neomatrix25/pixel-office-openclaw` README Credits
- **GitHub 미러 (사실, 파일 경로까지 직접 검증)**: `pixel-agents-hq/pixel-agents` — 8.4k star 오픈소스 프로젝트("The game interface where AI agents build real things", MIT License, 저작권자 Pablo De Lucca)의 `webview-ui/public/assets/furniture/` 하위에 2dPig 에셋이 **완전히 번들되어 오픈소스로 공개**되어 있음. README 원문: "All office assets (furniture, floors, walls) are now fully open-source and included in this repository."
  - 확인된 furniture 하위 폴더(28개): `DESK`, `COFFEE_TABLE`, `SMALL_TABLE`, `TABLE_FRONT`, `PC`, `COFFEE`, `SOFA`, `BOOKSHELF`, `DOUBLE_BOOKSHELF`, `CUSHIONED_CHAIR`, `WOODEN_CHAIR`, `CUSHIONED_BENCH`, `WOODEN_BENCH`, `WHITEBOARD`, `PLANT`, `PLANT_2`, `LARGE_PLANT`, `HANGING_PLANT`, `CACTUS`, `POT`, `SMALL_PAINTING`, `SMALL_PAINTING_2`, `LARGE_PAINTING`, `BIN`, `CLOCK` 등
  - `floors/` — `floor_0.png` ~ `floor_8.png` (9종 바닥 변형)
  - `walls/` — `wall_0.png` 확인 (전체 목록은 "View all files" 클릭 필요, 추가 변형 존재 가능성 있음 — 미확인)
  - 개별 파일 raw URL 예시(직접 fetch로 검증됨):
    - `https://raw.githubusercontent.com/pixel-agents-hq/pixel-agents/main/webview-ui/public/assets/furniture/DESK/manifest.json` → `DESK_FRONT` 48×32 (footprint 3×2), `DESK_SIDE` 16×64 (footprint 1×4)
    - `.../furniture/PC/manifest.json` → `PC_FRONT_ON_{1,2,3}` 16×32 (3프레임 애니메이션, 모니터 켜짐 상태), `PC_FRONT_OFF` 16×32, `PC_BACK`/`PC_SIDE` 16×32
    - `.../furniture/SOFA/manifest.json` → `SOFA_FRONT`/`SOFA_BACK` 32×16, `SOFA_SIDE` 16×32
    - `.../furniture/BOOKSHELF/manifest.json` → 32×16 (벽 부착형, `canPlaceOnWalls: true`)
    - `.../furniture/COFFEE/manifest.json` → 16×16 (테이블 위 소품형)
  - 리포 LICENSE: MIT (Pablo De Lucca, 2026) — 즉 이 리포에서 재배포된 형태 자체도 관대한 라이선스로 한 번 더 감싸져 있음.
  - **`gh api` 추출 경로 (사내망 우회, `pet-asset-sourcing` 메모 패턴과 동일)**:
    ```bash
    gh api "repos/pixel-agents-hq/pixel-agents/contents/webview-ui/public/assets/furniture/DESK/DESK_FRONT.png" --jq '.content' | base64 -d > DESK_FRONT.png
    ```
- **해상도 판단**: 16px을 기본 모듈로 16/32/48/64 조합 — CLAUDE.md에 명시된 기존 팩의 "16~32px" 톤과 잘 맞음. 다만 DESK_SIDE(16×64), TABLE 계열 등 세로로 긴 아이템은 다른 팩(Pirate Bomb 58~80px)만큼은 아니어도 다소 큼 — 실사용 시 스케일 조정 필요할 수 있음.
- **누락 항목**: 서버랙, 창문, 스탠딩 데스크(별도 폴더 미확인 — `DESK`/`TABLE_FRONT`로 대체 가능할 가능성 있음, 직접 확인 필요).

### 2위(보완용) — Kenney · Roguelike/RPG Pack & Roguelike Indoor Pack (CC0)

- **라이선스 (사실, OGA 직접 확인)**: 둘 다 CC0(Public Domain). 저작자 표시는 "권장"이지 필수 아님. [출처] https://opengameart.org/content/roguelikerpg-pack-1700-tiles , https://opengameart.org/content/roguelike-indoor-pack
- **다운로드**: OGA 직접 zip 링크 확인됨(`Roguelike%20pack.zip`, `Roguelike%20Indoor%20pack.zip`). **OGA도 itch.io처럼 사내망에서 차단될 가능성**은 이 세션에서 검증하지 못함(OGA 페이지 HTML은 WebFetch로 정상 읽혔으나, 이는 Anthropic 서버 경유이므로 로컬 사내망 차단 여부와는 별개 — `corp-network-github-asset-download` 메모의 선례처럼 실제 로컬 `curl`은 별도로 검증 필요).
- **GitHub 미러**: Kenney 에셋은 게임 개발 커뮤니티에서 가장 흔하게 재배포되는 CC0 팩 계열이라 미러 존재 가능성은 매우 높음(예: `arthurhp06/roguelike-prototipo-python`의 `roguelikeFinal/` 폴더에 Kenney 타일 사용 언급 확인 — 단, 정확한 파일 경로까지는 미검증). `pixel-agents` 리포만큼 파일 단위로 검증되지는 않음.
- **포함 내용**: 침대·의자·책장·문·**창문**·주방용품 등. 모던 오피스 특유의 PC/모니터/커피머신/서버랙류는 없음 — **창문 보강용**으로만 실질적 가치.
- **스타일 리스크**: 판타지 로그라이크 던전 톤이라 모던 오피스 화풍(2dPig)과 나란히 두면 이질적일 수 있음(주관, 실물 검증 필요).

### 배경 보완 후보 — Office Space Tileset (no2games, OGA, CC0)

- 컨셉이 "side scroller office game"용으로 정확히 일치. CC0, 다운로드 URL 직접 확인: `https://opengameart.org/sites/default/files/offie-space-tileset.png` [출처] https://opengameart.org/content/office-space-tileset
- 2014-09-19 최종 업데이트 — **1년 이상 경과, outdated 가능성 라벨**. 파일 크기 12.7KB로 볼륨이 작아 배경 타일 몇 종 수준으로 추정(가구는 별도 필요).
- GitHub 미러 미확인.

### 서버랙 후보 (미확정) — 0x72 계열 CC0 팩

- 기존에 이미 프로젝트가 채택 중인 작가(dungeon-tileset 팩)라 화풍 일관성 최고 이점.
- `16x16 Industrial Tileset`(CC0, itch.io) — "다크 톤" 산업 타일셋으로 서버/기계 소품 포함 가능성 있으나 **내용물 직접 확인 실패**(itch.io WebFetch 차단). 라이선스는 CC0로 검색 결과상 일관되게 확인됨. [참고] https://0x72.itch.io/16x16-industrial-tileset
- `16x16+ Robot Tileset`(CC0 추정) — 로봇/사이파이 소품, 9종 캐릭터 위주로 보임. 가구성 소품 유무 미확인.
- **결론**: 서버랙은 이 두 팩 중 하나에서 나올 가능성이 있으나 미검증 상태이므로, 확실한 대안으로 **코드 드로잉**(수직 사각형 + 점멸 LED 도트, SF Symbol `server.rack` 활용 가능)을 1차안으로 잡는 것을 권장. 서버랙은 시각적으로 단순해 코드 드로잉 리스크가 가장 낮은 항목이기도 함.

### 제외 후보 — 라이선스 부적합 상세

**LimeZu (Modern Office - Revamped / Modern Interiors) [16x16]**
- GameDevMarket 공식 라이선스 페이지: "License prohibits selling, sharing or redistributing the asset or Derivative Works outside of the Media Product." [출처] https://www.gamedevmarket.net/asset/modern-interiors-rpg-tileset-16x16 (Pro License 조항)
- itch.io: Modern Interiors 무료 버전(전체의 약 3%)은 **"private/testing 용도로만 허용"** — 배포·번들 금지. 전체 버전은 유료(Modern User Interface $3.90, Modern Exteriors $2.50 등 유사 가격대), 상업적 사용 허용하지만 **credit 필수**의 커스텀 EULA (Creative Commons 표준 라이선스가 아님).
- 라이선스 표기 신뢰도 이슈: itch.io 댓글에서 LimeZu 본인이 "CC-BY-SA로 표기된 적 있으나 이는 기본값이었고 의도한 적 없다, 실제로는 CC-BY"라고 정정한 이력이 있음 — **표기 자체가 한때 잘못되어 있었다는 사실**은 라이선스 신뢰도를 낮추는 근거. [출처] https://itch.io/post/2550685
- **결론**: (1) 유료, (2) Creative Commons 표준이 아닌 커스텀 EULA, (3) 앱 리포에 raw PNG를 공개 커밋하는 것은 "Media Product 밖 재배포"에 해당할 소지가 큼(컴파일된 바이너리 임베드보다 훨씬 노출도가 높음), (4) 라이선스 표기 정정 이력으로 신뢰도 낮음 → **채택 불가** 판단 유지.

**CraftPix.net 무료 오피스 팩**
- 공식 라이선스: "앱을 통해 다른 최종 사용자가 에셋 파일을 사용할 수 있도록 재배포 금지" 명시. [출처] https://craftpix.net/file-licenses/ (`docs/research/mythic-pet-assets.md`에서 이미 동일 사유로 검증됨 — 재확인만 진행)
- **결론**: 채택 불가 (기존 조사와 동일 결론 재사용).

**Donarg – Office Interior Tileset (16x16)**
- 유료(최소 $2), 라이선스 텍스트를 직접 확인하지 못함(itch.io 차단).
- 방증: `pixel-agents`(8.4k star) 프로젝트의 `docs/external-assets.md`가 이 팩을 "highly recommended" 외부 팩으로 소개하면서도, 자체 리포에는 **번들하지 않고 사용자가 개별 구매 후 로컬 디렉토리로 추가**하는 방식만 지원함. 같은 문제(가구 커버리지 좋은 유료 팩)를 겪은 유사 프로젝트가 번들을 피한 선택은 라이선스상 재배포 불가일 가능성을 뒷받침하는 정황 증거(추정, 단정 아님).

**Chris Perich – Pixel Life: Office Essentials**
- "Commercial Use is free... 그러나 재판매/단독 파일 재배포에는 제한" — CC0/CC-BY 같은 표준 라이선스가 아닌 커스텀 조항. [출처] 검색 결과 기반, 원문 페이지 직접 접근 실패
- **결론**: 조건부 불가. "무료"라는 점이 "재배포 가능"을 보장하지 않음 — 프로젝트 정책(CC0/CC-BY만) 미충족.

**rixitic – 2D Sidescroller Office Tileset (16x16)**
- 유료($1 최소가), 라이선스 텍스트 미확인.
- 컨셉(사이드스크롤러 오피스)은 가장 이상적이나 조사 미완 + 유료라는 이유로 우선순위 낮춤.

---

## 요청 12종 가구 ↔ 소스 매핑 (권장안 기준)

| 요청 항목 | 소스 | 상태 |
|---|---|---|
| 책상 | 2dPig `DESK` | 확보 |
| 모니터/PC | 2dPig `PC` (on/off 상태 + 3프레임 애니메이션) | 확보 |
| 스탠딩 데스크 | 2dPig `TABLE_FRONT` 변형 활용 또는 코드 드로잉 | **직접 확인 필요** |
| 커피머신 | 2dPig `COFFEE` | 확보 |
| 소파 | 2dPig `SOFA` | 확보 |
| 서버랙 | 0x72 Industrial/Robot Tileset (미검증) 또는 코드 드로잉 | **미확정** |
| 화이트보드 | 2dPig `WHITEBOARD` | 확보 |
| 책장 | 2dPig `BOOKSHELF` / `DOUBLE_BOOKSHELF` | 확보 |
| 창문 | Kenney Roguelike/RPG Pack (화풍 이질적) 또는 코드 드로잉 | **보완 필요** |
| 화분 | 2dPig `PLANT`/`PLANT_2`/`LARGE_PLANT`/`HANGING_PLANT`/`CACTUS`/`POT` (6종) | 확보 (과잉 충족) |
| (추가) 의자/벤치 | 2dPig `CUSHIONED_CHAIR`/`WOODEN_CHAIR`/`CUSHIONED_BENCH`/`WOODEN_BENCH` | 확보 |
| (추가) 벽 장식/시계/휴지통 | 2dPig `SMALL_PAINTING` 등, `CLOCK`, `BIN` | 확보 (보너스) |

**결론**: 12종 중 9종은 2dPig 단일 소스로 확보, 3종(스탠딩데스크·서버랙·창문)만 보완 필요 — 보완 난이도는 낮음(코드 드로잉으로도 위화감이 적은 단순한 형태들).

---

## 상충 정보

- **LimeZu 라이선스 표기(CC-BY vs CC-BY-SA vs 커스텀 EULA)**: itch.io 상품 페이지, GameDevMarket Pro License, 작가 본인의 댓글 정정 이력 세 출처가 서로 다른 뉘앙스를 보임. GameDevMarket 쪽(공식 라이선스 페이지, 신뢰도 최상)의 "Media Product 밖 재배포 금지" 조항을 최종 판단 근거로 채택 — LimeZu는 어느 표기를 기준으로 봐도 "PNG를 공개 리포에 직접 커밋"에는 부적합.
- **OGA/itch.io의 사내망 접근 가능 여부**: 이번 조사는 Anthropic 서버 경유 WebFetch/WebSearch로 진행되어 OGA HTML은 정상 조회됐지만, itch.io는 이 세션에서도 일관되게 `ECONNRESET`이 발생했다(로컬 사내망 문제가 아니라 도구 자체의 itch.io 접근 제한일 가능성 — 원인 미확정). 사용자의 로컬 사내망에서 OGA 직접 zip 다운로드가 실제로 되는지는 별도 검증 필요 (`corp-network-github-asset-download` 메모의 선례상 curl 직접 다운로드가 될 수도, 302 리다이렉트로 막힐 수도 있음).

---

## 확인 안 된 것

- 2dPig 팩의 **원본 itch.io 라이선스 원문 전체**(이 조사에서는 2차 교차검증만 수행 — 사용자 개인망에서 1차 확인 권장).
- 2dPig `TABLE_FRONT`가 "스탠딩 데스크"로 자연스럽게 보일지 (시각 검증 필요).
- 2dPig `walls/` 폴더의 전체 파일 목록 (`wall_0.png` 외 추가 변형·창문 포함 여부 — "View all files" 미클릭으로 미확인).
- 0x72 `16x16 Industrial Tileset` / `Robot Tileset`의 실제 내용물(서버랙류 소품 포함 여부).
- Kenney Roguelike/RPG Pack의 **GitHub 미러 정확한 파일 경로** (존재 가능성은 높으나 이번 조사에서 경로 단위로 확정하지 못함).
- CC0/CC-BY 팩들의 실제 픽셀 색감·톤이 기존 9개 팩(0x72, Pixel Frog 계열, ScratchIO 등)과 시각적으로 잘 어울리는지 — 전부 실물 다운로드 후 육안 비교 필요.

---

## Fallback 확인

기획서(`docs/plans/guild.md` §5-2, §6 P0)에 이미 명시된 대로, **적합한 팩을 못 구하면 P1은 코드 드로잉(단색 도형 + SF Symbol) 가구로 시작**하고 에셋 교체를 후속 PR로 분리하는 방침은 이번 조사 결과와 무관하게 유효하다. 다만 이번 조사로 2dPig 소스 하나로 가구 12종 중 9종을 CC0로, 검증된 GitHub 미러 경로까지 확보했으므로, **fallback을 전면 발동할 필요는 없어 보이며** 스탠딩데스크·서버랙·창문 3종에 한해서만 코드 드로잉 병행을 권장한다(1안 참조).

---

## 참고 자료 (미확인이지만 후속 가치 있는 URL)

- https://github.com/pixel-agents-hq/pixel-agents — 2dPig 에셋 번들 소스(furniture/floors/walls 전체 구조 직접 탐색 권장)
- https://github.com/pablodelucca/pixel-agents — 동일 프로젝트의 원 저자 계정으로 추정되는 리포(교차 확인 권장)
- https://github.com/neomatrix25/pixel-office-openclaw — 2dPig 크레딧을 명시한 파생 프로젝트
- https://opengameart.org/content/roguelikerpg-pack-1700-tiles , https://opengameart.org/content/roguelike-indoor-pack — Kenney CC0 zip 직접 다운로드
- https://opengameart.org/content/office-space-tileset — no2games CC0, "side scroller office game"용으로 컨셉이 정확히 일치하나 outdated(2014)
- https://0x72.itch.io/16x16-industrial-tileset , 0x72의 Robot Tileset — 서버랙 후보, 사용자 개인망에서 직접 열람 후 내용물 확인 필요
- https://github.com/arthurhp06/roguelike-prototipo-python — Kenney 타일 사용 확인된 소규모 리포(파일 경로 미검증, 추가 탐색 가치)
- https://itch.io/game-assets/assets-cc0/tag-office , https://itch.io/game-assets/assets-cc0/tag-16x16 — itch.io CC0 필터 목록(사용자 개인망에서 브라우징 시 추가 후보 발굴 가능)
