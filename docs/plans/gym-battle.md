# 관장 실전 배틀 기획서

> 상태: **확정 v1 (2026-07-23)** — 게이트 방식 · 진행 스케일 난이도 · 파티 재활용 · 애니메이션 재생 · clearedBadges 전체 초기화.
> 관계: `gym-map-redesign.md`에서 분리. 도장(Gym) + 아레나(BattleEngine) 접합. **도장 뱃지 획득 흐름을 근본적으로 바꾼다.**
> 전제: 기존 `BattleEngine.simulate`가 순수 결정론 PvE라 그대로 재활용. 신규 배틀 엔진 없음.

## ⚠️ 핵심 변경 — 게이트 방식 (2026-07-23 확정)

기존: metric이 tier 임계를 넘으면 **자동으로** 그 tier 뱃지 클리어 + 코인.
변경: metric이 tier 임계를 넘으면 그 tier **관장 배틀 "자격"만** 열린다. **배틀을 이겨야** 그 tier 뱃지를 획득한다.

- **초기화**: 기존 자동 획득한 `clearedBadges` **전체**를 리셋 → 이제 전부 배틀로 재획득. (creditedBadgeRewards 유지로 코인 재지급은 막음)
- **난이도**: 지역 진행 스케일 — 높은 tier일수록 관장 팀이 강함.
- **내 팀**: 기존 파티(PvP 팀) 재활용.
- **재생**: 처음부터 애니메이션 재생(ArenaView `battleStage` 공유 분리).

---

## 0. TL;DR

- 지금 관장(GymLeader)은 **대사만** 한다(진척 stage 0~3에 따라 자세/대사 변화). 실전 배틀이 없어 "도전"의 실체가 없다.
- `BattleEngine.simulate(teamA:teamB:seed:)`는 두 팀 스냅샷 + seed → `BattleResult`(승자·재생 로그)를 내는 순수 함수. **관장 배틀 = 내 팀(teamA) vs 관장 팀(teamB)** 로 바로 성립.
- 배틀 **재생 뷰**(`ArenaView.battleStage`)도 이미 있어, 관장 배틀 전용 재생만 얹으면 된다.
- 관장 격파는 **뱃지(metric 기반)와 분리된 트랙** — 격파 시 코인+프리미엄 가챠권+격파 칭호. 뱃지 진행을 배틀로 조작하지 않는다(수동 지표 원칙 유지).
- 재도전은 **무제한(연습)**, 보상은 **첫 격파 1회**.

---

## 1. 배경 / 목표

- 도장 페이지의 관장 섹션은 진척도에 따라 대사만 바뀐다(`GymView.gymLeaderSection`). "관장을 이긴다"는 상호작용이 없다.
- 목표: 각 도장에서 그 지역 **관장과 실제 배틀**을 하고, 이기면 그 지역을 "정복"한 실감 + 보상을 얻는다.
- 안티-골: 배틀 승패로 **뱃지 metric을 조작하지 않는다**(뱃지는 사용량/활동의 부산물이라는 원칙 유지). 배틀은 별도 도전 트랙.

## 2. BattleEngine 재활용

| 요소 | 재활용 |
|---|---|
| 시뮬레이션 | `BattleEngine.simulate(teamA:teamB:seed:) -> BattleResult` — 로컬, 서버 불필요 |
| 팀 | `BattleTeam([BattlePetSnapshot])` — 최대 5마리, `members[0]` 선봉 |
| 스냅샷 | `BattlePetSnapshot(kind, variant, enhanceLevel, progressUnits)` |
| 재생 뷰 | `ArenaView.battleStage` + `playbackStep` 로직 (HP/차지/효과 재구성) |
| seed | 결정론 — 관장별 고정 seed 또는 도전 회차 기반 |

아레나(PvP)는 서버 매칭이지만, 관장 배틀은 **완전 로컬**(관장 팀이 NPC 상수)이라 서버 의존 0.

## 3. 관장 팀 설계

- 관장 9명(본토 5 + 제도 4) 각각 **팀 5마리**: 관장 kind가 선봉 + 지역 테마 펫 4.
- 스냅샷 파라미터로 **난이도**를 표현:
  - `variant`(0~4, 이로치일수록 강함) · `enhanceLevel`(강화) · `progressUnits`(스탯 스케일)
- 난이도 후보:
  - **(A) 고정 난이도** — 관장별 정해진 팀(항상 동일). 단순·예측 가능.
  - **(B) 진행 스케일** — 그 지역 뱃지 진행(0~8)에 비례해 관장이 강해짐(stage처럼). "성장하는 라이벌".
- 관장 팀 정의는 `GymLeader`에 `team: [BattlePetSnapshot]` 추가(렌더 metadata와 분리, `PetTraits` 패턴).

예시(초안):
| 관장 | 지역 | 선봉 | 팀 컨셉 |
|---|---|---|---|
| Mr. Bean | coffee | ghost | 카페의 유령들(저속·지구력) |
| Agent V | vibe | bigDemon | 에이전트 군단(스킬 연계) |
| Load Balancer | arena | ogre | 거구 탱커 편성 |
| Maintainer | oss | wizardM | 마법사·원거리 딜 |
| … | | | |

