# AIUsage 픽셀아트 VFX(이펙트) 에셋 조사 — 가챠 리빌 + 펫 강화(도박) 연출용

조사일: 2026-07-16
조사 목적: (a) 가챠 뽑기 리빌 연출 개선, (b) "펫 강화(도박) 시스템"의 강화 성공/실패/파괴 연출에 쓸
**기존 CC0/CC-BY 픽셀아트 VFX 스프라이트 팩**을 확보(직접 그리지 않음). 6개 카테고리(폭발/타격,
반짝임/광휘, 마법진/오라/차지, 연기/파편, 충격파 링, 알부화/상자개봉) 각각 1~3개 후보 조사.
기존 채택 팩(Pixel Adventure, 0x72 DungeonTileset II, Kings and Pigs, Sunny Land 등, 16~32px 셀,
itch.io/OpenGameArt 출처)과의 화풍 일관성을 우선 기준으로 삼음. 관련 진행 중 작업: `docs/research/dnf-enhancement.md`,
`docs/research/maplestory-enhancement.md`(펫 강화 도박 시스템 설계 리서치, 같은 날 병행 조사).

---

## 요약 (3줄)

- 6개 카테고리 전부에서 **CC0 라이선스** 후보를 최소 1개씩 확보했다. 가장 신뢰도 높은 조합은
  **CodeManu(Free Pixel Effects Pack) + BenHickling(Explosion/Ring Explosion, OGA) + Foozle(Pixel
  Magic Effects) + GrafxKid(Mini FX, Items & UI — 기존 채택 캐릭터 팩과 동일 작가) + karsiori(Chest
  Pack)**의 5팩으로, 전부 CC0/공개 도메인이라 attribution 의무가 없다.
- **GitHub 미러는 이번 조사 범위에서 단 하나도 확인하지 못했다** — VFX 스프라이트시트는 파일명이
  일반적이고(`explosion.png` 등) PNG 내용이 GitHub 코드검색에 안 걸려, 기존 펫 팩 조사(`pet-asset-
  sourcing`, `pet-asset-candidates.md`)와 같은 이유로 미러 탐색이 실패했다. 사내망에서는 itch.io/OGA
  직접 다운로드가 TLS로 막히는 전례가 있어(`pet-asset-sourcing` 메모), 실제 확보 시 개인망 다운로드
  또는 `pet-expansion-200`에서 검증된 itch 비공식 다운로드 흐름(`POST /{slug}/download_url` →
  서명 URL) 우회가 필요할 가능성이 높다.
