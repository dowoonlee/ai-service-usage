# Mythic·Legendary 보스급 픽셀아트 펫 에셋 조사

조사일: 2026-06-24
조사 목적: AIUsage 가챠 신규 티어(Mythic 3종 + Legendary 보강 2종)에 쓸 보스급 픽셀아트 스프라이트 에셋 팩 후보 선별

---

## 요약 (3줄)

- CC0 라이선스에서 보스/드래곤급 애니메이션 스프라이트를 GitHub에서 직접 받을 수 있는 팩은 **pixel-boy/NinjaAdventure** (16×16, 드래곤 보스 포함 9종 보스, CC0, GitHub 공개)가 가장 유력하다.
- CC-BY 4.0으로 허용 범위를 넓히면 **chierit** 작가의 단일 보스 팩(Frost Guardian 92×79, Demon Slime 등)이 비주얼 품질이 뛰어나고 idle/walk 포함이지만 itch.io 직접 다운로드만 가능하다.
- **CraftPix.net** 계열 무료 팩은 "앱 번들에 에셋 파일 포함 불가" 조항으로 AIUsage 구조(SwiftPM 번들 내 PNG)에 **사용 불가**하다.

---

## 권장 결론

| 우선순위 | 팩 | 라이선스 | GitHub 직접 접근 | Mythic 적합성 |
|---|---|---|---|---|
| 1순위 | pixel-boy/NinjaAdventure | CC0 | itch.io 직접 다운 + GitHub 미러(Godot 프로젝트) | 드래곤 보스 등 9종 보스, 단 16×16으로 작음 |
| 2순위 | Ansimuz Legacy Collection (CC0 구형 팩) | CC0 | OpenGameArt 직접 다운 (GitHub 없음) | Flying Demon·Hell Beast 포함, 16×16 스타일 |
| 3순위 | chierit 보스 팩 (Frost Guardian, Demon Slime 등) | CC-BY 4.0 | itch.io 직접 다운 (GitHub 없음) | 대형(92×79~) 화려한 보스, attribution 필요 |

트레이드오프:
- CC0 팩은 크기가 16×16 기반으로 작아 "위엄있는 보스" 느낌이 약할 수 있음. 업스케일(4×) 적용 시 64×64로 기존 Pirate Bomb 팩(58~80px) 수준.
- chierit 팩은 비주얼 퀄리티가 가장 뛰어나지만 GitHub 미러가 없어 사내망에서 차단될 위험 있음. 로컬 환경에서 한 번 다운로드 후 내부 저장이 필요.
- CraftPix 계열은 라이선스상 앱 번들 포함 불가로 제외.

---

## 사실 (출처별)

### 팩 A: pixel-boy/NinjaAdventure

