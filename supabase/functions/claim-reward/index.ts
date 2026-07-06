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
  // rewardType은 서명 페이로드 밖 — coins/rp 라우팅용. 서명은 {deviceId,period,rank,ts}로 불변이라
  // 기존 클라(coins claim)와 호환된다. period/rank가 이미 서명돼 자기 보상만 수령 가능하므로 평문 OK.
  rewardType?: "coins" | "rp";
  // rp 원장 내 트랙 구분 (P2a) — 같은 period·rank에 개인(monthly)과 길드(guild-monthly) 보상이
  // 공존할 수 있어 라우팅이 필요. 서명 밖 평문 — 자기 row만 수령 가능하므로 rewardType과 동일 논리.
  // 구클라는 미전송 → 아래에서 "매칭 row 중 첫 미수령"을 수령 (둘 다 같은 RP 원장이라 총액 보존).
  periodType?: string;
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
  const rewardType = body.rewardType === "rp" ? "rp" : "coins";
  // period: coins=월간(YYYY-MM). rp=월간(YYYY-MM) 또는 주간(YYYY-Www).
  const periodOk = rewardType === "rp"
    ? /^\d{4}-(\d{2}|W\d{2})$/.test(p.period)
    : /^\d{4}-\d{2}$/.test(p.period);
  if (typeof p.period !== "string" || !periodOk) {
    return errorResponse(400, "invalid_period");
  }
  // rank: coins=Top3만. rp=전체 순위(1~).
  const rankOk = rewardType === "rp"
    ? (Number.isInteger(p.rank) && p.rank >= 1)
    : [1, 2, 3].includes(p.rank);
  if (typeof p.rank !== "number" || !rankOk) {
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

  // RP 보상 — rp_rewards 원장 (coins의 monthly_winners와 다른 테이블·컬럼).
  // 같은 (period, rank)에 개인·길드 트랙 row가 공존할 수 있어 단건 조회 대신 목록으로 받아
  // periodType 우선 매칭 → 첫 미수령 순으로 고른다 (구클라 호환 — §ClaimRequest 주석).
  if (rewardType === "rp") {
    let query = db
      .from("rp_rewards")
      .select("id, rp_amount, claimed_at, period_type")
      .eq("device_id", p.deviceId)
      .eq("period", p.period)
      .eq("rank", p.rank);
    if (typeof body.periodType === "string" && body.periodType.length > 0) {
      query = query.eq("period_type", body.periodType);
    }
    const { data: rows } = await query;
    if (!rows || rows.length === 0) return errorResponse(404, "no_pending_reward");
    const row = rows.find((r) => !r.claimed_at) ?? rows[0];
    if (row.claimed_at) {
      return jsonResponse({ alreadyClaimed: true, rewardType: "rp", rp: row.rp_amount, claimedAt: row.claimed_at });
    }
    const { error: rpErr } = await db
      .from("rp_rewards")
      .update({ claimed_at: new Date().toISOString() })
      .eq("id", row.id);
    if (rpErr) {
      console.error("rp claim update failed", rpErr);
      return errorResponse(500, "claim_failed");
    }
    return jsonResponse({ alreadyClaimed: false, rewardType: "rp", rp: row.rp_amount, claimedAt: new Date().toISOString() });
  }

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
      rewardType: "coins",
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
    rewardType: "coins",
    rewardCoins: winner.reward_coins,
    claimedAt: new Date().toISOString(),
  });
});
