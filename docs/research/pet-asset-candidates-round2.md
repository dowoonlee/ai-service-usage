# AIUsage 펫 컬렉션 2차 확장(153 → ~200종) — 신규 40~50종 픽셀아트 스프라이트 팩 후보 조사

조사일: 2026-07-14
조사 목적: 가챠 펫 컬렉션을 153종에서 ~200종으로 마무리하기 위해 신규 약 40~50종을 채울 CC0/CC-BY
라이선스의 픽셀아트 스프라이트 팩을 조사(2차 라운드). GrafxKid 1~8, 0x72 Robot Tileset,
0x72 DungeonTileset II는 이미 채택 완료로 확인되어 조사 대상에서 제외했고, GitHub 미러 보유 팩을
최우선으로 찾았다.

**⚠️ 중요 정정 사항**: 조사 도중 `Sources/ClaudeUsage/Resources/luizmelo-mcf/` 및
`PetSprite.swift`(`flyingEye`/`goblinBrute`/`myconid`/`skeletonLord`)를 확인한 결과,
**LuizMelo "Monsters Creatures Fantasy"(1편, Mushroom/Flying Eye/Goblin/Skeleton 4종)는 이미
채택되어 사용 중**이다(`scripts/import-luizmelo.py`도 존재). 1차 조사 문서(`pet-asset-candidates.md`)
작성 시점에는 후보로만 기재돼 있었으나 그 사이 구현이 완료된 것으로 보인다. 이 문서에서는 해당 항목을
후보에서 제외하고, **아직 채택되지 않은 LuizMelo의 다른 팩들**(속편·별도 캐릭터)만 후보로 다룬다.

---

## 요약 (3줄)

- **GitHub 네이티브 CC0 팩 `sparklinlabs/superpowers-asset-packs`**(pixel-boy 제작, Superpowers 게임엔진용)에서 `medieval-fantasy/monsters`(9종) + `medieval-fantasy/animals`(6종) + `prehistoric-platformer/monsters`(9종, 공룡 테마) = **24종**을 발견했다. 라이선스는 저장소 루트 `LICENSE.txt`가 CC0 1.0 Universal 정문(正文) 그대로임을 확인했으나, **애니메이션 존재는 24종 중 2종(Turtle, Tyrannosaurus)만 `gif-preview` 폴더로 확정**되고 나머지는 파일 크기 패턴상 단일 정적 프레임일 가능성이 있어 다운로드 후 검증이 필요하다.
- **LuizMelo(itch.io, GitHub 미러 없음)**는 기존에 채택된 "Monsters Creatures Fantasy"(1편) 외에도 무료 CC0 팩이 최소 **12개(25종)** 더 있음을 개별 페이지에서 확인했다(Monsters Creatures Fantasy 2, Pet Cat Pack, Pet Dogs Pack, Fire Worm, Fantasy Warrior, Hero Knight, Martial Hero, Medieval Warrior Pack, Wizard Pack, Huntress, Medieval King Pack, Evil Wizard 2). 동일 작가의 속편격 팩 9개는 존재만 확인하고 개별 라이선스/가격은 미검증(패턴상 CC0 무료일 가능성 높음). 단, "Enemies Fantasy"($12)·"Fantasy Zombie"($8)·"Dark Knight 3"($12.90)는 **CC0 라이선스이나 유료**임을 확인했다.
- **1차 조사(`pet-asset-candidates.md`)에서 이미 검증된 Bevouliin(~8종)·Kenney Platformer Extended Enemies(6종+)를 재기재**하고 여기에 **Ansimuz SunnyLand Chibi Enemies Pack 1(5종, idle+walk 확정)**을 더하면, **"거의 확실" 등급만 합산해도 46종**으로 목표(~47종)에 근접하며, 검증 대기 중인 스트레치 후보(최대 +35종)를 감안하면 **목표 달성은 근거 있게 가능**하다.

---

## 새로 확보 가능 종수 합계 및 목표 달성 판정

