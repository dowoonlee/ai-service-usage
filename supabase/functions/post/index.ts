// POST /post
// 게시판 글 작성. HMAC 서명 + 100자 제한 + 10분 cooldown.
//
// rate limit: 본인의 마지막 board_posts row가 600초 이내면 429.
// 클라이언트가 lastBoardPostAt 캐시를 잃거나 시계 조작해도 서버측이 권위.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface PostPayload {
  deviceId: string;
  content: string;
  ts: number;
}
interface PostRequest {
  payload: PostPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const POST_COOLDOWN_SEC = 600;     // 10분
const MAX_CONTENT_LENGTH = 100;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: PostRequest;
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
  if (typeof p.content !== "string") return errorResponse(400, "invalid_content");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  // 내용 검증 — trim 후 1~100자.
  const content = p.content.trim();
  if (content.length === 0) return errorResponse(400, "empty_content");
  if (content.length > MAX_CONTENT_LENGTH) return errorResponse(400, "content_too_long");

  const db = getDb();
  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, nickname, status")
    .eq("device_id", p.deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { content: p.content, deviceId: p.deviceId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 서버측 rate limit — 본인 가장 최근 글 시각 기준.
  const cooldownThreshold = new Date(Date.now() - POST_COOLDOWN_SEC * 1000).toISOString();
  const { data: recent } = await db
    .from("board_posts")
    .select("created_at")
    .eq("device_id", p.deviceId)
    .gte("created_at", cooldownThreshold)
    .order("created_at", { ascending: false })
    .limit(1);
  if (recent && recent.length > 0) {
    const lastAt = new Date(recent[0].created_at).getTime();
    const remainingSec = Math.ceil((lastAt + POST_COOLDOWN_SEC * 1000 - Date.now()) / 1000);
    return jsonResponse(
      { error: "rate_limited", retryAfterSec: Math.max(1, remainingSec) },
      { status: 429 },
    );
  }

  // shadow_banned는 insert 자체를 스킵 — 본인에겐 200 응답으로 잠잠.
  if (user.status === "shadow_banned") {
    return jsonResponse({ accepted: true, postId: null });
  }

  const { data: inserted, error: insertErr } = await db
    .from("board_posts")
    .insert({
      device_id: p.deviceId,
      nickname_snapshot: user.nickname,
      content,
    })
    .select("id, created_at")
    .single();
  if (insertErr || !inserted) {
    console.error("board post insert failed", insertErr);
    return errorResponse(500, "insert_failed");
  }

  return jsonResponse({
    accepted: true,
    postId: inserted.id,
    createdAt: inserted.created_at,
  });
});
