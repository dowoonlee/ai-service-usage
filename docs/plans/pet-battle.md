# 펫 대결 (아레나 / PvP) — 기획

> 유저 간 펫 배틀. 포켓몬식 타입 상성 + 턴제 + 3v3 팀 빌딩. **기획 문서 — 실제 구현 전.**
> 작성 시점: v0.16.11 기준.

## 0. 결론 요약

트레이너들이 **보유 펫 3마리로 팀을 짜** 서로 대결한다. 앱은 메뉴바 액세서리(폴링 10분, Realtime 미도입)라 **실시간 동기 대전은 불가능** — 대신 상대의 **등록 팀 스냅샷**을 서버가 보관하고, **서버가 결정적(seeded) 시뮬레이션으로 승패를 판정**하는 **비동기 "고스트 배틀"**로 설계한다. 이는 `daily-quiz`(정답이 서버에만 있어 조작 불가)와 `guild`(비동기 월간 경쟁 풀스택)의 두 선례를 그대로 잇는다.

펫에는 **전투 스탯이 전무**(순수 코스메틱)하므로 스탯 체계를 신설하되, **이미 있는 신호에서 파생**한다: `Rarity`(HP/공격 등 기본치, 압축 곡선) · `PetCollection` 19종 → **6개 배틀 타입**(상성 육각형) · 성장 두 축(숙련도 자동 + **강화** 도박) · variant(이로치 소폭 보너스).

**핵심 성장·도박 축 — VP 강화**(§2-9). 지금 사용량으로 쌓이기만 하는 "죽은 점수" VP에 소비처를 붙인다: VP를 연료로 펫 **강화 레벨(+0~+15)**을 도박으로 올린다(메이플 스타포스·던파 강화식 — 고강일수록 성공률 급락·파괴 리스크). "파괴"는 펫 소멸이 아니라 강화 리셋(수집 자산 불가침). VP는 **랭킹 점수와 별도 풀로 이중 크레딧**(강화 지출이 순위를 깎지 않음)되고, 무엇보다 **서버 submit로 검증된 유일한 사용량 신호**라 강화를 서버 RNG로 굴리면 아레나의 조작 방지가 완성된다.

**전 모드 자동전투(오토배틀러)** — 전략은 전투 중 조작이 아니라 **팀 구성·타입 상성·리드 순서·강화 투자**에서 나온다. **랭크전**(서버 authoritative 시뮬, 레이팅·RP·코인 보상)과 **연습전**(언랭·무보상 샌드박스, 로컬 시뮬)으로 나뉜다. 서버·클라 신규 개념을 최소화하기 위해 HMAC 인증·`reward_grants` 지급 파이프라인·월간 lazy finalize·테넌트 격리를 전부 재사용한다.

> **확정된 방향** (사용자 결정): ① 깊이 = **경쟁 래더 풀버전**(레이팅·시즌 RP·아레나 리더보드) · ② 전투 = **전 모드 자동전투 관전** · ③ 타입 = **6타입 육각형** · ④ 강화 = **도박성(메이플·던파식)**, VP를 연료로. 아래 본문은 이 결정들을 반영한다.

## 1. 확정 결정 (제안)

| 항목 | 결정 | 근거 |
|---|---|---|
| 이름 | **아레나** (코드/DB: `pvp` / `arena`) | `파티`(코스메틱 로드아웃)·`랭킹`(사용량 래더)·`도장`(PvE 뱃지)과 명확히 구분. 트레이너 세계관에 PvP 표면을 하나 더 얹음 |
| 대전 모델 | **비동기 고스트 배틀** — 상대 팀 스냅샷 vs 서버 시뮬 | Realtime 미도입 + 폴링 10분 앱. 동시 접속 전제 불가(§2 근거). 상대가 오프라인이어도 성립 |
| 승패 판정 | **서버 authoritative 결정적 시뮬레이션** | 클라가 결과를 위조할 수 없어야 RP 래더가 성립. `daily-quiz` 서버 채점과 동일 철학 |
| 전투 방식 | **전 모드 자동전투 (관전)** | 서버 authoritative 시뮬과 궁합이 좋고 구현 단순(오토배틀러 톤). 전략은 팀 구성·상성·리드 순서에 집중. 유저 결정 |
| 팀 크기 | **3마리 (종 유니크)** | 기존 `Settings.maxPartySize=3`·`PartyPreset` 구조 재사용. 6마리는 밸런싱/UI 부담 과다 |
| 스탯 출처 | **Rarity(기본치) × Type archetype(분배) × 성장(숙련도+강화) × Variant(보너스)** | 신규 grind 최소화 — 이미 추적 중인 값에서 파생. §2-3 |
| 타입 체계 | **6 배틀 타입 (19 컬렉션 → 매핑), 상성 육각형** | 포켓몬식 상성의 핵심. 컬렉션이 이미 "테마 그룹"이라 1:1 재활용. 상성 배수는 완만(×1.6/×0.625)해서 하위 등급에도 승리 경로 |
| 강화(성장) | **VP 도박성 강화 (+0~+15)** — 서버 RNG, 3단 리스크(안전→하락→파괴), 파괴=강화 리셋 | 메이플/던파식. VP에 소비처 부여 + 배틀 메인 성장축 + 서버 검증 사용량이라 조작 방지 완성. §2-9 |
| VP 모델 | **이중 크레딧** — 랭킹 점수(불변) + 강화 가용 풀(별도), 지출이 순위 미영향 | "VP=랭킹 점수" 불변식 보존. append-only 제출 모델과 정합. 가용 = 서버 SSOT. §2-9 |
| VP 획득 | **사용량만 (현금 판매 금지)** + `reward_grants` 이벤트 지급 | 실화폐 루트박스의 법적·평판 리스크 원천 차단. 사용량→도박연료 철학 일관 |
| 레이팅 | **Elo/MMR (`pvp_ratings.rating`, 1000 시작)** | 비슷한 실력끼리 매칭. 개인 VP 래더와 완전 독립 |
| 매치메이킹 | **비동기 — 유사 레이팅 상대의 저장 팀 스냅샷 무작위 추출** | 동시 접속 불필요. 길드 "최소 상대 존재 가드" 재사용 |
| 일일 제한 | **랭크전 하루 N판 (스태미나, 초안 10판)** | 서버 부하·grind 억제. 연습전은 무제한 |
| 보상 | 승리 → **코인**(로컬, 소액) / 시즌(월간) 레이팅 상위 → **RP** (`reward_grants` 재사용) | 코인=로컬 경제, RP=기존 순위 보상 화폐. 신규 지급 코드 0 |
| 테넌트 | **같은 테넌트끼리만 매칭** | 랭킹/길드/DM과 동일 파티션. `resolveTenant` 재사용 |
| UI 위치 | **가챠 창 7번째 탭 "아레나"** (랭킹·길드 오른쪽) | 상점/파티/도장/레포트/랭킹/길드와 동급 표면. 7분할 segmented는 여유 |

## 2. 규칙 상세

### 2-1. 왜 비동기인가 (아키텍처 제약)

- 앱은 `LSUIElement` 메뉴바 액세서리, 폴링 기본 **600초**. leaderboard/guild/DM 조회는 **300초 폴링**, 열린 DM 스레드만 8초 폴링. **Supabase Realtime/WebSocket 미사용** — 전부 HTTP 폴링.
- 두 유저가 같은 순간 온라인일 보장이 전혀 없다. 실시간 턴 교환 PvP는 (a) Realtime 신규 도입 + (b) 수초 폴링 엔드포인트 + (c) 타임아웃/기권 처리 등 신규 인프라를 요구 — 현 구조와 상극.
- **결론**: 상대는 항상 **오프라인 고스트**. 각 유저가 "배틀 팀"을 서버에 등록(스냅샷)해 두면, 도전자가 매치를 걸었을 때 서버가 상대 스냅샷을 꺼내 시뮬레이션한다. 클래시로얄식 동기 PvP가 아니라 포켓몬 GO 체육관 방어/오프라인 레이드에 가까운 async 모델.

### 2-2. 두 모드 (전 모드 자동전투)

전투는 모두 **자동 진행 관전**이다. 유저의 전략은 **전투 전** 결정 — 팀 3마리 구성·타입 상성·리드 순서 — 에서 나오고, 전투가 시작되면 엔진이 결정적으로 굴린다.

| 모드 | 실행 위치 | 보상/레이팅 | 목적 |
|---|---|---|---|
| **랭크전** | **서버** (authoritative 결정적 시뮬) | 코인 + 레이팅 + 시즌 RP | 경쟁·래더. 결과 위조 불가. 일일 N판 제한 |
| **연습전** | **클라 로컬** (동일 엔진, 무작위 고스트) | 없음 (언랭·무보상) | 레이팅·일일제한 리스크 없이 팀을 시험하는 샌드박스 |

