// 최소 지원 클라이언트 버전 게이트.
//
// 배경: v0.17.11 미만 클라는 쪽지 스레드를 8초(이후 20/60초), 게시판을 60초(이후 180초)로
// 폴링하고, 패널을 닫아도 뷰 레벨 루프가 멈추지 않는다(PollGate 도입 이전). 구버전 몇 대만으로
// 무료 플랜 invocation 쿼터를 넘기므로, 폴링 부하가 큰 함수(dm-thread/dm-read/board)만 막는다.
// submit/leaderboard 등 나머지는 그대로 둔다 — 조용히 멈추면 사용자에겐 그냥 고장으로 보인다.
//
// 응답이 평문 426인 이유: 구버전 클라의 에러 매핑이 403 → "이 계정은 운영 정책 위반으로
// 차단되었습니다", 409/412/429 → 각각 닉네임·처리방침·글쓰기 쿨다운 문구로 고정돼 있어 오해를
// 부른다. 매핑되지 않은 코드만 `.http(code, body)`로 떨어져 "서버 오류 <code>: <body>"로 body가
// 그대로 노출된다. 이때 JSON을 보내면 `{"error":"..."}` 원문이 통째로 보이므로 평문이어야 한다.

import { corsHeaders } from "./cors.ts";

export const MIN_APP_VERSION = "0.17.11";

/** dotted numeric 비교. 자리수가 달라도 짧은 쪽을 0으로 채운다. a<b면 -1, 같으면 0, a>b면 1. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map((s) => parseInt(s, 10) || 0);
  const pb = b.split(".").map((s) => parseInt(s, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

/**
 * `users.app_version` 기준 게이트. 막아야 하면 426 응답을, 통과면 null을 반환한다.
 *
 * version이 null/빈 문자열이면 통과시킨다 — 등록 직후 첫 submit 전에는 기록이 없어서
 * (users.app_version은 submit에서만 갱신된다) 신규 사용자를 막아버리게 된다.
 *
 * 같은 이유로 이 값은 최대 한 사이클 stale하다: submit은 `delta > 0`일 때만 나가므로
 * (ViewModel.submitRankingIfNeeded) 업데이트 직후 AI를 쓰기 전까지 DB엔 구버전이 남는다.
 * 이미 업데이트한 사용자가 잠깐 걸릴 수 있어 문구로 안내한다 — 사용량이 한 번 반영되면 풀린다.
 */
export function outdatedClientResponse(version: string | null | undefined): Response | null {
  if (!version) return null;
  if (compareVersions(version, MIN_APP_VERSION) >= 0) return null;
  const msg = `업데이트가 필요합니다 (현재 ${version} → ${MIN_APP_VERSION} 이상).`
    + ` 상단 버전 칩을 눌러 업데이트해 주세요.`
    + ` 이미 하셨다면 잠시 후 자동으로 풀립니다.`;
  return new Response(msg, {
    status: 426,
    headers: { ...corsHeaders, "Content-Type": "text/plain; charset=utf-8" },
  });
}
