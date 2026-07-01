// POST /comment-like
// 댓글 좋아요 toggle. 1인 1댓글 1좋아요. INSERT → conflict면 DELETE.
// PK (comment_id, device_id)가 멱등성 보장. 클라는 응답 (liked, count)로 UI 동기화.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface CommentLikePayload {
  deviceId: string;
  commentId: number;
  ts: number;
}
interface CommentLikeRequest {
  payload: CommentLikePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: CommentLikeRequest;
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
  if (typeof p.commentId !== "number" || !Number.isInteger(p.commentId) || p.commentId <= 0) {
    return errorResponse(400, "invalid_comment_id");
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
    { commentId: p.commentId, deviceId: p.deviceId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 댓글 존재 검증.
  const { data: commentRow } = await db
    .from("board_post_comments")
    .select("id")
    .eq("id", p.commentId)
    .maybeSingle();
  if (!commentRow) return errorResponse(404, "comment_not_found");

  const countLikes = async (): Promise<number> => {
    const { count } = await db
      .from("board_post_comment_likes")
      .select("comment_id", { count: "exact", head: true })
      .eq("comment_id", p.commentId);
    return count ?? 0;
  };

  // shadow_banned는 DB 변경 없이 실제 상태만 반환 (post/like와 일관).
  if (user.status === "shadow_banned") {
    const { data: existing } = await db
      .from("board_post_comment_likes")
      .select("comment_id")
      .eq("comment_id", p.commentId)
      .eq("device_id", p.deviceId)
      .maybeSingle();
    return jsonResponse({ liked: !!existing, count: await countLikes() });
  }

  const { data: existing } = await db
    .from("board_post_comment_likes")
    .select("comment_id")
    .eq("comment_id", p.commentId)
    .eq("device_id", p.deviceId)
    .maybeSingle();

  let liked: boolean;
  if (existing) {
    const { error: delErr } = await db
      .from("board_post_comment_likes")
      .delete()
      .eq("comment_id", p.commentId)
      .eq("device_id", p.deviceId);
    if (delErr) {
      console.error("comment unlike failed", delErr);
      return errorResponse(500, "delete_failed");
    }
    liked = false;
  } else {
    const { error: insErr } = await db
      .from("board_post_comment_likes")
      .insert({
        comment_id: p.commentId,
        device_id: p.deviceId,
        nickname_snapshot: user.nickname,
      });
    if (insErr && insErr.code !== "23505") {  // 23505 = unique_violation (race)
      console.error("comment like insert failed", insErr);
      return errorResponse(500, "insert_failed");
    }
    liked = true;
  }

  return jsonResponse({ liked, count: await countLikes() });
});
