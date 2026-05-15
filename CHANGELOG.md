# Changelog

본 파일은 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 톤을 따르며, 버전 표기는
[SemVer](https://semver.org/lang/ko/) 기준입니다.

## [Unreleased]

## [0.8.1] — 2026-05-15

### Added
- 상점 페이지 펫 미리보기에 이로치(variant) 토글 selector — dot 4개 직접 클릭으로 해금된
  variant 즉시 확인. 잠긴 variant는 회색/비활성.
- 게시판 글 작성 후 **1분 이내 본인 글 삭제** 가능. 카운트다운 (`Ns`)이 trash 버튼에 표시되고
  60초 지나면 자연스럽게 사라짐. 좋아요는 FK CASCADE로 자동 정리.

### Changed
- 게시판 표시 범위: 최근 100개 → **최근 1일 + 최대 100개**. DB는 영구 보관, UI 노출만 제한.
- 메뉴바 statusItem 우클릭 메뉴에서 "💬 게시판" 항목 제거. 진입은 메인 패널 코인 옆 아이콘으로 단일화.
- 게시판 cooldown 기준이 `board_posts.created_at` → `users.last_post_at`으로 변경. 글 작성 후
  삭제해도 cooldown 그대로 유지 — 어뷰징(작성→삭제→즉시 재작성) 차단.

### Fixed
- `shadow_banned` 사용자가 좋아요는 그대로 동작하던 문제 — `post`와 동일하게 silent skip
  (DB 변경 X, 본인에겐 정상 응답).

### Build
- GitHub Actions 환경변수 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` 설정. 2026/6/2 Node 20 →
  Node 24 강제 전환 deprecation 사전 해소. actions major bump (checkout v6 / upload-artifact v7
  / action-gh-release v3)는 별도 PR로 분리.

### Docs
- `CHANGELOG.md` 신설.

## [0.8.0] — 2026-05-15

### Added
- **명예의 전당** — 매월 1일 KST에 직전 달 Top 3 동결. 1/2/3등에게 각각 10,000 / 5,000 / 2,500
  coin 자동 보상. `RankingView` 상단 카드에서 한 달 내내 표시.
  - `claim-reward` Edge Function (HMAC-signed, idempotent)
  - `monthly_winners` 테이블 + `finalize_previous_month_if_needed()` lazy trigger
  - 알림: `🥇/🥈/🥉 명예의 전당` 시스템 노티
- **미니 게시판** — 100자 이내 텍스트 + 좋아요 + 마우스 호버 popover로 누른 사람 표시.
  - 1인당 10분 쓰기 cooldown (서버 권위)
  - 좋아요 연타 방지: in-flight + 1초 cooldown + optimistic toggle
  - 메인 패널 코인 옆 진입점 + 미확인 글 카운트 배지 (본인 글 제외)
  - 랭킹 미참여/일시중지 시 차단 + 케이스별 안내

### Changed
- `Settings.boardLastSeenAt` 추가 — 첫 fetch에서 현재 시각으로 시드 (과거 글 unread 미잡음).
- `ViewModel.boardUnreadCount` polling cycle (10분)에서 갱신 + BoardView active 동안 즉시 0 유지.

### Fixed
- `monthly_winners` RLS 활성화 — 이전 누락 fixup. anon 직접 query 차단.
- Keychain in-memory 캐시 도입 — 좋아요/글쓰기마다 SecItemCopyMatching → ad-hoc 서명 ACL
  무효화로 prompt 폭주하던 문제. 같은 process 안에서는 1회 query로 축소.

### Build
- `UsageSource.coinFractionKeyPath`에 `@MainActor` 명시 — Swift 6 mode 호환.

## [0.7.2] — 2026-05-14

### Added
- 트레이너 카드 액세서리 transform (드래그 위치 + 크기 조절) + 구매 확인 다이얼로그.

### Changed
- 액세서리 이름: `scarf` → `tshirt`, `ribbon` → `gift`.

## [0.7.1] — 2026-05-08

### Fixed
- `TrainerCardView` / `ReportView`에 `@MainActor` 명시 — GitHub Actions strict concurrency 빌드
  실패 해소.

## [0.7.0] — 2026-05-08

### Added
- **트레이너 카드 Report 탭** — Phase A–E 풀 스펙. 펫/액세서리/배지/스탯/컬렉션을 하나의
  카드 형태로 통합 표시.
- 외부 기여자 PR 보너스 단가: 50 → **1,000 coin** 상향.

### Promo
- 5월의 달 기념 일회성 캠페인: 기존 사용자에게 5,000 coin 지급 (`hasReceivedMay2026Bonus` flag).

## [0.6.x] 이전

이전 버전은 git log를 참고하세요. 주요 변경:
- 0.6.9: 컬렉션 업적 카드 → 입체 뱃지 + 호버 popover
- 0.6.8: 펫 컬렉션 셋 보너스 (75종 × 11 그룹)
- 0.6.7: Claude 5h/7d 코인 미적립 fix (resetAt 60초 슬랙)
- 0.6.6: wellness 1시간 쿨다운 재실행 유지
- 0.6.5: 가챠 비용 300 고정
- 0.6.3: 뱃지 보상 dedup + variant 합산 진행도
- 0.6.2: Cursor events 중복 적립 race fix
- 0.6.0: 가챠/도감 시스템 (75종 펫 + 4-tier rarity + 4 variant)
