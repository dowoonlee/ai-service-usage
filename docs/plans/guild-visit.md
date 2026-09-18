# 길드 방문 · 방명록 — 기획

> 다른 길드 사무실에 놀러가서 구경하고 방명록을 남기는 기능. **M1(방문)·M2(방명록)·M3(답글) 구현 완료, M4는 선택.**
> 작성 시점: v0.17.39 기준 (2026-09-18).

## 0. 결론 요약

사무실 렌더(`GuildOfficeView`)는 이미 `GuildInfoResponse` 하나로 그려지는 순수 뷰라 **읽기 전용 플래그만 있으면 남의 사무실도 그대로 그린다.** 빠진 것은 서버 쪽 "남의 길드를 읽는 엔드포인트"뿐이다 — `guild-info`는 멤버십을 강제하고, `guild-leaderboard`는 이름·점수·상위 5명만 준다. 그래서 M1은 **`guild-visit` 읽기 함수 하나 + 클라 읽기 전용 모드 + 방문객 펫 연출**로 끝난다. 방명록(M2)은 게시판이 아니라 **길드 표면의 관례(비익명)** 를 따른다.

## 1. 확정 결정

| 항목 | 결정 | 근거 |
|---|---|---|
| 진입 | 랭킹 탭 길드 리더보드 행 + 미가입 온보딩 길드 목록 행의 **"놀러가기"** 버튼 → 가챠 창 위 시트 | 이미 타 길드가 나열되는 두 화면. 새 탭·창 없이 시트 |
| 방문 대상 | 같은 테넌트의 모든 길드 (내 길드 포함, 미가입자도 가능) | 온보딩 단계의 "둘러보기"가 곧 방문. 교차 테넌트는 서버 `cross_tenant` |
| 사무실 | `GuildOfficeView` **읽기 전용** — 재배치·상점·로고 드래그·리더 컨트롤 없음 | 뷰가 이미 서버 payload의 순수 함수. 콜백은 no-op |
| 방문객 연출 | 내 대표 펫이 사무실 왼쪽 밖에서 걸어 들어와 normal 모드로 배회 + 방문객 전용 대사 | "놀러갔다"는 감각의 핵심. 커피머신 방문·스침 인사 로직 재사용 |
| 멤버 노출 | 닉네임·대표 펫(kind/variant)·장착 이펙트·리더 여부·월 VP만. **`profileJson` 제외** | 방문은 여러 길드를 훑는 행위라 호출 빈도가 `guild-info`보다 높다. 응답 10KB 이하 유지 |
| 트레이너 카드 | 방문 화면에서는 팝오버 없음 (닉네임·VP만) | 위와 동일 — Egress |
| 폴링 | 없음. 시트 진입 시 1회 | `guild-info`가 300s 루프를 제거한 이유와 같음 |
| 방명록 익명성 | **비익명** — 작성자 닉네임 + 소속 길드명 + 대표 펫 | 길드 표면은 실명 관례(게시판만 밈 닉네임 익명). "○○ 길드의 △△가 다녀감"이 재미의 본체 |
| 보상 | **MVP 없음.** 방명록 개수 자체가 인기 지표 | 방문 보상은 호출 어뷰즈 유도, 방명록 보상은 "서로 써주기" 담합 |

## 2. M1 — 방문 (구현)

### 서버 `guild-visit` (POST, HMAC)

payload(flat): `{ deviceId, guildId, ts }`

1. 등록 사용자 확인 + `banned` 403 + HMAC 검증 (guild-info와 동일 뼈대).
2. `resolveTenant(deviceId)` vs `guilds.tenant_id` 불일치 → 403 `cross_tenant`. 없는 길드 → 404 `guild_not_found`.
3. 공개 프로젝션 반환:

```
guild:     { id, name, floorTheme, wallTheme, officeFurniture, logo, logoX, logoY,
             createdAt, score, rank, memberCount, isMine }
members:   [{ nickname, monthlyVP, isTopContributor, isLeader, isMe, joinedAt,
              petKind, petVariant, equippedEffects }]
furniture: [{ slotId, itemKind, donorNickname }]
```

제외: `inviteCode`, `deviceId`, `sentInvites`, `joinRequests`, `githubLogin`, `profileJson`.
`petKind`/`petVariant`/`equippedEffects`는 `profile_json`에서 그 필드만 뽑는다 (`guild-leaderboard`의 `topMembers`와 같은 방식).

### 클라이언트

