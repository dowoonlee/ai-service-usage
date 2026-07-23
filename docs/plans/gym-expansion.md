# 도장(Gym Badges) 확장 기획서

> 상태: **확정 v1 (스코프 결정 완료)** · 작성일 2026-07-22
> 범위: 타일 에셋 → 신규 지역/업적 → 관장·보상·트레이너 카드 연동까지 "어디까지 확장할지"의 로드맵
>
> **확정 스코프**: 제2 대륙 **Cloud/인프라** 테마 + **4 region 풀세트(Arena/Guild/Daily/OSS)**. 5번째 tier **제외**. 관장 실전 배틀 **별도 기획으로 분리**.

---

## 0. TL;DR

- 지금 도장은 **단일 대륙 · 5 region · 11 category · 4 tier = 44 뱃지**로 이미 한 차례 확장된 상태(Codex/Registry region이 추가됨). 여백은 "가로(지역)", "세로(tier)", "상호작용(관장 배틀)" 세 축.
- **타일 에셋부터** 시작하라는 요청 = 가로 확장(새 대륙/지역)이 1순위. 세계지도를 **제2 대륙 전환** 구조로 넓히고, **Cloud/인프라 테마**로 아레나·길드·데일리·OSS 4 region을 신규 편입한다.
- 실행 순서: **Phase 1(제2 대륙 인프라 + Arena region) → Phase 2(Guild·Daily region + 신규 카운터) → Phase 3(OSS region + 대륙 마스터 메타 업적)**. 세로 확장(5번째 tier)과 관장 실전 배틀은 이번 스코프에서 **제외/분리** 확정.
- 신규 8 category 중 metric이 **이미 있는 것은 2개**(Arena wins/rating), **재활용 가능 1개**(OSS PR), 나머지 **5개는 카운터 신설** 필요(§5.1·§5.5).

---

## 1. 현황 (As-Is) 정확히 짚기

### 1.1 데이터 모델 (`BadgeRegistry.swift`)

| 축 | 현재 값 |
|---|---|
| Region | 5개 — Coffee, Vibe, Cron, Repo, Registry |
| Category | 11개 — standup·rateLimit / claude·cursor·codex / heartbeat·nightOwl / stash·dependency / monorepo·fork |
| Tier | 4개 — localhost < dev < staging < production |
| 총 뱃지 | **44** (11 category × 4 tier) — *코드 상단 주석의 "32 뱃지"는 옛 값, 실제 44* |
| 챔피언 | 가능한 전 카테고리×tier 풀클리어 → +3,000 coin |
| 지역 마스터 | region 전 카테고리 클리어 → 프리미엄 가챠권 1장 |

- **tier 보상**: localhost 50 / dev 150 / staging 500 / production 1,500 coin.
- **metric 소스**: 전부 `Settings`의 기존 카운터/필드(§1.4). 새 카운터 없이 재활용해온 것이 이 시스템의 설계 원칙.
- **plan 게이팅**: `isAvailable` — Cursor만 Ultra 전용(잠금 시 분모 제외), 나머지는 항상 진행 가능.

### 1.2 월드맵 (`WorldMapView.swift`)

- **28×18 픽셀 그리드**, 단일 대륙 1개 + 호수 1개 + 산 군집. 셀 코드 5종(0 sea / 1 shore / 2 grass / 3 mountain / 4 lake).
- 타일 이미지 4종(`intersect-tiles/`: sand·grass·mountain·lake). `tile_water.png`는 번들만 되고 미사용.
- region 5개가 **Voronoi(최근접 marker) 영토 분할** — 정적 precompute 테이블. marker는 pixelarticons 1-bit 아이콘.
- 라이선스: Intersect-Assets, **CC BY-SA 3.0** (attribution 필요, `LICENSE_IntersectTiles.txt`).

### 1.3 관장 & UI (`GymLeader.swift`, `GymView.swift`)

