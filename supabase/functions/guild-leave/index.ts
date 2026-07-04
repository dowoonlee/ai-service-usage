// POST /guild-leave
// 길드 탈퇴. 멤버 row 삭제 → DB 트리거(guild_member_exit_fixup)가 길드장 승계/빈 길드
// 해체를 처리. 탈퇴자는 재가입 쿨다운을 받는다 (월말 용병 이적 완화).
//
// payload(서명 대상, flat): { deviceId, ts }

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { JOIN_COOLDOWN_SEC } from "../_shared/guild_policy.ts";

interface LeavePayload {
  deviceId: string;
  ts: number;
}
interface LeaveRequest {
  payload: LeavePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: LeaveRequest;
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
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  const { data: membership } = await db
    .from("guild_members")
    .select("guild_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!membership) return errorResponse(404, "not_in_guild");

  const { error: delErr } = await db
    .from("guild_members")
    .delete()
    .eq("device_id", deviceId);
  if (delErr) {
    console.error("guild leave delete failed", delErr);
    return errorResponse(500, "leave_failed");
  }

  // 쿨다운 기록 — upsert로 갱신. best-effort가 아니라 정책의 일부이므로 실패 로깅.
  const until = new Date(Date.now() + JOIN_COOLDOWN_SEC * 1000).toISOString();
  const { error: cdErr } = await db
    .from("guild_join_cooldowns")
    .upsert({ device_id: deviceId, until });
  if (cdErr) {
    console.error("guild leave cooldown upsert failed", cdErr);
  }

  return jsonResponse({ ok: true, cooldownUntil: until });
});