- 시뮬레이션 엔진(`BattleEngine`)은 **순수 함수 + 결정적**으로 한 벌만 작성해 서버(Deno/TS)와 클라(Swift) 양쪽이 **같은 규칙**을 구현한다. 랭크전은 서버 결과가 진실, 클라는 서버가 내려준 **배틀 로그를 애니메이션으로 재생**만 한다. 연습전은 무보상이라 클라가 로컬에서 돌려도 조작 유인이 없다.
- 전 모드 자동이라 §4의 "수동 조작 vs 조작 방지" 긴장이 사라져 설계가 단순해진다. 유일한 조작 방지 표면은 **팀 스탯 스푸핑**(서버 클램프로 대응, §4)뿐이다.
- **전략 깊이**는 전적으로 팀 빌딩에 실린다: 6타입 상성 안에서 3마리 조합, 리드 순서(선봉이 상성 유리한 상대를 먼저 만나게), 등급/레벨/타입의 트레이드오프. 향후 사전 "전술 토글"(공격/방어 성향) 등으로 확장 여지(P3).

### 2-3. 스탯 체계 (신설 — 파생 원천 재사용)

펫엔 전투 스탯이 없다(`PetDefinition`은 렌더 전용, `MythicSpec`의 "Attack"은 애니 이름일 뿐). 4개 스탯을 아래 파생식으로 계산한다. **신설 코드는 `PetTraits.swift`의 `PetKind` extension**(렌더용 `PetDefinition`과 분리하는 코드베이스 규약)에 둔다.

**스탯 4종**: `HP` / `ATK`(공격) / `DEF`(방어) / `SPD`(속도, 턴 순서).

**① Rarity → 기본치 (압축 곡선)**. coinValue(100~5000, 50배)를 그대로 쓰면 페이-투-윈이라 **의도적으로 압축**(≈2배 스프레드):

| Rarity | base | 비고 |
|---|---|---|
| Common | 40 | 106종 — 신규/무과금의 주력 |
| Rare | 48 | |
| Epic | 56 | |
| Legendary | 66 | |
| Mythic | 78 | sudo pull 전용 5종 |

Common↔Mythic가 약 2배 → **상성 우위(×1.6)면 하위 등급도 상위를 잡을 수 있는** 밸런스. (coinValue 곡선을 쓰면 25~50배라 타입/전략이 무의미해짐.)

**② Type archetype → 분배**. base를 4스탯으로 나누는 프로필(합 ≈ base×4). 타입별 개성:

| Type | HP | ATK | DEF | SPD | 성격 |
|---|---|---|---|---|---|
| 🐾 Beast | 1.0 | 1.05 | 0.95 | 1.1 | 균형·빠름 |
| ⚔️ Warrior | 1.0 | 1.25 | 0.95 | 0.9 | 물리 딜러 |
| 🔮 Arcane | 0.85 | 1.3 | 0.8 | 1.05 | 유리대포 |
| 💀 Chaos | 0.9 | 1.2 | 0.85 | 1.1 | 변칙·상태이상 |
| 🤖 Machine | 1.05 | 0.95 | 1.35 | 0.75 | 탱커 |
| 🌱 Mascot | 1.35 | 0.85 | 1.1 | 0.85 | 물몸·회복 |

(가중치는 밸런스 상수 — 릴리스 전 조정. 합을 base×4 근처로 정규화.)

**③ 성장 → 숙련도 + 강화 (§2-9)**. 성장은 두 트랙으로 나뉜다: **숙련도**(무손실, `progressUnits` 자동, 저상한 ~+15%)와 **강화 레벨**(도박, VP 투자, 서버 RNG, 고상한 +0~+15). 상세와 근거는 §2-9. 이 개정으로 원안의 "레벨=progressUnits" 단일축이 대체된다 — 강화가 서버 검증축이라 조작 방지가 완성되기 때문(§2-9, §4).

**④ Variant → 소폭 보너스**. 이로치 1/2/3 = 전 스탯 +2%/+4%/+6%, 레인보우 레어(4) = +10%. 결정적이지 않은 "치장 + 약간의 자부심" 수준.

> **조작 방지 요약**: 배틀 파워의 메인축인 **강화 레벨은 서버 SSOT + 서버 RNG**라 스푸핑 불가(§2-9). 남는 로컬 축(숙련도·variant)은 저상한·저스테이크라 원안의 팀 전투력 클램프 대신 **상한 캡**만으로 충분. 연습전은 무보상이라 무관.

### 2-4. 타입 상성 (6타입 육각형)

19개 `PetCollection`을 6개 배틀 타입으로 매핑(1:1 kind→collection→type, `PetTraits.swift` 신규 매핑):

| Type | 소속 컬렉션 | 종 수(대략) |
|---|---|---|
| 🐾 **Beast** | mainframe, emotionalSupport, npmInstall, nodeModules, dns, deprecated | ~60 |
| ⚔️ **Warrior** | vibeCoders, tenXEngineer, onCall, rustEvangelists, noVerify | ~41 |
| 💀 **Chaos** | wontfix, oomKilled, fridayDeploy | ~31 |
| 🔮 **Arcane** | tokenBurners, todoSince2019 | ~19 |
| 🤖 **Machine** | ciRunners | ~16 |
| 🌱 **Mascot** | happyPath, helloWorld | ~28 |

**상성 사이클** (각 타입이 다음을 강하게 침 = ×1.6, 역방향 = ×0.625, 그 외 ×1.0):

```
  Machine 🤖 ─▶ Beast 🐾 ─▶ Chaos 💀 ─▶ Arcane 🔮 ─▶ Mascot 🌱 ─▶ Warrior ⚔️ ─▶ (Machine)
```

- Machine이 Beast를 (기계가 야수 제압) · Beast가 Chaos를 (야수가 버그·언데드 물어뜯음) · Chaos가 Arcane을 (버그가 연산 오염) · Arcane이 Mascot을 (연산이 마스코트 압도) · Mascot이 Warrior를 (귀여움 앞에 전사 무력화) · Warrior가 Machine을 (전사가 기계 파괴).
- 깔끔한 6-사이클 = 외우기 쉽고 각 타입이 정확히 하나를 이기고 하나에 진다. 배수를 완만하게 둬 상성이 "전부"가 되지 않게 함.
- 컬렉션→타입은 밸런스 레버(종 수 편중 시 재배치 가능). 최종 세밀 튜닝은 펫별 오버라이드도 가능하나 MVP는 컬렉션 단위.

### 2-5. 전투 진행 (턴제, 결정적)

- **3v3, 선봉 1:1 교전**. 각 진영 리드 펫부터 맞대결, 쓰러지면 다음 펫 투입(포켓몬 파티 방식).
- **턴 순서 (ATB — 액티브 타임 배틀)**: 각 선봉이 SPD에 비례한 주기(`cd = speedBase / SPD`)로 행동. 두 선봉의 "다음 행동 시각"을 비교해 이른 쪽이 행동하고 자기 주기를 더해 재스케줄. **SPD가 2배면 주기가 절반이라 상대 1회당 2회 연속 행동**(예: `AABAAB…`). 동시 준비(동률)엔 빠른 쪽 먼저(동속이면 시드). 결정적.
- **데미지**: `dmg = (ATK / DEF) × movePower × typeEff × collectionMult × rand(0.9~1.0) × rage`. ATK/DEF엔 이미 성장·팀 시너지가 반영됨(별도 levelScale 없음). `collectionMult`=펫간 상성(§2-10). `rand`는 **매치 시드 기반 결정적 PRNG**(서버·클라 동일 — `SeededRNG.uniform01 = (next()>>11)/2^53`으로 비트 단위 포팅 고정). HP 0이면 교체.
- **격노 램프(rage)**: 데미지식은 성장이 ATK/DEF에 동시 곱해져 **비율 불변** → TTK가 HP(성장 비례)만큼 선형 증가. 풀강 탱커 미러전이 backstop을 상시 초과해 "KO 없는 HP 총량 타이브레이크"로 메타가 수렴하는 것을 막기 위해, 누적 액션 `rageStart(40)` 이후 액션당 `rageStep(0.07)`씩 데미지를 점증. 이론상 최대 성장 미러도 backstop 전에 KO로 종결(검증: 3000판 max 111액션). 결정적 매치(강 vs 약, 수십 액션 종결)엔 배수 1.0이라 무영향.
- **기술(move)**: 펫당 **① 기본공격(자기 타입)** + **② 타입 시그니처 무브**(타입별 1개, 위력·부가효과 상이). 전 모드 자동이라 **엔진이 매 턴 휴리스틱으로 선택**(상성 유리·처치 가능·회복 필요 등 단순 규칙, 결정적). Mythic 5종은 이미 있는 `MythicSpec.specials`(Attack/Heal/Shoot/Hammer)를 시그니처 무브의 **시각 연출**로 재활용.
- **패링(퍼펙트 가드)**: 피격 시 방어자가 **SPD(반응)+DEF(가드) 조합 확률**로 데미지를 대폭 경감(×0.1). `parryChance = clamp(base + spdW·SPD차 + defW·DEF비중, 0, 0.40)`. 빠른 탱커 ≈24% / 밸런스 6% / 느린 유리몸 0% → **DEF+SPD 빌드가 방어 정체성**이 됨. 결정적(시드).
- **대사**: 공격·리타이어·패링 시 펫이 짧은 dev-밈 대사를 말풍선으로(순수 코스메틱, `BattleLines.swift`).
- **부가 효과(초안)**: Chaos=일정 확률 상태이상(버그: 다음 턴 스킵) · Mascot=턴 시작 소량 회복 · Machine=피격 데미지 경감 · Arcane=치명타율↑. 상태이상은 밸런스 리스크라 P2에서 확장, MVP는 단순 딜/타입 상성 위주 권장.
- **승리**: 상대 3마리 전멸. 무한 루프 방지로 **최대 액션수 cap**(`MAX_ACTIONS=120` backstop), 초과 시 잔여 HP 합 큰 쪽 승(결정적). 격노 램프로 정상 매치는 backstop 전에 KO 종결되므로 타이브레이크는 극단적 동률 방어전에서만.