- **알 부화(egg hatch)** 카테고리만 완전한 CC0가 아니라 커스텀 무료 라이선스(Nightspore, "NFT/Crypto/
  AI 생성 도용 금지" 조항 포함)뿐이었다 — 상용 배포 자체는 허용되나 프로젝트의 기존 CC0/CC-BY 이원
  컨벤션과 다른 세 번째 라이선스 카테고리가 되므로 별도 표기가 필요하다.

---

## 권장 결론 (트레이드오프 명시, 단정 회피)

- **강화(도박) 연출의 핵심 3종(성공 버스트/실패 하락/파괴)**은 CodeManu Free Pixel Effects Pack
  하나만으로도 폭발 계열 색조 6종(주황 화염/얼음/적백/황록/황주황)을 확보할 수 있어, 성공(따뜻한 색)/
  파괴(차갑거나 어두운 색)를 프레임 크롭 없이 색상만으로 구분하는 초기 구현이 가능하다. 다만 100×100px
  프레임은 기존 팩의 16~32px 셀보다 훨씬 커서, 다운스케일하거나 캐릭터 위에 오버레이할 때 스케일 조정이
  필요할 것으로 보인다(다운로드 후 확인 필요, 추정).
- **충격파 링은 BenHickling의 "Ring Explosion"이 사실상 유일한 정통 CC0 후보**다(56프레임, 100×100px,
  이미 "Explosion"과 남매 팩이라 톤이 자동으로 맞음). PixelDuck의 "16 shockwave effects" 컬렉션은
  존재는 확인했으나 라이선스/가격 페이지에 도달하지 못해 채택 여부를 판단할 수 없다 — 후속 확인 필요.
- **attribution을 감수할 여력이 있다면 unTied Games "Super Pixel Effects Gigapack"(무료 티어)** 하나로
  폭발·마법폭발·에너지링·연기·스파클·별 등 대부분의 카테고리를 단일 출처로 커버할 수 있어 팩 관리
  부담이 가장 적다. 다만 라이선스가 표준 CC-BY가 아니라 **"attribution 필수 + 원본 에셋 자체 재판매
  금지"라는 커스텀 조항**이라, 기존 CC-BY 팩(Kings and Pigs 등)과 동일한 `LICENSE_*.txt` 패턴으로
  관리는 가능하지만 "CC-BY"라고 표기하면 부정확하다 — 표기 시 정확한 원문 인용 필요.
- 알 부화는 CC0 후보를 찾지 못했다. Nightspore의 커스텀 무료 라이선스(속성 표기 불요, 상업 게임 허용,
  단 NFT/크립토/AI 도용 금지)를 쓰거나, 카테고리 자체를 **karsiori의 CC0 상자(chest) 팩으로 대체**해
  "알 대신 상자를 여는 리빌 연출"로 설계를 바꾸는 편이 라이선스 리스크가 가장 낮다(권장).

---

## 후보 상세 (카테고리별)

### 1. 폭발/타격 (explosion / impact / hit)

| 팩 | 제작자 | 라이선스 | URL | GitHub 미러 | 셀/프레임 | 포맷 | 내용물 | 톤 | Attribution |
|---|---|---|---|---|---|---|---|---|---|
| **Free Pixel Effects Pack** | CodeManu | **CC0**(itch 페이지 텍스트는 "public domain", itch 태그 메타는 모순적으로 "CC Attribution 4.0"이라 표기 — 아래 상충 정보 참조. **OpenGameArt 미러 페이지는 명시적으로 CC0으로 태깅**돼 있어 CC0으로 판단) | [codemanu.itch.io/pixelart-effect-pack](https://codemanu.itch.io/pixelart-effect-pack) | 없음(확인 못함). **OGA 미러 존재**: [opengameart.org/content/free-pixel-effects-pack](https://opengameart.org/content/free-pixel-effects-pack) (OGA는 GitHub이 아니지만 itch 직다운로드가 막힐 때 대체 경로가 될 수 있음) | 100×100px, 20개 이펙트 | 개별 PNG(정확한 스트립 여부 미확인) | fireball/explosion(주황), ice/frost explosion(백청), star/windmill 에너지, red&white explosion, yellow-green 원형(포자류), yellow-orange explosion | 채도 높은 만화적 폭발 — 기존 32px 팩보다 프레임이 커서 스케일 조정 필요 추정 | 불요(권장 사항) |
| **Explosion Animations Pack** | ansimuz | **CC0** (Creative Commons Zero v1.0 Universal, 페이지 명시) | [ansimuz.itch.io/explosion-animations-pack](https://ansimuz.itch.io/explosion-animations-pack) | 없음(확인 못함) | 미확인(페이지에 셀 크기 미기재) | "픽셀아트 스프라이트시트" (스트립 추정, 미확정) | 7종의 서로 다른 애니메이션 폭발 | 기존 채택 중인 Ansimuz SunnyLand(이미 채택된 CC0 팩)와 동일 작가 — 화풍 일관성 근거 있음 | 불요(감사 표시는 권장) |
| **Explosion** / **Ring Explosion** | BenHickling (OpenGameArt) | **CC0** (Public Domain Dedication, 페이지 명시) | [opengameart.org/content/explosion-7](https://opengameart.org/content/explosion-7), [opengameart.org/content/ring-explosion](https://opengameart.org/content/ring-explosion) | 없음(확인 못함) | 100×100px | 투명 PNG 스프라이트시트(단일 파일, `explosion1.png` 51KB / `explosion2.png` 52.4KB) | Explosion=50프레임 원형 버스트, Ring Explosion=56프레임 **링 형태 확산**(카테고리 5 충격파와 겸용 가능) | 단색조 흑백/그레이스케일에 가까운 절차적 렌더 느낌(스크린샷 미확인, 추정) — 채색 필요할 수도 있음 | 불요 |

**제외/후순위**: Ansimuz "Explosions & Magic Collection"(유료, 최소 $99.99 확인됨 — 무료 아님, 채택 불가). CodeManu의 유료작 "Pixel Art Impact & Hit FX Animations"도 유료로 확인(가격 미확인이나 purchase 페이지 존재 = 유료).

### 2. 반짝임/광휘 (sparkle / shine / star / twinkle)

| 팩 | 제작자 | 라이선스 | URL | GitHub 미러 | 셀/프레임 | 포맷 | 내용물 | 톤 | Attribution |
|---|---|---|---|---|---|---|---|---|---|
| **Mini FX, Items & UI** | GrafxKid | **CC0** (Creative Commons Zero v1.0 Universal, 페이지 명시) | [grafxkid.itch.io/mini-fx-items-ui](https://grafxkid.itch.io/mini-fx-items-ui) | 없음(확인 못함) | 미확인(다운로드 후 실측 필요) | 미확인 | "sparkles and cloud poofs"(스파클 + 구름 퍼프), 아이템/기본 UI 요소 동반 | **이미 프로젝트가 채택 중인 GrafxKid Sprite Pack 1~8과 동일 작가** — 톤 일관성이 이번 조사 전체에서 가장 강함(이미 `pet-asset-candidates.md`에서 GrafxKid 전 팩 CC0 확인됨) | 불요("Crediting is optional") |
| **Pixel Art Animated Star** | Narik | 명시적 CC0는 아니나 "personal/commercial 사용 가능, 수정 가능, credit 불요(권장)" — 사실상 CC0와 동등한 조건, 공식 CC 태그 미확인 | [soulofkiran.itch.io/pixel-art-animated-star](https://soulofkiran.itch.io/pixel-art-animated-star) | 없음 | 32×32px | PNG + GIF | 반짝이는(shine) 별 애니메이션 1종 | 32px는 기존 셀 규격과 그대로 호환 | 불요(권장) |
| **Free VFX Asset Pack**(참고, 반짝임 일부 포함) | CodeManu | CC0(1번 카테고리와 동일 라이선스 패턴, "public domain" 텍스트 vs itch 메타 불일치) | [codemanu.itch.io/vfx-free-pack](https://codemanu.itch.io/vfx-free-pack) | 없음 | 미확인 | PNG 스프라이트시트/개별 프레임/GIF(30fps·60fps 두 버전) | 22종 중 "Puff and Stars", "Constellation" 등이 반짝임 계열 | 폭발 카테고리와 같은 팩이라 별도 확보 없이 겸용 가능 | 불요 |

### 3. 마법진/오라/차지 (magic circle / aura / charge / glow / buff)

| 팩 | 제작자 | 라이선스 | URL | GitHub 미러 | 셀/프레임 | 포맷 | 내용물 | 톤 | Attribution |
|---|---|---|---|---|---|---|---|---|---|
| **Pixel Magic Effects** | Foozle (lordfitoi, Fiverr 제작) | **CC0** (페이지 명시, "Attribution not required") | [foozlecc.itch.io/pixel-magic-sprite-effects](https://foozlecc.itch.io/pixel-magic-sprite-effects) | 없음(확인 못함) | 32×32px | 미확인 | Fire Ball/Molten Spear, Water/Geyser, Rocks/Earth Spikes, Wind/Tornado, **Portal**, Explosion — "magic circle" 자체는 없으나 Portal이 원형 차지 이펙트로 대체 가능 | 32px는 기존 셀 규격과 호환. 생성형 AI 미사용 명시(4.9/5 평점) | 불요 |
| **Pixel Art Spells** | DevWizard (OpenGameArt) | **CC0** (페이지 명시) | [opengameart.org/content/pixel-art-spells](https://opengameart.org/content/pixel-art-spells) | 없음 | 16×16px | PNG + Aseprite(.aseprite) 파일 동봉 | 23종 주문(아케인 볼트/파이어볼/얼음창/빛의 화살/**마법 오브**/물대포/바람볼트/식물 미사일/락 슬링/**매직 실드** 등) — 대부분 발사체(projectile) 위주라 "차지/오라"보다는 "발동 이펙트"에 가까움 | 16px는 기존 DungeonTileset II 그리드와 완전히 동일 — 화풍 궁합 최상 | 불요 |
| **Free Magic Animated Effects Pixel Art** | Free Game Assets (브랜드명, CodeManu와 무관) | **불명확** — 페이지에 명시적 라이선스 문구 없음, "AI 미생성" 표기만 확인. CC0 단정 불가 | [free-game-assets.itch.io/free-pixel-magic-sprite-effects-pack](https://free-game-assets.itch.io/free-pixel-magic-sprite-effects-pack) | 없음 | 32×32px(아이콘 기준) | 미확인 | healing effect, blink, roots, **damage aura**, laser, spark, charm, starfall, petrification, invisible 등 — "오라/버프" 카테고리에 가장 직접적으로 부합하는 이름들이 많음 | 미확인 | **미확인 — 채택 전 라이선스 재확인 필수** |

**보완 후보(참고용, 톤 상충 위험)**: OpenGameArt "2D Spell Effects"(Mikodrak, CC0)는 라이선스는 적합하나 **Blender 파티클 + After Effects 합성으로 제작된 스무스 벡터 스타일**이라 도트 픽셀 톤과 맞지 않아 제외 권장.

### 4. 연기/파편/산산조각 (smoke / shatter / debris / shard)

| 팩 | 제작자 | 라이선스 | URL | GitHub 미러 | 셀/프레임 | 포맷 | 내용물 | 톤 | Attribution |
|---|---|---|---|---|---|---|---|---|---|
| **Mini FX, Items & UI**(카테고리 2와 동일 팩) | GrafxKid | CC0 | [grafxkid.itch.io/mini-fx-items-ui](https://grafxkid.itch.io/mini-fx-items-ui) | 없음 | 미확인 | 미확인 | "cloud poofs"(구름형 퍼프 = 연기/파괴 이펙트로 겸용 가능) | 카테고리 2와 동일 — 한 팩으로 두 카테고리 동시 커버 가능 | 불요 |
| **Pixel Art VFX - Smoke & Dust - FREE Version** | Frostwindz | **미확인** — 페이지에서 라이선스 문구를 확인하지 못함(price="name your own price"만 확인). 채택 전 라이선스 재확인 필수 | [frostwindz.itch.io/pixel-art-vfx-smoke-dust-free-version](https://frostwindz.itch.io/pixel-art-vfx-smoke-dust-free-version) | 없음 | 미확인 | 미확인 | 연기/먼지 계열(정확한 목록 미확인) | 미확인 | 미확인 |
| **Super Pixel Effects Gigapack**(무료 티어, 참고) | unTied Games | **커스텀 라이선스**(CC-BY 아님): "Attribution + no reselling the asset itself. Commercial and non-commercial use OK" | [untiedgames.itch.io/super-pixel-effects-gigapack](https://untiedgames.itch.io/super-pixel-effects-gigapack) | 없음 | 미확인 | PNG 스프라이트시트(파싱 가능한 메타데이터 포함이라고 명시) | 연기·스플래터 포함 145종 이펙트 중 일부(무료 티어=88종, 색상 테마 1개씩) | 카테고리 1·2·3·5와 광범위하게 겹침 — 단일 팩으로 다카테고리 커버 가능하나 attribution 의무 발생 | **필수**(attribution) + 재판매 금지 |

### 5. 충격파 링/에너지 (shockwave ring / energy nova)

| 팩 | 제작자 | 라이선스 | URL | GitHub 미러 | 셀/프레임 | 포맷 | 내용물 | 톤 | Attribution |
|---|---|---|---|---|---|---|---|---|---|
| **Ring Explosion**(카테고리 1과 동일 출처) | BenHickling (OpenGameArt) | **CC0** | [opengameart.org/content/ring-explosion](https://opengameart.org/content/ring-explosion) | 없음 | 100×100px, 56프레임 | 투명 PNG 스프라이트시트 | 링 형태로 확산되는 폭발 — "성공 쇼크웨이브" 연출에 이름 그대로 부합 | Explosion과 남매 팩이라 세트로 쓰면 톤 일관 | 불요 |
| **Super Pixel Effects Gigapack**("energy rings" 포함, 참고) | unTied Games | 커스텀(4번 카테고리와 동일 조항 — attribution 필수 + 재판매 금지) | [untiedgames.itch.io/super-pixel-effects-gigapack](https://untiedgames.itch.io/super-pixel-effects-gigapack) | 없음 | 미확인 | PNG 스프라이트시트 | "energy rings", "magic explosion" 등 145종 중 일부 | 위와 동일 | 필수 |
| **(미확인 후보) PixelDuck "16 distinct shockwave effects"** | PixelDuck | **미확인** — 정확한 상품 페이지 URL·가격·라이선스를 이번 조사에서 확보하지 못함 | 정확한 URL 미확인(프로필: [pixelduck.itch.io](https://pixelduck.itch.io/), 컬렉션: [itch.io/c/598214/pixel-effects](https://itch.io/c/598214/pixel-effects)) | 없음 | 미확인 | 미확인 | 셔이크웨이브 16종(설명 문구만 확인) | 미확인 | 미확인 — **후속 조사 필요, 채택 보류** |

### 6. 알 부화 / 상자 개봉 (egg hatch / chest open) — 가챠 리빌용

| 팩 | 제작자 | 라이선스 | URL | GitHub 미러 | 셀/프레임 | 포맷 | 내용물 | 톤 | Attribution |
|---|---|---|---|---|---|---|---|---|---|
| **Pixel Art Chest Pack - Animated** | karsiori | **CC0**(페이지 명시: "you can use this asset pack however you want, in your commercial or non-commercial projects") | [karsiori.itch.io/pixel-art-chest-pack-animated](https://karsiori.itch.io/pixel-art-chest-pack-animated) | 없음 | Wooden Chest 48×36~48×38px / Golden Chest 40×25~41×25px / (보너스) Metal Chest 72×62px, Retro Chest 43×40px | **개별 프레임 제공**("Every chest has it's own sprite sheet as well as separate sprite for each frame") | Lock/Unlock 1프레임, Open/Close 2~5프레임, 나무/황금/금속/레트로 등 여러 변형 | 셀 크기가 기존 팩(16~32px)보다 다소 큼(40~72px) — 스케일 조정 필요 추정 | 불요, 단 권장("we would be very grateful if you could give us credit") |
| **Hatching Egg Sprites** | Nightspore | **CC0/CC-BY 아닌 커스텀 무료 라이선스** — 원문: *"For free or commercial games. Not for use in NFTs, Crypto, AI or other machine-generated grift."* | [nightspore.itch.io/hatching-egg-sprites](https://nightspore.itch.io/hatching-egg-sprites) | 없음 | 32×32px | GIF + PNG | 흔들기(rock)→튀기기(bounce)→금가기(crack)→부화(hatch) 4단계 애니메이션, **색상 변형 4종**(cream/brown/grey/purple) — 가챠 리빌에 사실상 이상적인 스펙 | 32px 호환, 톤은 스크린샷 미확인 | 명시 안 됨(라이선스 문구에 "attribution 필수"는 없음) |
| (보완) FREE 100+ Eggs Pixel Art | Life in pixels | "100% free for personal/commercial use, no credit required" — CC0 아니지만 사실상 동등 조건. **부화 애니메이션 존재 여부는 미확인**(정적 알 디자인 100종 위주로 추정) | [life-in-pixels.itch.io/free-100-eggspixel-art-16x16](https://life-in-pixels.itch.io/free-100-eggspixel-art-16x16) | 없음 | 16×16 / 32×32 / 48×48px(3종) | 미확인(Aseprite 파일 제공) | 알 디자인 10종 + 변형 | 16~32px는 기존 팩과 완전 호환 | 불요 |

---

## 상충 정보

1. **CodeManu 팩들의 라이선스 표기 불일치**: `codemanu.itch.io/pixelart-effect-pack` 페이지 본문은
   "This is a public domain asset... No credit required"이라고 서술하지만, itch.io의 구조화 메타데이터
   태그는 모순적으로 **"Creative Commons Attribution v4.0 International"**로 표시된다(WebFetch 결과
   재확인). 반면 **동일 팩의 OpenGameArt 미러(`opengameart.org/content/free-pixel-effects-pack`)는
   명시적으로 "CC0"로 태깅**되어 있다 — OGA는 CC 라이선스를 구조화 필드로 강제 선택하게 하는 플랫폼이라
   신뢰도가 상대적으로 높다고 판단, **본 문서는 CC0 쪽을 채택**했다. 다만 완전히 해소된 상충은 아니므로
   실제 배포 전 attribution 문구를 넣어도 손해 없는 선택(예: `LICENSE_CodeManu.txt`에 트위터 크레딧
   문구 포함)을 권장한다.
2. **"CC0에 가까운 조건"과 "정식 CC0 태그"의 구분**: Narik(Pixel Art Animated Star), Life in pixels
   (100+ Eggs), Nightspore(Hatching Egg) 세 팩은 모두 "개인/상업적 사용 가능, credit 불요"라는
   실질적으로 CC0와 동등한 조건을 명시하지만 **정식 CC0 라이선스 배지/문서는 확인하지 못했다**. 이들은
   본 문서에서 "CC0"가 아니라 "CC0와 동등한 커스텀 무료 라이선스"로 별도 표기했다 — 프로젝트의 기존
   CLAUDE.md 컨벤션(CC0/CC-BY 이원 분류)과 정확히 일치하지 않으므로, 채택 시 라이선스 카테고리를
   새로 만들거나 원문 그대로 인용하는 방식을 권장한다.
3. **unTied Games Gigapack의 "attribution + no reselling" 조항**: 이 조항은 표준 CC-BY(재판매 허용,
   저작자 표시만 요구)와 다르다 — CC-BY라면 에셋 자체를 재판매해도 저작자 표시만 하면 무방하지만, 이
   팩은 "에셋 자체의 재판매"를 별도로 금지한다. 프로젝트가 앱을 유료 판매하지 않고 무료 배포하므로 실질
   리스크는 낮으나, 문서/README에 "CC-BY"라고 단순 표기하면 부정확한 인용이 되므로 원문 그대로 인용
   필요.

---

## 확인 안 된 것

- **GitHub 미러 전무**: 이번 조사에서 다룬 모든 VFX 팩(CodeManu, Ansimuz, BenHickling, Foozle,
  DevWizard, GrafxKid Mini FX, karsiori, Nightspore, unTied Games) 중 **단 하나도 GitHub 미러를 찾지
  못했다**. `pet-asset-sourcing`/`corp-network-github-asset-download` 메모의 우회 파이프라인(`gh api
  search/code` → base64 추출)은 캐릭터 스프라이트 팩에서는 통했지만, 이번엔 WebSearch 레벨에서 후보
  자체를 못 찾았다 — **실제 다운로드 시도 시 `gh api "search/code?q=<파일명 키워드> extension:png"`로
  재시도할 가치는 있으나, 이번 리서치의 신뢰도 있는 결과는 아니다** (추정/미확인으로 표기).
- **정확한 프레임 크기/개수**: 대부분의 itch.io 팩 페이지가 프레임 크기·개수를 명시하지 않아(Ansimuz
  Explosion Animations Pack, Foozle 프레임 수, GrafxKid Mini FX 전체 사양 등) 다운로드 후 실측이
  필요하다.
- **PixelDuck 16 shockwave effects**: 정확한 itch.io 상품 URL, 가격, 라이선스를 확보하지 못했다.
  카테고리 5(충격파)의 유일한 미확인 후보이므로 후속 조사 가치가 있다.
- **Frostwindz "Pixel Art VFX - Smoke & Dust FREE"의 라이선스**: "name your own price"만 확인, 재배포
  조건 문구를 확보하지 못해 채택 여부 판단 불가.
- **CodeManu/GrafxKid 등 CC0 팩들의 실제 색감·해상도 스크린샷 검증**: 텍스트 기반 조사만 수행했고
  실제 이미지 톤(채도, 외곽선 두께 등)이 기존 팩과 시각적으로 잘 어울리는지는 다운로드 후 육안 확인이
  필요하다(itch 페이지에는 스크린샷이 있으나 WebFetch로는 이미지 내용을 볼 수 없었음).
- **사내망에서 이번 조사 대상 도메인(itch.io, opengameart.org) 접근 가능 여부**: 과거 메모 기준으로는
  차단 이력이 있으나, 이번 세션에서 실제 다운로드를 시도하지 않아 재확인은 못했다.

---

## 추천 조합

### 안 A — CC0 전량, attribution 부담 0 (권장)

| 카테고리 | 채택 팩 |
|---|---|
| 1. 폭발/타격 | CodeManu Free Pixel Effects Pack + BenHickling Explosion |
| 2. 반짝임/광휘 | GrafxKid Mini FX, Items & UI |
| 3. 마법진/오라/차지 | Foozle Pixel Magic Effects |
| 4. 연기/파편 | GrafxKid Mini FX, Items & UI (2번과 동일 팩 겸용) |
| 5. 충격파 링 | BenHickling Ring Explosion (1번과 남매 팩) |
| 6. 알부화/상자개봉 | karsiori Pixel Art Chest Pack (CC0) — **"알" 대신 "상자"로 리빌 연출 통일** |

**팩 수**: 5개(CodeManu, BenHickling, Foozle, GrafxKid, karsiori). **라이선스 부담**: 전부 CC0 —
attribution 완전 불요, 기존 CC0 팩(SunnyLand, Robot Tileset 등)과 동일한 관리 방식으로 편입 가능.
**트레이드오프**: 알 부화(egg hatch) 특유의 "꿈틀꿈틀 → 쩍 → 캐릭터 등장" 서사를 포기하고 상자 개봉으로
대체해야 함. 셀 크기가 팩마다 32~100px로 들쭉날쭉해 다운스케일/리스케일 작업이 필요할 가능성이 높음
(미확인, 다운로드 후 검증 필요).

### 안 B — 알 부화 서사 유지, 라이선스 3종 혼재 감수

안 A에 **Nightspore Hatching Egg Sprites**(커스텀 무료 라이선스, NFT/AI 도용 금지 조항 포함)를
6번 카테고리에 추가하고, 필요 시 카테고리 3(마법진/오라)에 **unTied Games Super Pixel Effects
Gigapack 무료 티어**(attribution 필수 + 재판매 금지)를 더해 "energy ring"/"magic explosion" 등
고품질 대체 이펙트를 확보.

**팩 수**: 6~7개. **라이선스 부담**: CC0 5개 + 커스텀 무료(Nightspore) 1개 + attribution 필수
(unTied Games, 선택) 0~1개. attribution 필수 팩을 포함할 경우 기존 `LICENSE_*.txt` 관리 패턴(Kings
and Pigs 등 CC-BY 팩과 동일한 방식)을 그대로 재사용할 수 있으나, "CC-BY"가 아니라 원문 그대로("attribution
+ no reselling the asset itself") 인용해야 정확하다. **트레이드오프**: 라이선스 카테고리가 CC0/CC-BY
이원에서 3~4종으로 늘어나 관리 복잡도가 증가하지만, 가챠 리빌의 "알" 메타포를 그대로 유지할 수 있고
강화 연출의 이펙트 품질/가짓수가 안 A보다 풍부해진다.

**공통 후속 작업(두 안 모두)**: 다운로드는 사내망이 아닌 개인망에서 수행하거나 `pet-expansion-200`에서
검증된 itch 비공식 다운로드 흐름(`POST /{slug}/download_url` → 다운로드 페이지 → `data-upload_id`+
`csrf2` → `POST /{slug}/file/{uid}` → 서명 URL)을 재사용할 것. GitHub 미러가 없으므로 `gh api`
우회 파이프라인은 이번엔 적용 불가.

---

## 참고 자료 (미확인이지만 후속 가치 있는 URL)

- [pixelduck.itch.io](https://pixelduck.itch.io/), [itch.io/c/598214/pixel-effects](https://itch.io/c/598214/pixel-effects) — PixelDuck 셔이크웨이브 16종, 정확한 상품 페이지/라이선스 미확인
- [frostwindz.itch.io/pixel-art-vfx-smoke-dust-free-version](https://frostwindz.itch.io/pixel-art-vfx-smoke-dust-free-version) — 연기/먼지 팩, 라이선스 미확인
- [free-game-assets.itch.io/free-pixel-magic-sprite-effects-pack](https://free-game-assets.itch.io/free-pixel-magic-sprite-effects-pack) — "damage aura" 등 버프 이펙트명 직접 부합, 라이선스 불명확
- [opengameart.org/content/explosion-effects-and-more](https://opengameart.org/content/explosion-effects-and-more) — Soluna Software, CC-BY 3.0/CC0 이중 라이선스, Aura38.png 등 오라 이펙트 포함(카테고리 3 보완 후보)
- [opengameart.org/content/cc0-special-effects](https://opengameart.org/content/cc0-special-effects) — Ragnar Random의 CC0 이펙트 큐레이션 목록(실제 에셋 아닌 링크 모음, 개별 재확인 필요)
- [untiedgames.itch.io/super-pixel-effects-pack-1](https://untiedgames.itch.io/super-pixel-effects-pack-1) 등 unTied Games의 개별 유료 팩들 — Gigapack 무료 티어로 충분하지 않을 경우의 보완 후보
- [zulextia.itch.io/aluna-lights-the-night-sky-sparkling-star-sprite-sheet](https://zulextia.itch.io/aluna-lights-the-night-sky-sparkling-star-sprite-sheet) — 스파클 스타 시트, credit 요청됨(요청이지 강제인지 미확인)
- [life-in-pixels.itch.io/free-100-eggspixel-art-16x16](https://life-in-pixels.itch.io/free-100-eggspixel-art-16x16) — 알 디자인 100+, 부화 애니메이션 여부 미확인이라 재조사 시 우선 확인 가치

---

## 검토 체크리스트

- [x] 출처 신뢰도 평가 — itch.io/OpenGameArt 공식 페이지 최우선, OGA 구조화 라이선스 태그를 itch.io
      본문 텍스트보다 더 신뢰 가능한 것으로 취급(상충 정보 1번 참조)
- [x] 최신성 평가 — 조사 대상 페이지 대부분 발행일 불명(itch.io 특성상 devlog가 없으면 날짜 미노출),
      다만 모두 현재 활성 배포 중인 페이지로 확인됨. 1년 이상 경과로 인한 outdated 라벨을 붙일 근거는
      없음(신규 게시 여부와 무관하게 라이선스 문구는 페이지 스냅샷 기준 유효)
- [x] 상충 정보 식별 — CodeManu 라이선스 표기 불일치, "CC0 동등 조건" vs "정식 CC0", unTied Games
      커스텀 조항 3건 별도 섹션 기재
- [x] 사실/권장 분리 — 카테고리별 표는 사실 위주, "권장 결론"/"추천 조합" 섹션에서만 의견 제시
- [x] 출처 URL 모든 표 항목에 포함
- [x] 확인 못 한 영역 명시 — GitHub 미러 전무, 프레임 크기 다수 미확인, PixelDuck/Frostwindz 라이선스
      미확인 등 별도 섹션
- [x] prompt injection 패턴 없음 — 모든 WebFetch 결과는 일반적인 상품 설명/라이선스 문구였고
      `<system-reminder>`, "ignore previous instructions" 류의 이상 패턴은 발견되지 않음