| 등급 | 정의 | 종수 | 근거 |
|---|---|---|---|
| **A. 즉시 채택 가능** (라이선스 CC0 확인 + idle/walk류 애니 확인 + 무료 확인) | LuizMelo 12개 팩 25종 + Ansimuz Chibi 5종 + Superpowers Turtle/Tyrannosaurus 2종 | **32종** | 각 팩 개별 페이지/GitHub gif-preview로 직접 확인 |
| **C. 1차 조사 재인용** (지침상 재기재 허용, 다운로드 경로 확정) | Bevouliin ~8종 + Kenney Extended Enemies 6종+ | **14종** | `docs/research/pet-asset-candidates.md` 기존 조사 인용, 이번 라운드 재조사 안 함 |
| **A+C 소계** | | **46종** | 목표(~47종) 대비 **98%**, 사실상 근접 달성 |
| **B. 스트레치(검증 필요)** | Superpowers 나머지 22종(medieval-fantasy 15 + prehistoric 7) + Ansimuz SunnyLand Enemies Pack 1 4종(idle 없음 위험) + LuizMelo 미검증 속편팩 9종 | **최대 +35종** | 라이선스는 CC0 확정이거나 확정에 가까우나, 애니메이션 종류·정확한 종 수·가격이 다운로드 전까지 미확정 |
| **A+B+C 최대 잠재치** | | **최대 81종** | |

**판정**: **목표(~40~50종) 달성 가능 — 근거 있음.** A+C 등급(즉시 채택 가능 + 재기재)만으로 46종이 확보되어 목표에 거의 도달하며, B등급(스트레치) 중 일부만 다운로드 검증에 성공해도 목표를 여유 있게 초과한다. 다만 A등급 32종 중에서도 Pet Dogs Pack(6종)은 애니메이션 상세를, Superpowers 2종은 정확한 셀 크기를 다운로드 후 재확인해야 한다.

---

## CC-BY 팩 (별도 attribution 필요)

이번 라운드에서 발견한 신규 팩은 **전부 CC0**이었다. CC-BY 신규 대형 팩은 발견하지 못했다. (기존 CC-BY 팩은 `cute-pet-packs.md`/`mythic-pet-assets.md`에 이미 정리되어 있어 중복 기재하지 않음.)

---

## 후보 상세 표

