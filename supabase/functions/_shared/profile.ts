// =========================================================================
// SSOT: profile_json.backup 누출 방지.
// `BackupPayload` (ProfileState.swift)는 본인 디바이스 복구 전용 페이로드이며
// 다른 사용자에게는 절대 노출되면 안 된다. profileJson을 응답에 싣는 모든
// endpoint(leaderboard, guild-info, …)는 반드시 이 함수를 경유할 것.
//
// 이 함수는 **2차 방어선**이다. 1차는 DB로 내려가 있다 —
// monthly_leaderboard 뷰와 monthly_winners 스냅샷은 backup을 아예 담지 않는다
// (20260818000000_strip_backup_at_db_boundary.sql). 함수 단계에서만 떨구면
// DB→함수 구간 Egress는 그대로 나가기 때문이고, 실제로 그게 무료 플랜 Egress의
// 대부분이었다. users 테이블을 직접 읽는 경로는 여전히 원본을 받으므로
// 이 함수는 계속 필요하다 — 두 겹 다 유지할 것.
//
// 두 구현은 의미가 같아야 한다: 객체가 아니면 그대로 두고, 객체면 "backup" 키만
// 제거. SQL 쪽은 `jsonb - text`가 스칼라에서 에러라 jsonb_typeof 가드를 쓴다.
//
// 새 백업 필드 추가 시 점검:
//   - ProfileState.BackupPayload에 필드 추가
//   - Settings.applyBackup 머지 정책 정의
//   - 본 함수는 키 화이트리스트 방식이 아니라 "backup" 키 자체를 통째로 drop
//     하므로 백업 페이로드 내부 필드 추가는 본 함수 수정 불필요. 단, 백업이
//     아닌 새 민감 필드를 ProfileState에 직접 추가한다면 키 화이트리스트
//     방식으로 전환 검토.
// =========================================================================
export function stripBackup(pj: unknown): unknown {
  if (pj && typeof pj === "object" && pj !== null && "backup" in pj) {
    const { backup: _drop, ...rest } = pj as Record<string, unknown>;
    return rest;
  }
  return pj;
}
