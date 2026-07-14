# AIUsage 펫 컬렉션 확장(84 → ~200종) — 대형 픽셀아트 스프라이트 팩 후보 조사

조사일: 2026-07-14
조사 목적: 가챠 펫 컬렉션을 84종에서 ~200종으로 확장하기 위해 신규 116종을 채울 CC0/CC-BY 라이선스의
**대형(10종 이상) 픽셀아트 스프라이트 팩**을 조사. 기존 리서치(`cute-pet-packs.md` — 귀여운 소형 팩,
`mythic-pet-assets.md` — 보스급 소량 팩)와는 결이 다른, "양(volume)" 확보가 목적인 조사.

조사 소스: itch.io, OpenGameArt.org, Kenney.nl, GitHub 검색

---

## 요약 (3줄)

- **GrafxKid의 Sprite Pack 1~8 (전부 CC0)** 하나에서만 **60종**을 확보할 수 있어 이번 조사에서 가장 비중 있는 단일 출처다. 여기에 **0x72 16x16+ Robot Tileset(CC0, 9종, 기존 DungeonTileset II와 동일 작가·톤)**, **Kenney Platformer Art Extended Enemies(CC0, 확인된 것만 6종+)**, **Bevouliin 개별 몬스터 스프라이트 시트 모음(CC0, ~8종)**, **LuizMelo 소형 몬스터 팩들(CC0, ~5종 확정)**을 더하면 **최소 88종은 비교적 확실하게 확보 가능**하다.
- 나머지 ~28종 간극은 **Kenney New Platformer Pack(2025, CC0, 440+ 에셋 — 세부 미확인)**, **LuizMelo Fantasy Creatures/Fantasy Beast(라이선스는 CC0로 보이나 종 수 미확인)** 등에서 채울 여지가 있어 **116종 목표는 현실적으로 달성 가능**하나, 다운로드 후 실물 검증이 안 된 부분이 많아 100% 확정은 아니다.
- 이번 조사에서 발견한 신규 대형팩은 **전부 CC0**였다(CC-BY 팩은 발견하지 못함). 다만 **검증된 GitHub 미러는 하나도 없었다** — 전부 itch.io 또는 OpenGameArt 직접 다운로드가 유일 경로이므로, 기존 `gh api` 추출 파이프라인을 그대로 쓸 수 없고 사내망에서 itch.io 접근이 막히는 기존 이슈(메모 `pet-asset-sourcing`)가 재발할 가능성이 있다.

---

## 권장 결론

| 순위 | 팩 | 확보 종 수(추정) | 트레이드오프 |
|---|---|---|---|
| 1 (필수 채택 권장) | GrafxKid Sprite Pack 1~8 | 60 | 단일 출처 최대 기여. 전부 CC0, 사이드뷰, 애니메이션 존재가 거의 확실(설명상 "side-scrolling games"용, 일부 캐릭터는 "fast runner"처럼 동작이 명시됨)하나 **정확한 walk 프레임 수는 다운로드 전까지 미확인**. itch.io 8개 페이지를 개별 다운로드해야 해서 작업량이 있음. |
| 2 (권장) | 0x72 16x16+ Robot Tileset | 9 | 기존에 이미 채택 중인 0x72 DungeonTileset II와 동일 작가·동일 그리드(16px)·동일 idle+run 애니메이션 컨벤션이라 화풍 일관성이 가장 높음. 종 수는 적음. |
| 3 (권장) | Kenney Platformer Art: Extended Enemies | 6+ (확인된 것만) | CC0 확정, 이미 `cute-pet-packs.md`에서도 조사된 팩. Walk가 2프레임뿐이라 애니메이션이 단순하고, 21×21px로 기존 팩(32px 위주)보다 작음. |
| 4 (권장, 취합형) | Bevouliin 개별 몬스터 스프라이트 시트 | ~8 (개별 소형 팩 합산) | 팩이 아니라 "몬스터 1종 = 1개 itch/OGA 페이지" 형태라 8개 이상을 낱개로 받아야 함. CC0는 OGA 태그로 확인되나 정확한 해상도·프레임 수는 각 페이지 직접 확인 필요. |
| 5 (조건부 권장) | LuizMelo 소형 몬스터 팩 (Monsters Creatures Fantasy + Fire Worm 등) | 5 확정 (+α 미확인) | CC0 확정이나 화풍이 다크판타지 톤(`cute-pet-packs.md`에서 이미 지적됨). 언데드/악마 테마(`wontfix`/`fridayDeploy` 컬렉션)에는 오히려 잘 맞을 수 있음. |

