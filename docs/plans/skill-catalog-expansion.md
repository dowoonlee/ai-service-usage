# 스킬 카탈로그 다양화 — 기본기·타입기 풀 확장 설계

상위: [pet-skills.md](pet-skills.md)(스킬 시스템 SSOT) · [arena-skills-status.md](arena-skills-status.md)(작업 현황).
관련 메모리: `arena-battle-parity`, `arena-balance-snowball`.

## 1. 문제 — 저티어 스킬의 극단적 중복

로스터 195종(common 106 / rare 55 / epic+ 34) 기준:

| tier | 현재 | 중복 체감 |
|---|---|---|
| generic (v0) | **전 펫 공용 1종** (`hotfix`) | 195마리 전원 동일 |
| typeShared (v1) | 타입당 1종 (6종) | beast 60마리가 전부 `mem_leak` |
| collectionShared (v2) | 컬렉션당 1종 (19종) | 컬렉션 내 동일 (평균 10마리) |
| unique (v3) | Epic+ 34종 per-kind | ✅ 다양 — 단 Common/Rare엔 없음 |
| ultimate (v4) | 타입당 1종 (6종) | 레인보우 희소라 체감 낮음 |

→ **Common/Rare 161종(83%)은 같은 컬렉션이면 스킬 3개가 전부 동일한 복사본 킷.**
포켓몬이라면 "같은 타입 = 같은 기술 4개"인 셈 — 종별 개성이 없다.

## 2. 설계 원칙

1. **밸런스 완전 불변 (S1)** — 신규 스킬은 기존 tier의 (타입=자속, power, rider)를 그대로 상속하고
   **id/이름만 다양화**. 선택 AI 점수 = `power × eff × stab`이라 배틀 결과가 수학적으로 동일 —
   승률·라운드 수 비트 불변, 골든은 로그의 move id 문자열만 변동(재캡처 필요하나 지표 무변).
   `arena-balance-snowball`(밸런스 보류)·effects 후 재실측 결정과 충돌하지 않는다.
2. **파리티** — 배정 결과를 `gen_pet_meta.py`가 서버로 포팅(uniqueTable과 동일 경로).
   양측이 공식을 재구현하지 않고 **resolved 테이블을 생성**해 발산 여지를 없앤다.
3. **dyadic 유지** — power 변경 없음(8/11)이라 tie-break 파리티 이슈 없음.
4. **구 로그 호환** — 기존 7개 id(`hotfix` + typeShared 6종)는 풀에 잔류(일부 펫이 계속 배정받음)
   → 과거 전적 재생·구클라 표시 모두 기존 `nameById` 폴백 경로로 자연 호환.
5. **톤** — 기존 개발+AI 밈 유지. 타입별 풀은 타입 정체성(§3) 안에서만 다양화해 톤 미스매치
   (귀여운 mascot이 `rm -rf`를 쓰는 류)를 구조적으로 차단.

## 3. 신규 카탈로그 (S1)

### generic 풀 — "신입 기본기" 12종 (전 타입 공용 · 자속 · power 8)

누구나 아는 개발 기초 동작. 타입 무관 톤-중립.

| id | 이름 | 밈 |
|---|---|---|
| `hotfix` | 핫픽스 | (기존) 급한 패치로 후려침 |
| `printf_debug` | printf 디버깅 | 로그로 두들겨 패기 |
| `stackoverflow_paste` | 스택오버플로 복붙 | 출처 불명의 한 방 |
| `off_and_on` | 껐다 켜기 | IT 만능 해결책 |
| `cache_purge` | 캐시 삭제 | 일단 지우고 본다 |
| `git_blame` | git blame | 범인 지목 공격 |
| `rubber_duck` | 러버덕 디버깅 | 오리에게 설명하다 답이 나옴 |
| `console_log_spam` | console.log 도배 | 화면을 로그로 덮는다 |
| `retry_loop` | 일단 재시도 | 될 때까지 다시 |
| `todo_later` | TODO: 나중에 | 미룬 일이 부메랑으로 |
| `ctrl_cv` | Ctrl+C Ctrl+V | 복붙의 힘 |
| `regenerate` | 다시 생성 | AI 응답 리롤 |

### typeShared 풀 — 타입 정체성 확장 25종 (자속 · power 11 · **타입 rider 상속**)

풀 크기는 로스터 비례(beast 60 → 6종 … machine 16 → 3종). 기존 6종은 각 풀에 잔류.

