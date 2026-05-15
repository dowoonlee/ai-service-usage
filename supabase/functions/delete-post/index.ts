// POST /delete-post
// 본인이 작성한 글을 1분 이내에 한해 삭제. 좋아요는 FK ON DELETE CASCADE로 자동 정리.
//
// cooldown은 영향 없음 — users.last_post_at은 작성 시점에 박혀 있고 삭제로 변경 X.
// 즉 글 작성 후 삭제해도 다음 글 작성까지 600초 cooldown 그대로.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface DeletePostPayload {
  deviceId: string;
  postId: number;
  ts: number;
}
interface DeletePostRequest {
  payload: DeletePostPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const DELETE_WINDOW_SEC = 60;          // 작성 후 삭제 가능한 윈도우

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: DeletePostRequest;
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
    .select("device_id, hmac_key_b64, status")
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

  // 글 존재 + 본인 글 + 윈도우 검증.
  const { data: post } = await db
    .from("board_posts")
    .select("id, device_id, created_at")
    .eq("id", p.postId)
    .maybeSingle();
  if (!post) return errorResponse(404, "post_not_found");
  if (post.device_id !== p.deviceId) return errorResponse(403, "not_post_owner");

  const ageSec = (Date.now() - new Date(post.created_at).getTime()) / 1000;
  if (ageSec > DELETE_WINDOW_SEC) {
    return errorResponse(403, "delete_window_expired");
  }

  // shadow_banned는 noop으로 200 응답 — 본인에겐 삭제된 것처럼 보임.
  // 이미 다른 사용자 시야에서 가려져 있으니 실제 row는 보존해도 무관.
  if (user.status === "shadow_banned") {
    return jsonResponse({ deleted: true });
  }

  const { error: delErr } = await db
    .from("board_posts")
    .delete()
    .eq("id", p.postId);
  if (delErr) {
    console.error("post delete failed", delErr);
    return errorResponse(500, "delete_failed");
  }

  return jsonResponse({ deleted: true });
});