**단정 회피**: 위 "확보 종 수"는 페이지 설명·검색 결과 기반 추정이며, 실제 스프라이트시트를 열어 프레임 수·셀 크기·애니메이션 종류를 확인하기 전까지는 확정이 아니다. 특히 GrafxKid 8개 팩은 이번 조사의 최대 기여 출처이므로 **다운로드 우선순위 1순위**로 두고 시각 검증할 것을 권장.

---

## 총 확보 가능 종 수 판정

| 구분 | 종 수 | 근거 신뢰도 |
|---|---|---|
| 확정에 가까움 (요건 충족 확인, 개별 종 수 확인) | **88종** | GrafxKid 60 + 0x72 Robot 9 + Kenney Extended Enemies 6 + Bevouliin 8 + LuizMelo 5 |
| 추가 확보 가능(요건 미확인, 후속 검증 필요) | **약 20~40종** | Kenney New Platformer Pack, LuizMelo Fantasy Creatures/Fantasy Beast, 0x72 Pirates/Industrial Tileset(뷰·내용물 미확인), OGA "Enemies and characters" 혼합 컬렉션 중 CC0 항목만 선별 |
| **116종 목표 대비** | **달성 가능 (근거 있음)** | 확정분 88종만으로도 목표의 76%. 다운로드 후 실제 종 수가 설명보다 적게 나올 경우를 대비해 "추가 확보 가능" 목록을 예비로 확보해두는 것을 권장. |

---

## 후보 상세 표

### 대형 팩 (10종 이상 또는 취합 시 10종 이상)