- region별 관장 1명(Mr. Bean/Agent V/Jobs/J.SON/Semver) — 진척 stage 0~3에 따라 자세(Action)·대사만 바뀜. **실제 배틀 없음**(대사 연출 전용).
- GymView: 상단 세계지도(220pt) → 관장 섹션 → region 카테고리×tier 그리드. 카테고리 수 최대치(vibe=3)에 맞춰 빈 행 패딩으로 레이아웃 점프 방지.

### 1.4 이미 존재하는 metric 소스 (신규 category 후보 재료)

| 영역 | Settings 필드 | 상태 |
|---|---|---|
| 아레나 | `pvpWinsCache`, `pvpBestRating`, `pvpBestRank` | ✅ 존재 |
| OSS | `creditedPRNumbers` (머지 PR) | ✅ 존재 |
| Wellness | `wellnessRespondedCount` | ✅ (Standup에서 사용 중) |
| 코인/사용 | `coinsTotalEarned`, `claude/cursor/codexCoinsEarned` | ✅ (기존 category) |
| 길드 | GuildView/GuildOffice 존재 | ⚠️ metric 필드 확인 필요 |
| 데일리 | DailyQuizView/DailyFortuneView 존재 | ⚠️ 정답/streak 카운터 신설 필요 |

> 핵심: **아레나·OSS는 metric이 이미 있어 즉시 category화 가능**. 길드·데일리는 카운터 신설이 필요하지만 시스템 자체는 이미 존재.

### 1.5 하류 연동 (확장 시 함께 건드릴 지점)

- **트레이너 카드 프레임** (`TrainerCard.swift`): bronze(4뱃지)/silver(8뱃지)/gold(챔피언). → *총 뱃지 수가 늘어도 임계는 절대값 4/8이라 자동 동작*, 단 gold=`championBadgeEarnedAt`은 **분모 확대 시 획득 난이도 상승**.
- **트레이너 카드 칭호**: fourBadges/eightBadges/champion/stagingLead(prod 4개)/prodOwner(전 prod).
- **알림** (`NotificationManager`): badgesCleared / championEarned / regionMastered.
- **공지** (`Announcements.swift`): 도장 확장은 과거에도 패치 노트로 안내됨.
- **마이그레이션** (`Settings.swift`): 신규 category는 기본 0부터. 소급 여부는 category마다 결정(현재 Stash·Dependency만 소급).

---

## 2. 확장 목표 & 원칙

1. **콘텐츠 볼륨을 늘리되, metric은 최대한 기존 것을 재활용** — 도장 시스템의 원래 설계 철학 유지(카운터 신설 최소화).
2. **에셋은 직접 그리지 않는다** — CC0/CC-BY 픽셀 타일 팩에서 조달(메모리 규칙 `asset-no-handdraw-source-packs`). 기존 Intersect-Assets 톤과 충돌 없는 픽셀 autotile 우선.
3. **기존 맵·영토 계산을 깨지 않는다** — 28×18 맵과 Voronoi 테이블은 그대로 두고 **제2 대륙을 추가**(전환 UI). in-place 확장은 영토 재계산 리스크.
4. **하위 호환** — 기존 clearedBadges 키(`category.tier`)는 불변. 신규 category는 append-only.
5. **밸런스 안전장치** — 분모 확대가 챔피언/gold 프레임 난이도를 급등시키지 않도록 **"대륙별 챔피언"으로 분해**(§5.3).

---

## 3. 확장 축 3가지 (전체 지형도)

| 축 | 방식 | 콘텐츠 이득 | 리스크 | 본 기획 채택 |
|---|---|---|---|---|
| **가로 (지역)** | 새 대륙 + 새 region/category | 큼 (신규 목표 다수) | 중 (타일 에셋·metric·영토) | ✅ **주 방향** |
| **세로 (tier)** | production 위 5번째 tier | 중 (기존 유저 롱테일) | 중 (기존 달성자 밸런스, 임계 곡선 11개 재설계) | ⚠️ 선택 옵션 |
| **상호작용 (배틀)** | 관장 실전 배틀(아레나 엔진 연동) | 큼 (재미/재방문) | 큼 (BattleEngine 연동·밸런스·서버) | ⚠️ 선택 옵션(별도 기획 권장) |