## 4. 도전 흐름

1. **진입**: `GymView` 관장 섹션에 "도전" 버튼(또는 관장 클릭).
2. **팀 확인**: 내 팀 = 기존 **파티**(PartyView/아레나 팀 구성) 재활용. 없으면 트레이너 대표 + 보유 상위 펫 자동 편성.
3. **배틀**: `simulate(내 팀, 관장 팀, seed)` → `BattleResult`.
4. **재생**: 배틀 재생 뷰(`battleStage` 재활용)로 애니메이션 재생.
5. **결과**: 승/패 + 보상(첫 격파 시).

## 5. 보상 (뱃지와 분리된 도전 트랙)

| 이벤트 | 보상 |
|---|---|
| 관장 **첫 격파** | 코인 + 프리미엄 가챠권 1 (또는 코인만) — 결정 필요 |
| 9관장 전원 격파 | "그랜드 마스터" 칭호 + 보너스 |
| 재도전 승리 | 보상 없음(연습). 격파 기록만 유지 |

- 격파 기록: `Settings.defeatedLeaders: Set<String>`(region rawValue). dedup으로 보상 1회.
- 트레이너 카드/칭호 연동: "XX 격파" 칭호 또는 카드 표식. (기존 CardTitle 패턴 재활용)
- **뱃지/지역 마스터와 무관** — 관장 격파는 배틀 트랙, 지역 마스터는 metric 트랙. 단, 맵에서 격파한 관장 마을에 표식(깃발/트로피)을 얹는 연동은 선택.

## 6. 재도전 정책

- **무제한**(연습용). 보상은 첫 격파 1회.
- 쿨다운/횟수 제한 없음(로컬 배틀이라 서버 부하 0, 어뷰징 무의미 — 보상 1회라).

## 7. UI

- **진입**: GymView 관장 섹션 "도전" 버튼.
- **배틀 재생**: `ArenaView.battleStage` 재활용 — 단, ArenaView는 PvP 서버/랭킹 로직이 얽혀 있어, **재생 뷰만 추출**하거나 관장 배틀 전용 `GymBattleView`에서 `battleStage` 상당 로직을 공유.
- **결과 오버레이**: 승/패 + 보상.
- 최소 신규: `GymBattleView`(팀 확인 → simulate → 재생 → 결과). battleStage 렌더는 ArenaView에서 공유 컴포넌트로 분리.

## 8. 영속(Settings)

- `defeatedLeaders: Set<String>` — 격파한 region(dedup 보상).
- (선택) `leaderBattleCount: [String: Int]` — 도전 횟수(통계).

## 9. Phase

| Phase | 내용 | 상태 |
|---|---|---|
| **P1 — 게이트 로직** | BadgeRegistry `challengeableTier`/`defeatLeader`/`evaluateDerived` + Settings `hasResetBadgesForBattle` 초기화 | ✅ 완료 |
| **P2 — 코어+재생** | `GymLeader.team(tier:)` (9관장 진행 스케일) + `GymBattleView`(파티 vs 관장 → simulate → 공유 재생 → 결과 카드) + GymView 도전 버튼(게이트 연동) | ✅ 완료 |
| **P3 — 연동** | 격파 칭호(cloud/grandChampion) + Grandmaster 프레임 + 맵 마을 페넌트 + 헤더 챔피언 연출 | ✅ 완료 |

### P3 구현 (2026-07-24)

- **칭호/카드 표식**: `CardTitle`에 `cloudChampion`("클라우드 챔피언")·`grandChampion`("그랜드 챔피언") 추가
  (unlock = `cloudChampionAt`/`grandChampionAt`). `CardFrame`에 최상위 `grandmaster`(프리즘 아쿠아, glow,
  unlock = `grandChampionAt`) 추가 — `hasGlow` 도입해 sparkle과 동급 연출. `champion` 칭호는 "본토 챔피언"으로 명칭 정리.
- **맵 마을 트로피**: `WorldMapView` 건물 렌더에 페넌트(깃대+삼각 깃발) — 관장을 한 번이라도 격파
  (`townProgress.cleared > 0`)했지만 아직 마스터(전 tier) 전이면 표시. 마스터 시 왕관으로 승격(기존).
