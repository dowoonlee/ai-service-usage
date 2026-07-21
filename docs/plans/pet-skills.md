# 펫 스킬 시스템 + 궁극기 (포켓몬식) — 설계

상위: 아레나 배틀(`docs/plans/pet-battle.md`) 확장. 이로치(variant) 단계마다 스킬을 얻고,
최종 이로치(레인보우) 해금 시 궁극기를 쓴다. 스킬은 자체 상성(×2/×0.5)을 가져 "무엇으로
때리냐(커버리지)"가 실력 요소가 된다. 톤은 기존 개발 + AI 밈 유지.

> 결정(사용자 확정): ①스킬 타입 = 기존 6타입 재사용 ②스킬 상성 ×2/×0.5로 **전환**(패시브 ×1.6/0.625 대체)
> ③히든 최종 = 레인보우(variant 4)에서 궁극기 해금 ④궁극기 = 충전 게이지 ⑤슬롯 상한 = 정규 4 + 궁극기 1.

## 1. 스킬 모델
```
Skill = { id, name, type(6타입 중 1), power, tier, effect? }
```
- `type`: 기존 `BattleType`(beast/warrior/chaos/arcane/machine/mascot) 재사용.
- `power`: 기본 데미지 계수(현 basic 10 / signature 14 자리를 대체).
- `tier`: generic / typeShared / collectionShared / unique / ultimate.
- `effect`(선택): 궁극기·일부 고유기의 특수효과(방어무시 / 확정크리 / 광역 / 자힐 등).
- 기존 `basic/signature` 2-무브를 이 스킬셋으로 대체. `BattleEvent.move` = 스킬 id(로그에 스킬명 표시).

## 2. 데미지식 (전환 후)
```
skill      = selectSkill(attacker, defender)                 // §6 결정적 AI
skillEff   = skillEffectiveness(skill.type, defender.type)   // 2.0 / 1.0 / 0.5  (기존 6-사이클 재사용)
stab       = (skill.type == attacker.battleType) ? 1.5 : 1.0 // 자속 보정
raw        = (atk/def) × skill.power × skillEff × stab × collectionMatchup × rngFactor × rage
dmg        = 크리·패링 적용(현행 유지)
```
- **skillEff**: `attacker skillType`이 `defender battleType`을 이기면 ×2.0, 지면 ×0.5, 중립 ×1.0.
  (기존 `effectiveness(펫타입, 펫타입)` 패시브를 **스킬 타입 기준으로 전환**.)
- **STAB**: 스킬 타입 == 펫 타입 → ×1.5 (자기 타입 스킬 보상, 커버리지와 트레이드오프).
- **collectionMatchup**: 밈 라이벌(×1.30)/상성망(×1.12)은 그대로 유지(공격자 컬렉션 vs 방어자 컬렉션, 대사 포함).
- 시너지(팀)·크리(레인보우)·패링·격노·rngFactor 전부 현행대로 위에 곱.
- ⚠️ 배수 누적이 커질 수 있음(×2×1.5×1.3 = ×3.9) → power 하향 등 **밸런스 튜닝 대상**(골든 승률 실측).

## 3. 스킬 3계층 + 궁극기 (톤: 개발 + AI 밈)
### generic — 전 펫 공용 (variant 0)
잡몹 baseline. 저파워, **펫 자기 타입**(항상 자속). 규칙 파생(데이터 불요).
- `hotfix` "핫픽스" · power 8 · 자기 타입 — 급한 패치로 후려침.

### typeShared — 타입 단위 6종 (variant 1)
같은 배틀 타입이면 공유. power 11.
| 타입 | 스킬 | 밈 |
|---|---|---|
| beast | `mem_leak` "메모리 릭" | node_modules가 램을 다 먹는다 |
| warrior | `force_push` "강제 푸시" | git push -f, 히스토리를 밀어버림 |
| chaos | `friday_deploy` "금요일 배포" | 5시 커밋, 주말 장애 |
| arcane | `context_overflow` "컨텍스트 폭발" | 토큰 창을 통째로 태움 |
| machine | `regression_sweep` "회귀 스윕" | CI가 전 테스트를 갈아버림 |
| mascot | `onboarding` "온보딩" | 방어형 — 자힐/방어 버프 성향 |

### collectionShared — 컬렉션 단위 19종 (variant 2)
컬렉션 밈을 스킬화. power 12. (전체 카탈로그는 Phase B에서 채움 — 예시)
- dns → `it_was_dns` "그건 DNS였어"(beast) · oomKilled → `oom_kill` "OOM 킬러"(chaos)
- rustEvangelists → `rewrite_in_rust` "Rust로 재작성"(warrior) · ciRunners → `pipeline_stall` "파이프라인 병목"(machine)
- tokenBurners → `token_burn` "토큰 소각"(arcane) · happyPath → `happy_path` "해피 패스"(mascot)