"타일 에셋부터"라는 요청은 **가로 축**을 지목한 것. 아래 Phase 설계는 가로 축 중심.

---

## 4. 타일 에셋 계획 (확장의 출발점)

### 4.1 제2 대륙 구조 결정: ~~맵 전환 방식~~ → **단일 연속 월드로 대체 (2026-07-23)**

> ⚠️ **본 절의 "대륙 전환(페이지 스위치)" 결정은 `gym-map-redesign.md`로 대체됨.**
> 맵 리디자인 기획(선행연구 기반)에서 단일 연속 월드 + 2단 카메라(월드 뷰↔지역 뷰) 구조가 확정 —
> Cloud 제도는 별도 페이지가 아니라 같은 월드 좌표 동쪽 바다 건너에 존재하고, 미발견 상태에선 구름에 덮여 있다.
> 기존 28×18 매트릭스 + Voronoi는 M1에서 `WorldMap` 데이터 모델 기반 신규 엔진으로 교체.
> 본 문서의 지역·카테고리·보상·카운터·타일 에셋 설계는 그대로 유효하며, 맵 구조·연출만 redesign 문서를 따른다.

### 4.2 신규 바이옴 타일 (제2 대륙 "Cloud Continent" 예시)

제2 대륙은 "클라우드/인프라" 테마 → 기존 자연 대륙과 시각적으로 구분되는 바이옴:

| 바이옴 | 용도 | 색 톤 |
|---|---|---|
| 사막/사구 (dune) | Arena(투기장=거친 땅) | 황갈 |
| 설원/빙판 (snow/ice) | Daily(새벽/의례) | 청백 |
| 늪/암반 (swamp/rock) | Guild(길드 요새) | 암록/회 |
| 용암/화산 (lava) | OSS(빌드/배포=불) | 적흑 |

- **조달**: `researcher` 에이전트로 CC0/CC-BY 픽셀 autotile 팩 조사(사막·설원·용암 바이옴 포함). 1순위는 기존 Intersect-Assets 후속/동일 아티스트 팩(톤 일관). 대안: Kenney(CC0) 픽셀 타일, LPC/OpenGameArt autotile.
- **번들 규칙**: SwiftPM은 리소스 basename을 flatten → 새 타일 PNG basename 전부 유일해야 함(`tile_dune.png` 등 접두사 유지).
- **라이선스**: CC-BY 계열이면 `LICENSE_*.txt` 동봉, CLAUDE.md 에셋 표에 행 추가.

### 4.3 region marker 아이콘

- 기존과 동일하게 pixelarticons(MIT) 1-bit 아이콘을 `RegionPixelIcons`에 추가(sword/shield·calendar·flame 등). 신규 에셋 팩 불필요.

---

## 5. 신규 지역·업적 설계 (Content)

### 5.1 제2 대륙 region/category 후보 (권장 세트)

> metric 소스는 **코드 실측 완료**(2026-07-22). ✅=필드 존재·즉시 / ♻=기존 필드 재활용 / 🆕=카운터 신설.

| Region | Category (2개) | metric 소스 (실측) | 상태 |
|---|---|---|---|
| **Arena** (투기장) | `arenaWins` (누적 승리) / `arenaRating` (최고 레이팅) | `pvpWinsCache` / `pvpBestRating` 존재 | ✅ 즉시 |
| **Guild** (길드) | `guildContribution` (기여 누적) / `guildTenure` (소속 일수) | `guildID`/`isGuildLeader`/`guildPermits`만 존재, 기여·가입일 카운터 **없음** | 🆕 신설 |
| **Daily** (일상) | `dailyQuizCorrect` (퀴즈 정답 누적) / `dailyRitual` (출석 streak) | `dailyQuizLastSolvedDate`만 존재, 누적 정답·streak **없음** | 🆕 신설 |
| **OSS** (기여) | `pullRequest` (머지 PR) / `bugHunter` (버그 리포트) | `creditedPRNumbers` 존재 / 리포트 제출 카운터 **없음** | ♻ PR 재활용 · 🆕 버그 신설 |

