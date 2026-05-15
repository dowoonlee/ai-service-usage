// POST /like
// 게시글 좋아요 toggle. 1인 1글 1좋아요. INSERT … ON CONFLICT DO NOTHING → rowCount=0이면 DELETE.
//
// PK (post_id, device_id)가 멱등성 보장 — 동시 호출이 들어와도 DB 차원에서 한 번만 적용.
// 클라이언트는 응답의 (liked, count) 기준으로 UI 동기화.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface LikePayload {
  deviceId: string;
  postId: number;
  ts: number;
}
interface LikeRequest {
  payload: LikePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: LikeRequest;
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
  if (typeof p.postId !== "number" || !Number.isInteger(p.postId) || p.postId <= 0) {
    return errorResponse(400, "invalid_post_id");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const db = getDb();
  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, nickname, status")
    .eq("device_id", p.deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, postId: p.postId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 글 존재 검증 — 없으면 like 자체 거부.
  const { data: postRow } = await db
    .from("board_posts")
    .select("id")
    .eq("id", p.postId)
    .maybeSingle();
  if (!postRow) return errorResponse(404, "post_not_found");

  // shadow_banned는 DB 변경 없이 silent 응답 — 본인에겐 toggle된 것처럼 보이지만
  // 다른 사용자에겐 좋아요 안 보임. post의 shadow_banned 처리와 일관.
  if (user.status === "shadow_banned") {
    const { data: existing } = await db
      .from("board_post_likes")
      .select("post_id")
      .eq("post_id", p.postId)
      .eq("device_id", p.deviceId)
      .maybeSingle();
    const { count } = await db
      .from("board_post_likes")
      .select("post_id", { count: "exact", head: true })
      .eq("post_id", p.postId);
    // 실제 DB 상태 그대로 반환 — 매 호출마다 같은 응답 (사용자 입장 always "안 눌린 상태").
    return jsonResponse({ liked: !!existing, count: count ?? 0 });
  }

  // 현재 좋아요 상태 조회 → toggle 결정.
  const { data: existing } = await db
    .from("board_post_likes")
    .select("post_id")
    .eq("post_id", p.postId)
    .eq("device_id", p.deviceId)
    .maybeSingle();

  let liked: boolean;
  if (existing) {
    // 이미 좋아요 → unlike (DELETE)
    const { error: delErr } = await db
      .from("board_post_likes")
      .delete()
      .eq("post_id", p.postId)
      .eq("device_id", p.deviceId);
    if (delErr) {
      console.error("like delete failed", delErr);
      return errorResponse(500, "delete_failed");
    }
    liked = false;
  } else {
    // 미좋아요 → INSERT. ON CONFLICT는 race 시 무시 (이미 누군가 insert한 경우 → liked로 취급).
    const { error: insErr } = await db
      .from("board_post_likes")
      .insert({
        post_id: p.postId,
        device_id: p.deviceId,
        nickname_snapshot: user.nickname,
      });
    if (insErr && insErr.code !== "23505") {  // 23505 = unique_violation
      console.error("like insert failed", insErr);
      return errorResponse(500, "insert_failed");
    }
    liked = true;
  }

  // 갱신 후 count 조회 — 클라이언트가 즉시 표시.
  const { count } = await db
    .from("board_post_likes")
    .select("post_id", { count: "exact", head: true })
    .eq("post_id", p.postId);

  return jsonResponse({
    liked,
    count: count ?? 0,
  });
});