### 2-6. 배틀 팀 & 등록

- **배틀 팀** = `PetSelection[3]`(종 유니크) + 리드 순서. `PartyPreset` 구조를 재사용하되 **코스메틱 파티와 분리된 전용 프리셋**("배틀 팀")로 둔다 — 파티는 차트 위 걷는 펫이라 성격이 다름. 파티 프리셋에서 **가져오기**로 시드 가능.
- 등록: 배틀 팀을 서버에 **스냅샷 업로드**(kind·variant·level·파생 스탯). 이 스냅샷이 다른 유저의 도전 상대가 된다(고스트). 미등록 유저는 매칭 풀에서 제외(도전은 가능, 방어 대상은 아님).
- 스냅샷은 등록/변경 시점의 값으로 동결 — 상대가 그 뒤 펫을 키워도 과거 스냅샷으로 싸움(길드 office_slot 스냅샷과 같은 "서버가 SSOT" 원칙).

### 2-7. 매치메이킹 & 래더

- **레이팅** `pvp_ratings.rating`(Elo, 1000 시작, 테넌트 스코프). 승패 시 ±K.
- **매칭**: 도전 시 서버가 같은 테넌트 · 유사 레이팅(±윈도우, 없으면 확장) · 본인 아님 · 팀 등록됨 인 상대 스냅샷을 무작위 1건 추출. 길드 "최소 상대 존재 가드"(rank ≤ Q-1) 재사용해 상대 풀이 비면 매칭 거부.
- **일일 제한**: 랭크전 하루 N판(초안 10). 서버가 (device, KST일자) 카운트. 연습전 무제한.
- **시즌 정산**: cron 없음 → `leaderboard`의 lazy finalize 패턴처럼, 아레나 리더보드 조회 시 `finalize_previous_month_pvp_if_needed` RPC를 lazy 트리거해 직전 달 레이팅 상위에게 RP 큐잉.

### 2-8. 보상

- **판당**: 승리 시 코인(로컬, 소액 — 예: 기본 30 + 상성·상위레이팅 보너스). 연출은 wellness/시상대 보상과 동일 톤. **로컬 경제라 서버 검증 없음**(코인은 늘 클라 게이트 + `IntegrityGuard`).
- **시즌(월간)**: 직전 달 레이팅 티어별 RP를 `rp_rewards`가 아니라 **`reward_grants`에 `grant_key="pvp:season:<period>:<device>"`로 INSERT** → 기존 `pendingGrant`/`claim-reward` 파이프라인이 중복·이중지급 방지까지 공짜로 처리. 지급액은 개인 월간(1000/600/400…)보다 작은 스케일(초안 Top1 400 / Top10 150 / 상위50% 40 / 참여 15).
- **칭호/뱃지**: `TrainerCard.CardTitle`에 아레나 업적 칭호 추가(예: 첫 승리 / 10연승 / 특정 레이팅 도달). 자동 unlock 패턴 그대로.

## 2-9. 펫 강화 — VP 도박성 강화 (메이플·던파식)

> 리서치 근거: `docs/research/maplestory-enhancement.md`(스타포스/큐브/주문서), `docs/research/dnf-enhancement.md`(강화/증폭/재련). 두 게임의 도박 설계 패턴을 VP·아레나에 이식.

VP를 연료로 펫의 **강화 레벨(+0~+15)**을 도박으로 올린다. 고강일수록 성공률이 급락하고 리스크(하락→파괴)가 커지는 스타포스/던파식 루프. 이로써 (a) VP가 드디어 소비처를 얻고, (b) 배틀 성장의 메인축이 되며, (c) VP가 **서버 검증된 사용량 신호**라 조작 방지가 완성된다.

### VP 모델 변경 — "VP = 랭킹 점수" 불변식 보존

VP는 현재 사용량으로 쌓이기만 하는 "죽은 점수"(`rankingScoreEarnedVP`, 단조 증가, 랭킹 제출 점수 그 자체)다. 여기 소비처를 붙이되 랭킹을 깨지 않는다:

- VP 적립(사용량)은 **두 곳에 동시 크레딧**: ① 랭킹 제출 누적(기존 그대로, 서버 append-only, 순위 산정) + ② **강화에 쓰는 가용 풀**.
- **강화에 VP를 써도 랭킹 점수는 안 줄어든다.** 랭킹은 서버가 누적한 제출 총량(append-only submissions)이고 강화 지출은 별도 풀에서 빠진다. "순위 자랑 vs 펫 투자"의 희생 관계가 아니라, 한 번 번 VP가 순위(자동)와 강화(선택)에 둘 다 쓰이는 순수 추가. (희생 관계안은 append-only 제출 모델과 상극이라 비채택.)
- **가용 VP = 서버 SSOT**: 배틀이 서버 authoritative라 강화 지출도 서버가 검증한다. 서버는 계정의 제출 VP 총량(이미 앎, `users.total_coins`)으로 `가용 = 제출VP + 지급VP − 누적 강화지출`을 강제 → **실제로 번 VP만큼만 강화 가능, 스푸핑 불가**. 클라는 서버 응답으로 잔여를 표시(낙관적, RP 모델과 동일).
- **지급(grant)**: `reward_grants.currency`에 `'vp'` 추가 → 이벤트/보상 VP 지급 가능. 지급 VP는 **가용 풀에만** 들어가고 **랭킹 점수엔 미반영**(사용량 아니므로 순위 불공정 방지). coin/rp와 동일 `grant_key` dedup 파이프라인.

### 성장 두 축 (§2-3 스탯 개정)

원안의 "레벨 = progressUnits(로컬, 스푸핑 가능)"를 두 트랙으로 재편 — 던파의 재련(무손실) vs 강화(도박) 병행 구조를 그대로 차용:

| 트랙 | 출처 | 손실 | 상한 | 성격 |
|---|---|---|---|---|
| **숙련도** (무손실) | `progressUnits`(가챠 중복+사용시간) 자동 | 없음 | **낮음**(배틀 스탯 최대 ~+15%) | 던파 재련 역할 — 도박 안 해도 조금 강해지되 최상위 파워는 강화 의존. 로컬 값이나 저상한·저스테이크라 클램프 불필요 |
| **강화 레벨** (도박) | VP 시도, **서버 RNG** | 하락/파괴 | 높음(+0~+15, 가속형) | 배틀 스탯 메인 성장축. 아래 상세 |

최종 배틀 스탯 = `base(rarity×type archetype) × (1 + 숙련도보너스 + 강화보너스) × variant보너스`. 강화보너스는 고강일수록 **가속**(예: +5 ≈ +25% · +10 ≈ +60% · +15 ≈ +120%). **상한**을 둬 풀강 커먼 ≈ 중상위 등급 → 타입/조합이 여전히 승부를 가른다(압축 밸런스 철학 유지).

### 3단 리스크 계단 (던파 3단 + 메이플 파괴)