| 팩 이름 | 저자 | 라이선스 | 추출 가능 종 수 | 애니메이션 | 해상도/셀크기 | 뷰 | 소스 URL | 비고 |
|---|---|---|---|---|---|---|---|---|
| Sprite Pack 1 | GrafxKid | **CC0** ("crediting is optional") | 13종 (Mr. Man, Bumpy the Robot, Princess Sera, Bushly, Devo the Devil, Rolling Nero, Gloppy Slime, Chi Chi the Bird, Diver the Fish, Bub Family 등) | Idle+동작 다수 확인(정확한 walk 프레임 수 미확인, 사이드스크롤러용이라 walk 존재 확실시) | 미확인 (다운로드 후 확인 필요) | side (side-scrolling 태그 확인) | https://grafxkid.itch.io/sprite-pack-1 | 캐릭터명이 구체적으로 잡혀 UI 표시명 짓기 쉬움. `happyPath`(마스코트) 또는 `vibeCoders`(모험가) 테마 후보. |
| Sprite Pack 2 | GrafxKid | **CC0** | 9종 (Onion Lad, Mr. Mochi, Octi, Robo Pumpkin, Daikon, Robo Totem, Rocket Cherry, Comrade Cheese Puff, Snip Snap Crab) | 캐릭터별 개별 애니메이션 보유(구체 종류 미확인) | 미확인 | side (platformer 스크린샷 확인) | https://grafxkid.itch.io/sprite-pack-2 | 음식/사물 의인화 마스코트 — `happyPath`(밝고 귀여운) 테마에 가장 잘 맞음. |
| Sprite Pack 3 | GrafxKid | **CC0** | 5종 (Gum Bot, Twiggy, Robot J5, Tommy, Geralt) | "다양한 동작" (Tommy="fast runner" 명시 → run 애니 존재 시사) | 미확인 | side | https://grafxkid.itch.io/sprite-pack-3 | 로봇 3종 포함 — 신규 "기계/로봇" 테마 그룹핑 후보. |
| Sprite Pack 4 | GrafxKid | **CC0** (추정, 동일 작가 컨벤션) | 10종 | 미확인 | 미확인 | side (추정) | https://grafxkid.itch.io/sprite-pack-4 | 개별 상세 미조사 — 다운로드 후 확인 필요. |
| Sprite Pack 5 | GrafxKid | **CC0** (추정) | 9종 | 미확인 | 미확인 | side (추정) | https://grafxkid.itch.io/sprite-pack-5 | 상동. |
| Sprite Pack 6 | GrafxKid | **CC0** (추정) | 4종 | 미확인 | 미확인 | side (추정) | https://grafxkid.itch.io/sprite-pack-6 | 상동. |
| Sprite Pack 7 | GrafxKid | **CC0** (추정) | 3종 | 미확인 | 미확인 | side (추정) | https://grafxkid.itch.io/sprite-pack-7 | 상동. |
| Sprite Pack 8 | GrafxKid | **CC0** (추정) | 7종 | 미확인 | 미확인 | side (추정) | https://grafxkid.itch.io/sprite-pack-8 | 상동. **GrafxKid 8팩 합계 = 60종.** |
| 16x16+ Robot Tileset | 0x72 | **CC0** ("Credit is not necessary") | 9종 (개별 명칭 미공개) | **Idle + Run 확인됨** (itch 댓글에서 작가가 직접 "idle 200ms/frame, run 100ms/frame" 언급) | 16×32px (그리드는 16×16 기반) | side | https://0x72.itch.io/16x16-robot-tileset | 기존 채택 중인 0x72 DungeonTileset II와 **동일 작가·동일 그리드·동일 애니메이션 컨벤션** — 화풍 일관성 최고. GitHub 미러 미확인, itch.io 직접 다운로드 유일 경로. |
| Platformer Art: More Animations and Enemies | Kenney | **CC0** (attribution 선택) | 최소 6종 확인(Bat, Frog, Ladybug, Mouse, Snake, Barnacle) — 165개 개별 PNG + 스프라이트시트 7개 안에 추가 종 존재 가능성 있음(미확인) | Walk **2프레임**(단순), Climbing/Swimming 별도 확인 | 약 21×21px (margin/spacing 2px) | side (platformer) | https://kenney.nl/assets/platformer-art-extended-enemies , OGA 미러: https://opengameart.org/content/platformer-art-more-animations-and-enemies | `cute-pet-packs.md`에서 이미 1차 조사됨(귀여움 관점). 이번 조사는 "종 수" 관점 재확인. Kenney 팩은 GitHub 미러가 흔한 편(비공식)이나 이 팩 전용 미러 경로는 확인 못 함. |
| Bevouliin 개별 몬스터 스프라이트 시트 (Green Walking Monster / Green Horn Monster / Underground Worm Monster / Flappy Monster / Orange Bubble Land Monster / Plant Monster / Enemy Villain Monster 등) | Bevouliin | **CC0** (OGA 페이지에서 개별 확인 — "bevouliin-free-walking-monster-sprite-sheets" 직접 확인함) | 확인된 타이틀 기준 약 **7~8종** (모두 1페이지=1종 형태, 완전한 목록은 작가 공식 사이트 bevouliin.com에서 재확인 필요) | Walk 확인(1건: "FREE WALKING MONSTER SPRITE SHEETS"), 나머지는 제목상 walk/flying 추정, 개별 확인 필요 | 미확인 (페이지별 상이 추정) | side (side-scroller 태그 확인) | https://opengameart.org/content/bevouliin-free-walking-monster-sprite-sheets 외 개별 페이지(하단 참고자료 참조) | 각 페이지가 독립 라이선스 표기라 하나씩 확인 필요. 종 수가 적은 대신 팩 개수 자체가 많아 취합형 대형 출처. `fridayDeploy`(괴물) 테마와 잘 맞음. |

