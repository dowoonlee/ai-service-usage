# 폴링 감축 계획 — 통합 sync 설계 (Edge Function 쿼터 대응)

## 배경

Supabase Free 플랜 Edge Function 쿼터는 **500,000회/월(약 16,700회/일)**이다. 과금은 응답 상태
코드와 무관하다 — *"charged … regardless of the response status code. Preflight (OPTIONS)
requests are not billed."* 서버에서 426으로 막아도 호출 수는 줄지 않는다(8/10 실측으로 확인).

실측 추이 (로그 샘플 100건 × 2회, 24시간 균등 환산 — 상한값):

| 시점 | 회/분 | 월 환산 | 쿼터 대비 |
|---|---:|---:|---:|
| #195 이전 | — | 1,350,000 | 270% |
| #195 배포 후 (8/7) | 25.0 | 1,080,000 | 216% |
| 서버 426 게이트 후 (8/10) | 20.0 | 864,000 | 173% |
| 쪽지·게시판 배경 폴링 제거 (구현됨, 미릴리스) | — | ~720,000 | 144% |
| **통합 sync + 구버전 해소 (본 계획)** | — | **~59,000** | **12%** |

사용자당 약 175회/일 기준 활성 90명까지 쿼터 안쪽 — Pro 플랜 전환 불필요.

## 확정 설계 — 단일 `sync` 엔드포인트

**스레드(active)를 제외한 모든 주기 폴링을 메인 사이클(600s) 1회의 `sync` 호출로 통합한다.**

### 요청/응답

```
POST /sync   (HMAC 서명)
payload: { deviceId, ts, want: "board,inbox",  boardSeenAt: <epoch sec> }
→ {
    badges: { dmUnread, invites, boardUnread, announcements },   // 항상 포함 (경량)
    inbox:  { threads: [...], invites: [...] },   // want에 "inbox" 있을 때만 (dm-inbox와 동일 형태)
    board:  { posts: [...] },                     // want에 "board" 있을 때만 (GET /board와 동일 형태)
    leaderboard: { entries: [...] },              // want에 "ranking" 있을 때만
    guild:  { ... },                              // want에 "guild" 있을 때만
    tenantAnnouncements: [...],                   // want에 "ranking" 있을 때만
  }
```

`want`는 지금 열려 있는 창 목록 — PollGate의 open 플래그에서 산출. 창이 닫혀 있으면 `badges`만
받아 배지를 갱신하고, 열려 있으면 그 화면의 전체 페이로드를 받는다. **안 보는 화면의 데이터를
받지 않으므로 Egress(Free 5GB/월)가 늘지 않는다.**

### 재검토에서 확정된 제약 4가지

