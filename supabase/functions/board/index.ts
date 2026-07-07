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
import { resolveTenant } from "../_shared/tenant.ts";
import {
  DISPLAY_WINDOW_HOURS,
  POST_COOLDOWN_SEC,
  DELETE_POST_WINDOW_SEC,
  COMMENT_MAX_LEN,
  DELETE_COMMENT_WINDOW_SEC,
} from "../_shared/board_policy.ts";

const POST_LIMIT = 100;

// MARK: - 익명 닉네임 풀 (개발자 밈)
//
// 글 단위 익명: post_id 시드 deterministic 해시로 형용사+명사 조합 생성.
// 같은 글은 새로고침해도 같은 닉네임. DB nickname_snapshot은 보존 — 응답 단계에서만 마스킹.
// 풀 30 × 40 = 1200조합 → 1일 100글 기준 충돌 ~4개로 게시판이 살아있는 느낌 살림.
const DEV_ADJECTIVES = [
  "타입드", "빌드된", "캐시드", "롤백된", "디버깅중인",
  "무중단의", "401난", "PR받은", "누수난", "무한루프의",
  "데드락난", "우당탕탕", "null인", "async한", "졸린",
  "야근중인", "새벽3시의", "핫픽스난", "LGTM받은", "WIP중인",
  "포스푸시된", "메인직커밋", "트레이스난", "덤프된", "undefined한",
  "localhost의", "프로덕션의", "임시방편의", "점심거른", "커피급한",
];

const DEV_NOUNS = [
  "DNS의신", "마이맘", "시니어인턴", "헬로월드", "코드몽키",
  "키보드워리어", "PR머지러", "빌드그린", "LGTM감별사", "console.log",
  "TODO마스터", "핫픽스러", "캐시버스터", "사이드이펙트", "메모리누수",
  "데드락", "401에러", "504타임아웃", "no-verify러", "내환경파",
  "풀스택셰프", "백엔드무당", "프론트엔드도사", "PR리뷰어", "깃블레임러",
  "머지마스터", "리베이스러", "포스푸시러", "NPE", "세그폴트",
  "임시방편러", "프로파일러", "CI수문장", "main지킴이", "k8s무사",
  "도커잡이", "헬프데스크", "슬랙멘션러", "스탠드업러", "회의실예약자",
];