| 구간 | 실패 시 결과 | 성격 |
|---|---|---|
| **+0 ~ +5 (안전)** | 유지 (VP만 소모) | 습관·기대 학습. sunk cost 축적 |
| **+6 ~ +9 (하락)** | 유지 or **강등 (−1)** | 중위험 |
| **+10 ~ +15 (파괴)** | 유지 or **파괴 = 강화 0 초기화** | 고위험. **펫 자체·도감·컬렉션·variant는 불가침** — 잃는 건 강화치 + 투입 VP뿐 |

> **핵심 이식 판단 — "파괴 ≠ 펫 소멸".** 메이플/던파는 장비를 파괴(소멸/흔적화)하지만, 펫은 도감·컬렉션 무결성이 걸린 수집물이라 **절대 소멸시키지 않는다.** "파괴" = 강화 레벨이 +0으로 리셋(던파 보호권 거동과 동일). 잃는 것은 그동안 태운 VP와 강화 진행도 → 도박 긴장은 살리되 수집 자산은 보존.

성공/파괴 확률 예시(전부 튜닝 대상 — `_shared/pvp_policy.ts` 상수, 확률 UI에 투명 공개):

| 레벨 | 성공 | 실패(유지) | 강등/파괴 |
|---|---|---|---|
| +5→6 | 60% | 40% | – |
| +8→9 | 35% | 45% | 강등 20% |
| +11→12 | 18% | 62% | 파괴 20% |
| +14→15 | 6% | 69% | 파괴 25% |

VP 비용은 레벨별 **지수 폭증**(메이플 ^2.7 곡선 차용) — 고강 도전 자체가 "전설의 영역"이 되게. 정확한 곡선은 VP 적립률 대비 밸런스로 릴리스 전 확정.

### 리스크 완화 장치 (연구 패턴 이식)

| 장치 | 효과 | 재원 | 원본 |
|---|---|---|---|
| **강화 보호권** | 1회 파괴 방지 (파괴→유지 전환) | 코인 or RP 구매 (sink) | 메이플 안전장치 + 던파 보호권 |
| **안전 강화 모드** | 파괴 없음(+12까지) + 연속 실패 시 성공률 누적 보정(soft-pity) | VP 더 비쌈 | 던파 안전강화 |
| **확정 강화권** | RNG 우회, 확정 +1 | 시즌 RP 보상·이벤트 | 양 게임 확정권 (도박 스트레스 배출구) |
| **강화 이벤트** | 주말·사용 스트릭·시즌에 "확률 UP / 파괴 감소 / VP 할인" 창 | 시간 한정 | 메이플 썬데이·샤타포스 (FOMO 리텐션) |
| (P2) **타이밍 미니게임** | 스타캐칭식 — 성공 시 성공률 소폭(×1.05) 보정 | 스킬 개입 | 메이플 스타캐칭 (통제감 착시). 저스테이크라 클라 신고 허용 |

**천장 비대칭** (메이플 교훈 — 파괴형엔 천장 없이 긴장 유지, 리롤형엔 천장): 기본(도박) 강화엔 하드 천장 없음. 특정 레벨(+11/+12)에만 소규모 연속실패 보정(던파식). 확실한 구제는 **안전 강화 모드(soft-pity) + 확정권 + 보호권**으로 분리 제공 → "무한 손실 신뢰붕괴"는 막되 도박 긴장은 살림.

### 서버 authoritative RNG (조작 방지 완성)

- 강화 시도 = `pet-enhance` 호출 → 서버가 ① 가용 VP 검증 → ② VP 차감 → ③ **RNG 서버 롤(crypto random)** → ④ 강화 레벨 갱신(서버 SSOT) → ⑤ 결과 반환. 클라는 연출만 재생. `daily-quiz` 서버 채점과 동일 원리 — **결과·확률 조작 불가**.
- 강화 레벨이 서버 SSOT라 배틀 시뮬이 이걸 직접 읽어 스탯 계산 → §2-3의 "레벨 스푸핑" 문제가 원천 소멸(원안의 전투력 클램프는 숙련도 저상한 처리로 축소).
- **확률 투명 공개**(연구: 투명성이 몰입 안 깎음 + 한국 확률형아이템 공시 규범). **VP는 사용량으로만 획득 — 현금 판매 금지**: 실화폐 루트박스의 법적·평판 리스크(연구의 넥슨 사례)를 원천 차단하면서 도박 재미만 취한다. VP·강화는 "사용량 → 도박 연료"라 앱의 사용량-보상 철학과도 일관.

## 2-10. 펫간 상성 3층 (타입 위에 얹는 세밀 상성)

> 타입 6-사이클(§2-4) 위에 3개 층을 얹어 "펫간" 상성을 세밀화. 구현: `PetSynergy.swift`(+`BattleEngine` 배선). 전부 P0.5로 구현·테스트 완료.

### A. 팀 시너지 (팀 빌딩 전략)
같은 컬렉션/타입 팀원끼리 스탯 버프 — 팀 전체 스탯에 곱.
- **같은 컬렉션**(강한 유대) 최대 동족: 2 → +5% / 3 → +10%.
- **같은 타입**(느슨한 유대) 최대 동속: 2 → +3% / 3 → +5%. (동족은 자동 동속이라 소폭 중첩 = 의도)
- 모노 컬렉션 팀 = **×1.15** — 강하지만 단일 타입이라 카운터 하나에 취약(리스크/리턴).

### B. 밈 라이벌 (개체 느낌 + dev-밈)
큐레이션 라이벌 페어에 큰 보너스 **×1.30** + **배틀로그 대사**(왜 이겼는지 서사). 역방향(라이벌에게 공격)은 ×0.77.

| A ▶ D | 대사 |
|---|---|
| `--no-verify` ▶ CI Runners | "CI? 그게 뭔데." |
| DNS ▶ Works on My Machine | "네 컴퓨터가 아니라 DNS였어." |
| On-Call ▶ Friday Deploy | "삐삐 울렸다. 금요일 장애, 진압." |
| Rust Evangelists ▶ Deprecated | "그거, Rust로 다시 짜면 되잖아?" |
| OOMKilled ▶ node_modules | "node_modules가 메모리를 다 먹었다." |
| WONTFIX ▶ TODO Since 2019 | "닫아도 닫아도 살아 돌아온다." |
| 10x Engineer ▶ Vibe Coders | "vibe로는 안 돼. 실력으로 갈아넣는다." |
| Token Burners ▶ npm install | "의존성 지옥? context에 통째로 태워버려." |
| Friday Deploy ▶ Happy Path | "금요일 5시. 평화는 끝났다." |

### C. 컬렉션 상성망 (중간 해상도)
컬렉션 간 강약(타입 6개보다 세밀), 작은 보너스 **×1.12** / 역 ×0.89. 밈과 모순 없게 큐레이션(8엣지: mainframe▶deprecated, emotionalSupport▶oomKilled, vibeCoders▶todoSince2019, npmInstall▶happyPath, ciRunners▶wontfix, tokenBurners▶helloWorld, onCall▶oomKilled, rustEvangelists▶npmInstall).

**우선순위**: 밈(1.30) > 상성망(1.12) > 중립(1.0). 데미지 반영 = `× collectionMult`(§2-5). 최대 스택 = 타입 1.6 × 밈 1.30 ≈ **×2.08**(특정 매치업 한정). **무결성 가드**: 순방향은 항상 우위(>1), a▶d와 d▶a 동시 존재 금지(`testNoContradictoryEdges`).

## 3. 서버 설계

### 스키마 (migrations)

전부 `RLS ENABLE + 정책 0개`(anon 차단, service_role만) — 기존 관례.