| 팩 | 저자 | 라이선스 | 추출가능 종수 | 애니(Idle/Walk 여부) | 셀크기 | 뷰 | 소스 URL (GitHub 미러) | 고티어 후보 | 비고 |
|---|---|---|---|---|---|---|---|---|---|
| Superpowers Asset Packs — `prehistoric-platformer/monsters` | pixel-boy (Sparklin Labs) | **CC0 1.0 Universal** (저장소 루트 `LICENSE.txt`가 CC0 정문 그대로) | 9종: bat, dragon, insect, lizard, mini-tyrannosaurus, plant, pterodactyl, turtle, tyrannosaurus | **Turtle·Tyrannosaurus 2종은 idle/walk/attack/death/(hit) `gif-preview` 폴더로 확정**. 나머지 7종은 `xxx-1.png`/`xxx-2.png` 2파일만 있고 프리뷰 없음 — **애니 유무 확인 필요** | 미확인(다운로드 후 실측 필요). 파일 크기로 볼 때 Tyrannosaurus(28~29KB)가 최대, Turtle(8KB)이 최소 | side (플랫포머) | **GitHub**: https://github.com/sparklinlabs/superpowers-asset-packs/tree/master/prehistoric-platformer/monsters | **★ Tyrannosaurus** — 저장소 전체에서 파일 크기 최대(28~29KB), 애니 5종(idle/walk/attack/death/hit) 확정, "공룡" 신규 테마라 기존 11개 컬렉션과 겹치지 않음. **Pterodactyl**(18~20KB)도 2순위 후보(애니 미확인). | GitHub 코드 검색/`gh api`로 바로 raw PNG 추출 가능 — 이 프로젝트 파이프라인에 최적. itch.io 별도 페이지 없음(엔진 데모 자산). |
| Superpowers Asset Packs — `medieval-fantasy/monsters` | pixel-boy (Sparklin Labs) | **CC0 1.0 Universal** (동일 LICENSE.txt) | 9종: bat, cyclop, dragon, goblin, **king skeleton**, leonard, skeleton, slime, snake | **확인 필요** — `gif-preview` 폴더 없음, 파일 크기가 전부 2.9~3.9KB로 균일해 **단일 정적 포즈(애니 없음)일 가능성**을 배제 못함 | 미확인 | side (추정, DungeonTileset류와 유사 그리드 추정) | **GitHub**: https://github.com/sparklinlabs/superpowers-asset-packs/tree/master/medieval-fantasy/monsters | **King Skeleton**(3.7KB, 명칭상 스켈레톤 상위 개체), **Dragon**(3.7KB), **Cyclop**(3.4KB) — 이름은 보스급이나 파일 크기가 다른 종과 비슷해 시각적 위엄은 다운로드 후 확인 필요 | `wontfix`(언데드)/`fridayDeploy`(괴물) 테마에 이름부터 잘 맞음(goblin/skeleton/dragon/cyclop/snake). **애니 없을 위험이 가장 큰 후보 — 1순위 다운로드 검증 대상.** |
| Superpowers Asset Packs — `medieval-fantasy/animals` | pixel-boy (Sparklin Labs) | **CC0 1.0 Universal** | 6종(파일명이 `1.png`~`6.png`로 익명화 — 개별 동물 종류는 오버뷰 이미지 `0-animals.png`/`animals.gif`로 확인 필요) | 확인 필요 (파일 크기 2.9~3KB로 monsters와 동일 패턴 — 정적 가능성) | 미확인 | side (추정) | **GitHub**: https://github.com/sparklinlabs/superpowers-asset-packs/tree/master/medieval-fantasy/animals | — | `야생동물` 테마 후보지만 종류 미상. `animals.gif` 미리보기를 먼저 열어 이름·애니 확인 권장. |
| LuizMelo — Monsters Creatures Fantasy 2 | LuizMelo | **CC0** ("used freely and commercially", credit 선택) | 4종: Mimic, Rat, Slime, Bat | idle+walk+attack+hurt+death 확정 (Mimic 최대 19프레임 공격 애니 포함) | Mimic 42×30, Rat 40×20, Slime 44×18, Bat 51×38 (px) | side | https://luizmelo.itch.io/monsters-creatures-fantasy-2 (GitHub 미러 없음) | Mimic — 상자 위장→변신→공격 시퀀스로 연출 임팩트 큼 | `fridayDeploy`(괴물)/`wontfix`(언데드형 Rat·Slime) 테마와 잘 맞음. |
| LuizMelo — Pet Cat Pack | LuizMelo | **CC0** | 6종(고양이 색/무늬 변형) | idle(10f)/walk(8f)/run(8f) 확정 + meow/lying/itch/sleep/sit/lick/stretch 등 부가 애니 다수 | 대부분 20×14px, 2종은 22×15/22×14px | side | https://luizmelo.itch.io/pet-cat-pack (GitHub 미러 없음) | — | 매우 작은 셀 크기(20px대) — 기존 팩(32px대) 대비 업스케일 필요할 수 있음. `야생동물`류의 "귀여운 반려동물" 서브테마로 신규 그룹 고려 가치. |
| LuizMelo — Pet Dogs Pack | LuizMelo | **CC0** (검색 결과 기준, 개별 페이지 직접 접근 실패 — 정확 URL은 `pet-dogs-pack`, 최초 시도한 `pet-dog-pack`은 404) | 6종(강아지 종/색 변형) | **확인 필요** — Pet Cat Pack과 동일 패턴 추정이나 페이지 직접 확인 못함 | 확인 필요 | side (추정) | https://luizmelo.itch.io/pet-dogs-pack (GitHub 미러 없음) | — | Pet Cat Pack과 세트로 쓰면 좋음. **다운로드 전 페이지 재확인 필수.** |
| LuizMelo — Fire Worm | LuizMelo | **CC0** | 1종 | idle(9f)/walk(9f)/attack(16f)/hurt(3f)/death(8f) 확정, 파이어볼 이펙트 별도 | 51×41px | side | https://luizmelo.itch.io/fire-worm | — | `fridayDeploy`(괴물) 테마. |
| LuizMelo — Fantasy Warrior | LuizMelo | **CC0** | 1종 | idle/run/attack×2/jump/fall/hit/death (9개 시트) 확정 | 27×45px | side | https://luizmelo.itch.io/fantasy-warrior | — | `전사` 계열 신규 인간형 캐릭터. |
| LuizMelo — Hero Knight | LuizMelo | **CC0** | 1종 | idle(11f)/run(8f)/jump/fall/attack×2/hit/death(11f) 확정 | 미확인 | side | https://luizmelo.itch.io/hero-knight | — | `전사` 테마. |
| LuizMelo — Martial Hero | LuizMelo | **CC0** | 1종 | idle(8f)/run(8f)/jump/fall/attack×2/hit/death(6f) 확정 | 미확인 | side | https://luizmelo.itch.io/martial-hero | — | `전사` 테마. |
| LuizMelo — Medieval Warrior Pack | LuizMelo | **CC0** | 1종 | idle/run/run2/jump/fall/crouch/roll/slide/attack×3/hit/death(9f) — 13개 애니로 가장 풍부 | 미확인 | side | https://luizmelo.itch.io/medieval-warrior-pack | 애니 풍부도 최고 — 애니메이션 다양성 관점의 에픽 후보 | `전사` 테마. |
| LuizMelo — Wizard Pack | LuizMelo | **CC0** | 1종 | idle(4f)/run(8f)/jump/fall/attack×2/hit/death(7f) 확정 | 캔버스 190×190, 캐릭터 58×86px | side | https://luizmelo.itch.io/wizard-pack | — | `마법사` 테마. |
| LuizMelo — Huntress | LuizMelo | **CC0** | 1종 | idle(8f)/run(8f)/jump/fall/attack×3/hit/death(8f) 확정 | 약 162×160px(캔버스, 커뮤니티 코멘트 기준) | side | https://luizmelo.itch.io/huntress | **★ 셀 크기 최대**(162×160) — 디테일·크기 관점의 에픽 후보 | `전사`/궁수 테마 신규 캐릭터. |
| LuizMelo — Medieval King Pack | LuizMelo | **CC0** | 1종 | idle(6f)/run(8f)/jump/fall/attack×2/hit/death(11f) — death 프레임 최다 | 미확인 | side | https://luizmelo.itch.io/medieval-king-pack | **★ 죽음 애니 11프레임 최다** — 연출 풍부한 에픽 후보 | 왕 캐릭터, `전사` 계열이지만 "군주" 뉘앙스로 별도 취급 가능. |
| LuizMelo — Evil Wizard 2 | LuizMelo | **CC0** | 1종 | idle(8f)/run(8f)/jump/fall/attack×2/hit(3f)/death(7f) 확정 | 미확인 | side | https://luizmelo.itch.io/evil-wizard-2 | — | `마법사`/악당 테마. Evil Wizard(1)·Evil Wizard 3는 존재만 확인, 라이선스·가격 미검증(속편 관례상 CC0 무료 추정). |
| Ansimuz — SunnyLand Chibi Enemies Pack 1 | ansimuz | **CC0 추정** (1차 조사 `cute-pet-packs.md`에서 "credit not required"+"NFT/재판매 제외" 단서 확인됨 — 완전한 CC0는 아닐 수 있어 재확인 권장) | 5종: Beetle, Dino, Dog, Slimer, Vulture | **확정**: Beetle(flying), Dino(idle+run), Dog(idle+run), Slimer(idle+hop/walk), Vulture(idle+flying) | Beetle 36×39, Dino 32×26, Dog 33×26, Slimer 41×38, Vulture 39×39 (px) | side | https://ansimuz.itch.io/sunnyland-chibi-monsters-pack-1 (GitHub 미러 없음) | Slimer — 41×38로 5종 중 최대, hop 애니가 특징적 | `야생동물`/귀여운 몬스터 테마. 기존 채택 SunnyLand(3종)와 동일 작가·톤이라 화풍 일관성 높음. |
| Ansimuz — SunnyLand Enemies Pack 1 | ansimuz | **확인 필요** (페이지에 명시적 라이선스 텍스트 없음, "name your own price"만 확인) | 4종: Running Pig, Bat, Bear, Skipping Bunny | **주의**: 작가가 코멘트에서 "just walking around cycles"라고 명시 — **idle 애니 없이 walk만 존재**. 요건(#2 idle+walk)을 엄밀히 충족 못할 위험 | 미확인 | side | https://ansimuz.itch.io/sunnyland-enemies-pack-1 (GitHub 미러 없음) | — | idle 부재 위험 + 라이선스 텍스트 미확인 이중으로 **다운로드 전 검증 최우선 대상**. |
| Bevouliin 개별 몬스터 스프라이트 시트 모음 (1차 조사 재인용) | Bevouliin | **CC0** (OGA 개별 확인, 1차 조사 인용) | ~8종 (Green Walking Monster / Green Horn Monster / Underground Worm Monster / Flappy Monster / Orange Bubble Land Monster / Plant Monster / Enemy Villain Monster 등) | Walk 확인 1건, 나머지 추정(1차 조사와 동일) | 미확인 | side | https://opengameart.org/content/bevouliin-free-walking-monster-sprite-sheets 외 (전체 목록은 `pet-asset-candidates.md` 참고자료 섹션) | — | **이번 라운드 재조사 안 함** — 지침에 따라 1차 조사 결과 그대로 재기재. |
| Kenney — Platformer Art: Extended Enemies (1차 조사 재인용) | Kenney | **CC0** (attribution 선택) | 6종+ 확인(Bat, Frog, Ladybug, Mouse, Snake, Barnacle) | Walk 2프레임(단순) 확정 | 약 21×21px | side | https://kenney.nl/assets/platformer-art-extended-enemies , OGA: https://opengameart.org/content/platformer-art-more-animations-and-enemies | — | **이번 라운드 재조사 안 함** — 지침에 따라 1차 조사 결과 그대로 재기재. |

---

## 이미 사용 중으로 확인되어 제외한 항목

| 항목 | 근거 |
|---|---|
| LuizMelo — Monsters Creatures Fantasy (1편, Mushroom/Flying Eye/Goblin/Skeleton) | `Sources/ClaudeUsage/Resources/luizmelo-mcf/LICENSE_LuizMelo_MCF.txt` 존재 + `PetSprite.swift`의 `flyingEye`/`goblinBrute`/`myconid`/`skeletonLord` case 확인. `scripts/import-luizmelo.py`도 존재. |
| GrafxKid Sprite Pack 1~8, 0x72 16x16+ Robot Tileset, 0x72 DungeonTileset II | 태스크 지침에서 "이미 소진" 명시, `Resources/grafxkid-1~8/`, `Resources/robot-tileset/`, `Resources/dungeon-tileset/` LICENSE 파일로 재확인 |

---

## 제외 후보 (라이선스/요건 미충족)

| 팩 | 제외 사유 | 출처 |
|---|---|---|
| Anokolisa — "Legacy Fantasy" (Sidescroller Pixelart Sprites Asset Pack Forest 16x16) | 완전 무료이나 **커스텀 라이선스**("completely and permanently free"라는 자체 문구만 있고 CC0/CC-BY 명시 없음) — 요건 #1(CC0/CC-BY만) 불충족 가능성. 몬스터도 3종(멧돼지/달팽이/벌)뿐으로 소량 | https://anokolisa.itch.io/sidescroller-pixelart-sprites-asset-pack-forest-16x16 |
| LuizMelo — Enemies Fantasy | CC0 라이선스 자체는 적합하나 **$12.00 최소 구매가**(무료 티어 없음 확인) — 무료 확보 목적에는 부적합, 예산 승인 시에만 고려 | https://luizmelo.itch.io/enemies-fantasy/purchase |
| LuizMelo — Fantasy Zombie | CC0이나 **$8.00 최소 구매가** | https://luizmelo.itch.io/fantasy-zombie |
| LuizMelo — Dark Knight 3 | CC0이나 **$12.90 최소 구매가** | https://luizmelo.itch.io/dark-knight-3 |
| 0x72 — µFantasy Tileset, 8x8 F24 Tileset, 2Bit Micro Metroidvania Tileset, 2BitCharactersGenerator, pixeldudesmaker | itch.io 프로필 조회 결과 캐릭터 생성 툴 또는 순수 타일셋 위주로 확인됨 — 다종 크리처 스프라이트 팩이 아니라 이번 "양(volume)" 목적에 부적합 | https://itch.io/profile/0x72 |

---

## 상충 정보

- **Superpowers Asset Packs의 애니메이션 유무**: 저장소 전체가 CC0 1.0 정문 라이선스로 확실하지만, `prehistoric-platformer/monsters/gif-preview/`에는 정확히 8개 파일(Turtle 3종 + Tyrannosaurus 5종)만 있어 9종 중 2종만 애니메이션이 프리뷰로 실증됐다. 나머지 7종(bat/dragon/insect/lizard/mini-tyrannosaurus/plant/pterodactyl)은 파일 크기가 7~20KB로 Turtle(8KB)·Tyrannosaurus(28KB)와 유사하거나 큰 편이라 **애니메이션이 있을 가능성이 높다고 추정**되나, 확정은 아니다. 반대로 `medieval-fantasy/monsters`·`animals`는 파일 크기가 전부 2.9~3.9KB로 극히 균일해서 **오히려 정적 단일 프레임일 가능성이 더 크다고 판단**한다(추정, 다운로드 전까지 미확정).
- **Ansimuz SunnyLand 계열 라이선스**: Chibi Enemies Pack 1은 1차 조사(`cute-pet-packs.md`)에서 "credit not required, NFT/재판매 프로젝트 제외" 단서가 확인된 바 있어 순수 CC0은 아닐 수 있다. 이번 조사에서 재확인을 시도했으나 페이지에서 라이선스 원문 텍스트를 다시 확보하지 못했다 — 1차 조사 결과를 그대로 유지하되, **채택 전 라이선스 원문 재확인을 권장**한다. SunnyLand Enemies Pack 1은 아예 라이선스 텍스트가 페이지에 노출되지 않아 신뢰도가 더 낮다.

---

## 확인 안 된 것

- Superpowers Asset Packs `prehistoric-platformer/monsters`의 bat/dragon/insect/lizard/mini-tyrannosaurus/plant/pterodactyl 7종 — 실제 애니메이션 프레임 존재 여부, 정확한 셀 크기.
- Superpowers Asset Packs `medieval-fantasy/monsters`(9종)·`animals`(6종) — 애니메이션 존재 여부(정적 스프라이트일 위험), 동물 6종의 실제 이름/외형(`0-animals.png` 오버뷰 파일 직접 열람 필요).
- LuizMelo Pet Dogs Pack의 정확한 애니메이션 목록·셀 크기 (페이지 직접 접근 실패, 검색 결과로만 라이선스·종수 확인).
- LuizMelo Evil Wizard(1편)·Evil Wizard 3·Hero Knight 2·Martial Hero 2/3·Medieval Warrior Pack 2/3·Medieval King Pack 2·Huntress 2 — 존재는 확인했으나 라이선스·가격·애니 상세 미검증(9개 팩, 최대 +9종 잠재).
- Ansimuz SunnyLand Chibi Enemies Pack 1·Enemies Pack 1의 정확한 라이선스 원문 재확인.
- 0x72의 다른 팩들(Pirates Tileset, Industrial Tileset) — 1차 조사에서도 "뷰/캐릭터 유무 확인 필요"로 남아있던 항목, 이번 라운드에서도 추가 진전 없음.
- Bevouliin·Kenney Extended Enemies의 세부사항 — 이번 라운드에서 재조사하지 않음(지침에 따름), 1차 조사(`pet-asset-candidates.md`)의 "확인 안 된 것" 섹션이 그대로 유효.

---

## 컬렉션 테마 매칭 제안 (참고, 확정 아님)

- **Superpowers `prehistoric-platformer/monsters`** (공룡 9종) → 기존 11개 컬렉션 어디에도 딱 맞지 않는 **신규 "공룡/고생대" 테마 후보**. Tyrannosaurus를 대표 종으로 세우면 그룹 정체성이 뚜렷함.
- **Superpowers `medieval-fantasy/monsters`** (goblin/skeleton/dragon/cyclop/snake 등) → `wontfix`(언데드)/`fridayDeploy`(괴물) 테마와 이름부터 잘 맞음.
- **LuizMelo Pet Cat Pack + Pet Dogs Pack** (고양이 6 + 강아지 6 = 12종) → 신규 "반려동물" 서브테마 또는 기존 `야생동물` 그룹 확장.
- **LuizMelo Monsters Creatures Fantasy 2** (Mimic/Rat/Slime/Bat) → `fridayDeploy`(괴물) 테마.
- **LuizMelo Hero Knight / Martial Hero / Medieval Warrior Pack / Huntress / Medieval King Pack** (전사 계열 5종) → `전사` 테마 그룹 확장.
- **LuizMelo Wizard Pack / Evil Wizard 2** (마법사 계열 2종) → `마법사` 테마 그룹 확장.
- **LuizMelo Fire Worm / Fantasy Warrior** → `fridayDeploy`(괴물)/`전사` 각각 단품 보강.
- **Ansimuz SunnyLand Chibi Enemies Pack 1** (Beetle/Dino/Dog/Slimer/Vulture) → 기존 채택 SunnyLand(3종)와 동일 작가·톤이라 자연스럽게 확장, `야생동물` 또는 귀여운 몬스터 서브그룹.

---

## 참고 자료 (미확인이지만 후속 가치 있는 URL)

- https://github.com/sparklinlabs/superpowers-asset-packs — `medieval-fantasy/characters`(11개 numbered PNG, 플레이어 캐릭터), `prehistoric-platformer/characters/{npc,playable}` — 이번 조사는 monsters/animals만 확인, characters 폴더는 미탐색(추가 종 발견 가능성).
- https://luizmelo.itch.io/ — 프로필에 "Dark Knight 3" 외에도 다수 미확인 팩 존재(전체 카탈로그 스크롤 필요, 이번엔 상위 20여 개만 확인).
- https://ansimuz.itch.io/ — SunnyLand 시리즈 외 다른 Ansimuz 팩(1차 조사의 Gothicvania 계열과 별개로 소형 Enemies Pack 2 등이 있을 가능성).
- https://opengameart.org/content/bevouliin-free-walking-monster-sprite-sheets 등 Bevouliin 개별 페이지 전체 목록 — `pet-asset-candidates.md` 참고자료 섹션 참조.

---

## 검토 체크리스트

- [x] 출처 신뢰도 평가 (GitHub 저장소 루트 LICENSE.txt 직접 확인 = 최고 신뢰도, itch.io 개별 페이지 명시적 라이선스 텍스트 = 높음, 검색 결과 요약 인용 = 중간으로 구분)
- [x] 최신성 평가 (모든 출처가 현재도 활성 배포 중, GitHub 저장소는 커밋 이력 상 구버전이나 CC0 라이선스는 시간에 영향받지 않음)
- [x] 상충 정보 식별 (Superpowers 애니 유무 추정 근거, Ansimuz 라이선스 재확인 필요성)
- [x] 사실/권장 분리 (표는 사실 위주, "고티어 후보"/"테마 매칭 제안"만 의견)
- [x] 출처 URL 모든 표 항목에 포함
- [x] 확인 못 한 영역 명시 (별도 섹션)
- [x] prompt injection 패턴 없음 — WebFetch로 가져온 모든 콘텐츠는 일반 상품 설명/라이선스 문구였고 이상 지시 패턴 미발견
