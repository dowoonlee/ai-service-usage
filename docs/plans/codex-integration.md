# Codex(OpenAI) 사용량 소스 추가 — 구현 계획

> 이슈 #36 "코덱스 추가도 가능할까요" 대응. 조사 결과는 [`docs/research/codex-usage.md`](../research/codex-usage.md) 참조.
> 작성 시점: 코드 베이스 v0.10.2 기준. **계획 문서 — 실제 구현 전.**

## 0. 결론 요약

Cursor 소스와 **거의 동일한 패턴**으로 추가 가능. 로컬 파일에서 토큰을 읽어 비공식 HTTP 엔드포인트를 폴링하는 구조가 `CursorAPI`와 1:1로 대응한다. 게다가 Codex의 `primary_window`(5h) / `secondary_window`(7d) `used_percent` 모델은 **Claude의 5h/7d 윈도우 모델과 구조가 같아**, `UsageEventProducer.ingestClaude`를 그대로 베껴 `ingestCodex`를 만들 수 있다.

핵심 경로:
- 인증: `~/.codex/auth.json` → access_token + (id_token JWT 디코딩) account_id / plan_type
- 사용량: `GET https://chatgpt.com/backend-api/wham/usage` (`Authorization: Bearer` + `ChatGPT-Account-ID`)
- 응답: `primary_window.used_percent` / `resets_in_seconds`, `secondary_window.used_percent` / `resets_in_seconds`

## 1. 신규 소스 추가의 표준 경로 (코드가 의도한 확장점)

`UsageEvent.swift` 주석이 명시한 3단계 + UI/저장/폴링:
1. `UsageSource` enum에 case 추가
2. `UsageEventProducer.ingestCodex()` 추가 (raw → pureValue + coinFactor/vpFactor)
3. ViewModel에서 호출
→ CoinLedger / VPLedger는 **자동 처리** (분기 불필요)

여기에 Cursor가 실제로 건드린 파일들을 더하면 전체 작업 목록이 나온다.

## 2. 작업 단위 (파일별)

### 2-1. `CodexAPI.swift` (신규 actor) — `CursorAPI.swift` 템플릿
- `~/.codex/auth.json` 파싱. **스키마 A/B 둘 다 처리** (조사 보고서 §1):
  - A: `{ auth_mode, tokens: { access_token, id_token, refresh_token } }`
  - B: `{ type: "oauth", access, refresh, accountId }`
- JWT 디코딩(`CursorAPI.base64URLDecode` 재사용 가능) → `https://api.openai.com/auth` claim에서 `chatgpt_account_id`, `chatgpt_plan_type` 추출. account_id가 JWT에 없고 스키마 B의 `accountId`만 있는 경우 fallback.
- `refresh() async throws -> CodexSnapshot`: `GET wham/usage` 호출.
  - 헤더: `Authorization: Bearer <access>`, `ChatGPT-Account-ID: <id>`, `Accept: application/json`, Cursor와 동일한 Safari UA(`User-Agent`).
  - 401/403 → `unauthorized` (캐시 clear), 비-2xx → `http(code)`.
- `diagnose() async -> CodexDiagnostics`: `--check` 경로(`UsageAPI.diagnose`/`CursorAPI.diagnose`와 동일하게 단계별 status/raw body).
- 보안: send 로그에 status/bytes만 (Cursor 주석과 동일 정책 — body엔 사용 패턴/account id 포함).

### 2-2. `Models.swift` (또는 신규 `CodexModels.swift`)
- `CodexSnapshot: Codable, Hashable` — Claude `UsageSnapshot` 미러:
  ```
  takenAt, planName,
  fiveHourPct, fiveHourResetAt,
  sevenDayPct, sevenDayResetAt,
  (옵션) creditsBalance/hasCredits — wham/rate-limit-reset-credits
  ```
  `resets_in_seconds` → `Date()` + 초로 환산해 `resetAt` 저장 (Claude는 절대 ISO, Codex는 상대 초라 변환 필요).