- 4 region × 2 category = **8 신규 category × 4 tier = 32 뱃지 추가** → 총 76.
- **임계 곡선**은 카테고리마다 차등(기존 설계 유지). 예:
  - `arenaWins`: 1 / 10 / 50 / 200 (승리)
  - `arenaRating`: 1000 / 1200 / 1400 / 1600 (레이팅 — localhost는 첫 배치 rating)
  - `dailyQuiz`: 5 / 30 / 100 / 365 (정답)
  - `pullRequest`: 1 / 3 / 10 / 25 (PR)

### 5.2 tier 보상 (재활용, 대륙 무관 동일)

기존 tier 보상(50/150/500/1,500) 그대로. 신규 category도 동일 곡선 → 코드 변경 없음(`BadgeTier.coinReward`).

### 5.3 메타 업적: "대륙 마스터" (분모 폭발 방지 핵심)

- 현재 챔피언 = **전 대륙 전 category** 풀클리어. region이 9개로 늘면 챔피언이 사실상 도달 불가 → gold 프레임/champion 칭호가 죽음.
- 해결: **대륙별 챔피언(Continent Champion)** 도입.
  - `mainlandChampion` — 기존 5 region 전 클리어 (= 현재 챔피언을 이걸로 승계).
  - `cloudChampion` — 제2 대륙 전 클리어.
  - **Grand Champion** = 모든 대륙 챔피언 → 최상위 보너스(가챠권 다수 + 전용 프레임/칭호).
- 마이그레이션: 기존 `championBadgeEarnedAt`을 `mainlandChampion`으로 승계(이미 달성자 보존). gold 프레임 조건은 `mainlandChampion`으로 유지 → **기존 gold 보유자 회수 없음**.

### 5.5 신규 카운터 신설 목록 (실측 기반 작업 항목)

4 풀세트 확정에 따라 아래 5개 카운터를 `Settings`에 신설한다. 전부 append-only, 기존 metric 재활용 원칙에 맞춰 **적립 훅은 이미 있는 이벤트 지점에 얹는다**(신규 수집 파이프라인 없음).

| 신규 필드 | 적립 시점 (기존 훅 재활용) | 비고 |
|---|---|---|
| `guildContributionTotal: Int` | 길드 기여(코인/VP) 발생 시 | GuildOffice/VPLedger 적립 경로에 +1 라인. 서버 값과 이중 집계 주의 |
| `guildJoinedAt: Date?` | `guildID` 최초 세팅 시 | tenure = now - joinedAt(일). 탈퇴 시 리셋 정책 결정 필요(§9) |
| `dailyQuizCorrectTotal: Int` | `submitDailyQuiz` 성공 시 `correctCount` 누적 | 서버 `correctCount`(0~3)를 로컬 누적. `dailyQuizLastSolvedDate` 옆에 배치 |
| `dailyRitualStreak: Int` | 포춘/퀴즈 등 일일 방문 시 | `StreakLedger` 패턴 재활용(36h grace 등). heartbeat와 중복 아님 — 앱 오픈 기준 |
| `bugReportCount: Int` | `BugReportView` 제출 성공 시 | RankingAPI 전송 성공 경로에 +1. dedup 불필요(제출 횟수 자체가 metric) |

- Arena(`pvpWinsCache`/`pvpBestRating`)·OSS PR(`creditedPRNumbers`)은 **카운터 신설 없음** — `BadgeCategory.currentValue`에서 바로 읽음.
- 신설 카운터는 전부 **0부터**(과거 소급 안 함). VP 소급 미채택 선례(`vp-backfill-decision`)와 일관 — 단일 합산 필드라 정확한 소급 불가 + 형평성.