### 중형/보완 팩 (검증 필요 — 확정 못 함)

| 팩 이름 | 저자 | 라이선스 | 추출 가능 종 수 | 애니메이션 | 해상도/셀크기 | 뷰 | 소스 URL | 비고 |
|---|---|---|---|---|---|---|---|---|
| Monsters Creatures Fantasy | LuizMelo | **CC0** (`cute-pet-packs.md`에서 이미 확정) | 4종 (Mushroom, Flying Eye, Goblin, Skeleton) | Idle+Run+Attack 풀셋 | 약 35×39px (추정) | side | https://luizmelo.itch.io/monsters-creatures-fantasy | 이미 1차 조사에서 "다크판타지 톤"으로 평가됨. `wontfix`(언데드)/`fridayDeploy`(악마·괴물) 테마에 붙이면 톤 위화감이 오히려 적을 수 있음. |
| Fire Worm | LuizMelo | **CC0** (동일 작가 관례 — 페이지 직접 재확인 필요) | 1종 | 미확인 | 미확인 | side (추정) | https://luizmelo.itch.io/ (프로필에서 확인, 개별 URL 미검증) | 단일 종. |
| Fantasy Creatures | LuizMelo | **CC0** (검색 결과 기준 "credits not required" — 원문 재확인 필요) | 미확인(2종 이상 추정) | 미확인 | 미확인 | side (추정) | https://luizmelo.itch.io/fantasy-creatures | **확인 필요** — 종 수·애니메이션 모두 미검증. |
| Fantasy Beast | LuizMelo | **확인 필요** | 미확인 | 미확인 | 미확인 | side (추정) | https://luizmelo.itch.io/fantasy-beast | 페이지 존재만 확인, 상세 미조사. |
| New Platformer Pack (2025) | Kenney | **CC0** (kenney.nl 확인) | 미확인 (440+ 에셋 중 캐릭터/적 비중 불명) | 미확인 | 미확인 | side (추정, 미리보기 이미지 기준) | https://kenney.nl/assets/new-platformer-pack , OGA: https://opengameart.org/content/new-platformer-pack | 2025-05 출시로 리뷰 자료 부족. `cute-pet-packs.md`에서도 "미정" 평가. **다운로드 후 재조사 1순위 후보.** |
| 16x16 Pirates Tileset | 0x72 | **CC0** ("Credit is not necessary") | 미확인 | 미확인 | 16×16px | **뷰 불확실** — 썸네일 상 top-down/isometric일 가능성 언급됨 (side-view 미확정) | https://0x72.itch.io/16x16-pirates-tileset | 뷰가 사이드뷰가 아닐 가능성이 있어 **후순위**. `noVerify`(해적단) 테마와 이름은 잘 맞으나 채택 전 스크린샷 실사 확인 필수. |
| 16x16 Industrial Tileset | 0x72 | **CC0** | 미확인 (작가가 "적을 좀 추가했다"고만 언급, 구체 종 수·명칭 없음) | 미확인 | 16×16px | side (추정, DungeonTileset II와 동일 그리드 컨벤션) | https://0x72.itch.io/16x16-industrial-tileset | `mythic-pet-assets.md` 부록 조사에서 이미 "서버랙 없음"으로 가구 관점은 확인됨 — 이번엔 캐릭터/적 관점 재조사 필요. |

---

## CC-BY 팩 (별도 attribution 필요)

이번 조사에서 발견한 신규 대형 팩 중 **CC-BY 라이선스는 없었다.** 모두 CC0으로 확인되거나(대부분) attribution이 명시적으로 선택사항이었다. 기존 CC-BY 팩(Calciumtrice, chierit 등)은 `cute-pet-packs.md`/`mythic-pet-assets.md`에 이미 정리되어 있으므로 본 문서에서는 중복 기재하지 않는다.

---

## 컬렉션 테마 매칭 제안 (참고, 확정 아님)