- `CodexPlan` enum (`plus`, `pro`, `business`, `unknown`) + `from(_:)`.
- `CodexError` enum (Cursor와 동일 케이스: notInstalled/notLoggedIn/unauthorized/http/transport/decoding + **keyringStored** 신규).
- `wham/usage` 응답 디코딩 구조체 (`CodexUsageResponse`).

### 2-3. `UsageEvent.swift`
- `UsageSource`에 `.codexFiveHour`, `.codexSevenDay` 추가.
- `VibeCategory`에 `.codex` 추가할지 **결정 필요** (→ §4 결정 A). 추가 시 `vibeCategory` 분기 + 도장 카운터 영향.
- `coinFractionKeyPath`에 codex fraction 케이스.
- `UsageEventProducer.ingestCodex(_ snapshot:)` — `ingestClaude` 복제 (5h/7d delta, resetAt 60s slack, curve 적용).

### 2-4. `CoinLedger.swift`
- `codexPlanMultiplier(_:)` 또는 기존 `planMultiplier` 확장 (Plus/Pro multiplier — §4 결정 A).
- `codexPlanPriceVP(_:)` — VP 환산용 월 가격 (Plus≈$20→2000, Pro≈$200→20000 등 — §4 결정 B).
- `codexFiveHourMaxCoin` / `codexSevenDayMaxCoin` 상수 (Claude와 동일 30/60으로 시작 가능).
- `CoinSource`에 `.codex` 추가 + `credit(_:source:)` 분기 (②카운터 분리하려면).

### 2-5. `Settings.swift`
- 영속 필드 신규:
  - `lastCodexFiveHourReset/PctSeen`, `lastCodexSevenDayReset/PctSeen` (Producer state machine)
  - `codexFiveHourCoinFraction`, `codexSevenDayCoinFraction` (fractional carry)
  - `codexCoinsEarned` (②카운터 — 추가 시)
  - `petCodexParty: [PetSelection]`, `petCodexEnabled: Bool` (펫 차트 — §4 결정 C)
  - `section.codex.collapsed`
- 마이그레이션: 신규 필드라 기본값만. 기존 `applyOnceMigration` 패턴은 보너스 지급 시에만 필요(여기선 불필요).

### 2-6. `SnapshotStore.swift`
- `static let codex = JSONLStore<CodexSnapshot>(filename: "codex-snapshots.jsonl", label: ...)` 추가.

### 2-7. `ViewModel.swift`
- `@Published codexCurrent/codexHistory/codexLoading/codexError/codexLastSuccess/codexNeedsSetup`.
- `refreshCodex()` — `refreshClaude` 미러 (snapshot append, ingestCodex, alerts, pollOutcome).
- 폴링 루프(`startPolling`)에 `await refreshCodex()` 추가.
- `loadPersistedHistory`에 codex 로드 추가.
- projection getter (`codex5hProjectedPct` 등), `codexFiveHourSeries` 헬퍼 (claudeFiveHourSeries 복제).
- `nextPollDelay`의 resets 배열에 codex reset 2개 추가 (윈도우 끝 정밀 폴링).
- `accumulatePetUsage`에 codex 파티 추가 (펫 차트 채택 시).
- `isSchemaSuspect`에 `CodexError` 분기 추가.
- schema-suspect 카운터/알림에 codex source 추가.

### 2-8. `MainView.swift`
- Codex 섹션 추가 — **Cursor 섹션을 복제**가 가장 가까움 (5h/7d 두 게이지라 오히려 Claude 섹션 구조에 더 가까움; 실제로는 Claude 섹션 복제가 정답).
- `sectionHeader` + sparkline 2개(5h/7d) + `chartPet`/`chartTerrainDecor` 재사용.
- needsSetup(=auth.json 없음/keyring) 상태 UI — "Codex CLI 로그인 필요" 또는 "미설치 시 섹션 숨김".

### 2-9. `NotificationManager` (`evaluateClaudeAlerts` 미러)
- `codex.5h`, `codex.7d` 키로 임계 알림. dedup 패턴 동일.