// FNV-1a 32-bit. 시드 다양화를 위해 prefix 다른 두 문자열로 두 번 해시.
function fnv1a(input: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

function memeNickname(postId: number): string {
  const adj = DEV_ADJECTIVES[fnv1a(`adj:${postId}`) % DEV_ADJECTIVES.length];
  const noun = DEV_NOUNS[fnv1a(`noun:${postId}`) % DEV_NOUNS.length];
  return `${adj} ${noun}`;
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const deviceId = url.searchParams.get("deviceId");
  if (deviceId && !isValidUUID(deviceId)) {
    return errorResponse(400, "invalid_device_id");
  }
  // Postgres UUID 컬럼은 소문자로 정규화 저장되는데 클라(Swift UUID)는 대문자를 보낸다.
  // isMine/likedByMe를 JS 문자열 `===`로 비교하므로 양쪽을 소문자로 맞추지 않으면 항상 false가
  // 되어 재진입 시 하트/'나' 배지가 사라진다(leaderboard/index.ts:52 선례).
  const deviceIdLower = deviceId ? deviceId.toLowerCase() : null;

  const db = getDb();

  // 호출자 테넌트 — 미등록/익명(deviceId 없음)은 기본(public) 게시판. 클라는 tenant를 주장 못 한다(§2-1).
  let tenant = "public";
  if (deviceId) {
    const t = await resolveTenant(db, deviceId);
    if (t) tenant = t;
  }

  // 1) 최근 1일 + 최대 100개 글(테넌트 내). 두 조건 모두 적용 — 1일 안에 100개 넘게 와도 LIMIT으로 컷.
  //    likes/comments/comment_likes는 아래에서 post_id IN (이 테넌트 글)로 조회되므로 자연히 테넌트 스코프.
  const windowStart = new Date(Date.now() - DISPLAY_WINDOW_HOURS * 3600 * 1000).toISOString();
  const { data: posts, error: postsErr } = await db
    .from("board_posts")
    .select("id, device_id, nickname_snapshot, content, created_at")
    .eq("tenant_id", tenant)
    .gte("created_at", windowStart)
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

  // 2.5) 댓글 + 댓글 좋아요 일괄 조회 (in절). 글당 inline으로 응답에 포함(소규모 커뮤니티 가정).
  type CommentRow = {
    id: number; post_id: number; device_id: string; content: string; created_at: string;
  };
  const commentsByPost = new Map<number, CommentRow[]>();
  const commentLikesByComment = new Map<number, string[]>();  // comment_id → device_ids
  let commentRows: CommentRow[] = [];
  if (postIds.length > 0) {
    const { data: comments, error: cErr } = await db
      .from("board_post_comments")
      .select("id, post_id, device_id, content, created_at")
      .in("post_id", postIds)
      .order("created_at", { ascending: true });
    if (cErr) {
      console.error("comments fetch failed", cErr);
      return errorResponse(500, "fetch_failed");
    }
    commentRows = (comments ?? []) as CommentRow[];
    for (const row of commentRows) {
      const arr = commentsByPost.get(row.post_id) ?? [];
      arr.push(row);
      commentsByPost.set(row.post_id, arr);
    }
    const commentIds = commentRows.map((c) => c.id);
    if (commentIds.length > 0) {
      const { data: cLikes, error: clErr } = await db
        .from("board_post_comment_likes")
        .select("comment_id, device_id")
        .in("comment_id", commentIds);
      if (clErr) {
        console.error("comment likes fetch failed", clErr);
        return errorResponse(500, "fetch_failed");
      }
      for (const row of (cLikes ?? []) as { comment_id: number; device_id: string }[]) {
        const arr = commentLikesByComment.get(row.comment_id) ?? [];
        arr.push(row.device_id);
        commentLikesByComment.set(row.comment_id, arr);
      }
    }
  }

  // 3) 응답 조립 — 윈도우 단위 익명:
  //    같은 device_id가 표시 윈도우(DISPLAY_WINDOW_HOURS) 안에 여러 글을 썼으면
  //    모두 같은 닉네임으로 묶임. 시드는 그 device_id의 "가장 오래된 글의 id" —
  //    가장 처음 작성한 글의 닉네임이 이후 글에 승계되는 형태. 글 단위 일관성 +
  //    본인 글끼리 그룹화 둘 다 충족. 가장 오래된 글이 윈도우 밖으로 사라지면 남은
  //    글의 시드가 다음 글로 이동. (영구 안정성을 원하면 board_posts에 nickname_seed
  //    컬럼 도입 필요 — 현재는 미적용)
  //
  //    likers의 nickname은 클라이언트에서 popover로 노출하지 않음 — 빈 배열로 응답해
  //    추가 식별 정보 차단. likeCount는 별도 필드라 카운트 표시는 정상 동작.
  const seedByDevice = new Map<string, number>();
  for (const p of (posts ?? [])) {
    const existing = seedByDevice.get(p.device_id);
    if (existing === undefined || p.id < existing) {
      seedByDevice.set(p.device_id, p.id);
    }
  }
  // 댓글 작성자 닉네임 시드 — 본인 글이 있으면 글과 동일 닉을 승계, 글이 없으면 본인 첫(최소 id)
  // 댓글 id를 시드로. commentRows는 created_at asc라 "없을 때만 set"이 최소 id를 준다.
  const commentSeedByDevice = new Map(seedByDevice);
  for (const c of commentRows) {
    if (!commentSeedByDevice.has(c.device_id)) commentSeedByDevice.set(c.device_id, c.id);
  }

  const entries = (posts ?? []).map((p) => {
    const likes = likesByPost.get(p.id) ?? [];
    const seed = seedByDevice.get(p.device_id) ?? p.id;
    const comments = (commentsByPost.get(p.id) ?? []).map((c) => {
      const cLikes = commentLikesByComment.get(c.id) ?? [];
      return {
        id: c.id,
        nickname: memeNickname(commentSeedByDevice.get(c.device_id) ?? c.id),
        content: c.content,
        createdAt: c.created_at,
        isMine: deviceIdLower !== null && c.device_id.toLowerCase() === deviceIdLower,
        likeCount: cLikes.length,
        likedByMe: deviceIdLower !== null && cLikes.some((d) => d.toLowerCase() === deviceIdLower),
      };
    });
    return {
      id: p.id,
      nickname: memeNickname(seed),
      content: p.content,
      createdAt: p.created_at,
      isMine: deviceIdLower !== null && p.device_id.toLowerCase() === deviceIdLower,
      likeCount: likes.length,
      likedByMe: deviceIdLower !== null && likes.some((l) => l.device_id.toLowerCase() === deviceIdLower),
      likers: [] as { nickname: string; createdAt: string }[],
      comments,
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

  // 정책 값들은 서버가 권위(SSOT는 _shared/board_policy.ts) — 클라이언트는 헤더/푸터/help
  // 문구와 카운트다운/삭제 버튼 윈도우를 이 값들로 동적 생성해, 정책이 바뀌어도 한 곳
  // (board_policy.ts) 수정만으로 양쪽 동기화됨.
  return jsonResponse({
    posts: entries,
    cooldownRemainingSec,
    displayWindowHours: DISPLAY_WINDOW_HOURS,
    postCooldownSec: POST_COOLDOWN_SEC,
    deletePostWindowSec: DELETE_POST_WINDOW_SEC,
    commentMaxLen: COMMENT_MAX_LEN,
    deleteCommentWindowSec: DELETE_COMMENT_WINDOW_SEC,
  });
});
