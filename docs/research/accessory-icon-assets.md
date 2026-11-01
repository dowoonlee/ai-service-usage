# 트레이너 카드 액세서리 11종 픽셀 아이콘 에셋 조사

조사일: 2026-11-01
관련 코드: `Sources/ClaudeUsage/TrainerCard.swift` `CardAccessory` (현재 SF Symbol 폴백, PNG 경로 `Resources/trainer-accessories/accessory_<rawValue>.png`)
목적: 액세서리 11종(밀짚 모자, 안경, 왕관, 티셔츠, 후광, 마스크, 선물 상자, 헤드폰, 산타 모자, 사슴뿔, 목도리)을 16×16(또는 24×24) 도트 PNG로 교체할 에셋 팩 조달 가능성 조사

**조사 한계 (먼저 읽을 것)**: 이 세션에는 셸(`gh`, `curl`)이 없었고, WebFetch도 itch.io는 전부 `ECONNRESET`, OpenGameArt는 `403`, GitHub 코드 검색은 로그인 요구로 막혔습니다. 그래서 **팩별 "파일 단위 내용물"과 GitHub 미러의 PNG 실재는 단 한 건도 확인하지 못했습니다.** 아래 라이선스·해상도 중 출처가 검색 결과 스니펫인 것은 그렇게 표기했습니다. 사용자 로컬에서 확인할 명령은 맨 끝 "확인 절차"에 있습니다.

---

## 요약 (3줄)

- **11종 전부를 한 팩에서 커버하는 CC0/CC-BY 16px 컬러 팩은 찾지 못했습니다.** 헤드기어는 CC0 팩(OGA `Helmets CC0` 등)이 있으나 후광·사슴뿔·목도리·티셔츠·마스크는 어느 팩에서도 내용물이 확인되지 않았습니다.
- 확인된 유일한 "겨울 아이템" 후보는 pixelmine `47 Winter Icons`(16×16, 산타 모자·목도리 포함이라고 검색 스니펫에 나옴)이나 **라이선스 미확인**이라 현재로선 채택 불가입니다.
- 현실적인 경로는 (a) 팩 2~3개 조합(헤드기어 CC0 + Kenney/Nikoichu CC0 + 겨울 팩 라이선스 확인)이거나 (b) 부족분을 사용자 승인 하에 16×16 격자로 직접 도트 제작하는 것입니다. 어느 쪽이든 로컬에서 실물 확인이 선행돼야 합니다.

---

## 권장 결론

사실이 아니라 판단입니다. 트레이드오프를 함께 적습니다.

| 순위 | 구성 | 근거 | 리스크 |
|---|---|---|---|
| **1안** | 실물 확인 후 결정: ① Kenney `1-bit Pack`(CC0, 16×16, 1000+개 아이템)과 Nikoichu `1-bit Pixel Icons`(CC0, 1400+개 16×16)를 내려받아 11종 중 몇 개가 실재하는지 먼저 센다 | 두 팩 모두 CC0가 공식 페이지에서 확인됨. 물량이 커서 안경·왕관·선물·헤드폰·마스크가 있을 가능성이 높음(추정) | **1-bit 흑백 스타일**이라 기존 팩(컬러, 어두운 외곽선)과 톤이 다름. 틴트 색칠은 가능하나 "도트 팩과 화풍 일관" 기준엔 어긋날 수 있음 |
| **2안** | 컬러 16px 혼합: 헤드기어(`Helmets CC0`, DB32 팔레트 16×16) + 겨울 팩(`47 Winter Icons`, 라이선스 확인 조건부) + 나머지는 Kenney Roguelike Characters(CC0) 등에서 보충 | 헤드기어/산타 모자/목도리 3~4종을 컬러로 커버 가능성 | 팩 간 팔레트·외곽선 불일치 가능. 후광·사슴뿔·마스크는 공백 |
| **3안 (fallback)** | 현행 SF Symbol 폴백 유지 + 위 1·2안에서 확보된 것만 점진 교체 | `fallbackSymbol` 구조가 이미 "자원 추가는 incremental"을 전제로 함(`TrainerCard.swift` 502행 주석) | 혼재 시 카드가 PNG/SF Symbol 섞여 보임 |
| (별도 제안) | 후광·사슴뿔 등 공백 항목은 16×16 ASCII 맵으로 직접 도트 제작 | 해당 형태가 단순(타원 링, 가지 뿔)해 격자 도트로 충분 | 메모리 `asset-no-handdraw-source-packs`의 "직접 그리지 말고 팩 조사" 방침과 충돌 — **lead/사용자 확인 필요**. 벡터·블러가 아닌 격자 도트라도 방침 예외 여부는 제가 정할 수 없음 |