### 2-10. `SettingsView.swift`
- Codex 펫 파티 선택/토글 UI (펫 차트 채택 시).
- (옵션) Codex 사용량 표시 on/off 토글.

### 2-11. `TUI.swift` (선택)
- 터미널 대시보드에 Codex 행 추가. 우선순위 낮음 — GUI 먼저.

### 2-12. 랭킹/VP (`VPLedger.swift`)
- `ingestCodex`가 vpFactor를 emit하면 VPLedger가 자동 처리 → 랭킹 점수에 반영됨.
- **VP 소급(backfill) 안 함** — 기존 결정([[vp-backfill-decision]])과 동일. Codex는 등록 시점부터 누적. (Codex는 단일 합산이 아니라 윈도우 pct delta라 Cursor보다 backfill 부적합성이 더 큼.)

## 3. 권장 구현 순서 (PR 분할)

비공식 endpoint + ad-hoc 서명이라 작은 PR로 점진 배포가 안전 (CLAUDE.md 원칙).

1. **PR 1 — 데이터 레이어**: `CodexAPI` + `CodexSnapshot`/Error/Models + SnapshotStore + `--check` 진단. UI 없이 `usage-diagnostics` skill로 실데이터 검증. **이 단계에서 실제 `wham/usage` 응답 JSON을 확정**(미확인 스키마 보정).
2. **PR 2 — 표시**: ViewModel refresh + MainView 섹션 + NotificationManager 알림. 보기만, 코인 적립 없음.
3. **PR 3 — 경제 통합**: UsageEvent/Producer + CoinLedger/VP + Settings 마이그레이션 + 펫 차트.
4. **PR 4 (옵션)** — TUI, SettingsView 토글 등 부가.

## 4. 확정된 결정 (오너 승인 완료)

- **A. 코인 multiplier — Plus 1.0 / Pro 2.5.** 가격 동급 Claude 플랜(Pro=1.0, Max20x=2.5)과 배율 일치. `CoinLedger.planMultiplier`에 Codex 분기 또는 `codexPlanMultiplier` 신설. 도장(Vibe Coder) 카운터는 **`VibeCategory.codex` 신설**(claude/cursor와 분리) + `Settings.codexCoinsEarned` ②카운터.
- **B. VP 환산 — Claude와 동일 (가격 비례).** `codexPlanPriceVP`: Plus=2000, Pro=20000 cents. 분모는 Claude와 동일(`claudeMaxPureCoinPerMonth=4578` 재사용 또는 codex 전용 max 산정). 소급(backfill) 안 함([[vp-backfill-decision]]).
- **C. 펫 차트 — 채택.** Claude/Cursor와 동일하게 `chartPet`/`petCodexParty`/`petCodexEnabled`로 펫 차트 제공. 세 번째 차트지만 Codex 미사용자는 섹션 숨김이라 영향 제한.
- **D. keyring 모드 — 미지원 안내 후 숨김.** `cli_auth_credentials_store: keyring`로 `auth.json` 부재 시 `CodexError.keyringStored`(또는 notLoggedIn) → "Codex CLI 파일 인증 필요" 안내 / 섹션 숨김. file 모드가 기본이라 대부분 커버. 수요 시 추후 Keychain 직접 조회 추가.

## 5. 리스크 / 주의

- **`wham/usage` 전체 응답 스키마 미확정** — OpenAI 비공개. PR 1에서 실제 응답을 떠서 파서 확정해야 함(추측 파싱 금지).
- **auth.json 스키마 2종 공존** — A/B 둘 다 처리 안 하면 일부 버전 사용자 누락.
- **비공식 endpoint fragility** — Cursor/Claude와 동일 리스크. 기존 `isSchemaSuspect` + 알림 + backoff 인프라에 codex를 끼우면 그대로 보호받음.
- **plan_type 누락 케이스** — 일부 환경 JWT에 `chatgpt_plan_type` 없음(보고서 §1). plan unknown fallback 필요.
- **SwiftPM 리소스 basename 유일성** — 신규 PNG 추가 시 주의(여기선 해당 없음, 코드만).