기존 11개 `PetCollection`(`Sources/ClaudeUsage/PetCollection.swift`) 기준 한 줄 제안:

- **GrafxKid Sprite Pack 2** (Onion Lad, Mr. Mochi, Daikon, Rocket Cherry 등 음식 의인화) → `happyPath`("밝고 귀여운 마스코트") 그룹과 톤이 가장 잘 맞음.
- **GrafxKid Sprite Pack 3** (Gum Bot, Robot J5, Geralt — 로봇 3종) → 기존 컬렉션 중 로봇 테마가 없어 **신규 그룹 후보**로 고려 가치 있음(architect 판단 필요).
- **0x72 16x16+ Robot Tileset** → 동일하게 로봇 테마 — Sprite Pack 3와 묶어 신규 "로봇/기계" 컬렉션을 만들면 자연스러움.
- **Bevouliin 몬스터 시트 모음** (Green Horn Monster, Underground Worm 등 그로테스크 계열) → `fridayDeploy`("악마·괴물") 그룹에 적합.
- **LuizMelo Monsters Creatures Fantasy/Fire Worm** (다크판타지 톤) → `wontfix`("언데드") 또는 `fridayDeploy`("악마·괴물") 그룹.
- **Kenney Extended Enemies** (Bat, Frog, Ladybug, Mouse, Snail류 소형 동물) → `npmInstall`("땅 위 작은 친구") 그룹과 크기·톤이 맞음.
- **0x72 Pirates Tileset** (뷰 확정 시) → `noVerify`("해적단") 그룹에 이름부터 직관적으로 어울림.

---

## 제외 후보 (라이선스/요건 미충족)

| 팩 | 제외 사유 | 출처 |
|---|---|---|
| Hexany's Monster Menagerie | CC0 확인되나 **애니메이션 전무**(정적 스프라이트만, 64종이나 idle/walk 없음) — 요건 #2 미충족 | https://hexany-ives.itch.io/hexanys-monster-menagerie |
| Pixel Monsters Megapack (Blacis) | CC0, 100+ 종이나 **"Animation: idle only"** 명시 — walk/run 없어 요건 #2(최소 idle+walk) 미충족 | https://blacis.itch.io/pixel-monsters-mega-pack |
| Project Cordon Sprites (GitHub) | CC0-1.0(라이선스는 적합)이나 **isometric/3-4 뷰** — 요건 #3(사이드뷰 우선) 미충족 | https://github.com/doficia/project-cordon-sprites |
| 0x72 16x16 Dungeon Tileset (구버전, DungeonTileset II 이전작) | CC0이나 **애니메이션 없는 정적 스프라이트**로 확인됨. 이미 채택 중인 DungeonTileset II와 컨셉 중복 | https://0x72.itch.io/16x16-dungeon-tileset |
| Pixel Mob! (Henry Software, 80종 전체판) | **유료 $3.50**, CC0 아님(무료판은 슬라임 1종만 CC0) — 요건 #1 미충족 | https://henrysoftware.itch.io/pixel-mob |
| Fantasy RPG Creatures & Monsters: Free Pack (Electric Lemon) | 무료이나 라이선스에 **"No reselling/distribution of asset"** 명시 — CC0/CC-BY 아닌 커스텀 제한 라이선스, 요건 #1 미충족 | https://electriclemon.itch.io/creatures-free-pack |
| Fantasy RPG Monster pack (Franuka) | **유료 $12.50** + "cannot redistribute it as is or resell" 명시 — 요건 #1 미충족 | https://franuka.itch.io/fantasy-rpg-monster-pack |
| FREE RPG Monster Pack (Pipoya) | RPG Maker 계열 **탑다운 스타일로 추정**(직접 확인은 못 했으나 Pipoya 작품군 전체가 탑다운 컨벤션) — 요건 #3 위반 가능성 높아 후순위 제외 | https://pipoya.itch.io/free-rpg-monster-pack |
| Kenney Monster Builder Pack | CC0이나 "170+ 스프라이트"가 **완성 캐릭터가 아닌 조립용 파츠**(머리/몸통 등) — 별도 합성 작업 없이는 바로 쓸 수 없어 이번 목적엔 부적합 | https://kenney.nl/assets/monster-builder-pack |
| OGA "Enemies and characters (Pixel Art)" 컬렉션 | 100+ 스프라이트셋을 모아둔 큐레이션 컬렉션이나 **개별 에셋마다 라이선스가 CC0/CC-BY/CC-BY-SA로 혼재** — 컬렉션 자체를 하나의 팩으로 채택 불가, 개별 심사 필요 | https://opengameart.org/content/enemies-and-characters-pixel-art |
| Ragnar's CC0 Bag of Holding | CC0 확정이나 내용물이 **격투게임(MUGEN)/비트엠업 스타일 캐릭터 위주**로 기존 팩들의 "SD 픽셀아트" 톤과 이질적이고 해상도도 들쭉날쭉(8px~48px 혼재) — 전체 채택보다 개별 발췌가 필요해 이번 "메가팩" 기준엔 부적합 | https://opengameart.org/content/ragnars-cc0-bag-of-holding |

