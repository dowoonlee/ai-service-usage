# 아레나 팀 시너지 배지 — 픽셀 아트 아이콘 후보 조사

조사일: 2026-07-20
조사 목적: 아레나 탭의 "팀 시너지" 배지(`Sources/ClaudeUsage/ArenaView.swift:150-159`, `synergyBadge`
헬퍼 `ArenaView.swift:737`)가 현재 SF Symbol(`person.3.sequence.fill`, `hexagon.fill`,
`person.3.sequence`, 13pt)을 쓰고 있어 프로젝트 전체의 픽셀 아트 화풍(Pixel Frog / 0x72
DungeonTileset II / Sunny Land / ScratchIO Wild Animals 등, 전부 CC0/CC-BY)과 충돌한다. 대체용
**픽셀 아트 아이콘**을 (1) 팀 시너지/유대 배지용, (2) 6종 속성 배틀 타입(Beast/Warrior/Chaos/Arcane/
Machine/Mascot) 또는 일반 RPG 속성 아이콘용으로 조사했다. 사내망 TLS가 itch.io/OpenGameArt 직접
다운로드를 막는다는 기존 이력(`pet-asset-sourcing` 메모)을 고려해 **GitHub 호스팅 여부를 최우선
기준**으로 뒀다.

---

## 요약 (3줄)

