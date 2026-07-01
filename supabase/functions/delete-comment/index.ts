// POST /delete-comment
// 본인 댓글 60초 이내 삭제. 윈도우 만료/타인 댓글이면 403.
// 좋아요는 FK CASCADE로 자동 정리.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { DELETE_COMMENT_WINDOW_SEC } from "../_shared/board_policy.ts";

interface DeleteCommentPayload {
  deviceId: string;
  commentId: number;
  ts: number;
}
interface DeleteCommentRequest {
  payload: DeleteCommentPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: DeleteCommentRequest;
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
    .select("device_id, hmac_key_b64, status")
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

  // 소유권 + 삭제 윈도우 검증.
  const { data: comment } = await db
    .from("board_post_comments")
    .select("id, device_id, created_at")
    .eq("id", p.commentId)
    .maybeSingle();
  if (!comment) return errorResponse(404, "comment_not_found");
  // Postgres UUID 비교는 .eq로 case-insensitive지만, JS 비교는 소문자로 맞춘다.
  if (String(comment.device_id).toLowerCase() !== p.deviceId.toLowerCase()) {
    return errorResponse(403, "not_owner");
  }
  const createdAt = new Date(comment.created_at).getTime();
  if (Date.now() - createdAt > DELETE_COMMENT_WINDOW_SEC * 1000) {
    return errorResponse(403, "delete_window_expired");
  }

  const { error: delErr } = await db
    .from("board_post_comments")
    .delete()
    .eq("id", p.commentId);
  if (delErr) {
    console.error("comment delete failed", delErr);
    return errorResponse(500, "delete_failed");
  }

  return jsonResponse({ deleted: true });
});