- `RankingAPI.GuildMember`에 옵션 필드 `petKind`/`petVariant`/`equippedEffects` 추가. `guild-info`는 안 보내므로 nil. `OfficeSimulation.configure`는 `profileJson?.card.avatar`가 없으면 이 필드로 폴백.
- `RankingAPI.GuildVisitResponse` + `visitGuild(deviceId:guildId:)`. `asInfoResponse`로 `GuildInfoResponse`를 조립해 사무실 뷰에 넘긴다 (`inviteCode: ""`, `isLeader: false`).
- `GuildOfficeView(readOnly:guest:)` — 읽기 전용이면 상점 앵커·로고 드래그 비활성. `guest`는 시뮬레이션에 방문객 펫 1마리를 추가.
- `OfficeSimulation.Guest` — id는 `"__guest:"` 접두로 멤버와 충돌 방지. 씬 왼쪽 밖(x<0)에서 앞레인 왼쪽 자유 지점으로 걸어 들어온다. `isGuest` 펫은 방문객 대사 풀 사용.
- `GuildVisitView` — 시트. 헤더(로고·이름·순위·점수·인원) / 사무실 / 멤버 칩 줄. 최상위 `ScrollView` + `minHeight`.
- 진입: `GuildLeaderboardView(onVisit:)`, `GuildView.browseRow`의 버튼. `.sheet(item:)`.
- 프리뷰: `ScenePreviews.testRenderGuildVisit` (`PREVIEW_OUT_DIR`).

## 3. M2 — 방명록 (구현)

### 규칙

| 항목 | 값 | 근거 |
|---|---|---|
| 길이 | 60자 | 포디움 한 줄(50)과 게시판(100) 사이 |
| 작성 대상 | 타 길드만 | 자기 길드는 열람·삭제만 |
| 쿨다운 | 같은 길드 24h, 전체 10분 | 도배 방지. 게시판 쿨다운과 같은 감각 |
| 삭제 | 작성자 5분 내, 해당 길드 리더는 언제나 | 리더가 자기 집 청소 |
| GitHub 게이트 | 적용 (`board_policy.boardInteractionBlocked`) | 게시판과 동일 |
| 표시 | 최근 30개. 길드 해체 시 `ON DELETE CASCADE` | |
| shadow_banned | 게시판처럼 가짜 200 | |

### DB (마이그레이션 1개)

- `guild_guestbook`: `id bigserial`, `guild_id → guilds ON DELETE CASCADE`, `author_device_id → users ON DELETE SET NULL`, `author_nickname_snapshot`, `author_guild_name_snapshot`, `content CHECK 1..60`, `tenant_id`, `created_at`. 인덱스 `(guild_id, created_at DESC)`. RLS on, 정책 0개.
- `guild_guestbook_writes`: PK `(device_id, guild_id)`, `last_at`. 삭제해도 쿨다운이 살아남도록 별도 테이블 (`users.last_post_at`이 존재하는 이유와 같다).
- `guilds.last_guestbook_at` — 배지 카운트용.

### 서버

- `guild-guestbook` POST HMAC `{ action: write|delete, deviceId, guildId, content?, entryId?, ts }`. 옵션 키는 present-only 규약(`guild-request` 참조).
- 쓰기는 `guild_guestbook_write` RPC 한 트랜잭션: 전역 쿨다운(조건부 `UPDATE users`) → 길드별 쿨다운(`INSERT ... ON CONFLICT DO UPDATE ... WHERE`) → insert → `guilds.last_guestbook_at`. 거절은 `RAISE EXCEPTION '<code>:<retryAfterSec>'`로 전체 롤백(실패한 시도가 전역 쿨다운을 소모하지 않도록). Edge가 파싱해 `rate_limited`(429) / `guestbook_cooldown`(403)으로 매핑.
- `guild-visit` 응답에 `guestbook[30]` + `guestbookPolicy { canWrite, maxLen, cooldownRemainingSec, deleteWindowSec, requiresGitHub, canInteract, isLeader }`.
- `guild-info`에 `guestbook[10]` + `guestbookDeleteWindowSec` (60자×10 < 1KB).
- `sync` 배지에 `guestbookLatestAt` **스칼라**(내 길드 `guilds.last_guestbook_at`). 카운트 대신 최신 시각을 준 이유: 클라 `seenAt`을 payload에 넣으면 서명 대상이 바뀌어 구버전 클라/서버 조합이 깨진다. 클라가 자기 `guildGuestbookSeenAt`과 비교해 점만 찍는다.

### 클라이언트

- `GuildGuestbookRow`(공용 줄: 대표 펫 + 닉네임 + 소속 길드 + 상대 시각 + 삭제) — 방문 시트와 내 길드 화면이 공유.
- 방문 시트 하단: 목록 + 작성창. `BoardView`의 서버 주도 정책 패턴(글자 수 잘라내기, 쿨다운 틱, GitHub 안내 카드). 작성 성공 시 로컬 prepend + 24h 카운트다운 시드(재조회 없음).
- 내 길드 화면 "받은 방명록" 섹션(길드장 삭제). `guild-info` 성공 시 `guildGuestbookSeenAt = now`.
- 가챠 창 길드 탭: `Settings.hasUnseenGuestbook`이면 "길드 •".
- 에러 코드 `own_guild`, `guestbook_cooldown`, `entry_not_found`, `not_entry_owner`, `delete_window_expired`, `content_too_long`, `empty_content`를 `domainErrorCodes`와 한국어 메시지에 등록.