| 타입 (로스터) | id | 이름 | 밈 |
|---|---|---|---|
| beast (60) | `mem_leak` | 메모리 릭 | (기존) node_modules가 램을 다 먹는다 |
| | `cpu_spike` | CPU 스파이크 | 팬이 이륙한다 |
| | `fork_bomb` | 포크 폭탄 | `:(){ :\|:& };:` |
| | `disk_full` | 디스크 100% | 로그가 디스크를 삼킴 |
| | `swap_thrash` | 스왑 지옥 | 램 대신 디스크가 운다 |
| | `thread_stampede` | 스레드 폭주 | 요청이 한꺼번에 몰려온다 |
| warrior (41) | `force_push` | 강제 푸시 | (기존) git push -f |
| | `hard_reset` | hard reset | git reset --hard, 돌이킬 수 없음 |
| | `sudo_strike` | sudo 일격 | 권한으로 해결한다 |
| | `breaking_change` | 브레이킹 체인지 | 하위호환은 없다 |
| | `prod_hotpatch` | 프로드 직수정 | 서버에서 vim으로 |
| chaos (31) | `friday_deploy` | 금요일 배포 | (기존) 5시 커밋, 주말 장애 |
| | `heisenbug` | 하이젠버그 | 보려고 하면 사라진다 |
| | `cascade_failure` | 연쇄 장애 | 하나가 넘어지면 전부 |
| | `flaky_test` | 플레이키 테스트 | 됐다 안 됐다 한다 |
| arcane (19) | `context_overflow` | 컨텍스트 폭발 | (기존) 토큰 창을 통째로 태움 |
| | `hallucinated_api` | 존재하지 않는 API | AI가 자신있게 지어냄 |
| | `temperature_max` | temperature 1.0 | 창의력 최대, 정확도 최소 |
| machine (16) | `regression_sweep` | 회귀 스윕 | (기존) CI가 전 테스트를 갈아버림 |
| | `retry_storm` | 리트라이 폭풍 | 백오프 없는 재시도 폭격 |
| | `cron_avalanche` | 크론 눈사태 | 자정에 전부 동시 실행 |
| mascot (28) | `onboarding` | 온보딩 | (기존) 방어형 |
| | `lgtm` | LGTM | 다 안 읽었지만 승인 |
| | `pair_programming` | 페어 프로그래밍 | 함께라서 강하다 |
| | `daily_standup` | 데일리 스탠드업 | 어제 한 일, 오늘 할 일 |

- rider는 **타입 단위로 기존 그대로**(beast 전 스킬 = `mem_leak` DoT 30% 등) — 효과/스킬은 이미
  별도 네임스페이스(`EffectCatalog` 주석)라 이름 혼선 없음. rider 분화는 S2(§6).

## 4. 배정 — 결정적 파생 + 생성 포팅

컬렉션 멤버 인덱스 기반 순환(같은 컬렉션 안에서도 킷이 갈리는 게 목적):

```
mIdx = PetCollection.members 내 인덱스, cIdx = PetCollection.allCases 내 인덱스
typeShared(kind) = typePool[battleType][ mIdx % n(type) ]
generic(kind)    = genericPool[ (cIdx × 5 + mIdx) % 12 ]   // stride 5 — 두 tier 인덱스 정렬 방지
```

- **members 배열은 append-only 규약**(이미 인덱스가 다른 데서도 의미 가짐) — 중간 삽입 시 기존
  유저의 배정이 바뀐다. 신규 펫은 뒤에 추가.
- 파리티: Swift가 배정을 계산하고 `gen_pet_meta.py`가 **resolved `[kind: (genericId, typeSharedId)]`**를
  `pet_meta_gen.ts`로 emit — 서버는 공식을 모른 채 테이블 조회(공식 재구현 발산 원천 차단).
- 카탈로그(id→name/type/power/rider)는 기존처럼 양측 상수 테이블 1:1 확장.
- `nameById`에 신규 전량 등록. 구 id 잔류로 과거 로그 호환(§2-4).

## 5. 구현 체크리스트 (S1 — 1 PR)

- [ ] `PetSkills.swift` — genericPool/typePool 테이블 + 배정 파생, `skills(kind:variant:)` 시그니처 유지
- [ ] `pvp_policy.ts` — 카탈로그 확장 + resolved 배정 테이블 조회로 전환
- [ ] `gen_pet_meta.py` — 배정 emit + 신선도 게이트(기존 CI 경로)
- [ ] 골든 재캡처(`--arena-demo` PARITY → `pvp_engine.parity.test.ts`) — move id만 변동, 승률/라운드 불변 확인이 곧 회귀 테스트
- [ ] `PetSkillsTests` — 전 kind 배정 커버리지·결정성·기존 7 id 잔류 가드
- [ ] UI 무변경(GachaView 스킬 카드·배틀 로그가 카탈로그를 따라 자동 반영)

배포: 서버 pvp 함수 재배포 + 클라 릴리스(절차는 `supabase-ranking`/`release-app` 스킬).
스큐: pvp는 서버 시뮬+클라 재생이라 구클라가 신 id를 만나면 표시명 폴백 — #175 HP 실링과 같은
계열로 안전하나, 신 id 이름 표시를 위해 클라 릴리스를 서버 재배포와 같은 사이클로.

## 6. S2 후보 (별도 결정 — 밸런스 재실측 게이트 뒤)

승률에 손대는 확장은 effects 후 재실측(status doc §밸런스)과 함께만:

- **rider 분화** — 같은 타입 풀 안에서 스킬별 rider 차등(예: `fork_bomb`=DoT, `swap_thrash`=spd 디버프)
- **저레어 개성** — Common/Rare에 4번째 슬롯 or 경량 고유기(B2의 "3슬롯 유지" 결정 재검토)
- **오프타입 소풀** — typeShared 일부를 오프타입으로 뒤집어 커버리지 다양화(승률 영향 큼)
- **궁극기 다양화** — 타입 6종 → 컬렉션 19종(레인보우 희소로 후순위)

## 7. 리스크

- 이름 195×2 조합 노출로 밈 피로 가능 — 풀 크기가 로스터 비례라 스킬당 노출 ~10마리, 현 195보다 낫다.
- members 중간 삽입 실수 → 배정 시프트: gen 신선도 게이트가 diff로 드러냄(조용히 못 지나감).
- 신규 id 오타/누락 → PetSkillsTests 커버리지 가드 + gen 검증으로 차단.
