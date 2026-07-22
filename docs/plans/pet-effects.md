# 배틀 효과 레이어 — 상태이상 + 버프 설계

상위: 아레나 배틀(`pet-battle.md`) + 스킬(`pet-skills.md`) 확장. 공격/수비만 있던 배틀에 지속 효과
(상태이상 디버프 + 버프)를 추가. 효과는 **스킬이 부여**한다(버프 스킬 = 자버프, 공격 스킬 = 확률 상태이상).
톤은 개발 + AI 밈 유지. 결정성·클라↔서버 파리티([[arena-battle-parity]]) 필수.

> 결정(사용자 확정): ①DoT/Regen 크기 = **maxHP %**(스탯 무관 균형) ②Control = **확률 스킵 + 고정 N턴 둘 다**
> ③타겟 = **자버프 + 적디버프만**(팀 전체 버프는 일부 궁극기만) ④부여 = **공격 부수효과(확률) + 전용 디버프 스킬 둘 다**
> ⑤효과 슬롯 상한 **4** + 재부여 **refresh**(중첩 안 함) ⑥순서 = **스킬 Phase A 이후 별도 착수**.

## 1. 효과 모델
```
Effect       = { id, kind, magnitude, duration, chance? }
ActiveEffect = { effect, remaining }        // 각 전투원이 리스트(상한 4)로 보유
```
**kind 6종**:
| kind | 동작 |
|---|---|
| DoT | 매 자기 턴 시작 시 HP -= magnitude(% of maxHP) |
| Regen | 매 자기 턴 시작 시 HP += magnitude(% of maxHP) |
| StatMod | 지속 중 atk/def/spd × magnitude (effective stat) |
| Control | 자기 턴 스킵 — 확률형(매 턴 chance) 또는 고정형(duration 동안 무행동) |
| Shield | flat HP 흡수(피해를 실드에서 먼저 차감, 소진 시 제거) |
| Cleanse | 즉시 — 자기 디버프 전부 제거(지속 아님) |

## 2. 효과 카탈로그 (초안 — 밈 톤, 수치는 튜닝 대상)
### 상태이상 (디버프, 적 활성 펫 대상)
| id | 이름 | kind | magnitude | duration | 밈 |
|---|---|---|---|---|---|
| mem_leak | 메모리 릭 | DoT | 5%/턴 | 3 | node_modules가 램 잠식 |
| infinite_loop | 무한 루프 | DoT | 8%/턴 | 3 | CPU 100% |
| deadlock | 데드락 | Control(확률) | 35% 스킵 | 3 | 서로 대기하다 멈춤 |
| rate_limited | 레이트 리밋 | Control(고정) | 무행동 | 2 | 429 Too Many Requests |
| tech_debt | 기술 부채 | StatMod atk | ×0.80 | 3 | 쌓일수록 굼뜸 |
| legacy | 레거시 | StatMod spd | ×0.75 | 3 | 오래된 코드 |

### 버프 (자신 대상)
| id | 이름 | kind | magnitude | duration | 밈 |
|---|---|---|---|---|---|
| optimization | 최적화 | StatMod atk | ×1.25 | 3 | O(n²)→O(n) |
| firewall | 방화벽 | StatMod def | ×1.30 | 3 | |
| caching | 캐싱 | StatMod spd | ×1.25 | 3 | 캐시 히트 |
| load_balancer | 로드 밸런서 | Shield | 20% maxHP | 3 | 트래픽 분산 흡수 |
| autoscaling | 오토스케일링 | Regen | 6%/턴 | 3 | 부하 따라 회복 |
| hot_reload | 핫 리로드 | Cleanse | — | 즉시 | 디버프 리셋 |

## 3. 부여 방식
- **버프 스킬**: 자신에 버프 부여(확정). 데미지 대신/함께(저파워 + 버프).
- **전용 디버프 스킬**: 적에 상태이상 부여(높은/확정 chance, 저파워).
- **공격 스킬 부수효과**: 공격에 `chance`로 상태이상 부여(예: mem_leak 30%) — RNG draw.
- **타겟**: self / enemy active. 팀 전체 버프는 일부 궁극기 한정(스코프 절감).

## 4. 엔진 통합 (ATB)
각 전투원 턴이 오면 순서대로:
1. **효과 틱** — DoT 피해 / Regen 회복(% of maxHP), 모든 ActiveEffect `remaining--`, 0이면 제거.
2. **Control 체크** — 고정형(rate_limited)이면 무조건 스킵; 확률형(deadlock)이면 rng로 스킵 판정.
3. **행동** — 스킵 아니면 스킬 선택·시전.
- **effective stat**: atk/def는 attack 시 활성 StatMod 곱; spd는 ATB 스케줄(cd=speedBase/effSpd) 시 곱.
- **Shield**: 피해 적용 시 실드부터 차감, 남으면 HP.
- 효과 틱/Control/데미지의 RNG·순서 전부 클라↔서버 1:1.