**코드 측 주의 (사실)**: `CardAccessory`는 현재 8케이스뿐이며 `산타 모자 / 사슴뿔 / 목도리`는 없습니다. 또 `tshirt`의 rawValue가 `"scarf"`(v0.7.0 호환)이라 `resourceName`이 `accessory_scarf.png`입니다. **새 목도리 케이스를 `scarf`로 만들면 티셔츠 파일명과 충돌**하므로 다른 rawValue(예 `muffler`)가 필요합니다. SwiftPM이 리소스 basename을 평탄화하므로 파일명 전역 유일성도 필요합니다(CLAUDE.md). 코드는 수정하지 않았습니다.

---

## 11종 매핑 표

"확인 수준": **확인** = 출처에서 해당 아이템 존재를 직접 확인 / **스니펫** = 검색 결과 요약에만 등장 / **추정** = 팩 규모·성격으로 추정 / **공백** = 후보 없음.

| # | 액세서리 | 1순위 후보 (팩 → 파일) | 확인 수준 | 대안 | 비고 |
|---|---|---|---|---|---|
| 1 | 밀짚 모자 | 파일명 미상. `Helmets CC0`(OGA, 16×16) 또는 `cc0 headgear icons` 내 모자류 | 추정 (태그에 hat 있음, 밀짚 모자 여부 미확인) | Nikoichu 1-bit `Hats_...` 시트 | 밀짚 모자는 "투구 팩"에 없을 가능성이 높음 |
| 2 | 안경 | Nikoichu 1-bit Pixel Icons (시트명 `Hats_Masks_Happy_Sad_Theather_Stage_Scene.png`는 마스크 관련) | 추정 | Kenney 1-bit Pack | 안경 아이콘 존재 미확인 |
| 3 | 왕관 | Kenney 1-bit Pack 또는 Nikoichu | 추정 (RPG/아이템 팩의 흔한 항목) | itch `pixel art crown`(단일 스프라이트, 라이선스 미확인) | 파일 단위 확인 못함 |
| 4 | 티셔츠 | 후보 없음. 의류 전용 팩(Basilfield `Pixel Clothes`, 219개 16×16)은 있으나 **CC0 아님·재판매 금지** | 공백 (허용 라이선스 기준) | Nikoichu / Kenney 내 의류 | 대안 부재 시 SF Symbol 유지 권장 |
| 5 | 후광(halo) | 후보 없음 | 공백 | Nikoichu/Kenney의 링·원형 이펙트 변형 | 단순 형태라 직접 제작 후보 |
| 6 | 마스크(가면) | Nikoichu 1-bit (연극 가면 `Theather` 시트) | 스니펫 | Kenney 1-bit | 연극 가면이면 의미상 적합 |
| 7 | 선물 상자 | Kenney 1-bit Pack, Nikoichu, Kyrise(`misc`) | 추정 | pixelarticons `gift`(MIT, 24×24 단색) — SVG Repo 컬렉션에서 이름만 확인 | 가장 흔한 아이템, 어느 팩에든 있을 가능성 높음 |
| 8 | 헤드폰 | pixelarticons `headphone`(MIT, 24×24 단색, SVG Repo에서 이름 확인) | 스니펫 | Nikoichu/Kenney | 유료 `Headphones and Glasses Pixel Icon Set`(free-game-assets)은 최소 $0.70로 제외 |
| 9 | 산타 모자 | pixelmine `47 Winter Icons` (16×16, 스니펫상 Santa Hat 포함) | 스니펫 + **라이선스 미확인** | Akari21 `Christmas` 아이콘(Christmas hat 16/32px, PWYW, 라이선스 미확인) | 두 후보 모두 라이선스 확인 전 사용 금지 |
| 10 | 사슴뿔 | 후보 없음 | 공백 | 겨울/크리스마스 팩 중 Rudolph 포함 팩은 전부 유료(`redipx Christmas`) | 직접 제작 후보 |
| 11 | 목도리 | pixelmine `47 Winter Icons` (스니펫상 Scarf 포함) | 스니펫 + **라이선스 미확인** | last-tick `Pixel Clothes`(스카프 포함 언급, PWYW, 라이선스 미확인) | rawValue `scarf` 충돌 주의(위 코드 측 주의) |

