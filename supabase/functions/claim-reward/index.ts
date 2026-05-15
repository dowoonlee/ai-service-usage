// POST /claim-reward
// 명예의 전당 보상 수령 confirm. HMAC-signed payload로 본인 인증.
// 이미 claim된 row면 idempotent 응답 (클라이언트 재시도/race 안전).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface ClaimPayload {
  deviceId: string;
  period: string;
  rank: number;
  ts: number;
}
interface ClaimRequest {
  payload: ClaimPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: ClaimRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.period !== "string" || !/^\d{4}-\d{2}$/.test(p.period)) {
    return errorResponse(400, "invalid_period");
  }
  if (typeof p.rank !== "number" || ![1, 2, 3].includes(p.rank)) {
    return errorResponse(400, "invalid_rank");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const db = getDb();
  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", p.deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, period: p.period, rank: p.rank, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 해당 row 조회 + claim 여부 확인.
  const { data: winner } = await db
    .from("monthly_winners")
    .select("id, reward_coins, reward_claimed_at")
    .eq("device_id", p.deviceId)
    .eq("period", p.period)
    .eq("rank", p.rank)
    .maybeSingle();
  if (!winner) return errorResponse(404, "no_pending_reward");

  // 이미 claim됨 — idempotent 응답 (클라이언트 재시도 안전).
  if (winner.reward_claimed_at) {
    return jsonResponse({
      alreadyClaimed: true,
      rewardCoins: winner.reward_coins,
      claimedAt: winner.reward_claimed_at,
    });
  }

  // claim 완료 처리.
  const { error } = await db
    .from("monthly_winners")
    .update({ reward_claimed_at: new Date().toISOString() })
    .eq("id", winner.id);
  if (error) {
    console.error("claim update failed", error);
    return errorResponse(500, "claim_failed");
  }

  return jsonResponse({
    alreadyClaimed: false,
    rewardCoins: winner.reward_coins,
    claimedAt: new Date().toISOString(),
  });
});
