// GET /board?deviceId=<uuid>
// 최근 100개 게시글 + 각 글의 좋아요 정보 (count + 누른 사람 목록).
//
// deviceId 옵션:
//   * isMine — 본인 글 표시
//   * likedByMe — 본인이 좋아요 누른 글 표시
//   * cooldownRemainingSec — 다음 글 작성까지 남은 초 (10분 cooldown 기준)
//
// likers는 popover 호버용 — 50명 커뮤니티 가정으로 매 응답에 inline 포함 (별도 fetch X).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { isValidUUID } from "../_shared/validation.ts";

const POST_LIMIT = 100;
const POST_COOLDOWN_SEC = 600;     // /post와 동일

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const deviceId = url.searchParams.get("deviceId");
  if (deviceId && !isValidUUID(deviceId)) {
    return errorResponse(400, "invalid_device_id");
  }

  const db = getDb();

  // 1) 최근 N개 글
  const { data: posts, error: postsErr } = await db
    .from("board_posts")
    .select("id, device_id, nickname_snapshot, content, created_at")
    .order("created_at", { ascending: false })
    .limit(POST_LIMIT);
  if (postsErr) {
    console.error("board fetch failed", postsErr);
    return errorResponse(500, "fetch_failed");
  }

  const postIds = (posts ?? []).map((p) => p.id);

  // 2) 좋아요 일괄 조회 (in 절). post_id 기준 그룹화.
  type LikeRow = { post_id: number; device_id: string; nickname_snapshot: string; created_at: string };
  let likesByPost: Map<number, LikeRow[]> = new Map();
  if (postIds.length > 0) {
    const { data: likes, error: likesErr } = await db
      .from("board_post_likes")
      .select("post_id, device_id, nickname_snapshot, created_at")
      .in("post_id", postIds)
      .order("created_at", { ascending: true });
    if (likesErr) {
      console.error("likes fetch failed", likesErr);
      return errorResponse(500, "fetch_failed");
    }
    likesByPost = new Map();
    for (const row of (likes ?? []) as LikeRow[]) {
      const arr = likesByPost.get(row.post_id) ?? [];
      arr.push(row);
      likesByPost.set(row.post_id, arr);
    }
  }

  // 3) 응답 조립
  const entries = (posts ?? []).map((p) => {
    const likes = likesByPost.get(p.id) ?? [];
    return {
      id: p.id,
      nickname: p.nickname_snapshot,
      content: p.content,
      createdAt: p.created_at,
      isMine: deviceId !== null && p.device_id === deviceId,
      likeCount: likes.length,
      likedByMe: deviceId !== null && likes.some((l) => l.device_id === deviceId),
      likers: likes.map((l) => ({ nickname: l.nickname_snapshot, createdAt: l.created_at })),
    };
  });

  // 4) cooldown — 본인 마지막 글 시각 기준
  let cooldownRemainingSec = 0;
  if (deviceId) {
    const cooldownThreshold = new Date(Date.now() - POST_COOLDOWN_SEC * 1000).toISOString();
    const { data: recent } = await db
      .from("board_posts")
      .select("created_at")
      .eq("device_id", deviceId)
      .gte("created_at", cooldownThreshold)
      .order("created_at", { ascending: false })
      .limit(1);
    if (recent && recent.length > 0) {
      const lastAt = new Date(recent[0].created_at).getTime();
      cooldownRemainingSec = Math.max(
        0,
        Math.ceil((lastAt + POST_COOLDOWN_SEC * 1000 - Date.now()) / 1000),
      );
    }
  }

  return jsonResponse({
    posts: entries,
    cooldownRemainingSec,
  });
});