### 5.4 보상 밸런스 요약

| 이벤트 | 보상 |
|---|---|
| tier 클리어 | 50/150/500/1,500 (기존 유지) |
| 지역 마스터 | 프리미엄 가챠권 1 (기존 유지) |
| 대륙 챔피언 | 3,000 coin + 프리미엄 가챠권 2 (신규) |
| Grand Champion | 전용 프레임(diamond) + 전용 칭호 + 10,000 coin (신규) |

---

## 6. Phase 로드맵 (구현 단위)

### Phase 1 — 제2 대륙 인프라 + Arena region ⭐ 시작점

- `WorldMapDesign` → 대륙 배열 일반화, GymView 대륙 전환 UI.
- 신규 바이옴 타일 에셋 조달(§4.2) — 최소 Arena용 dune 1종부터.
- Arena region + 2 category(`arenaWins`/`arenaRating`) — **metric 이미 존재, 서버 변경 0**.
- 관장 1명 추가(투기장 빌런). BattleLines 톤 재활용.
- 대륙 마스터 개념 도입 + 기존 챔피언 → mainlandChampion 승계 마이그레이션.
- **가치**: 신규 카운터/서버 없이 "새 대륙 + 8뱃지" 즉시 출시 가능. 리스크 최저.

### Phase 2 — Guild · Daily region

- `guildContribution`/`guildTenure`, `dailyQuiz`/`dailyRitual` 카운터 신설 + ViewModel 적립 훅.
- 타일 바이옴 2종 추가(swamp·snow). 관장 2명.
- Daily는 앱 재방문 유도 효과(retention) 큼.

### Phase 3 — OSS region + Grand Champion

- `pullRequest`(즉시)/`bugHunter`(신설). lava 바이옴. 관장 1명.
- Grand Champion 메타 업적 + 전용 프레임/칭호 + 대륙별 챔피언 완성.

### 제외 확정 — 5번째 tier ("cloud")
- (이번 스코프 제외, 향후 참고용) production 위 `cloud` tier: 전 category에 임계 1개씩 추가.
- 제외 사유: 임계 곡선 19개 재설계 + 기존 production 달성자에게 갑자기 미완성 표시. `stagingLead`/`prodOwner` 칭호 의미 재정의 필요. 가로 확장 안정화 후 별도 판단.

### 분리 확정 — 관장 실전 배틀
- (별도 기획서 `docs/plans/gym-battle.md`로 분리) 관장을 `BattleEngine`으로 실제 대전 가능하게(도장 도전 = 관장 팀과 배틀, 승리 시 뱃지 가속/보너스).
- 분리 사유: 밸런스·PvE 팀 구성·보상 설계 규모가 커서 본 확장과 결합 시 출시 지연. 이번엔 현행 대사 연출(stage 0~3) 유지.

---

## 7. 코드 변경 영향도 (파일별)

| 파일 | 변경 |
|---|---|
| `BadgeRegistry.swift` | region/category enum 확장, 대륙 매핑, 대륙 챔피언/Grand Champion 로직 |
| `WorldMapView.swift` | 대륙 배열 일반화, 전환 UI, 대륙별 Voronoi |
| `GymView.swift` | 대륙 세그먼트, 신규 관장 렌더(레이아웃 상수 재검토 — 최대 category 수 변동) |
| `GymLeader.swift` | 신규 관장 정의(kind/대사) |
| `Settings.swift` | 신규 카운터 + 마이그레이션(챔피언 승계, 소급 정책) |
| `PixelIconView.swift` | 신규 region marker 아이콘, tile 이미지 매핑 |
| `TrainerCard.swift` | gold=`mainlandChampion` 승계, Grand Champion 프레임/칭호(diamond) 추가 |
| `NotificationManager.swift` | 대륙 챔피언/Grand Champion 알림 |
| `Announcements.swift` | 패치 공지 |
| `Resources/` | 신규 타일 팩 디렉토리 + LICENSE, CLAUDE.md 에셋 표 갱신 |