## 5. 스택 규칙
- 같은 효과 재부여 = duration **refresh**(magnitude 중첩 X — 무한 스택 방지).
- 다른 효과는 공존(optimization + firewall 동시). 상충(atk↑ vs atk↓)은 곱해져 상쇄.
- 슬롯 상한 **4**: 초과 부여 시 가장 오래된(remaining 최소 or 부여 순서) 것부터 밀어냄.

## 6. 스킬 선택 AI (효과 반영, 결정적)
우선순위 규칙: **궁극기(충전 시) > 위급 자힐(HP<임계 & 회복/실드 보유) > 버프(미보유 시) > 최대 데미지 공격(부수 상태이상 포함)**. 동점은 슬롯 인덱스. RNG 없이 상태 기반 결정.

## 7. 파리티/데이터
- 효과 카탈로그(id→kind/magnitude/duration/chance) 양측 상수 1:1.
- ActiveEffect 처리(틱·StatMod·Shield·Control) 클라 `BattleEngine` ↔ 서버 `battle_engine` 1:1.
- 어느 스킬이 어떤 효과를 부여하는지 = 스킬 카탈로그(`pet-skills.md`)에 `effect` 필드로. per-kind 고유 효과는 `pet_meta_gen` 경로.
- `BattleEvent` 확장: 효과 이벤트(부여/틱/만료 — id·kind·대상). 구 로그 호환 위해 Optional. 로그·UI(상태 아이콘)에 표시.
- 신규 골든: 효과 배틀(DoT·버프·control) 벡터를 `pvp_engine.parity.test.ts`에 추가(arena-demo 캡처).

## 7.5 궁극기 특수효과 매핑 (설계안 — E2에서 구현)

pet-skills.md의 궁극기 6종에 효과 1개씩. **두 부류**로 나뉜다:
- **히트 변형(즉시)**: 그 한 방의 데미지 계산을 바꿈 — ActiveEffect 불요, E2에서 스킬 `effect` 필드로.
- **지속효과(ActiveEffect)**: §1 프레임 사용 — E1 의존.

| 궁극기 | 타입 | 부류 | 효과 | 밈 근거 |
|---|---|---|---|---|
| `rm_rf` | warrior | 히트 변형 | **방어무시** — def를 ×0.3로 계산 | 루트 권한 삭제에 방어권 없음 |
| `kernel_panic` | beast | 히트 변형 | **광역** — 활성 100% + 후열 전원 30% 스플래시 | 커널 패닉 = 전 프로세스 다운 |
| `context_window_exceeded` | arcane | 히트 변형 | **확정 크리** — 크리 draw는 소비하되 결과 강제 true(RNG 스트림 보존) | 컨텍스트 초과 = 치명적 손실 |
| `total_outage` | chaos | 지속효과 | **Control(고정)** — rate_limited 1턴 부여 | 전면 장애 = 아무것도 못 함 |
| `blue_screen` | machine | 지속효과 | **StatMod spd ×0.6, 2턴** 부여 | 재부팅하는 동안 굼뜸 |
| `full_rollback` | mascot | 지속효과(즉시) | **자힐 maxHP 25%** | 마지막 정상 커밋으로 롤백 |

- 밸런스 가드: 궁극기는 이미 power 24 — 효과가 얹히므로 승률 실측 후 power 하향 여지(§9).
- 광역은 순차 처치 구조에서 후열 HP를 미리 깎음 — hpDicts류 UI 재구성에 다중 대상 이벤트 필요(`BattleEvent` 확장과 함께).