### 배포 순서

마이그레이션(`20260918000000_guild_guestbook.sql`) → 함수(`guild-visit`, `guild-guestbook`, `guild-info`, `sync`) → 클라 릴리스. 서버가 먼저 나가도 구버전 클라는 새 필드를 무시하므로 안전하다.

## 4. M3 — 방명록 답글 (구현)

방명록 한 줄에 답글을 다는 기능. 방문자가 남기고 끝나는 일방향을 "집주인이 답하는" 양방향으로.

### 결정

| 항목 | 안 | 근거 |
|---|---|---|
| 깊이 | **1단** — 방명록 아래 답글만, 답글의 답글 없음 | 60자 한 줄 문화에 스레드는 과함 |
| 답글 권한 | 그 길드 멤버(집주인) + 원글 작성자 | 방문자끼리 남의 집에서 대화하는 건 방명록 취지 밖 |
| 길이 | 60자 (원글과 동일) | |
| 쿨다운 | 전체 30초 (댓글 `COMMENT_COOLDOWN_SEC`와 동일), 길드별 24h 제한 없음 | 대화 흐름 허용, 스팸만 차단 |
| 삭제 | 작성자 5분 내, 길드장 언제나. 원글 삭제 시 CASCADE | 원글 규칙과 동일 |
| GitHub 게이트 | 적용 | |
| 표시 | 원글당 최근 3개 + "N개 더" (전체는 펼침) | 방문 응답 Egress — 30원글×답글 무제한은 안 됨 |

### 방문자가 답글을 읽는 경로 — 점을 따라 재방문

새 화면을 만들지 않는다. **가챠 창 "랭킹 •" → 스코프 "길드 •" → 그 길드 행의 놀러가기 버튼 점 → 방문 시트에서 답글.** 무소속 방문자도 랭킹 탭은 보이므로 자리 문제가 없다(온보딩 둘러보기 행의 버튼에도 같은 점).

- 신호: `sync` 배지 `guestbookReplies: [{guildId, latestAt}]` — 내가 쓴 원글에 달린 답글(본인 답글 제외)의 길드별 최신 시각, 최근 30일. 같은 길드엔 하루 한 번만 쓸 수 있어 목록이 작다.
- 읽음: 클라 `Settings.guestbookReplySeen[guildId]` — 그 길드 방문 시트를 열면 갱신. 서명 payload는 바뀌지 않는다.
- 집주인 쪽은 새 신호 없이 `guilds.last_guestbook_at`을 답글에도 갱신 → 기존 "길드 •"가 "내 길드 방명록에 새 활동"으로 확장.
- 한계: 리더보드는 상위 50개만 보여 주므로 순위 밖 길드의 답글은 버튼이 없어 닿지 않는다. 길드 수가 넘치면 "답글 온 길드" 행을 따로 띄우는 것으로 보완.

### 서버

- `guild_guestbook_replies(id, entry_id → guild_guestbook CASCADE, guild_id → guilds CASCADE, entry_author_device_id, author_*, content CHECK 1..60, tenant_id, created_at)`. `guild_id`·`entry_author_device_id`는 비정규화 — 배지 조회를 조인 없이 하기 위해(sync는 전 사용자가 600s마다 친다).
- `guild-guestbook`에 `reply` / `delete_reply` / `list_replies` 추가 (present-only 키 `entryId`/`replyId`/`content`). 쿨다운 30초는 마지막 답글 기준(댓글과 같은 방식).
- `guild-visit`·`guild-info`의 `guestbook[]`에 `replies[≤3]`(시간순) + `replyCount`. 전체는 `list_replies`.
- `guild-info`에 `guestbookCanInteract`(집주인 답글 작성창 게이트).

### 클라이언트

- `GuildGuestbookRow`가 답글 목록·"N개 더 보기"·답글 작성창까지 그린다. 방문 시트는 로컬 상태를 직접 갱신하고, 내 길드 화면은 `runAction` → refresh로 재정합(더 보기는 로컬 `expandedReplies`).
- `Settings.guestbookReplyLatest/Seen` + `guildsWithUnseenReplies`. 점 3곳: 가챠 탭 "랭킹 •", 스코프 "길드 •", 놀러가기 버튼 오버레이.
- 프리뷰 `ScenePreviews.testRenderGuildGuestbookRows`.

## 5. M4 — 선택

- 하루 첫 방명록 소액 코인 (로컬 `creditBonus`, dedup 키 `guestbook.daily`).
- "이번 주 방문 많은 길드" 같은 지표.

## 6. Egress 메모

- 방문 응답은 `profileJson` 없이 ~10KB. 리더보드 응답에 사무실 데이터를 섞지 않는다 (과거 `profile_json`을 실었다가 수백 KB가 된 기록, #238).
- 방문 화면에 폴링 없음. 방명록 새 글 신호는 `sync` 스칼라 배지로만.
