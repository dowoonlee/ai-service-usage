// POST /set-podium-message
// 월별 우승자(1·2·3위)가 본인 시상대 칸에 한마디를 1회 등록. HMAC-signed payload로 본인 인증.
// immutable — 이미 설정된 row면 기존 값 반환(변경 불가). 50자 이내, 제어문자 금지.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface Payload {
  deviceId: string;
  message: string;
  period: string;
  rank: number;
  ts: number;
}
interface Req {
  payload: Payload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const MAX_LEN = 50;

// 제어문자(0x00-0x1f, 개행 포함) + DEL(0x7f) 포함 여부. 말풍선 레이아웃 보호용.
function hasControlChar(s: string): boolean {
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 0;
    if (c < 0x20 || c === 0x7f) return true;
  }
  return false;
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: Req;
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
  if (typeof p.message !== "string") return errorResponse(400, "invalid_message");
  const msg = p.message;
  // 코드포인트 길이 — PG char_length 및 클라이언트 표기와 일치.
  const len = [...msg].length;
  if (len < 1 || len > MAX_LEN) return errorResponse(400, "invalid_message_length");
  if (hasControlChar(msg)) return errorResponse(400, "invalid_message_chars");

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

  // 서명 대상은 클라이언트가 보낸 raw message 그대로 (canonicalize = 키 정렬 + JSON.stringify).
  const ok = await verifyHmac(
    { deviceId: p.deviceId, message: msg, period: p.period, rank: p.rank, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 본인이 그 (period, rank)의 우승자인지 확인.
  const { data: winner } = await db
    .from("monthly_winners")
    .select("id, podium_message")
    .eq("device_id", p.deviceId)
    .eq("period", p.period)
    .eq("rank", p.rank)
    .maybeSingle();
  if (!winner) return errorResponse(404, "not_a_winner");

  // 이미 등록됨 — immutable. 기존 값 반환 (클라이언트가 동기화).
  if (winner.podium_message != null) {
    return jsonResponse({ alreadySet: true, message: winner.podium_message });
  }

  // race-safe: podium_message가 여전히 NULL일 때만 set.
  const { data: updated, error } = await db
    .from("monthly_winners")
    .update({ podium_message: msg })
    .eq("id", winner.id)
    .is("podium_message", null)
    .select("podium_message")
    .maybeSingle();
  if (error) {
    console.error("set podium_message failed", error);
    return errorResponse(500, "update_failed");
  }
  if (!updated) {
    // 동시 요청이 먼저 set — 현재 값 재조회 후 반환.
    const { data: cur } = await db
      .from("monthly_winners")
      .select("podium_message")
      .eq("id", winner.id)
      .maybeSingle();
    return jsonResponse({ alreadySet: true, message: cur?.podium_message ?? msg });
  }
  return jsonResponse({ alreadySet: false, message: updated.podium_message });
});