- **챔피언 연출**: `GymView` 헤더가 그랜드 챔피언이면 아쿠아 "그랜드 챔피언" 라벨+glow, 아니면 본토(gold)/
  클라우드(cyan) 왕관을 대륙별로 표시. (전원 격파 보너스 코인/티켓은 #189 `evaluateDerived`에 이미 배선됨.)

### 구현 노트 (2026-07-23)

- **공유 재생 컴포넌트 추출**: `ArenaView.battleStage`(+파티행·컨트롤·연출 상태·재생 드라이버)를 신규
  `BattleReplayView.swift`로 전량 이관. ArenaView는 `result`/팀 스냅샷만 소유하고 재생 UI는 위임(랭크전
  결과 카드는 `resultExtra`로 주입). 도장 관장 배틀도 **동일 코드**로 재생 → 아레나와 100% 동일 연출.
  재생은 `result` 변화 감지로 자동 시작(startPlayback/stopPlayback 호출부 제거).
- **강화 반영(2026-07-23 결정)**: gym 배틀은 내 **실제 강화 레벨**로 싸운다(내 480 전투력 전사가 gym에서도
  480). `GymBattleView.loadEnhanceLevels()`가 아레나 `loadEnhanceState`와 동일 경로로 서버에서 강화 레벨을
  로드(랭킹 유저) → 내 팀 스냅샷에 `enhanceLevel` 반영. 랭킹 미등록(=강화 불가) 유저는 강화 0(진짜 상태),
  컬렉션(이로치·시너지·레어도)으로 승부. 로드 실패해도 강화 0으로 진행(배틀 계속).
- **난이도 (EP-타겟 설계)**: 배틀은 데미지가 atk/def **비율식**이라 승패가 팀 전투력 비의 대략 **세제곱**에
  좌우된다([[arena-balance-snowball]]) → 미세 튜닝 무의미, **절대 전투력을 내 팀 밴드에 놓는 것**이 핵심.
  앱 표시 **전투력 ≈ EP × 4.6** (EP = base × growth × 이로치; ×4.6 = archetype 합, hp 1.5배 포함).
  - **해법**: 서포터는 전부 **common(base40)**, 각 펫을 **"목표 EP"에 맞춰 강화 레벨을 개별 역산**
    (레어도·이로치 보정). `GymLeader.targetEP(tier)` = localhost 50 / dev 68 / staging 88 / production 110
    (≈ 전투력 230 / 313 / 405 / 506). **이 4개 상수만 만지면 전 지역 난이도가 함께 움직인다.**
  - **검증**(엔진 수식 미러, 전투력): localhost 팀평균 ~230 → production ~425(선봉 ~500-517). common 서포터는
    강화 상한(+15)이라 전투력 ~405에서 캡 → 선봉(고레어도)만 더 높아 자연스러운 "보스+졸개". mythic 관장
    (Semver/Monk)만 base 하한 때문에 저 tier에서 조금 셈(엘리트 편차, 해당 지역 metric 게이트도 높음).
  - **팀 시너지 = 테마 살리고 강화에서 상쇄**: 컬렉션이 곧 테마(언데드=wontfix, 데몬=fridayDeploy…)라
    관장팀을 **테마대로 한 컬렉션/타입에 몰아 시너지를 살린다** — 유령카페·언데드·데몬gym은 컬렉션 5-full
    (collMult 1.26), 수호전사단은 warrior 타입×5, 마법사gym은 arcane 타입×5. 그로 인한 collMult를
    `team(tier:)`이 **강화 레벨 역산에서 상쇄**(`target / collMult`)하므로 난이도는 균일. (풀시너지 팀은
    오히려 common으로도 production 도달 가능 — 시너지가 데미지 비율을 올려서.) 타입 시너지(대표 스탯 1개)는
    상쇄 안 하고 "테마 시그니처"로 남긴다(전사gym은 atk↑, 언데드gym은 spd↑).
    - 특성: mythic 선봉(Semver/Monk)은 base 하한 때문에 localhost 보스가 조금 셈(전투력 ~380, 엘리트 편차,
      해당 지역 metric 게이트도 높음). 저시너지 지역은 production 졸개가 캡(전투력 ~430)이라 보스가 커버,
      풀시너지 지역은 졸개도 target 도달(~510) — 둘 다 팀 평균은 target 근처.
  - **보스 엣지**: production 선봉만 레인보우(variant4) — 궁극기·컷인·20% 크리(스탯 벽 아닌 연출).
  - 플레이어 참고 전투력(강화 반영): 캐주얼 rare·강화3 ~257 / 중반 epic·강화6·시너지 ~390 / 투자 epic·강화9
    ~501 / 고래 mythic·강화12·5S ~1009 → production(~506)은 "투자" 팀이라야 잡는 endgame, 고래는 압도.
- **보상 지급 시점**: 시뮬 결과가 승리(=deterministic)이면 즉시 `defeatLeader`로 뱃지·코인 지급 후 재생
  관전(아레나 관례: 결과 확정 → 재생). 재도전 무제한, 재지급은 `creditedBadgeRewards` dedup.
- **미구현**: `defeatedLeaders`/`leaderBattleCount`(별도 통계 트랙 — 뱃지 게이트로 대체돼 불요), P3 연동.

## 10. 결정 필요 (사용자)

1. **난이도**: (A) 고정 vs (B) 지역 진행 스케일(성장 라이벌)
2. **보상**: 첫 격파 = 코인만 vs 코인+프리미엄 가챠권 vs 그 외
3. **내 팀 구성**: 기존 파티(PvP 팀) 재활용 vs 관장 배틀 전용 편성 vs 자동 편성
4. **배틀 재생**: P1에서 결과 텍스트만(빠름) vs 처음부터 애니메이션 재생(battleStage 공유 분리 필요)
5. **맵 연동**: 격파 시 마을에 트로피/깃발 표식 넣을지
