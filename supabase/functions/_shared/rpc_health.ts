// best-effort RPC 호출 — 실패해도 요청은 계속하되, 실패한 흔적은 반드시 남긴다 (#243).
//
// `db.rpc()` 는 throw 하지 않고 `{ data, error }` 를 돌려준다. 그래서 `error` 를 안 읽으면
// 실패가 **완전히 무음**이다. 정산 계열 9개 호출부 중 8개가 그 상태였고, 그 결과 아레나 시즌
// 정산이 19일간 매 호출 실패하는 동안 로그 한 줄 남지 않았다(PR #242).
//
// 이 헬퍼의 계약:
//   * 실패해도 throw 하지 않는다 — 랭킹/보드 조회는 정산 성패와 무관하게 응답해야 한다.
//     정산은 어디까지나 lazy 부수효과다.
//   * 대신 실패를 console.error + `rpc_failures` 테이블 양쪽에 남긴다. 로그만으로는 부족하다 —
//     무료 플랜 로그 보존이 24시간이라 그 창을 놓치면 흔적이 사라진다.
//   * 성공 시에는 **아무것도 쓰지 않는다.** 호출부가 sync/leaderboard 같은 고빈도 경로라
//     정상 트래픽에 쓰기를 붙이면 안 된다(현재 병목은 Egress).
//
// 기록 자체가 실패하는 경우(기록용 RPC 마저 죽는 상황)도 삼키고 로그만 남긴다. 여기서 throw 하면
// 정산 실패가 조회 실패로 승격돼, 고치려던 문제보다 큰 문제를 만든다.

import { getDb } from "./db.ts";

type Db = ReturnType<typeof getDb>;

export interface BestEffortResult {
  /** RPC 반환값. 실패했으면 null/undefined 다 — 호출부는 ok 를 보고 판단할 것. */
  data: unknown;
  /** RPC 가 에러 없이 끝났는지. */
  ok: boolean;
}

export async function callBestEffortRpc(
  db: Db,
  fn: string,
  args?: Record<string, unknown>,
): Promise<BestEffortResult> {
  const { data, error } = args === undefined
    ? await db.rpc(fn)
    : await db.rpc(fn, args);

  if (!error) return { data, ok: true };

  const detail = [error.code, error.message].filter(Boolean).join(" ").slice(0, 500);
  console.error(`rpc failed (ignored): ${fn} — ${detail}`);

  try {
    const { error: recErr } = await db.rpc("record_rpc_failure", { p_fn: fn, p_error: detail });
    if (recErr) console.error(`rpc failure record failed: ${fn} — ${recErr.message}`);
  } catch (e) {
    console.error(`rpc failure record threw: ${fn}`, e instanceof Error ? e.message : String(e));
  }

  return { data: null, ok: false };
}