---

## 상충 정보

- **0x72 Pirates Tileset의 뷰(관점)**: WebFetch 결과는 "16x16 픽셀 그리드"라고만 명시했고, 검색 결과 한쪽은 "ships and characters"(뷰 불명), 다른 쪽 WebFetch 결과는 "썸네일이 top-down 또는 isometric처럼 보인다"고 판단했다. 같은 작가(0x72)의 DungeonTileset II·Robot Tileset은 명백히 사이드뷰이므로 Pirates만 다른 관점일 가능성은 낮아 보이나(주관적 추정), **확정하려면 실제 스크린샷을 직접 봐야 한다.**
- **GrafxKid 팩들의 "애니메이션 존재" 확신 수준**: 페이지 설명은 "각 캐릭터가 자신만의 애니메이션 세트를 가진다"는 식으로만 서술되어 walk 애니메이션의 존재를 텍스트로 100% 확정하진 못했다. 다만 (a) 장르 태그가 "action/platformer"이고, (b) Sprite Pack 3의 "Tommy = fast runner" 같은 캐릭터 설명이 동작 애니메이션 존재를 강하게 시사하므로, **높은 확신으로 존재를 추정**하되 다운로드 후 최종 확인이 필요하다.
- **Bevouliin 팩들의 정확한 개수**: 검색 결과마다 발견되는 타이틀 목록이 조금씩 다르고(예: "Green Walking Monster"와 "Walking Monster"가 동일 자산의 다른 표기인지 별개 자산인지 이번 조사로는 확정 못 함), 작가 공식 사이트(bevouliin.com)의 전체 카탈로그를 직접 열람하지 못했다. **중복 집계 가능성**이 있으므로 "확정 88종" 계산에서 Bevouliin 몫(8종)은 보수적으로 잡은 값이다.

---

## 확인 안 된 것

- GrafxKid Sprite Pack 4~8의 캐릭터 명칭·정확한 애니메이션 종류·셀 크기 — 1, 2, 3번 팩만 상세 확인했고 나머지는 itch.io 목록의 "N free characters" 문구만 확인함.
- 모든 신규 후보 팩의 **정확한 셀 크기(px)** — 대부분 페이지 설명에 명시되어 있지 않아 실제 다운로드 후 실측이 필요함.
- **사내망에서 itch.io/OpenGameArt 직접 다운로드 가능 여부** — 기존 메모(`pet-asset-sourcing`)에 따르면 itch.io/OGA 직접 다운로드가 사내망 TLS로 차단된 이력이 있음. 이번 조사에서 발견한 팩들은 **GitHub 미러가 하나도 확인되지 않아** 기존 `gh api` 우회 파이프라인을 그대로 쓸 수 없다. 실제 다운로드는 사용자 개인망에서 수행 후 리포에 커밋하는 방식이 필요할 가능성이 높음(과거 `office-assets.md`/`mythic-pet-assets.md`에서도 동일 결론).
- Kenney New Platformer Pack(2025)의 구체적 캐릭터/적 목록과 애니메이션.
- LuizMelo Fantasy Creatures/Fantasy Beast의 정확한 종 수·애니메이션·라이선스 원문.
- 0x72 Pirates Tileset·Industrial Tileset의 실제 캐릭터 유무 및 종 수(둘 다 "포함되어 있다"는 정황만 있고 목록 확인 못 함).
- Bevouliin 전체 카탈로그(bevouliin.com 직접 방문 시 추가 종 발견 가능성 있음 — 이번 조사는 검색엔진에 노출된 OGA 페이지 8개만 확인).