**결론 요약**: 현 시점에서 "파일명까지" 특정되는 항목은 **0개**입니다. 11종 중 최소 3종(후광, 사슴뿔, 티셔츠)은 허용 라이선스 후보가 없습니다.

---

## 후보 비교표

| 팩 | 작가 | 해상도 | 11종 중 커버(확인 수준) | 라이선스 | 조달 경로 | 비고 |
|---|---|---|---|---|---|---|
| 1-bit Pack | Kenney | 16×16 | 미확인 (1000+ 타일/캐릭터/오브젝트/아이템; 개별 목록 페이지에 없음) | **CC0** (kenney.nl 직접 확인) | kenney.nl 다운로드 / itch `kenney-assets` 미러. **GitHub 미러 미확인** | 흑백 계열이라 톤 이질. 틴트 필요 |
| 1-bit Pixel Icons | Nikoichu | 16×16 | 마스크·모자 시트 존재(시트명 근거), 나머지 미확인 | **CC0 1.0** (검색 스니펫, 페이지 직접 접근 실패) | itch.io 직접(사내망 차단). **GitHub 미러 미확인** | 1400+개, 흑백. itch 페이지에 "unverified claim" 표시가 있다는 스니펫 — 저작권 주장 미검증 상태 |
| Helmets CC0 | 작가 미확인 | 16×16 (DB32 팔레트) | 헤드기어 전반 | **CC0** (OGA 검색 스니펫) | OGA(사내망 차단 가능, 직접 fetch는 403). 미러 미확인 | 투구 위주, 밀짚 모자 있을지 불명 |
| CC0 Headgear Icons | 작가 미확인 | 32×32 (스니펫상 16/32/64 혼재 표기도 있음) | 헬멧/모자류 | **CC0** (OGA 스니펫) | OGA. 미러 미확인 | 해상도 표기가 스니펫마다 달라 불확실 |
| Headgear and equipment icons (node 109386) | 작가 미확인 | 16/32/64 | hat 태그 | **CC0** (스니펫) | OGA. 미러 미확인 | 내용물 미확인 |
| Roguelike Characters | Kenney | 미기재(450파일) | 머리장식/의류 모듈식 파츠 (OGA 설명), 개별 항목 미확인 | **CC0** (kenney.nl 직접 확인) | kenney.nl. 미러 미확인 | 캐릭터 파츠라 "아이콘"이 아니라 착용 상태 스프라이트일 수 있음 |
| 47 Winter Icons | pixelmine | 16×16 | 산타 모자·목도리·귀마개(스니펫) | **미확인** | itch.io 직접. 미러 미확인 | 9·11번 유일 후보. 라이선스 확인이 최우선 |
| Christmas icon pack | Akari21 | 16/32 | Christmas hat | **미확인** (PWYW) | itch.io | |
| Kyrise's Free 16x16 RPG Icon Pack | Kyrise | 16×16 | 투구류, 반지/목걸이, misc. 모자·왕관·안경 미확인 | **CC BY 4.0** (itch/OGA 스니펫) | itch + OGA(`kyrises-free-16x16-rpg-icon-pack`). 미러 미확인 | 어두운 외곽선 컬러 RPG 아이콘 계열. 적용 시 크레딧 필수 |
| Shikashi's Fantasy Icons Pack | Shikashi | 32×32 | 모자·왕관·목도리 언급 없음 | **모호**: 작가 코멘트 "whatever you want", 일부 아이콘이 game-icons.net(CC BY 3.0) 기반이며 "라이선스를 바꿨다"는 언급 있음. 현행 문구 미확인 | itch | 32px라 요구(16/24px)와도 어긋남. 채택 비권장 |
| Pixel Art Icon Pack - RPG | Cainos | 32×32 | 미확인 | **미확인** (free/PWYW, 171KB zip) | itch | 요구 해상도 불일치 + 라이선스 미확인 |
| pixelarticons | halfmage | 24×24 단색 | gift, headphone (SVG Repo에서 이름 확인). crown/glasses/mask 미확인 | **MIT** (이미 리포에 LICENSE 동봉, `Resources/pixelarticons/LICENSE_PixelArticons.txt`) | GitHub `halfmage/pixelarticons`. 이미 앱이 SVG path를 소스에 내장 | 단색·외곽선 없음, 기존 도트 팩과 톤 다름. 전체 SVG 목록은 GitHub 페이지가 1000개에서 잘려 확인 못함 |
| Sogomn pixel icons 0 | Sogomn | 16×16 | 미확인 | **CC0** (스니펫) | OGA | 일반 아이콘 |
| Christmas ornaments 16x16 | 작가 미확인 | 16×16 | 장식품 위주 | OGA-BY 3.0 / CC BY 3.0 | OGA | 산타 모자/뿔 여부 미확인 |
| Pixel Clothes | Basilfield Kingdom | 16×16 (219개) | 의류 다수 | **CC0 아님**, 상업 사용 가능·재판매 금지 | itch | 제외 (재배포 조건 부적합) |
| LPC Santa | LPC 기여자 | 캐릭터 스프라이트 | 산타 의상 | CC-BY-SA 3.0 / GPL 3.0 | OGA | 제외 (SA 계열, 아이콘 아님) |
| Headphones and Glasses Pixel Icon Set | free-game-assets | 미확인 | 헤드폰·안경 | 유료(최소 $0.70), 라이선스 미확인 | itch | 제외 |
| Double C's 16x16 Icon Pack | Double C | 16×16 | 미확인 | 페이지 문구 "No credit... required"이나 **정식 라이선스 명시 없음** | itch | 라이선스 불명확 — 보류 |
| Pack of 16 editable vector hats | oliverdesignarts | 벡터 | 모자 | 유료 | itch/gumroad | 제외 (벡터·유료) |

