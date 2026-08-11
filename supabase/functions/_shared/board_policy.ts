// 게시판 시간 정책 SSOT — board, post, delete-post 함수가 모두 여기서 import.
//
// 정책 변경 시 이 파일만 수정하면 서버 측 3개 함수와 board 응답을 통한 클라이언트
// UI 라벨/카운트다운까지 자동 동기화됨. 단위는 의도적으로 분리:
//   - displayWindowHours: 시간(클라가 "N일 / N시간" 라벨을 동적 생성하기 편함)
//   - postCooldownSec / deletePostWindowSec: 초(서버 측 timestamp 산술과 직접 매칭)

export const DISPLAY_WINDOW_HOURS = 24;
export const POST_COOLDOWN_SEC = 600;
export const DELETE_POST_WINDOW_SEC = 60;

// 댓글 정책 — comment, delete-comment 함수 + board 응답이 공유.
export const COMMENT_MAX_LEN = 200;
export const COMMENT_COOLDOWN_SEC = 30;      // 글(600s)보다 짧게 — 대화 흐름 허용, 스팸만 차단
export const DELETE_COMMENT_WINDOW_SEC = 60;

// 쓰기 게이트 — GitHub 미연동 계정은 읽기 전용. 익명 어뷰징 대응(작성자 추적 수단이
// device_id뿐이라 실효 제재가 어려움) + 최소한의 신원 담보.
//
// 적용 범위: post / like / comment / comment-like (쓰기 4종).
// 비적용: 조회, delete-post / delete-comment — 본인이 이미 만든 콘텐츠 정리는 게이트와
// 무관하게 허용한다(게이트 도입 후엔 새 글 자체가 안 생기므로 사실상 사문화된 경로).
export const BOARD_REQUIRES_GITHUB = true;

/** 게시판 쓰기가 막혀야 하는 계정인지. 호출부는 403 `github_required`로 매핑. */
export function boardInteractionBlocked(
  user: { github_login?: string | null },
): boolean {
  return BOARD_REQUIRES_GITHUB && !user.github_login;
}