- **[Tuxemon/Tuxemon](https://github.com/Tuxemon/Tuxemon) GitHub 레포**에 `mods/tuxemon/gfx/ui/icons/`
  아래 `bond/`(유대 4단계), `party/`(파티 슬롯 4종), `element/`(속성 타입 14종 × 3배리언트=42파일)
  폴더가 **그대로 존재**해 두 요구사항(시너지/유대 + 속성 타입)을 **단일 GitHub 소스로 동시에**
  충족한다 — 사내망 제약을 사실상 해결하는 유일한 후보다. 다만 라이선스가 프로젝트 관례(CC0/CC-BY)를
  벗어나는 **CC-BY-SA 4.0**(ShareAlike, Tuxemon 프로젝트 기본 아트 라이선스)이라 채택 전 확인이 필요하다.
- OpenGameArt에 **속성 타입 전용 CC0/CC-BY 팩**이 여럿 있다 — [OwlishMedia "RPG UI Icons"](https://opengameart.org/content/rpg-ui-icons)(CC0, 16×16/32×32, "status effect·elements·items" 명시)와
  [RogimonDev "12 Elemental Type Symbols/Icons"](https://opengameart.org/content/12-elemental-type-symbolsicons)(CC-BY 4.0, 9×9px, Fire/Water/Earth/Air/Ice/Plant/Electric/Metal/Magic/Monster/Darkness/Undead
  12종)가 라이선스는 더 낫지만 **GitHub 미러를 찾지 못했다** — 기존 VFX 조사(`pixel-vfx-assets.md`)와
  동일하게 OGA 직접 다운로드 경로만 있어 사내망에서 막힐 가능성이 높다.
- "시너지/유대"만을 위한 전용 아이콘(사슬·핸드셰이크·문장) 팩은 **찾지 못했다** — 이 개념은 대개
  "party"(파티 편성 UI) 또는 게임별 자체 제작 아이콘으로만 존재해서, Tuxemon의 `bond/`+`party/`
  조합이 사실상 유일하게 정확히 부합하는 후보다.

---

## 권장 결론 (트레이드오프 명시, 단정 회피)

### Top 추천 1 — Tuxemon/Tuxemon GitHub 레포 (`bond` + `party` + `element` 아이콘)

**즉시 사용 가능성**: 매우 높음. `icons/bond/{bond1..4}.png`(유대 단계 배지 — "동족/컬렉션 시너지"
배지로 의미가 가장 정확히 부합), `icons/party/{party_empty, party_icon01..03}.png`(파티 편성 배지),
`icons/element/{aether,cosmic,earth,fire,frost,heroic,lightning,metal,normal,shadow,sky,venom,water,
wood}_type{,_small,_watermark}.png`(속성 타입 14종, 각 3배리언트)가 전부 GitHub에 있어 `gh api
repos/Tuxemon/Tuxemon/contents/<path> --jq '.content' | base64 -d > out.png`로 바로 추출 가능
(`pet-asset-sourcing` 메모의 검증된 우회 패턴 재사용, 이번엔 "미러"가 아니라 원본 자체가 GitHub임).
14개 타입 중 우리 6종(Beast/Warrior/Chaos/Arcane/Machine/Mascot)에 의미상 근접한 걸 고르면
(예: `fire`→Chaos, `metal`→Machine, `heroic`→Warrior, `aether`/`cosmic`→Arcane, `normal`→Mascot,
`earth`/`wood`→Beast 식) 직접 그리지 않고도 6종 세트를 채울 수 있다.

**트레이드오프**: 라이선스가 **CC-BY-SA 4.0**(Tuxemon 프로젝트 아트 기본 라이선스, wiki 확인 —
"contributions are placed under Creative Commons Attribution-ShareAlike 4.0")이다. 프로젝트
CLAUDE.md 관례는 "CC0 최우선, CC-BY 허용"이고 **ShareAlike는 언급되지 않은 세 번째 카테고리**다.
SA 조항은 "이 아이콘을 리사이즈/재색상해서 만든 파생물도 CC-BY-SA로 공개해야 한다"는 의무를
발생시키는데, 이는 기존에 채택한 CC-BY 팩(Kings and Pigs 등)과 성격이 다르다 — **채택 전 lead
확인 권장** (본 리서치의 HITL 규칙 대상). 정확한 픽셀 크기(16×16 추정이나 미확인)와 실제 색감·
외곽선이 기존 팩과 어울리는지도 다운로드 후 육안 확인이 필요하다.

### Top 추천 2 — OwlishMedia "RPG UI Icons" (OpenGameArt, CC0)

라이선스 부담이 없는(**CC0**) 대안. 16×16/32×32 PNG 스프라이트시트 하나에 "status effect, elements,
items"가 명시적으로 포함돼 있어 6종 속성 배지 후보로 적합하다. 다만 **GitHub 미러를 찾지 못했다** —
OGA 직접 다운로드는 사내망에서 막힐 가능성이 높으므로(`pet-asset-sourcing` 메모 전례), 실제 확보는
개인망 다운로드 또는 `pet-expansion-200`에서 검증된 itch류 우회(OGA는 itch와 다운로드 메커니즘이
달라 그대로 재사용은 안 됨, 별도 확인 필요)가 필요하다. "시너지/유대" 아이콘은 이 팩에 없어(아이템/
스탯 위주) 1번 후보(Tuxemon `bond`)와 조합해야 한다.

### 실무적 고려사항 (구현 팀 참고용, 확정 아님)

현재 SF Symbol 방식은 `foregroundStyle(color)`로 **하나의 벡터 도형을 타입 색상별로 동적 틴트**한다
(`ArenaView.swift:738-740`, `typeColor(t.type)`). 이번에 조사한 픽셀 아트 팩들은 대부분 **타입별로
이미 배색이 고정된 개별 PNG**(예: `fire_type.png`는 이미 주황/빨강으로 그려짐)라 SF Symbol과 동일한
"틴트" 패턴을 그대로 유지하려면 무채색 실루엣 버전이 따로 필요하다. 반대로, 타입마다 이미 배색된
아이콘을 그대로 쓰면 동적 틴트 로직 자체가 필요 없어지고(각 타입 아이콘 자체가 색을 내장) 오히려
더 게임다운 표현이 될 수 있다 — 이는 설계 선택의 문제이며 본 리서치의 범위를 벗어난 권장이므로
구현 시 별도 판단 필요.

---

## 후보 상세 (사실, 출처별)

| # | 팩 | 저작자 | URL | 라이선스 | 수록 아이콘 | 크기/포맷 | 다운로드 경로 |
|---|---|---|---|---|---|---|---|
| 1 | **Tuxemon UI Icons** (`icons/bond`, `icons/party`, `icons/element`) | Tuxemon 프로젝트 팀(개별 작가 미상 — `ATTRIBUTIONS.md`에 이 3개 폴더에 대한 별도 크레딧 항목을 찾지 못함, 프로젝트 기본 아트 라이선스 적용으로 추정) | [github.com/Tuxemon/Tuxemon](https://github.com/Tuxemon/Tuxemon) (default branch `development`), 경로: [`mods/tuxemon/gfx/ui/icons`](https://github.com/Tuxemon/Tuxemon/tree/development/mods/tuxemon/gfx/ui/icons) | **CC-BY-SA 4.0**(아트, wiki 확인) / 코드는 GPL-3.0(별개, 아이콘 자체와 무관) | `bond1~4.png`(유대 4단계), `party_empty.png`+`party_icon01~03.png`(파티 슬롯), `element/{aether,cosmic,earth,fire,frost,heroic,lightning,metal,normal,shadow,sky,venom,water,wood}_type.png` 각 `_small`/`_watermark` 배리언트 포함(총 14종×3=42개) | 픽셀 아트(Pokémon류 SNES 스타일 몬스터 배틀 RPG의 실제 UI 자산). 정확한 px 크기는 GitHub 파일 뷰에 표시 안 됨(`fire_type.png`=292B, `bond1.png`=2.88KB, `fire_type_small.png`=559B — 파일 크기만으로 정확한 치수 추정 불가, **미확인**) | `gh api repos/Tuxemon/Tuxemon/contents/mods/tuxemon/gfx/ui/icons/bond/bond1.png --jq '.content' \| base64 -d > bond1.png` 식으로 파일별 추출(레포 원본이 GitHub이라 미러 탐색 불필요) |
| 2 | **RPG UI Icons** | OwlishMedia | [opengameart.org/content/rpg-ui-icons](https://opengameart.org/content/rpg-ui-icons) | **CC0**(Public Domain, OGA 명시) | "status effect, elements, items" 포함 RPG 공용 UI 아이콘(정확한 개별 목록/개수 미확인). 무기/방어구/의약품/마법/포인터·커서 포함 | 16×16 및 32×32px, PNG(zip 안에 스프라이트시트, 46.3KB) | GitHub 미러 못 찾음(Alien_shooter-DOS 레포가 이 팩을 credit만 하고 실제 PNG는 미포함 — README 크레딧만 확인). OGA 직접 다운로드 유일 경로 — 사내망 차단 가능성(미확인, 이번 세션에서 실제 접속 시도는 안 함) |
| 3 | **12 Elemental Type Symbols/Icons** | RogimonDev | [opengameart.org/content/12-elemental-type-symbolsicons](https://opengameart.org/content/12-elemental-type-symbolsicons) | **CC-BY 4.0**(작가 명시: "you must give credit to me; please just link this page") | Water / Earth(Ground) / Air(Wind) / Fire / Ice / Plant(Grass) / Electric(Thunder) / Metal(Iron) / Magic / Monster(Dragon/Beast) / Darkness / Undead — 12종, 단일 스프라이트시트 `elementsymbols.png`(410 bytes) | **9×9px** — "white, transparent, 한 아이콘당 base color 1개" | GitHub 미러 못 찾음. OGA 단일 파일(410B)이라 용량은 문제 없으나 접속 자체가 사내망 이슈일 가능성(미확인). 9×9는 13~16pt 타깃보다 훨씬 작아 세부가 뭉개질 위험(미확인, 다운로드 후 확대 검증 필요) |
| 4 | **1-bit Pixel Icons** | Nikoichu | [nikoichu.itch.io/pixel-icons](https://nikoichu.itch.io/pixel-icons) | **CC0**(명시, attribution "권장이나 불요") | 1,476개(v1.2, 2025-11) — RPG(무기/장비/스탯/마법/전리품), 소프트웨어/하드웨어, 보드게임, 소셜미디어, 날씨, 지도마커 등. **팀 시너지/유대/사슬/문장 전용 카테고리는 확인 못 함**(있어도 세부 카테고리에 묻혀 있을 가능성) | 16×16px, PNG(개별 파일 + cropped 버전) | GitHub 미러 못 찾음. itch.io 전용, 1-bit(흑백)라 "시너지 없음" 상태의 회색 배지 표현엔 오히려 잘 맞을 수 있음(추정) |
| 5 | **Achievements Icon Pack** | GTORAVERSE | [gtoraverse.itch.io/achievement-icon-pack-pixel](https://gtoraverse.itch.io/achievement-icon-pack-pixel) | **커스텀 무료 라이선스**(CC0/CC-BY 아님) — "personal or commercial use 허용 + attribution 필수 + 재판매·NFT·AI학습 금지" | 트로피/메달/배지/방패/보물상자/선물상자/별/하트/다이아몬드/코인/왕관 등 11종(각 흑백 아웃라인 버전 포함) | 8×8 / 16×16 / 32×32px, PNG + PSD + TexturePacker | GitHub 미러 못 찾음. "방패/메달/배지" 계열이 시너지 배지의 **틀(프레임)** 용도로 보완 가능(문장/크레스트 대체재) — 단, 시너지 자체("동족/동타입")를 표현하진 않아 1번 후보와 조합 필요 |

**제외**: [game-icons.net / game-icons/icons GitHub 레포](https://github.com/game-icons/icons)(CC-BY 3.0, GitHub
호스팅 확정·4180개 아이콘·party/chain/crest/fire/water 다 있음)는 **SVG 전용 벡터**이고(README:
"white foreground on black background" 커스터마이즈 가능한 vector line-art) 래스터라이즈해도 매끈한
벡터 느낌이 남아 프로젝트의 도트 화풍과 충돌할 가능성이 높아 제외했다(현재 SF Symbol과 같은 문제
재발). [Kenney "Game Icons"](https://kenney.nl/assets/game-icons)도 CC0·GitHub 파생 미러가 존재하나
게임패드/오디오/커서 등 인터페이스 아이콘 위주라 팀 시너지·속성 타입 요구와 무관해 제외했다.
[GandalfHardcore "100 Pixel Art Buffs and Ability Icons Pack"](https://gandalfhardcore.itch.io/buffs-and-ability-icons-pixel-art-pack)은
버프/디버프 아이콘으로 방향성은 맞으나 **유료($3.24~)**라 제외했다.

---

## 상충 정보

1. **"GitHub에 있음" ≠ "라이선스가 가장 좋음"**: Tuxemon 레포(1번)는 다운로드 경로가 가장 확실하지만
   라이선스가 CC-BY-SA 4.0으로 프로젝트 관례(CC0/CC-BY)보다 제약이 크다. 반대로 OwlishMedia(2번)는
   라이선스가 가장 좋지만(CC0) GitHub 경로가 없다. 두 기준이 상충하므로 **어느 쪽을 우선할지는
   lead/architect 판단이 필요**하다 — 본 리서치는 어느 쪽이 "정답"이라 단정하지 않는다.
2. **Tuxemon 개별 파일의 정확한 원저작자**: `ATTRIBUTIONS.md`에서 `bond`/`party`/`element` 폴더에
   대한 별도 크레딧 항목을 찾지 못했다 — 이는 (a) 파일이 누락 문서화됐거나 (b) Tuxemon 팀이 직접
   제작해 프로젝트 기본 라이선스(CC-BY-SA 4.0)를 그대로 적용받는 경우일 수 있다. 후자로 추정하지만
   **확정은 아니다** — 실제 채택 전 `ATTRIBUTIONS.md` 전문(현재는 발췌만 확인)을 재확인할 필요가 있다.

---

## 확인 안 된 것

- **Tuxemon 아이콘의 정확한 px 크기** — GitHub blob 뷰가 이미지 치수를 노출하지 않아 파일 크기(수백
  바이트~수 KB)로만 추정했다. 다운로드 후 실측 필요.
- **Tuxemon 아이콘의 실제 색감/외곽선이 기존 채택 팩(Pixel Frog, 0x72 등)과 시각적으로 어울리는지** —
  텍스트 기반 조사만 했고 스크린샷을 열람하지 못했다.
- **OwlishMedia RPG UI Icons / RogimonDev 12 Elemental Type Symbols의 사내망 접속 가능 여부** —
  과거 메모(`pet-asset-sourcing`) 기준 itch.io/OGA 직접 다운로드가 막힌 이력이 있으나, 이번 세션에서
  실제 접속을 시도하진 않았다.
- **"팀 시너지/유대" 전용 아이콘의 더 넓은 후보군** — 사슬(chain)·핸드셰이크·하트 오라 등 구체적
  키워드로 여러 차례 검색했으나 Tuxemon `bond`/`party` 외에는 의미가 정확히 부합하는 CC0/CC-BY 팩을
  찾지 못했다. 검색이 itch.io/OGA 텍스트 설명에 의존하다 보니 "이미지는 있지만 설명에 키워드가 없어
  검색에 안 걸리는" 후보가 있을 가능성이 있다(추정, 미확인).
- **7Soul1 "496 Pixel Art Icons for Medieval/Fantasy RPG"**(CC0, 34×34px, Tuxemon/undying-dusk/jonga
  등 실제 GitHub 프로젝트에서 파생 사용된 이력 확인)는 속성/시너지 전용 카테고리가 없어 본문 표에서
  제외했으나, 그 GitHub 사용처 레포들(예: `Lucas-C/undying-dusk`, `cxong/jonga`)에 개별 아이콘 PNG가
  실제로 포함돼 있는지는 확인하지 못했다 — 확인되면 간접 GitHub 경로가 될 수 있어 후속 조사 가치가
  있다.

---

## 참고 자료 (미확인이지만 후속 가치 있는 URL)

- [github.com/Tuxemon/Tuxemon/tree/development/mods/tuxemon/gfx/ui/icons](https://github.com/Tuxemon/Tuxemon/tree/development/mods/tuxemon/gfx/ui/icons) — `bond`/`party`/`element` 외에 `status`/`range`/`speed`/`plusminus` 폴더도 있음(상태이상/사거리/속도/증감 아이콘 추정, 이번 조사 범위 밖이라 미상세 조사 — 추후 "상태이상 배지" 필요 시 같은 레포에서 확보 가능할 것으로 보임)
- [github.com/Tuxemon/Tuxemon/blob/development/ATTRIBUTIONS.md](https://github.com/Tuxemon/Tuxemon/blob/development/ATTRIBUTIONS.md) — 전문 재확인 필요(이번엔 발췌만 확인, 특히 UI 아이콘 관련 항목 유무)
- [opengameart.org/content/element-icons](https://opengameart.org/content/element-icons) — onlyjb, CC0이나 4원소(fire/earth/water/air)만, **SVG 포맷**이라 벡터 스타일 위험 있음, 미상세 조사
- [opengameart.org/content/magical-element-icons](https://opengameart.org/content/magical-element-icons), [opengameart.org/content/icons-for-abilities-skills-etc](https://opengameart.org/content/icons-for-abilities-skills-etc) — 검색에서 발견만 하고 라이선스/크기 미조사
- [gandalfhardcore.itch.io/16x16-pixel-art-item-icons](https://gandalfhardcore.itch.io/16x16-pixel-art-item-icons) — 600+ 아이콘, 라이선스(무료 여부/CC 태그) 미확인
- [vilrink.itch.io/pixel-art-icon-pack-16x16](https://vilrink.itch.io/pixel-art-icon-pack-16x16), [marvinomm.itch.io/pixel-icons-16x16](https://marvinomm.itch.io/pixel-icons-16x16) — 16×16 아이콘 팩, 라이선스·시너지 관련 내용물 미조사
- [huggingface.co/datasets/nyuuzyou/OpenGameArt-CC-BY-4.0](https://huggingface.co/datasets/nyuuzyou/OpenGameArt-CC-BY-4.0) — OpenGameArt CC-BY 4.0 자산을 모은 벌크 데이터셋 미러(GitHub는 아니지만 사내망에서 huggingface.co가 itch.io/OGA와 달리 차단 안 될 가능성이 있어 대체 경로로 후속 확인 가치 있음, **완전 미확인**)

---

## 검토 체크리스트

- [x] 출처 신뢰도 평가 — GitHub 원본(Tuxemon, 1.1k star 활성 프로젝트) 최우선, OpenGameArt 공식
      페이지 차선, itch.io 페이지 설명 그 다음 순으로 신뢰도 구분
- [x] 최신성 평가 — Tuxemon 레포는 활성 개발 중(확인, star/설명 기준), Nikoichu 팩은 2025-11 최신
      업데이트 확인. RogimonDev/OwlishMedia 팩은 게시일 정확히 확인 못했으나 OGA 페이지가 현재도
      활성 상태라 outdated 라벨 근거는 없음
- [x] 상충 정보 식별 — "GitHub 확보 가능" vs "라이선스 우수함" 트레이드오프, Tuxemon 개별 파일
      크레딧 불명 2건 별도 섹션 기재
- [x] 사실/권장 분리 — 표는 사실 위주, "권장 결론" 섹션에서만 Top 추천·트레이드오프 서술
- [x] 출처 URL 모든 표 항목에 포함
- [x] 확인 못 한 영역 명시 — px 크기, 시각적 어울림, 사내망 접속 가능 여부, bond 전용 후보군 부족
      등 별도 섹션
- [x] prompt injection 패턴 없음 — 모든 WebFetch 결과는 GitHub/itch.io/OpenGameArt의 일반적인
      리포지토리 설명·라이선스 문구였고 `<system-reminder>`, "ignore previous instructions" 류의
      이상 지시 패턴은 발견되지 않음