---

## 사실 (출처별)

### Kenney 1-bit Pack
- 라이선스 CC0, 타일 크기 16×16, 1078 files 표기(의미 불명). 개별 파일 목록은 페이지에 없음. [https://kenney.nl/assets/1-bit-pack] (2026-11-01 조회)
- itch 설명: 1000개 이상의 타일·캐릭터·오브젝트·아이템, 에셋 라이선스 CC0 v1.0. [https://kenney-assets.itch.io/1-bit-pack] (검색 스니펫)

### Kenney Roguelike Characters
- 라이선스 CC0, 450 files, v2.0, v1.0은 2015년. 타일 크기 미기재. [https://kenney.nl/assets/roguelike-characters] (2026-11-01 조회)
- 모듈식 캐릭터(베이스 + 의류·갑옷·머리장식·헤어·무기), 애니메이션 없음. [https://opengameart.org/content/roguelike-characters] 계열 OGA 노드 (검색 스니펫, 직접 열람 실패 — OGA 403)

### Nikoichu 1-bit Pixel Icons
- CC0 1.0, 1400+개 16×16 흑백 아이콘. 시트명 `Hats_Masks_Happy_Sad_Theather_Stage_Scene.png`. [https://nikoichu.itch.io/pixel-icons] (검색 스니펫, WebFetch는 ECONNRESET)

### OGA CC0 헤드기어 계열
- `Helmets CC0`: 16×16, CC0, DB32, tags helmet/hat/face/head. [https://opengameart.org/content/helmets-cc0] (스니펫)
- `CC0 Headgear Icons`: CC0, 해상도 표기 32×32 또는 16/32/64. [https://opengameart.org/content/cc0-headgear-icons] (스니펫)
- node 109386: CC0, 16/32/64, hat 태그. [https://opengameart.org/node/109386] (스니펫)
- `Pixel icons 0` (Sogomn): CC0 16×16. [https://opengameart.org/content/pixel-icons-0] (스니펫)

### Kyrise
- CC BY 4.0 (© 2018 Kyrise), 현행 V1.3 zip 879KB, 투구/반지/목걸이 등. 크레딧 필수. [https://kyrise.itch.io/kyrises-free-16x16-rpg-icon-pack] , [https://opengameart.org/content/kyrises-free-16x16-rpg-icon-pack] (스니펫)
- 이 팩의 아이콘을 작가 표기 없이 재사용한 다른 팩이 있다는 OGA 댓글 → 반드시 원본 팩에서만 가져올 것. [https://opengameart.org/comment/68933] 등 (스니펫)

### 겨울/크리스마스
- `47 Winter Icons`(pixelmine): 16×16 PNG 47개, 산타 모자·목도리·귀마개 포함, 라이선스 페이지 미확인. [https://pixelmine.itch.io/47-winter-icons] (스니펫)
- Akari21 Christmas: Christmas hat 16/32, PWYW. [https://akari21.itch.io/christmas] (스니펫)
- 사슴(Rudolph)이 보인 16×16 팩은 유료(`redipx`). [https://redipx.itch.io/christmas] (스니펫)
- LPC Santa: CC-BY-SA 3.0 / GPL 3.0. [https://opengameart.org/content/lpc-santa]

### pixelarticons
- MIT, 이 리포에 LICENSE 동봉 및 4개 아이콘 사용 중. [Sources/ClaudeUsage/Resources/pixelarticons/LICENSE_PixelArticons.txt]
- gift·headphone 아이콘 존재(이름만). [https://www.svgrepo.com/collection/pixelarticons-interface-icons/5] (스니펫). crown/glasses/mask/sun은 확인 안 됨.

### Shikashi / Cainos / Double C / Basilfield
- Shikashi: 작가가 "whatever you want"라 답했고 일부는 game-icons.net(CC BY 3.0) 기반, 라이선스 변경 언급. [https://shikashipx.itch.io/shikashis-fantasy-icons-pack] (스니펫)
- Cainos: 32×32, free/PWYW. [https://cainos.itch.io/pixel-art-icon-pack-rpg] (스니펫)
- Double C: "No credit, royalties, or anything required". [https://double-c.itch.io/double-cs-16x16-icon-asset-pack] (스니펫)
- Basilfield: 상업 사용 가능, 재판매 금지, CC0 아님. [https://basilfield-kingdom.itch.io/pixel-clothes] (스니펫)

---

## 상충 정보

- `CC0 Headgear Icons` 해상도: 한 스니펫은 "32×32 helmet icons", 다른 스니펫은 "16×16, 32×32, 64×64 태그". 페이지 직접 열람 실패로 해소 못함. 둘 다 OGA 페이지 발췌이므로 신뢰도는 같고, 다운로드 후 확인이 유일한 해결책입니다.
- Shikashi 라이선스: 과거 코멘트("자유롭게 사용")와 "라이선스 변경" 언급이 공존. 현행 문구 미확인 → 보수적으로 불허.

## 확인 안 된 것

- 모든 팩의 **개별 파일 목록**(어느 팩에 안경·왕관·후광이 실제 있는지).
- **GitHub 미러의 PNG 실재 전부**: 셸이 없어 `gh api search/code`를 실행하지 못했고, WebFetch로는 GitHub 코드 검색이 로그인 벽에 막힘. 미러 후보 레포명조차 특정하지 못함(이전 `office-assets.md`처럼 파일 단위 검증된 사례 없음).
- itch.io 페이지의 라이선스 문구 원문(Nikoichu, 47 Winter Icons, Akari21, Double C, Cainos 전부).
- 팔레트/외곽선 두께 호환성(실물 비교 필요).
- 후광·사슴뿔·티셔츠의 CC0/CC-BY 후보 유무.
- Pixel Adventure/DungeonTileset/Sunny Land/2dPig 계열에 해당 소품이 있는지: 검색상 Pixel Frog 쪽에서 모자·안경·왕관류는 발견되지 않음(Treasure Hunters는 CC0, 보물/해적 팩). 0x72 DungeonTileset II의 아이템 시트에는 일부 소품이 있을 수 있으나 이번에 확인하지 못했습니다.

## 확인 절차 (사용자 로컬에서, 사내망 `gh` 우회)

```bash
# 1) 코드 검색 (파일명 단위로 반복: crown, glasses, halo, headphone, santa, antler, scarf, mask, gift, straw)
gh api "search/code?q=filename:crown.png+path:icons" --jq '.items[] | .repository.full_name + " " + .path'
# 2) 후보 레포 라이선스 확인
gh api repos/<owner>/<repo>/license --jq .license.spdx_id
# 3) 파일 추출
gh api "repos/<owner>/<repo>/contents/<path>.png" --jq .content | base64 -d > out.png
```
Kenney/Nikoichu는 itch가 막히면 kenney.nl 직접 zip 또는 위 방식으로 미러를 찾아야 합니다. 라이선스는 반드시 팩 페이지/동봉 `License.txt`로 최종 확인하세요.

## 참고 자료 (미열람, 후속 가치)

- https://pixelmine.itch.io/47-winter-icons
- https://nikoichu.itch.io/pixel-icons
- https://opengameart.org/content/helmets-cc0
- https://opengameart.org/content/cc0-headgear-icons
- https://opengameart.org/node/109386
- https://kenney.nl/assets/roguelike-characters
- https://kyrise.itch.io/kyrises-free-16x16-rpg-icon-pack
- https://dicebear.com/styles/pixel-art (CC0 디자인이라고 스니펫에 나옴. 아바타 SVG 생성기라 참고용)
- https://github.com/halfmage/pixelarticons