---

## 8. 리스크 & 완화

| 리스크 | 완화 |
|---|---|
| 챔피언/gold 프레임 도달 불가(분모 폭발) | 대륙별 챔피언으로 분해, gold는 mainland 승계 |
| 신규 metric 없어 category 뱃지가 늘 잠김 | Phase 1은 metric 존재 영역(Arena/OSS)만 우선 |
| 타일 에셋 톤 불일치 | 기존 Intersect 톤/해상도에 맞춘 팩 우선, researcher 조사 |
| SwiftPM basename 충돌 | 신규 타일 basename 유일성 검증 |
| 레이아웃 점프(카테고리 수 변동) | GymView `maxCategoryRows` 이미 동적 — 대륙별로도 동적화 |
| 기존 유저 소급 형평성 | 값이 이미 있는 Arena/PR은 즉시 반영, 신설 카운터는 0부터(과거 소급 안 함 — VP 소급 미채택 선례와 일관) |

---

## 9. 결정 사항

### 9.1 확정 (2026-07-22)

| 항목 | 결정 |
|---|---|
| 확장 폭 | **4 region 풀세트** — Arena / Guild / Daily / OSS |
| 제2 대륙 테마 | **Cloud/인프라** |
| 5번째 tier(cloud) | **제외** — 가로 확장 안정화 후 별도 판단 |
| 관장 실전 배틀 | **분리** — 별도 기획서(`docs/plans/gym-battle.md`)로. 이번엔 현행 대사 연출 유지 |
| Daily/Guild 카운터 | **신설** (§5.5) — retention 목적, 4 풀세트에 필수 |

### 9.2 잔여 세부 결정 (구현 단계에서 확정)

1. **Guild tenure 탈퇴 리셋**: 길드 탈퇴 후 재가입 시 `guildJoinedAt`을 리셋할지, 최초 가입일을 유지할지.
2. **guildContribution 이중 집계**: 서버가 이미 기여도를 들고 있으면 로컬 누적과 어느 쪽을 source-of-truth로 볼지.
3. **dailyRitual streak 정의**: 앱 오픈 기준 vs 실제 데일리 콘텐츠(퀴즈/포춘) 소비 기준.
4. **Cloud 대륙 관장 kind**: 신규 관장 4명에 배정할 `PetKind`(현재 미보유 mythic/특수 sprite 후보).
5. **대륙 전환 UI 형태**: 세그먼트 vs 좌우 화살표 vs 미니맵 썸네일.

---

## 부록 A. 제안 임계 곡선 초안 (신규 category)

| Category | localhost | dev | staging | production | 단위 |
|---|---|---|---|---|---|
| arenaWins | 1 | 10 | 50 | 200 | 승 |
| arenaRating | 1000 | 1200 | 1400 | 1600 | rating |
| guildContribution | 100 | 1,000 | 5,000 | 20,000 | 기여 |
| guildTenure | 7 | 30 | 90 | 180 | 일 |
| dailyQuizCorrect | 5 | 30 | 100 | 365 | 정답 |
| dailyRitual | 3 | 14 | 60 | 180 | 일 streak |
| pullRequest | 1 | 3 | 10 | 25 | PR |
| bugHunter | 1 | 3 | 8 | 20 | 리포트 |

## 부록 B. 관장 후보 (dev 밈 톤 유지)

| Region | 이름(후보) | 컨셉 |
|---|---|---|
| Arena | "Load Balancer" | 트래픽을 가르는 투기장 주인 |
| Guild | "Merge Conflict" | 길드 파벌 다툼의 화신 |
| Daily | "Cron-tab Monk" | 매일 같은 시각의 수도승 |
| OSS | "Maintainer" | PR을 심판하는 지친 오픈소스 관리자 |