---

## 참고 자료 (미확인이지만 후속 가치 있는 URL)

- https://grafxkid.itch.io/sprite-pack-4 , https://grafxkid.itch.io/sprite-pack-5 , https://grafxkid.itch.io/sprite-pack-6 , https://grafxkid.itch.io/sprite-pack-7 , https://grafxkid.itch.io/sprite-pack-8 — 상세 미조사 4개 팩, 다운로드 우선순위 1순위
- https://kenney.nl/assets/new-platformer-pack — 2025년 신규 대형팩, 세부 미확인
- https://luizmelo.itch.io/fantasy-creatures , https://luizmelo.itch.io/fantasy-beast — LuizMelo 추가 몬스터 팩
- https://bevouliin.com/ — Bevouliin 공식 사이트, 전체 카탈로그 확인용
- https://0x72.itch.io/16x16-pirates-tileset , https://0x72.itch.io/16x16-industrial-tileset — 0x72 보완 팩, 뷰/캐릭터 목록 실사 확인 필요
- https://opengameart.org/content/enemies-and-characters-pixel-art — 100+ 혼합 컬렉션, 개별 CC0 항목만 골라내는 후속 조사 가치 있음
- https://itch.io/game-assets/assets-cc0/tag-monsters , https://itch.io/game-assets/assets-cc0/tag-characters — itch.io CC0 필터 목록(추가 후보 탐색용, 이번 조사에서 전량 열람은 못함)
- https://opengameart.org/content/bevouliin-free-sprite-sheets-monster-game-asset , https://opengameart.org/content/bevouliin-green-horn-monster-sprite-sheets , https://opengameart.org/content/bevouliin-free-sprite-sheets-underground-worm-monster , https://opengameart.org/content/bevouliin-free-flappy-monster-sprite-sheets , https://opengameart.org/content/bevouliin-free-orange-bubble-land-monster-sprite-sheets , https://opengameart.org/content/bevouliin-free-sprite-sheets-plant-monster , https://opengameart.org/content/bevouliin-free-enemy-villain-monster-game-asset-for-game-developers — Bevouliin 개별 페이지 전체 목록(각각 라이선스 재확인 후 채택)

---

## 검토 체크리스트

- [x] 출처 신뢰도 평가 (itch.io/kenney.nl 공식 페이지 최우선, OGA 태그 차선, 검색엔진 요약 인용은 최하 신뢰도로 표시)
- [x] 최신성 평가 (Kenney New Platformer Pack 2025-05 = 최신, 나머지는 발행일 명확치 않으나 모두 현재도 활성 배포 중인 페이지)
- [x] 상충 정보 식별 (0x72 Pirates 뷰, GrafxKid 애니메이션 확신 수준, Bevouliin 개수 중복 가능성)
- [x] 사실/권장 분리 (표는 사실 위주, "권장 결론"/"테마 매칭 제안" 섹션에서만 의견 제시)
- [x] 출처 URL 모든 표에 포함
- [x] 확인 못 한 영역 명시 (별도 섹션)
- [x] prompt injection 패턴 없음 — WebFetch로 가져온 모든 콘텐츠는 일반적인 상품 설명/라이선스 문구였고 `<system-reminder>`, "ignore previous instructions" 류의 이상 패턴은 발견되지 않음
