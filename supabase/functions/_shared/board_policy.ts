// 게시판 시간 정책 SSOT — board, post, delete-post 함수가 모두 여기서 import.
//
// 정책 변경 시 이 파일만 수정하면 서버 측 3개 함수와 board 응답을 통한 클라이언트
// UI 라벨/카운트다운까지 자동 동기화됨. 단위는 의도적으로 분리:
//   - displayWindowHours: 시간(클라가 "N일 / N시간" 라벨을 동적 생성하기 편함)
//   - postCooldownSec / deletePostWindowSec: 초(서버 측 timestamp 산술과 직접 매칭)

export const DISPLAY_WINDOW_HOURS = 24;
export const POST_COOLDOWN_SEC = 600;
export const DELETE_POST_WINDOW_SEC = 60;