```sql
pet_enhancements (                     -- 펫별 강화 레벨 (서버 SSOT — 배틀 스탯의 메인축, §2-9)
  device_id     uuid REFERENCES users ON DELETE CASCADE,
  kind          text NOT NULL,         -- PetKind rawValue
  level         smallint NOT NULL DEFAULT 0,  -- 강화 레벨 +0..+15 (서버 RNG로만 변동)
  spent_vp      bigint  NOT NULL DEFAULT 0,   -- 이 펫에 누적 투입한 VP (감사/표시용)
  fail_streak   smallint NOT NULL DEFAULT 0,  -- soft-pity/보정 카운터
  updated_at    timestamptz,
  PRIMARY KEY (device_id, kind)
)
-- 가용 VP = users.total_coins(제출 VP) + granted_vp − SUM(pet_enhancements.spent_vp)
--   granted_vp: reward_grants(currency='vp') 지급분. 서버가 매 강화 시도에 재계산해 검증.

pvp_teams (                            -- 유저별 등록된 배틀 팀 스냅샷 (고스트 방어 대상)
  device_id   uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE,
  tenant_id   text NOT NULL,           -- 매칭 파티션
  team_json   jsonb NOT NULL,          -- [{kind, variant}] ×3 + lead 순서. 강화 레벨은 pet_enhancements에서 join(스냅샷 시점 동결)
  power       integer NOT NULL,        -- 매칭용 요약 전투력 (서버가 강화레벨 포함 재계산)
  rating      integer NOT NULL DEFAULT 1000,  -- (pvp_ratings로 분리 가능)
  updated_at  timestamptz NOT NULL
)

pvp_ratings (                          -- 시즌 레이팅 (pvp_teams에 합쳐도 되나 정산 뷰 편의로 분리 권장)
  device_id   uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE,
  tenant_id   text NOT NULL,
  rating      integer NOT NULL DEFAULT 1000,
  wins        integer NOT NULL DEFAULT 0,
  losses      integer NOT NULL DEFAULT 0,
  updated_at  timestamptz
)

pvp_matches (                          -- 매치 결과 감사 로그
  id              uuid PRIMARY KEY,
  tenant_id       text NOT NULL,
  challenger      text NOT NULL,       -- lower(device_id) — FK 없음(상대 탈퇴해도 기록 보존, DM 패턴)
  defender        text NOT NULL,       -- lower(device_id)
  seed            bigint NOT NULL,     -- 결정적 시뮬 시드
  winner          text,                -- lower(device_id) or NULL(무승부)
  challenger_delta integer, defender_delta integer,  -- 레이팅 변화
  log_json        jsonb,               -- 배틀 로그(재생용). 크기 크면 요약만/TTL 삭제
  created_at      timestamptz
)

pvp_daily_counts (device_id, kst_date, count)   -- 일일 랭크전 제한
-- 시즌 정산: 직전 달 레이팅 스냅샷 → reward_grants INSERT (grant_key="pvp:season:...")
--            finalize_previous_month_pvp_if_needed() RPC (leaderboard lazy 패턴)
```

