// 어뷰징 캡 정책. 클라이언트가 한 번에 보낼 수 있는 코인 delta 최대치.
//
// 기준치 산출:
//   - 사용자가 100% 활동 시 일일 최대 적립 ~500 coin (Claude 7d × max plan multiplier
//     + 5h 반복 + Cursor Ultra + Wellness + 가끔 PR/컬렉션). 1.3 마진 → 650/day.
//   - 0.05 coin/sec ≈ 4320/day → 사실상 어떤 정상 사용자도 못 닿는 상한.
//   - 컬렉션 보너스 burst (Legendary 컬렉션 = 25,000 coin)를 흡수하기 위해 floor 1000.
//   - 절대 ceiling 50,000 — 1개월 비활성 후 한 번에 보낼 수 있는 max. 정상 사용자는
//     월 ~15,000 coin이라 여유 있고, cheater가 한 번에 1M씩 보내는 건 차단.

const MAX_RATE_COINS_PER_SEC = 0.05;
const FLOOR_COINS = 1000;
const CEILING_COINS = 50000;

export function maxAllowedDelta(elapsedSeconds: number): number {
  const safeElapsed = Math.max(0, elapsedSeconds);
  const rateBased = Math.floor(safeElapsed * MAX_RATE_COINS_PER_SEC);
  return Math.min(CEILING_COINS, Math.max(FLOOR_COINS, rateBased));
}

export type CapDecision =
  | { kind: "ok"; accepted: number }
  | { kind: "truncated"; accepted: number; requested: number }
  | { kind: "rejected"; reason: string };

export function evaluateCap(args: {
  delta: number;
  elapsedSeconds: number;
  prevTotalReported: number;
  prevTotalServer: number;
}): CapDecision {
  const { delta, elapsedSeconds, prevTotalReported, prevTotalServer } = args;

  if (!Number.isFinite(delta) || delta < 0 || delta > 1_000_000_000) {
    return { kind: "rejected", reason: "invalid_delta" };
  }
  if (!Number.isFinite(elapsedSeconds) || elapsedSeconds < 0) {
    return { kind: "rejected", reason: "invalid_elapsed" };
  }
  // prevTotal은 sanity check — 10% 또는 1000 coin 중 큰 값보다 많이 어긋나면 reject.
  // 작은 차이는 정상 (네트워크 race, 캐시 stale 등).
  const drift = Math.abs(prevTotalReported - prevTotalServer);
  const driftAllowed = Math.max(1000, prevTotalServer * 0.1);
  if (drift > driftAllowed) {
    return { kind: "rejected", reason: "prev_total_mismatch" };
  }

  const cap = maxAllowedDelta(elapsedSeconds);
  if (delta <= cap) return { kind: "ok", accepted: delta };
  return { kind: "truncated", accepted: cap, requested: delta };
}
