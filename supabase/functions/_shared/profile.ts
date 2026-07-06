// =========================================================================
// SSOT: profile_json.backup 누출 방지.
// `BackupPayload` (ProfileState.swift)는 본인 디바이스 복구 전용 페이로드이며
// 다른 사용자에게는 절대 노출되면 안 된다. profileJson을 응답에 싣는 모든
// endpoint(leaderboard, guild-info, …)는 반드시 이 함수를 경유할 것.
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