### unique — Epic 이상 고유기 (variant 3, per-kind — **구현: Epic+ 전원 34종**)
**자기타입 시그니처. power 14, 효과 없음**(효과는 effects 페이즈로 분리 — [[pet-effects]]). variant 2
collectionShared가 오프타입 커버리지를 주므로 variant 3 unique는 "자기타입 한 방" 역할. **저레어(Common/Rare)는
고유기 없음 → variant 3에서도 3슬롯 유지**(레어리티 차별화 — B2 결정, 원안의 "shared 추가" 폐기).
- 구현 예: `segfault` "세그폴트"(skull) · `prod_outage` "프로덕션 장애"(bigDemon) · `hallucination` "환각 시전"(wizardM)
- AI 밈: `prompt_injection` "프롬프트 인젝션"(geralt) · `gradient_explosion` "그래디언트 폭발"(visorBot) · `quantization` "양자화"(roboRetro)
- per-kind 데이터라 `scripts/gen_pet_meta.py`가 Swift `uniqueTable`→서버 `pet_meta_gen.UNIQUE_SKILL` 생성(Epic+ 검증 내장).

### ultimate — 궁극기 (variant 4 레인보우 해금)
고파워(24) + 강효과 1종. §5 게이지 충전 시 발동. 타입/컬렉션별 또는 고레어 고유.
- `rm_rf` "rm -rf --no-preserve-root"(chaos, 방어무시) · `kernel_panic` "커널 패닉"(광역)
- `full_rollback` "전체 롤백"(자힐) · AI 밈 `context_window_exceeded` "컨텍스트 초과"(확정크리)

## 4. 이로치 단계별 해금 (슬롯: 정규 4 + 궁극기 1)
| variant | 획득 | 누적 정규 슬롯 |
|---|---|---|
| 0 기본 | generic | 1 |
| 1 이로치 | typeShared | 2 |
| 2 이로치 | collectionShared (오프타입 커버리지) | 3 |
| 3 이로치 | unique(Epic+만) / 저레어는 추가 없음 | Epic+ 4 · 저레어 3 |
| 4 레인보우(히든) | **궁극기** (+ 기존 레인보우 크리 유지) | +궁극기 |
- 미해금 펫은 하위 슬롯만 사용. 배틀엔 `battleVariant(kind)=max(unlockedVariants)` 반영(이로치 버프와 동일 경로).

## 5. 궁극기 메커닉 — 충전 게이지
- 펫이 행동할 때마다 게이지 +1. `ULT_CHARGE_ACTIONS`(예: 6) 도달 시 **다음 행동에서 궁극기 발동**(정규 스킬 대체), 게이지 리셋 → 장기전에선 여러 번 발동 가능.
- **RNG 불필요·행동수 기반 → 완전 결정적**(파리티 안전).
- 레인보우 미해금 펫은 게이지가 차도 궁극기 없음(발동 조건 = variant 4).

## 6. 스킬 선택 AI (결정적)
매 행동: 보유 정규 스킬 중 **기대 데미지 최대**(`power × skillEff(type, defender) × stab`)를 선택. 동점이면
슬롯 인덱스 낮은 것(결정적). 궁극기 충전 완료 & 레인보우면 궁극기 우선. → 커버리지 무브가 자동 활용됨.

## 7. 데이터·파리티 아키텍처
- **generic/typeShared/collectionShared**: 타입·컬렉션에서 **규칙 파생**(양측 동일 로직, per-kind 데이터 불요).
- **unique**: per-kind 스킬 매핑 → Swift SSOT → `pet_meta_gen`(RARITY/COLLECTION처럼) 서버 생성.
- **스킬 카탈로그**(id→type/power/effect): 양측 상수 테이블 1:1.
- **선택 AI·skillEff·STAB·게이지**: 클라 `BattleEngine` ↔ 서버 `battle_engine` 1:1.
- 신규 골든: 스킬 배틀(커버리지·STAB·궁극기 발동) 벡터를 `pvp_engine.parity.test.ts`에 추가.

## 8. 페이즈
- **Phase A** ✅(#170) — 프레임 + 엔진 전환: Skill 모델·카탈로그, skillEff/STAB로 데미지식 교체, generic+typeShared, 선택 AI. 골든 전면 재캡처.
- **Phase B1** ✅(#172) — collectionShared 19(오프타입 커버리지) + 이로치 해금. **B2** ✅(#173) — unique per-kind(Epic+ 34, gen 포팅).
- **Phase C** — 궁극기(게이지·효과) + 로그/연출("스킬명!" 태그).
- **Phase D**(선택) — 스킬 도감 UI(타입 상성표 원형 옆에), 밸런스 튜닝(승률 실측).

## 9. 리스크·미결
- 배수 누적 밸런스(§2 ⚠️) — power/skillEff 튜닝.
- 신규 원소 세트를 안 만들어 "지진 vs 물" 같은 전형적 상성 맛은 약함(6타입 재사용 트레이드오프).
- unique 콘텐츠 물량 = Epic+ 34종(구현 완료). ultimate(궁극기)는 Phase C에서 작성 예정 — 톤 유지 필요.
- unique power 14 자기타입 STAB(실효 21) 강력 → 레어리티 스탯갭과 겹쳐 원샷 경향, Phase D 승률 튜닝 대상.
- BattleEvent.move 문자열 확장 → 구 전적 로그 호환(기존 "basic"/"signature"도 렌더 유지).