- **device_id JS 비교는 전부 `lower()` 정규화** (board #94, ranking deviceId 대소문자 교훈). `challenger`/`defender`/`winner`는 소문자 text로 저장.
- 상대 device는 **FK 없음 또는 ON DELETE SET NULL** — 탈퇴/삭제돼도 매치 기록 유지(DM `sender_device` 선례).
- `delete`(계정 삭제) 함수: `pvp_teams`/`pvp_ratings` CASCADE + `pvp_matches`는 보존.
- 테넌트 전환(one-way) 시 `pvp_teams.tenant_id`도 carry (`apply_tenant_switch` 확장).

### Edge Functions (기존 "함수당 액션" 스타일)

| 함수 | 역할 | 인증 |
|---|---|---|
| `pet-enhance` | **강화 시도** (§2-9): 가용 VP 검증 → VP 차감 → **서버 RNG 롤** → `pet_enhancements.level` 갱신(성공/유지/강등/파괴) → 결과·잔여VP 반환. 보호권/안전모드/확정권 플래그 처리 | HMAC |
| `pvp-register-team` | 배틀 팀 스냅샷 등록/갱신. `pet_enhancements` join해 스탯 재계산·`power` 산출 후 동결 저장 | HMAC |
| `pvp-challenge` | 랭크전: 상대 매칭 + **서버 시뮬 실행** + 레이팅 갱신 + 매치 로그 저장 + 보상 코인 payload 반환. 일일 제한 검사 | HMAC |
| `pvp-leaderboard` | 아레나 레이팅 랭킹 + 내 순위 + 최근 전적 + pending 시즌 보상. `finalize_previous_month_pvp_if_needed` lazy 트리거 | HMAC |
| `pvp-history` | 내 매치 이력(로그 포함, 재생용) | HMAC |

- 신규 5개(총 45개). 시즌 보상 수령은 **기존 `claim-reward`의 `grant` 라우팅 재사용**(신규 수령 함수 불필요). VP 지급은 `reward_grants.currency`에 `'vp'` 추가로 커버.
- 시뮬 엔진은 `_shared/battle_engine.ts`(순수 함수, 결정적)로 두고 `pvp-challenge`가 호출. 강화 RNG·확률표는 `_shared/enhance_engine.ts`로 분리(`pet-enhance`가 서버에서만 롤). 정책 상수(스탯 배수·타입표·레이팅 K·일일 제한·보상액·강화 확률/비용 곡선)는 `_shared/pvp_policy.ts`로 SSOT화(`board_policy.ts`/`guild_policy.ts` 패턴).
- **조작 방지 축이 강화로 이동**: 배틀 파워 메인축인 강화 레벨은 `pet-enhance`가 서버 RNG로만 올리고 `pet_enhancements`가 SSOT라 스푸핑 불가. VP 지출도 서버가 `가용 = 제출VP + 지급VP − Σspent_vp`로 검증. 원안의 "전투력 클램프"는 로컬 잔존축(숙련도·variant)의 저상한 캡으로 축소.

## 4. 악용 방지

| 위협 | 대응 |
|---|---|
| **결과 위조** (클라가 "이겼다" 신고) | 랭크전 승패는 **서버가 시뮬레이션**해서만 확정. 클라는 로그 재생만. `daily-quiz` 서버채점과 동일 |
| **팀 스탯 스푸핑** (강화/level 조작) | 배틀 파워 메인축인 **강화 레벨은 `pet_enhancements` 서버 SSOT + 서버 RNG로만 변동**(§2-9) → 위조 불가. 강화 VP 지출도 서버가 `가용 = 제출VP + 지급VP − Σspent_vp`로 검증 → 실제로 번 VP만큼만 강화. 로컬 잔존축(숙련도·variant)은 저상한 캡 + `IntegrityGuard` abuse_flags |
| **VP 위조** (가용 VP 부풀리기) | 가용 VP는 **서버가 제출 VP 총량(검증된 submit)에서 산출** — 클라 자가신고 미사용. submit의 시간비례 캡·prev_total 검증이 VP 총량 자체를 이미 보호 |
| **강화 RNG 조작** (결과 뒤집기) | RNG는 **서버가 crypto random으로 롤**하고 `pet_enhancements`에 원자적 기록. 클라는 결과 연출만. `daily-quiz` 정답 서버보관과 동일 |
| **일일 판수 어뷰징 / grind** | 서버측 `pvp_daily_counts` 하드 제한(랭크전 N판). 연습전은 무보상이라 제한 불필요 |
| **부계정 승수 펌핑** (자기 부계정 상대로 이김) | 매칭은 서버 무작위 추출 — 상대 지정 불가. 동일 IP/유사 신원 대량 계정은 register IP rate-limit + abuse_flags |
| **매칭 풀 고갈/시상 부정** | 길드 "최소 상대 존재 가드"(rank ≤ Q-1) 재사용 — 정상 경쟁 성립 시에만 시즌 시상 |
| **레이팅 조작 재시도/replay** | 매치 결과는 `pvp-challenge`가 원자적으로 1회 기록 + `claimRow` 원자성 패턴. HMAC clock-skew(±3600s) replay 방어 재사용 |
| **테넌트 경계 침범** | 매칭·리더보드 전부 `resolveTenant` 필터. 교차 테넌트 403 |

> **조작 방지 요약**: 강화(메인 파워축)를 **서버 SSOT + 서버 RNG + 서버 검증 VP**로 옮긴 덕에, 원안의 취약점("로컬 레벨 스푸핑")이 대부분 해소됐다. 남는 로컬 축(숙련도·variant)은 저상한이라 스테이크가 작다. 그럼에도 아레나 RP 스테이크는 개인 월간 랭킹보다 낮게 유지해 잔여 유인을 더 줄인다. **VP는 현금 판매하지 않아**(사용량 획득 전용) 실화폐 도박 규제 리스크도 회피(§2-9).

## 5. 클라이언트 설계

- **`RankingAPI` 확장**: pvp 5개 endpoint + 모델(`BattleTeamSnapshot`, `BattleResult`, `BattleLog`, `PvPLeaderboardEntry`, `EnhanceResult`). HMAC 서명 헬퍼(`signEncodable`)·flat payload 규칙 그대로.
- **`BattleEngine.swift` 신규**: 결정적 시뮬 엔진(연습전 로컬 실행 + 랭크전 로그 검증용). 서버 `_shared/battle_engine.ts`와 **규칙 1:1**. 순수 함수(입력=두 팀 스냅샷+시드 → 출력=턴 로그).
- **`PetBattleStats.swift` 신규** (또는 `PetTraits.swift` 확장): `PetKind.battleType`(컬렉션→6타입), `baseStats(rarity)`, `archetype(type)`, `masteryBonus(progressUnits)`(숙련도), `enhanceBonus(level)`(강화), `computeStats(...)` 파생식. **렌더용 `PetDefinition`과 분리**.
- **`Settings`**: `battleTeam`(전용 `PartyPreset` 또는 `PetSelection[3]`), `pvpRating`/`pvpWins`/`pvpLosses` 캐시(표시용 — 서버 SSOT), `pvpDailyUsed`/`pvpDailyDate`, **`petEnhanceLevel: [PetKind:Int]`·`vpAvailable` 캐시**(서버 SSOT, 표시용). 강화 확률표/비용 곡선 상수는 `PetBattleStats`에 미러(UI 표시용, 진실은 서버).
- **VP 이중 크레딧**: `VPLedger.consume()`이 `rankingScoreEarnedVP`(기존)에 더해 표시용 `vpAvailable` 캐시도 갱신 — 단 **가용 판정 진실은 서버**(강화 시 서버가 재검증). `IntegrityGuard` 체크섬에 강화/VP 관련 로컬 캐시는 넣지 않는다(서버 SSOT라 로컬 조작이 무의미).
- **`CoinLedger`**: `creditBattleWin(_:)` — 승리 코인(`creditBonus` 계열, VP 무영향). 보호권 구매(`purchaseEnhanceGuard`)도 여기(코인/RP sink).
- **보상 수령**: `ViewModel.checkPodiumRewardIfNeeded()`에 pvp 시즌 pending(`pendingGrant` 중 `pvp:` prefix) + **VP grant(`currency='vp'`)** 트랙 추가.
- **알림**: `NotificationManager`에 아레나 시즌 보상 + (선택) 강화 대성공/파괴 케이스 추가.
- **트레이너 카드**: 아레나 레이팅/전적 태그 + 아레나 칭호(§2-8) + (선택) 최고 강화 펫 자랑.

### 5-1. UI 설계 — 아레나 탭 (`ArenaView.swift`)

**탭 추가**: `GachaView.Tab`에 `case arena` 추가, 순서 `상점 · 파티 · 도장 · 레포트 · 랭킹 · 길드 · 아레나`. 7분할 segmented picker(2글자 라벨)는 560pt 폭에서 칸당 ~78pt로 수용 가능.

**상태 머신** (게이트, 길드 탭 패턴):

| 상태 | 조건 | 화면 |
|---|---|---|
| 빌드 미구성 | `!RankingAPI.isConfigured` | placeholder |
| 랭킹 미등록 | `!settings.rankingRegistered` | "아레나는 랭킹 참여자 전용입니다" + 설정 열기 |
| 펫 부족 | 보유 펫 < 3 | "배틀 팀엔 펫 3마리가 필요합니다. 가챠를 돌리세요" |
| 정상 | 그 외 | **아레나 메인** (아래) |

**아레나 메인 레이아웃**:

```text
┌─ ⚔️ 아레나 ─────────────────────────── ↻ ┐
│  레이팅 1180 · 12승 5패 · 오늘 3/10판          │
│                                                │
│ ┌─ 내 배틀 팀 ──────────────────────────────┐ │
│ │  🦊+9    🐲+4     🤖+12                    │ │
│ │  Beast   Warrior  Machine                  │ │
│ │  [리드 순서]  [팀 편성]  [강화소 ⚒️]         │ │
│ └────────────────────────────────────────────┘ │
│                                                │
│  [ ⚔️ 랭크전 도전 ]      [ 🎮 연습전 (자유) ]   │
│                                                │
├─ 🏆 아레나 랭킹 ────────────────────────────┤
│  1  deadlock       1520  ▓▓▓                  │
│  2  kimcoder       1440                        │
│ ▶7  dowoon (나)    1180                        │
├─ 최근 전적 ─────────────────────────────────┤
│  ✅ vs ghostdev  +18   (🦊▶🐲 상성승)          │
│  ❌ vs nightowl  -15                           │
│  [전적 더보기]                                  │
└────────────────────────────────────────────────┘
```

**전투 화면** (도전 → 서버 로그 재생 / 연습전 → 로컬 진행):

```text
┌─ 배틀 ─────────────────────────────────────┐
│  나 🦊 Beast Lv12          상대 🐲 Warrior   │
│  HP ▓▓▓▓▓▓▓░░░  62%        HP ▓▓▓▓░░░░  41%  │
│                                              │
│        🦊  ⚡→        ←💥  🐲               │
│   "이 버그, 한 칼에!"                          │
│  ── 효과가 굉장했다! (Beast ▶ Chaos ×1.6) ──  │
│                                              │
│  대기: 🐱Lv8  🤖Lv15    상대 대기: 💀 ☠️      │
│                                              │
│  자동 진행 — 관전   [ ⏩ 빠르게 ]  [ 건너뛰기 ] │
└──────────────────────────────────────────────┘
```

- **배틀 팀 편성**: `PartyView`의 슬롯/추가 시트 UI를 대폭 재사용(종 유니크, 3슬롯, 썸네일+강화레벨). 리드 순서는 ◀▶ 이동(파티의 리더 개념 재사용). 각 펫 카드에 **타입 배지 + 강화 레벨(+N) + 파생 스탯 미니바** 표시.
- **강화소 (⚒️)** — 도박 강화 UI(`EnhanceView.swift`). 스타포스/던파 강화창 감성:

```text
┌─ ⚒️ 강화소 ── 🦊 Fox (Beast) ─────────────┐
│           ★ 현재 강화  +9  →  +10           │
│      HP 148  ATK 121  DEF 96  SPD 132        │
│      (+10 성공 시 → HP 162 ATK 133 …)        │
│  ┌──────────────────────────────────────┐   │
│  │  성공 30%   유지 45%   💥파괴 25%      │   │  ← 확률 투명 공개
│  │  ⚠️ 파괴 구간 — 실패 시 강화 +0 리셋    │   │
│  └──────────────────────────────────────┘   │
│  비용  🔷 1,200 VP      가용 🔷 8,400 VP     │
│  ☑ 강화 보호권 사용 (💥방지 · 🪙500)         │
│  [ 일반 강화 ]  [ 안전 강화 (VP↑, 파괴X) ]   │
│  최근: ✅+7 ✅+8 ✅+9 … 연속 실패 0          │
└──────────────────────────────────────────────┘
```

  - 현재 스탯 + "성공 시 미리보기"를 나란히 → 기대 이득 프레이밍(연구: 후반 가속 보상). 확률은 구간 색으로(안전=초록/하락=주황/파괴=빨강) + 숫자 병기(투명 공개).
  - **연출**: 시도 → 서버 `pet-enhance` → 결과 애니(성공 반짝/파괴 산산조각 + 사운드). 파괴 연출은 상실감 극대화하되 "펫은 무사, 강화만 리셋" 문구로 안심. Mythic은 `MythicSpec.aura`로 강화 이펙트 재활용.
  - 보호권/안전모드/확정권 토글, 잔여 가용 VP·연속 실패 카운터·강화 이벤트 배너(확률 UP 시) 노출.
- **랭크전 도전**: 확인 alert → `pvp-challenge` → 서버 배틀 로그 수신 → 전투 화면에서 **턴 단위 애니메이션 재생**(스프라이트는 기존 `PetSprite`, Mythic은 `MythicSpec.specials` 연출, 이로치 색조·오라 그대로). 재생 후 결과 카드(레이팅 변화·획득 코인).
- **연습전**: 상대 고스트를 무작위(레이팅 무관)로 뽑아 **로컬 자동전투**를 재생. 무보상·언랭·일일제한 없음 — 팀 조합·상성을 부담 없이 시험하는 샌드박스.
- **아레나 랭킹**: `LeaderboardRowView` 변형(내 행 하이라이트, 레이팅 표시). 시즌 시상대는 P2.
- **전투 로그/전적**: 최근 매치 리스트, 클릭 시 재생(`pvp-history` 로그).
- **타입 도감**: 6타입 상성 육각형을 보여주는 작은 도움말 시트(포켓몬 타입표 감성). 어느 펫이 어느 타입인지 도감(GachaView 상점)에도 타입 배지 추가 검토.

## 6. 단계

| Phase | 내용 | 배포 단위 |
|---|---|---|
| **P0 (선행)** | 밸런스 설계 확정 — `PetBattleStats` 파생식·6타입 매핑·상성 배수·데미지식 + **강화 확률/비용/스탯 곡선** 수치화 + 순수 로직 테스트(`BattleEngineTests`·`EnhanceEngineTests`) | 로직·테스트만, 서버/UI 없음 |
| **P1 (MVP)** | 스키마(`pet_enhancements`·`pvp_teams`·`pvp_ratings`·`pvp_matches`·`pvp_daily_counts`, `reward_grants` vp 확장) + 함수(`pet-enhance`·`pvp-register-team`·`pvp-challenge`·`pvp-leaderboard`·`pvp-history`) + `battle_engine.ts`·`enhance_engine.ts` + 클라 `BattleEngine.swift`·`ArenaView`·`EnhanceView`·배틀 팀 편성 + **랭크전(서버 시뮬 재생)** + **기본 도박 강화** + VP 이중크레딧 + 아레나 랭킹 + 승리 코인 | 서버 1 PR + 클라 2~3 PR(팀 편성/강화소 ↔ 전투 재생 분리) |
| **P2a** | 강화 완화장치(**보호권·안전강화 모드·확정권·강화 이벤트**) + 연습전 샌드박스 + 타입 상성 도움말 + 도감 타입 배지 | P1 후속(도박 리텐션 강화) |
| **P2b** | 시즌(월간) finalize + RP 시즌 보상(`reward_grants`) + VP grant 수령 + 아레나 시상대 + 보상 알림 + 아레나 칭호(`CardTitle`) | 첫 시즌 경과 후 자연 후속 |
| **P3 (선택)** | 강화 타이밍 미니게임(스타캐칭식), 상태이상/부가효과 확장, 친선전(특정 상대 지정·DM 연동), 길드 대항 아레나, 큐브식 2차 도박(랜덤 특성 리롤) | 반응 보고 결정 |

## 7. 결정 이력

주요 갈림길은 확정됐다:

| 항목 | 결정 | 비고 |
|---|---|---|
| **깊이** | ✅ **경쟁 래더 풀버전** | 레이팅·시즌 RP·아레나 리더보드. §4 조작 방지 전면 적용 |
| **전투 방식** | ✅ **전 모드 자동전투 관전** | 수동 기술선택 없음. 전략 = 팀 구성·상성·리드 순서·강화. 시뮬 엔진/UI 단순화 |
| **타입 체계** | ✅ **6타입 육각형** | Beast/Warrior/Chaos/Arcane/Machine/Mascot, 6-사이클 상성 |
| **강화 방식** | ✅ **도박성 (메이플·던파식)** | VP 연료, 서버 RNG, 3단 리스크(안전→하락→파괴), 파괴=강화 리셋(펫 불가침). EV식 결정적 배분안은 기각 (§2-9) |
| **VP 소비처** | ✅ **강화 연료** (이중 크레딧, 랭킹 미영향) | "죽은 점수" VP에 소비처 부여. 서버 검증 사용량이라 조작 방지 완성. 현금 판매 금지 (§2-9) |
| **스탯 조작 방지** | ✅ **강화 서버 SSOT + 서버 RNG** | 원안의 "로컬 레벨 클램프"를 대체 — 메인 파워축이 서버 검증축이 됨 (§2-9, §4) |

남은 세부(릴리스 전 밸런스 튜닝 대상): 등급 base 수치·타입 archetype 배수·레이팅 K값·일일 판수(초안 10)·시즌 RP 지급액·데미지식 상수 + **강화 확률표·VP 비용 곡선·강화 스탯 곡선·펫당 상한**. 전부 `_shared/pvp_policy.ts` + `PetBattleStats`의 상수라 코드 흐름 변경 없이 조정 가능. VP 비용은 실제 VP 적립률 데이터로 사이징 필요(현재 미확보).

## 8. 참고 — 재사용하는 기존 자산

| 신규로 안 만들어도 되는 것 | 재사용 원천 |
|---|---|
| 유저 식별·본인 인증 | `device_id` + per-install HMAC (`RankingAPI.signEncodable`, `_shared/hmac.ts`) |
| 보상 지급·수령·이중지급 방지 | `reward_grants` + `grant_key` + `pendingGrant` + `claim-reward` (grant 라우팅) |
| 시즌 정산 트리거 | leaderboard lazy finalize RPC 패턴 (cron 없음) |
| 비동기 경쟁 풀스택 선례 | 길드(8함수·월간 뷰·경쟁 가드·쿨다운) |
| 서버 authoritative 판정·RNG 선례 | `daily-quiz`(정답 서버 전용, 서버 채점) — 강화 RNG·배틀 판정 동일 원리 |
| VP 적립·이중 크레딧 | `VPLedger`·`rankingScoreEarnedVP`·submit 파이프라인(시간비례 캡) — 가용 VP 산출·검증의 서버-신뢰 원천 |
| VP 지급(grant) | `reward_grants` + `currency` enum에 `'vp'` 추가 (coin/rp와 동일 dedup) |
| 팀/슬롯 UI | `PartyView`·`PartyPreset`·`Settings.maxPartySize` |
| 스프라이트·특수모션·이로치·오라 렌더 | `PetSprite`·`MythicSpec.specials`·`WalkingCat.hueDegrees`·`PetEffectOverlay`(강화 이펙트에도) |
| 스탯 파생 원천 | `Rarity`(기본치)·`PetCollection`(→타입)·`PetOwnership.progressUnits`(→숙련도 무손실 트랙)·variant |
| 리더보드/시상대/행 UI | `LeaderboardRowView`·`RankingView` podium |
| 테넌트 격리 | `resolveTenant`·`sameTenant`·읽기필터/쓰기스탬프 |
| 로컬 조작 탐지 | `IntegrityGuard` → `abuse_flags` |
| 도트 VFX 이펙트 | 확정 팩 5종 (§9) — `docs/research/pixel-vfx-assets.md` |

## 9. 연출 설계 (도트 VFX)

> 확정 에셋 세트(§8·`docs/research/pixel-vfx-assets.md`)로 **가챠 리빌의 벡터/블러를 도트로 교체** + **강화 연출**을 구성. 전부 펫과 동일하게 nearest-neighbor(`interpolation:.none`) 렌더. 강화 연출 톤은 프로토타입(아티팩트)에서 검증됨.

**확정 팩**: Nightspore(알 부화·커스텀무료) · GrafxKid Mini FX(반짝임/연기, 펫과 동일 작가·CC0) · CodeManu Free Pixel Effects(폭발·CC0) · BenHickling Ring/Explosion(충격파·CC0) · Foozle Pixel Magic / Pixel Art Spells(차지·오라·CC0).

### 9-1. 가챠 리빌 재구성 (`GachaView.swift`)

| 단계 | 현재(교체 대상) | 도트 교체 |
|---|---|---|
| `.egg` | `EggShape()` 벡터 fallback | **Nightspore egg** idle/rock 프레임 (탭 시 rock) |
| `.cracking` | `CrackShape().trim().stroke(1.5px 벡터선)` | **Nightspore crack** 프레임 (rock→crack 진행) |
| `.revealing` flash | `Color.white.opacity(sin())` 단색 깜빡임 | **GrafxKid sparkle** + 등급별 버스트(**CodeManu**) |
| `.revealing` 등장 | `.colorMultiply`/`.saturation` 셰이더 실루엣 페이드 | **Nightspore hatch**(알 열림) → 펫 등장 |
| `premiumAura` | `AngularGradient`+`RadialGradient`+**`.blur(6)`**+`.screen` | **Foozle portal/aura** 프레임 + **BenHickling ring** + **CodeManu red&white**(진홍·금 색조) |

**등급 티어별 리빌 강도** (연출로 희귀도 체감):
- Common: Nightspore hatch + GrafxKid 작은 sparkle poof
- Rare/Epic: + CodeManu star/energy 버스트
- Legendary/Mythic(premium): + CodeManu 대형 폭발 + BenHickling Ring + Foozle aura

### 9-2. 강화 연출 (`EnhanceView.swift`) — 프로토타입 순간 → 도트 프레임

| 순간 | 프로토타입(CSS) | 도트 교체 |
|---|---|---|
| **charge** (~0.9s) | 링/그라디언트 차오름 | Foozle portal 또는 Pixel Art Spells 오브 회전 + GrafxKid sparkle 수렴 |
| **성공** | 화이트 플래시 + 쇼크웨이브 | CodeManu 따뜻한 폭발 + **BenHickling Ring Explosion** + GrafxKid sparkle + 별 슬램 |
| **대성공** | 무지개 버스트 | CodeManu star/windmill 에너지 + 이중 Ring + 무지개 `hueRotation` |
| **강등** | 앰버 플래시 | GrafxKid cloud poof(둔탁) + 앰버 tint |
| **파괴** | shard + shake + 회색화 | CodeManu red&white(차갑게 tint) + GrafxKid smoke poof + 펫 `saturation(0)` + shake. *(전용 shard 프레임은 CC0 부재 → 폭발+연기로 대체, §research)* |

### 9-3. 렌더 규칙

- 프레임 재생 = `TimelineView` elapsed → frameIndex (기존 `PetSprite`/`WalkingCat` 스트립 재생 패턴 재사용).
- 이펙트는 펫의 **2~3배 스케일 허용**(캐릭터보다 커도 자연스러움). 100px 팩은 다운스케일.
- **제거 코드**: `CrackShape`, `premiumAura`의 blur/gradient, `revealingView`의 `Color` flash·`colorMultiply`/`saturation` 실루엣.
- SwiftPM 리소스 flatten(전 basename 유니크): `Resources/vfx-codemanu/`, `vfx-egg/` 등 팩별 디렉터리 + prefix(`vfx_egg_hatch_*`).
- **강화 연출 상태머신 = 가챠 `egg→cracking→revealing→hatched`와 동일 phase 패턴 재사용** (charge→resolve→branch).
- 라이선스: CC0 4팩 attribution 불요 + Nightspore `LICENSE_Nightspore.txt` 원문 인용(커스텀 무료). 확보 절차는 `docs/plans/vfx-asset-acquisition.md`.

## 10. 부록 A — P0 밸런스 확정 (SSOT 후보)

> 아래 수치는 예시·튜닝 대상이나 P0에서 이 형태로 잠근다. 서버 `_shared/pvp_policy.ts` + 클라 `PetBattleStats`의 상수 SSOT. 아티팩트(강화 곡선)와 동일 값.

```ts
// 등급 기본치 (압축 곡선 — Common↔Mythic ≈ 2배)
RARITY_BASE = { common:40, rare:48, epic:56, legendary:66, mythic:78 }

// 타입 archetype 배수 (HP/ATK/DEF/SPD), 합 ≈ base×4로 정규화
ARCHETYPE = {
  beast:   [1.00,1.05,0.95,1.10], warrior:[1.00,1.25,0.95,0.90],
  arcane:  [0.85,1.30,0.80,1.05], chaos:  [0.90,1.20,0.85,1.10],
  machine: [1.05,0.95,1.35,0.75], mascot: [1.35,0.85,1.10,0.85] }

// 타입 상성 (6-사이클): 이기면 ×1.6, 지면 ×0.625, 그 외 ×1.0
BEATS = { machine:"beast", beast:"chaos", chaos:"arcane",
          arcane:"mascot", mascot:"warrior", warrior:"machine" }
TYPE_SUPER = 1.6; TYPE_WEAK = 0.625

// 성장: 숙련도(무손실, progressUnits) + 강화(도박, 서버 RNG)
MASTERY_MAX = 0.15                       // progressUnits→ 최대 +15%
ENHANCE_BONUS = [0,.04,.08,.13,.18,.25,.30,.36,.43,.51,.60,.70,.82,.95,1.07,1.20] // +0..+15
VARIANT_BONUS = [0,.02,.04,.06,.10]      // 기본/이로치1·2·3/레인보우
STAT_CAP_MULT = 2.6                      // 풀강 커먼 ≈ 중상위 등급 상한

// 펫 스탯 = base × archetype × min(STAT_CAP_MULT, 1+mastery+enhance) × (1+variant)
//   전투 시 여기에 팀 시너지(§2-10 A)가 팀 전체에 추가로 곱해짐

// 강화 확률표 [succ, stay, down, destroy]  (현재 강화 L=0..14 → 시도 +L→+L+1)
ENHANCE_ODDS = [
 [.95,.05,0,0],[.90,.10,0,0],[.85,.15,0,0],[.78,.22,0,0],[.68,.32,0,0],[.60,.40,0,0], // 안전
 [.50,.38,.12,0],[.42,.42,.16,0],[.35,.45,.20,0],[.30,.48,.22,0],                     // 하락(-1)
 [.22,.60,0,.18],[.18,.62,0,.20],[.13,.65,0,.22],[.09,.68,0,.23],[.06,.69,0,.25] ]     // 파괴(→+0)
ENHANCE_VP_COST = [20,40,75,130,210,320,470,680,950,1300,1800,2500,3400,4600,6200]     // Common 기준 지수 폭증
RARITY_COST_MULT = { common:1.0, rare:1.4, epic:2.0, legendary:3.0, mythic:4.5 }        // 고등급일수록 강화 비쌈
// 실제 비용 = ENHANCE_VP_COST[level] × RARITY_COST_MULT[rarity]
// 참고: 파괴 리셋 반영 +15 도달 기대 VP ≈ 5.3M (Common 단순합 22.7k의 233×, 마르코프)

// 전투
// 펫간 상성 (§2-10, PetSynergy)
TEAM_SYNERGY = { collection:[2:.05,3:.10], type:[2:.03,3:.05] }  // 팀 스탯 곱
COLLECTION_MATCHUP = { meme:1.30, network:1.12 }                 // 역방향은 역수. 밈>망>중립
// memeRivals 9쌍(+대사) / networkStrong 8엣지 — 순방향 우위·무모순

DAMAGE = (ATK/DEF) * movePower * typeEff * collectionMult * rng(0.9..1.0) * rage  // ATK/DEF에 성장·팀시너지 반영
RAGE = { start:40, step:0.07 }  // action>start부터 액션당 +step. TTK가 성장 비례로 늘어 backstop 초과하는 것 방지
RNG_UNIFORM = (next()>>11) / 2^53  // Double.random(in:) 대신 고정 명세(Swift 버전·TS 포팅 비트 일치)
ATB: cd = speedBase(1000) / SPD; 다음행동 이른 쪽부터, 동시엔 빠른 쪽 먼저(동속 시드)
     SPD 2배 → 2연속 행동(AABAAB…); MAX_ACTIONS = 120 backstop (초과 시 잔여 HP 합 큰 쪽)
PARRY = { base:0.06, spdW:0.25, defW:0.12, max:0.40, dmgMult:0.10 }  // DEF+SPD 조합 퍼펙트 가드
RATING_K = 24 (Elo, 1000 시작); DAILY_RANK_LIMIT = 10
WIN_COIN = 30 + 상성·상위레이팅 보너스
SEASON_RP = { top1:400, top10:150, top50pct:40, 참여:15 }  // reward_grants "pvp:season:*"
```

## 11. 부록 B — P0 테스트 케이스 (순수 로직)

**`EnhanceEngineTests`** (`enhance_engine.ts` / `EnhanceEngine.swift`):
- 각 레벨 `ENHANCE_ODDS[L]` 합 = 1.0 (부동소수 허용오차).
- 안전 구간(+0~+5)은 destroy·down = 0. 하락 구간(+6~+9)은 destroy = 0. 파괴 구간(+10~+14)은 down = 0.
- destroy 결과 → level = 0. down 결과 → level = max(0, L-1). stay → L 불변. succ → L+1.
- 시드 고정 시 결과 결정적(서버 RNG 재현). 가용 VP < 비용이면 시도 거부(레벨·VP 불변).
- 마르코프 기대 VP: `expected(+15) ∈ [5.0M, 5.6M]` (회귀 가드), `expected(+1)=21`.

**`PetBattleStatsTests`**:
- 스탯은 rarity·enhance·mastery에 대해 단조 증가. `STAT_CAP_MULT` 상한 준수.
- 타입 상성: `eff(machine,beast)=1.6`, `eff(beast,machine)=0.625`, `eff(beast,beast)=1.0`, 6-사이클 폐합.
- **밸런스 의도 가드**: 상성 우위(+동레벨) 커먼이 상성 열위 에픽을 이길 수 있다(특정 스탯 시나리오 assert).

**`BattleEngineTests`**:
- 같은 두 팀 스냅샷+시드 → 동일 로그·승자(서버/클라 1:1). 서로 다른 시드 → 분포 상이.
- SPD 높은 쪽 선공. 리드 순서대로 교체. 3마리 전멸 = 패배. MAX_TURNS 초과 시 잔여 HP 합 타이브레이크.
- 강화·타입 동일이면 승률 ≈ 50% (대량 시드 표본). 항상 MAX_ACTIONS 이내 종료. 로그 데미지 ≥ 1.
- **ATB**: 빠른 팀이 더 자주 행동(로그 자기 측 액션 수 ↑). SPD 2배 → 2연속(AABAAB… 시퀀스, 스탠드얼론 검증).
- **패링**: `parryChance` 빠른탱커>밸런스>느린유리몸·클램프·SPD/DEF 단조; 배틀에서 실제 발동(대량 시드 parried>0).

**`PetSynergyTests`** (§2-10, `PetSynergy.swift`):
- 팀 시너지: 모노 컬렉션 ×1.15 / 동일타입 다른컬렉션 ×1.05 / 2동족 ×1.08 / 전원 상이 ×1.0.
- 밈 라이벌: 순방향 ×1.30 + 대사, 역방향 ×0.77 무대사. 상성망: ×1.12 / 역 ×0.89. 진짜 중립 = 1.0.
- **무결성 가드**: 밈/상성망 순방향 항상 우위(>1), a▶d와 d▶a 동시 금지.
