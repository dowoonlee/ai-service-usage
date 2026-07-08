// POST /comment
// 게시글 댓글 작성. HMAC 서명 + 200자 제한 + 30초 cooldown.
//
// rate limit: 본인의 마지막 board_post_comments row가 COMMENT_COOLDOWN_SEC 이내면 429.
// (post와 달리 users에 last_comment_at 컬럼을 두지 않고 board_post_comments를 직접 조회 —
//  device_time 인덱스로 저렴. 댓글 삭제로 cooldown 우회가 되지만 window가 짧아 무해.)

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { COMMENT_MAX_LEN, COMMENT_COOLDOWN_SEC } from "../_shared/board_policy.ts";

interface CommentPayload {
  deviceId: string;
  postId: number;
  content: string;
  ts: number;
}
interface CommentRequest {
  payload: CommentPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: CommentRequest;
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
  if (typeof p.content !== "string") return errorResponse(400, "invalid_content");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const content = p.content.trim();
  if (content.length === 0) return errorResponse(400, "empty_content");
  if (content.length > COMMENT_MAX_LEN) return errorResponse(400, "content_too_long");

  const db = getDb();
  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, nickname, status, tenant_id")
    .eq("device_id", p.deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { content: p.content, deviceId: p.deviceId, postId: p.postId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 대상 글 존재 검증.
  const { data: postRow } = await db
    .from("board_posts")
    .select("id, tenant_id")
    .eq("id", p.postId)
    .maybeSingle();
  if (!postRow) return errorResponse(404, "post_not_found");
  // 교차 테넌트 상호작용 차단(§3-3) — 다른 테넌트 글엔 댓글 불가.
  if (postRow.tenant_id !== user.tenant_id) return errorResponse(403, "cross_tenant");

  // 서버측 rate limit — 본인 최근 댓글 시각 기준.
  const cooldownThreshold = new Date(Date.now() - COMMENT_COOLDOWN_SEC * 1000).toISOString();
  const { data: recent } = await db
    .from("board_post_comments")
    .select("created_at")
    .eq("device_id", p.deviceId)
    .gte("created_at", cooldownThreshold)
    .order("created_at", { ascending: false })
    .limit(1);
  if (recent && recent.length > 0) {
    const lastAt = new Date(recent[0].created_at).getTime();
    const remainingSec = Math.ceil((lastAt + COMMENT_COOLDOWN_SEC * 1000 - Date.now()) / 1000);
    if (remainingSec > 0) {
      return jsonResponse(
        { error: "rate_limited", retryAfterSec: Math.max(1, remainingSec) },
        { status: 429 },
      );
    }
  }

  // shadow_banned는 insert 스킵 — 본인에겐 200으로 잠잠.
  if (user.status === "shadow_banned") {
    return jsonResponse({ accepted: true, commentId: null });
  }

  const { data: inserted, error: insertErr } = await db
    .from("board_post_comments")
    .insert({
      post_id: p.postId,
      device_id: p.deviceId,
      nickname_snapshot: user.nickname,
      content,
      tenant_id: user.tenant_id,   // 글의 테넌트와 동일(위에서 일치 검증)
    })
    .select("id, created_at")
    .single();
  if (insertErr || !inserted) {
    console.error("comment insert failed", insertErr);
    return errorResponse(500, "insert_failed");
  }

  return jsonResponse({
    accepted: true,
    commentId: inserted.id,
    createdAt: inserted.created_at,
  });
});