## 8. 페이즈 (스킬 Phase A 이후)
- **E1** ✅(#181) 효과 프레임: 모델·틱·StatMod/DoT/Regen/Shield + effective stat 반영 (no-op — 골든 불변 증명).
- **E2** ✅ 스킬 연동: rider(부수효과) + 궁극기 특수효과(§7.5) + EffectEvent 스트림 + UI fold/태그. **구현 노트 §8.5.**
  Control 확률/고정 스킵도 이때 함께 활성(원안 E3 통합 — outage_stun/deadlock이 rider·궁극기로 이미 부여됨).
- **E3** ✅ collectionShared rider 19종 전량 + 선택 AI 자기버프 우선(§6 축소판) + 미배정 효과 활성화
  (optimization/firewall/caching/hot_reload/rate_limited 전부 rider로 연결). **구현 노트 §8.6.**
- **E4** UI: 전투원 상태 아이콘·스킵 연출·효과 로그 확장. 이후 승률 재실측 → 밸런스 재평가.

## 8.5 구현 노트 (E2 — 파리티·호환 결정)
- **rider 방식**: 효과는 전부 공격 스킬의 부수효과(rider)로 시작 — 선택 AI 무변경(§6 확장은 E3).
  typeShared 6종 + collectionShared happyPath + **unique는 자기 타입 rider 상속**(타입 특성) —
  미상속이면 Epic+가 unique(21)로 ts(16.5)를 항상 지배해 rider가 영영 침묵(실측으로 발견).
- **EffectEvent 스트림**: 효과 이벤트(tick/skip/grant/heal/splash)는 `BattleResult.effectEvents`
  (Optional, log와 **분리**)로 — 구 클라는 미지 필드를 무시하므로 공격 fold가 오염되지 않는다.
  hpDelta는 실적용량(클램프 후) — UI는 판정 없이 더하기만 한다. 스킵 액션은 공격 로그가 없다
  (rounds > log.count 가능).
- **RNG draw 순서 고정**: (controlChance 스킵) → rngFactor → (레인보우 크리) → 패링 → (rider chance).
  rider chance 1.0은 draw 미소비, 적 대상 rider는 막타 기절 시 draw까지 생략. forceCrit은 draw를
  소비하고 결과만 강제(스트림 보존).
- **스플래시**: 별도 BattleEvent 없이 effectEvents로만 기록(재생 스텝 미증가). 피격 충전 +1·기절 승계
  규칙 동일 적용. DoT 자멸도 행동 없이 종료 + 게이지 승계, 공격측 선봉 교체 시 ATB 재스케줄.
- **골든**: PARITYFX1(동타입 5쌍 — 틱/스킵/스플래시/부여/자힐), PARITYFX2(혼합 — 실드 refresh/자힐/
  bsod_lag/오프타입 rider 침묵), PARITYFXCAT(효과 정의 14·rider 6·궁극기 특수효과 6 전량).
  기존 골든 중 RAINBOW/UNIQUE/ULT 재캡처(리이더 draw·방어무시), 5V5/3v3/COVERAGE 불변.
- **밸런스 관찰(재실측 대상)**: rm_rf 방어무시로 궁극기 데미지 급증(80→124/151) → 배틀 단축(21→13R);
  mascot 확정 실드 refresh + full_rollback 자힐 = 강한 자기유지(FX2에서 3v3 역전승). 승률표 재실측 후 조정.

## 8.6 구현 노트 (E3 — cs rider 완성 + 선택 AI)
- **collectionShared rider 19종 전량**: 디버프 13종(20~30% — control 계열은 강력해 20%) + 버프 6종
  (확정 자부여). 밈 정합 우선(deprecated→tech_debt, wontfix→hot_reload cleanse 등). 이로써 미배정이던
  효과(optimization/firewall/caching/hot_reload/rate_limited)가 전부 실전에서 등장.
- **선택 AI 자기버프 우선**(§6 축소판, RNG 없음·상태 기반): 자기 대상 rider 스킬 중 ①일반 버프는
  미보유일 때 ②cleanse는 자기 디버프 보유 시가 "우선 후보"가 되고, 있으면 그중 점수 최대를 고른다
  (버프 uptime > 그 턴 데미지). 원안 "위급 자힐"은 전용 힐 스킬이 없어 regen 버프 우선으로 흡수.
  `select(activeEffectIds:hasDebuff:)`에 상태를 넘겨 결정 — 기본값(빈/false)이면 기존 최대 데미지와 동일.
- **cleanse grant 반환값**: `grant`가 실제 적용 여부(cleanse는 지운 게 있을 때만 true)를 반환 →
  호출부가 무의미한 grant 이벤트 미기록. 양측 1:1(로그 정합).
- **골든**: cs rider 신규 추가로 variant≥2 팀의 rider draw가 스트림에 붙어 RAINBOW·COVERAGE·ULT·
  FX1·FX2 재캡처. **5V5·UNIQUE(자기타입 unique만 씀)·3v3·SKILLCAT은 비트 불변**(stash 비교 확인).
  FXCAT에 csr 19종 추가로 잠금. deno 15/15.
- **잔여(E4)**: UI 상태 아이콘/스킵 연출은 배틀 로직 무관이라 별도. 이후 승률 재실측 → 밸런스.

## 9. 리스크·미결
- 밸런스: DoT %·Control 확률/지속·버프 배수 — 골든 승률 실측으로 튜닝.
- Control 락다운 과다 방지(고정형 duration 짧게, 면역/체감 고려).
- 효과 슬롯 밀어내기 규칙 정밀화(오래된 것 기준).
- RNG draw 추가로 스킬 배틀 골든이 커짐 — 대표 벡터만 고정.