1. **`want`는 배열이 아니라 CSV 문자열이어야 한다.** `_shared/hmac.ts`의 `canonicalize()`는
   **flat object만 지원**한다(파일 상단 주석에 명시 — "nested object/array 들어가면 재귀
   canonicalize 필요"). 배열을 넣으면 Swift `sortedKeys` 직렬화와 어긋나 서명이 항상 깨진다.
2. **HMAC 서명 필수.** inbox 섹션(스레드 목록·미확인 수)은 사적 데이터다. 기존 GET
   board/leaderboard처럼 deviceId만으로 열면 안 된다. 미등록자는 sync를 안 부르는데, 소셜
   기능 전부가 등록 전제라 기능 손실이 없다(`hasRankingPrerequisites` 가드 재사용).
3. **leaderboard 섹션은 반드시 `stripBackup()` 경유.** `profile_json.backup`은 본인 복구
   전용이다. `leaderboard/index.ts:124,169`가 유일한 차단 지점이며, profileJson을 싣는 새
   endpoint는 반드시 이걸 거쳐야 한다(supabase-ranking skill 보안 SSOT). **sync가 이 규칙의
   첫 적용 대상이다 — 놓치면 타 사용자 백업 페이로드가 유출된다.**
4. **`lastSyncAt` 스로틀(120s)이 필요하다.** 메인 사이클은 resetAt 임박 시 sleep을 60초
   미만으로 단축한다(`ViewModel.swift:339` resetGuard). 이때 사이클이 연달아 돌므로 sync를
   무조건 얹으면 초과 호출이 난다. 마지막 sync 후 120초 미만이면 건너뛴다.

### 새 폴링 루프를 만들지 않는다

sync는 **기존 메인 사이클의 `refreshBoardUnread()` 슬롯을 대체**한다. jitter(±15%)·PollGate
(sleep/visibility)·600s 주기가 이미 있으므로 재사용한다. 직전 변경에서 넣은 앱 시작 배지
시드(`DMViewModel.init`의 1회 fetch, `didSeedBoardUnread` 플래그)는 **sync가 대체하므로 제거**
— 첫 사이클이 시작 직후 돌아서 시드 역할을 겸한다.

부수 효과: 직전 변경으로 "배지가 실시간이 아니게 된" 트레이드오프가 **600s 단위 갱신으로
복원**된다. 배경 요청 0 → 사이클당 1회로 늘지만, 이 1회가 통합의 비용 전부다.

### 기존 엔드포인트는 유지한다 (sync는 주기 루프만 대체)

| 시점 | 경로 |
|---|---|
| 창 여는 순간 | 기존 전용 엔드포인트로 즉시 fetch (현행 유지) |
| 액션 (글쓰기·좋아요·쪽지 전송·읽음) | 기존 엔드포인트 (현행 유지) |
| 주기 갱신 | **sync만** — 각 뷰의 개별 폴링 루프는 전부 삭제 |
| 구버전 클라 | 기존 엔드포인트 그대로 (하위 호환) |

서버는 `_shared/guild_invites.ts` 패턴대로 board/inbox/leaderboard 조회 로직을 공유 모듈로
추출하고, 기존 endpoint와 sync가 같이 쓴다. 응답 형태를 기존과 동일하게 유지하므로 클라
디코딩 모델도 재사용된다.

### 스레드 — idle 폴링 제거, sync가 깨운다

- **active(마지막 활동 2분 내): 20s 유지.** 대화 중 UX는 양보하지 않는다.
- **idle: 폴링 0.** sync의 `badges.dmUnread`/inbox 섹션에서 열린 스레드 상대의 미확인이
  보이면 `refreshOpenThread()` → `lastThreadActivityAt` 갱신 → active로 복귀.
- APNs는 ad-hoc 서명이라 불가, Supabase Realtime은 RLS 정책 0개 + 비Auth(HMAC) 인증 모델이라
  "내 메시지만" 필터가 불가능해 보류. 폴링 wake가 현 구조의 최선이다.

**트레이드오프(명시):** idle 상태에서 새 메시지 발견 지연이 현행 최대 60s → **최대 600s**로
늘어난다. 진행 중 대화(2분 창)는 무영향. 읽음표시는 UI에 없어(`DisplayMessage`에 read 필드
없음) read receipt 회귀도 없다.

### 케이던스 변화 요약

| 화면 | 현행 | 후 |
|---|---:|---:|
| 게시판 (창 열림) | 180s | 600s |
| 랭킹 (창 열림) | 300s | 600s |
| 길드 (창 열림) | 300s | 600s |
| 스레드 idle | 60s | sync wake (≤600s) |
| 스레드 active | 20s | 20s |
| 배지 (창 닫힘) | 정지 (직전 변경) | 600s |

## 구현 상태 — 완료 (미릴리스)

### 서버 (배포 완료)

| 파일 | 내용 |
|---|---|
| `_shared/dm_inbox_query.ts` (신규) | dm-inbox 조회 추출. `totalUnread` 추가 |
| `_shared/board_query.ts` (신규) | board 조회·조립 추출 (익명 닉네임 시드 포함) |
| `_shared/leaderboard_query.ts` (신규) | leaderboard 조회 추출. **stripBackup 단일 차단 지점** |
| `sync/index.ts` (신규) | 통합 엔드포인트 |
| `dm-inbox` / `board` / `leaderboard` | 얇은 핸들러로 축소 (265→61, 261→54줄) |

리팩터 회귀 검증: 배포 전후 `board`·`leaderboard` 응답을 시간 의존 필드(`cooldownRemainingSec`,
`periodResetAt`) 제외하고 비교 → **완전 일치**.

sync 실호출 검증 (실제 HMAC 서명):

| want | 응답 | 섹션 |
|---|---:|---|
| (빈 문자열) | **70B** | 배지만 |
| `inbox` | 606B | inbox |
| `board` | 235B | board |
| `ranking` | 14,460B | leaderboard, tenantAnnouncements |
| `board,inbox,ranking` | 15,161B | 전부 |

서명 위조 → 401. `stripBackup` → entries 13건 중 backup 노출 0건.

### 클라 (빌드·테스트 190개 통과)

- `RankingAPI.sync()` — CSV `want`, `boardSeenAt` 전달
- `ViewModel.runSync()` — 메인 사이클에 편입, **120s 스로틀**(resetGuard 대비)
- 배분: `DMViewModel.applySync()` / `.boardSynced` / `.rankingSynced` 알림
- **삭제된 폴링 루프**: 인박스 300s, 게시판 180s, 랭킹 300s, 길드 300s, 스레드 idle 60s
- **남은 서버 폴링 루프: 스레드 active 20s 단 하나** (대화 중 UX)
- `PollGate.openSurfaces` — 열린 창 목록을 `want`로 산출

sync 실패는 메인 backoff에 연동하지 않는다(backoff는 Claude/Cursor/Codex 전용).

## 같은 릴리스에 묶는 재발 방지 (Phase 3)

1. **모든 요청에 `appVersion` 헤더** — 서버 게이트의 DB 조회·stale 문제 제거.
2. **426 수신 시 폴링 중단 + 안내 UI** — sync 루프가 426을 받으면 사이클에서 sync를 멈추고
   업데이트 안내를 띄운다. 구버전이 차단 후에도 계속 두드리는 구조적 문제의 근본 해결.
3. **`SUAutomaticallyUpdate=true`** (`scripts/package.sh`).

## 검증

- 릴리스 24시간 후 로그 샘플 2회 재측정 — 목표 **신버전 사용자당 200회/일 이하**.
- `users.app_version` 분포로 적용률 확인.
- 창 닫기(타이틀바 X) 후 로그에서 해당 사용자의 board/inbox 호출이 sync 1개로 수렴하는지 확인
  (`isReleasedWhenClosed=false` 창은 `onDisappear`가 안 와서 WindowController
  `windowWillClose`가 소유 — 직전 변경에서 확립한 패턴).