- **라이선스**: CC0 (Creative Commons Zero, attribution 불필요) [출처: https://pixel-boy.itch.io/ninja-adventure-asset-pack , 2025-03 최신 업데이트]
- **GitHub repo**: `pixel-boy/NinjaAdventure` (https://github.com/pixel-boy/NinjaAdventure) — Godot 4.0 프로젝트로 에셋 포함. 단, 저장소 루트가 Godot 프로젝트 구조(`content/`, `audio/`)이며 별도 스프라이트만 추출해야 함.
- **보스급 캐릭터**: 9종 보스(animations 포함). 확인된 것: Dragon Boss (Update #7, 2025-03), Squid Boss (Update #8), 4종 색상 변형 보스(Update 4), 2종 보스(애니메이션 포함, Update 5). 기타 보스 종류는 파일 직접 확인 필요.
- **셀 크기**: 기본 16×16, 4× 스케일업 시 64×64
- **애니메이션**: idle, walk, 공격 등 다수 — 캐릭터별 상이. 구형 보스는 Idle/Run만, Dragon Boss는 별도 FX 폴더 포함.
- **스타일**: 탑다운 닌자 테마, 0x72 DungeonTileset과 유사한 레트로 픽셀 톤
- **주의**: GitHub repo가 Godot 프로젝트이므로 스프라이트 파일이 `content/` 하위 중첩 폴더에 있음. 파일 경로는 다운로드 후 직접 확인 필요.
- [출처 1] https://pixel-boy.itch.io/ninja-adventure-asset-pack/devlog/910556/update-7-vfx-dragon-boss-items-more
- [출처 2] https://pixel-boy.itch.io/ninja-adventure-asset-pack/devlog/1462556/update-8-animation-v2-animals-camping-more
- [출처 3] https://github.com/pixel-boy/NinjaAdventure

### 팩 B: Ansimuz Legacy Collection (Gothicvania Patreon's Collection)

- **라이선스**: CC0 (attribution 권장이나 불필요) [출처: https://opengameart.org/content/gothicvania-patreons-collection]
- **다운로드**: OpenGameArt.org에서 ZIP 직접 다운 (3,600+ 다운). **GitHub 저장소 없음** (확인됨).
- **대표 보스/대형 적**: Flying Demon (비행 악마), Hell Beast (지옥 짐승 — idle + run 애니메이션), Nightmare Creature
- **셀 크기**: 16×16 기준 (배경 타일셋), 캐릭터 스프라이트는 별도 크기 — 정확한 값 미확인 (추정).
- **애니메이션**: Hell Beast는 run 애니메이션 확인됨 (devlog 0007, 0008), idle 포함 여부는 추정.
- **스타일**: Castlevania 스타일 고딕 호러 16비트 픽셀아트 — 기존 팩(DungeonTileset II, Sunny Land)과 유사한 톤
- **주의**: OGA 다운로드(직접 ZIP)가 사내망에서 차단될 가능성 있음. itch.io 미러가 `ansimuz.itch.io/gothicvania-patreon-collection`에 있음.
- [출처 1] https://opengameart.org/content/gothicvania-patreons-collection
- [출처 2] https://ansimuz.itch.io/gothicvania-patreon-collection/devlog/1553702/0007-hell-beast-run-animation
- [출처 3] https://ansimuz.itch.io/gothicvania-patreon-collection

### 팩 C: chierit 보스 스프라이트 팩

- **라이선스**: CC-BY 4.0 (attribution 필수, 상업 사용 허용, 수정 허용) [출처: chierit.itch.io, 검색 결과 확인]
- **대표 캐릭터**:
  - Boss: Frost Guardian — 92×79px, 캔버스 192×128, 9개 애니메이션 (idle·walk·attack 포함). 유료 ($3-5 수준).
  - Boss: Demon Slime — 12개 애니메이션. 무료.
  - Boss: Minotaur — 8개 애니메이션. 유료.
  - Boss: Poison Wyrm — 8개 애니메이션. 유료.
- **GitHub 저장소**: 없음 (확인됨). itch.io 직접 다운로드만.
- **스타일**: 대형(90~150px) 화려한 보스. 기존 팩보다 크고 고해상도.
- **주의**: idle/walk/run은 포함이나 정확한 strip PNG 구성인지 별도 frame PNG 구성인지 미확인 (추정: aseprite 소스 + PNG 스프라이트시트).
- [출처 1] https://chierit.itch.io/boss-frost-guardian (검색 결과 기반, 직접 접근 실패)
- [출처 2] https://chierit.itch.io/boss-demon-slime

### 팩 D: OpenGameArt "Pixel Bosses. Yes!"

- **라이선스**: CC0 [출처: https://opengameart.org/content/pixel-bosses-yes]
- **포함 보스**: 달팽이(투석기 장착), 드래곤+기수, 마법의 뿔을 가진 도마뱀 — 3종
- **셀 크기**: 미확인 (페이지에 미기재)
- **애니메이션**: 드래곤 날개 애니메이션 확인. idle/walk 여부는 미확인 (추정: walk 없음, 드래곤 날개만 애니).
- **GitHub**: 없음.
- [출처] https://opengameart.org/content/pixel-bosses-yes

### 팩 E: CraftPix.net 무료 보스 팩 (사용 불가 — 라이선스 충돌)

- **라이선스**: 독점 로열티프리. **"앱을 통해 다른 최종 사용자가 에셋 파일을 사용할 수 있도록 재배포 금지"** 명시.
- **결론**: AIUsage 구조(SwiftPM 번들에 PNG 직접 포함 → 앱 배포)는 이 조항에 저촉. **사용 불가**.
- [출처] https://craftpix.net/file-licenses/

---

## 5종 구체 추천

### Mythic 티어 (3종)

| # | 캐릭터 | 팩 | 파일 경로(추정) | 셀 크기 | 애니메이션 | 라이선스 |
|---|---|---|---|---|---|---|
| M1 | Dragon Boss | pixel-boy/NinjaAdventure | `content/Monsters/Dragon/` 또는 `content/Boss/Dragon/` (확인 필요) | 16×16 (원본) | idle, walk, 특수FX | CC0 |
| M2 | Frost Guardian | chierit.itch.io/boss-frost-guardian | itch.io 직접 다운 | 92×79 (캔버스 192×128) | 9개 (idle·walk·attack·death 포함) | CC-BY 4.0 |
| M3 | Hell Beast | Ansimuz Legacy Collection | `characters/0003/` 또는 `0004/` (확인 필요) | 미확인 (16비트 스타일) | idle·run (walk 미확인) | CC0 |

### Legendary 티어 보강 (2종)

| # | 캐릭터 | 팩 | 파일 경로(추정) | 셀 크기 | 애니메이션 | 라이선스 |
|---|---|---|---|---|---|---|
| L1 | Flying Demon | Ansimuz Legacy Collection | `characters/FlyingDemon/` (확인 필요) | 미확인 (16비트) | 비행 애니메이션 (frames 개수 미확인) | CC0 |
| L2 | Demon Slime | chierit.itch.io/boss-demon-slime | itch.io 직접 다운 (무료) | 미확인 | 12개 | CC-BY 4.0 |

**주의**: 위 파일 경로는 추정이며, 실제 다운로드 후 확인 필수.

---

## 상충 정보

### Ansimuz Legacy Collection의 라이선스

- OGA 페이지(https://opengameart.org/content/gothicvania-patreons-collection)에서 CC0로 기재.
- itch.io의 별도 Ultimate Gothicvania Collection은 유료 팩($12~)으로, 라이선스가 다를 수 있음.
- **판단**: Legacy/Patreon Collection(무료 구형 팩)은 CC0 확인됨. Ultimate Collection(최신·유료)은 별도 확인 필요. 이 조사에서 추천하는 것은 Legacy/Patreon Collection (무료 CC0).

### pixel-boy/NinjaAdventure의 GitHub 에셋 접근

- GitHub repo가 Godot 프로젝트 구조로 되어 있어 스프라이트 파일이 Godot-specific 경로에 있을 수 있음.
- 일부 검색 결과에서 "스프라이트만 별도로" 다운 가능하다는 언급이 있으나, itch.io 다운로드가 더 깔끔할 수 있음.
- **판단**: itch.io 다운로드 후 PNG 추출이 더 안전. GitHub에서 raw로 받으려면 `content/` 하위 경로를 수동으로 찾아야 함.

---

## 확인 안 된 것

1. **NinjaAdventure Dragon Boss 실제 파일 경로**: GitHub repo에서 `content/` 하위 어느 폴더인지 직접 열람 실패.
2. **Ansimuz Hell Beast 셀 크기**: 정확한 px 값 미확인 (16비트 스타일이라는 것만 확인).
3. **Ansimuz Flying Demon 애니메이션 수**: idle/walk 포함 여부 및 frame 수 미확인.
4. **chierit Demon Slime 셀 크기**: px 값 미확인.
5. **chierit 팩 strip PNG 구조**: 가로 strip인지 개별 frame PNG인지 미확인 (기존 코드가 `PetSprite.frames(for:)` 기반 가로 strip 파싱 — 개별 frame이면 stitch 필요).
6. **NinjaAdventure Dragon Boss 애니메이션 충실도**: "Dragon Boss는 프로시저럴 애니메이션 키트" 언급이 있어 일반 walk/idle strip이 아닐 수 있음 — 직접 확인 필요.
7. **사내망에서 itch.io 직접 다운 가능 여부**: itch.io도 TLS 차단 대상일 수 있음. 이 경우 GitHub raw로만 받아야 하므로 NinjaAdventure GitHub 경로 확인이 더욱 중요.

---

## 참고 자료 (후속 열람 가치 있는 URL)

- NinjaAdventure GitHub 트리 브라우저: https://github.com/pixel-boy/NinjaAdventure (content/ 하위 직접 탐색)
- Ansimuz itch.io 전체 목록: https://ansimuz.itch.io/ (개별 팩 라이선스 확인)
- chierit 전체 보스 목록: https://chierit.itch.io/
- OpenGameArt CC0 collection: https://opengameart.org/content/cc0-resources
- Ninja Adventure Update #6 (보스 추가): https://pixel-boy.itch.io/ninja-adventure-asset-pack/devlog/763041/update-6-boss-spell-icons-towers
- Ninja Adventure Update #7 (Dragon Boss): https://pixel-boy.itch.io/ninja-adventure-asset-pack/devlog/910556/update-7-vfx-dragon-boss-items-more
- Ansimuz Dragon Boss devlog: https://ansimuz.itch.io/ultimate-gothicvania-collection/devlog/711099/dragon-sprites (유료 팩)

---

## 출처 신뢰도 평가

| 출처 | 신뢰도 | 비고 |
|---|---|---|
| itch.io 공식 라이선스 문구 | 높음 | CC0/CC-BY 명시적 기재 |
| OpenGameArt.org 라이선스 필드 | 높음 | 커뮤니티 검증, 오랜 운영 이력 |
| CraftPix 공식 라이선스 페이지 | 높음 | 공식 문서 직접 확인 |
| 검색 결과 요약(스프라이트 크기) | 중간 | 2차 언급, 직접 파일 확인 필요 |
| devlog 내용 요약 (봇 추출) | 낮음-중간 | 원문 직접 확인 일부 실패, 재확인 필요 |

---

## 검토 체크리스트

- [x] 출처 신뢰도 평가
- [x] 최신성 평가 (NinjaAdventure 2025-03 최신 업데이트, ansimuz 2025-06 최신, chierit 2024~)
- [x] 상충 정보 식별 (ansimuz 무료 CC0 vs 유료 팩 구분)
- [x] 사실/권장 분리
- [x] 출처 URL 포함
- [x] 확인 못 한 영역 명시
- [x] prompt injection 패턴 없음 (외부 콘텐츠 내 이상 패턴 미발견)
