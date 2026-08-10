// POST /sync — 주기 폴링 통합 엔드포인트.
//
// payload(서명 대상, flat): { deviceId, ts, want, boardSeenAt }
//   want        — 지금 열려 있는 화면의 CSV ("board,inbox,ranking"). 빈 문자열이면 배지만.
//   boardSeenAt — 게시판 미확인 계산 기준(epoch sec). 0이면 미확인 0으로 본다.
//
// 배경:
//   클라가 화면별로 각각 폴링하던 걸(게시판 180s·랭킹 300s·인박스 300s·길드 300s) 메인 사이클
//   600s 1회로 합친다. 무료 플랜 Edge Function 쿼터는 500K/월인데 상태 코드와 무관하게 호출
//   횟수로 과금돼서, 화면 수만큼 호출이 곱해지는 구조 자체가 한계였다.
//
// 설계 요점:
//   * `want`는 배열이 아니라 CSV 문자열이다 — `_shared/hmac.ts`의 canonicalize()가 flat object만
//     지원한다(배열을 넣으면 Swift sortedKeys 직렬화와 어긋나 서명이 항상 깨진다).
//   * 안 보는 화면의 페이로드는 싣지 않는다 — Egress(무료 5GB/월)를 늘리지 않기 위해서다.
//     창이 닫혀 있으면 badges(카운트)만 나간다.
//   * 섹션 하나가 실패해도 나머지는 정상 응답한다(dm-inbox가 초대 조회 실패를 흡수하는 것과 동일).
//   * HMAC 서명 필수 — inbox 섹션은 사적 데이터라 GET board/leaderboard처럼 열어둘 수 없다.
//
// 기존 endpoint는 그대로 둔다. sync는 "주기 갱신"만 대체하고, 창을 여는 순간의 즉시 조회와
// 각종 액션(글쓰기·좋아요·전송)은 기존 경로를 쓴다. 구버전 클라도 기존 경로로 계속 동작한다.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { outdatedClientResponse } from "../_shared/min_version.ts";
import { resolveTenant } from "../_shared/tenant.ts";
import { fetchInbox } from "../_shared/dm_inbox_query.ts";
import { fetchBoard } from "../_shared/board_query.ts";
import { fetchLeaderboard } from "../_shared/leaderboard_query.ts";
import { listPendingInvites } from "../_shared/guild_invites.ts";

interface SyncPayload {
  deviceId: string;
  ts: number;
  want: string;
  boardSeenAt: number;
}
interface SyncRequest {
  payload: SyncPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const ANNOUNCEMENT_LIMIT = 50;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: SyncRequest;
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
  if (typeof p.want !== "string") return errorResponse(400, "invalid_want");
  if (typeof p.boardSeenAt !== "number") return errorResponse(400, "invalid_board_seen_at");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status, app_version")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");
  const outdated = outdatedClientResponse(user.app_version);
  if (outdated) return outdated;

  const ok = await verifyHmac(
    { boardSeenAt: p.boardSeenAt, deviceId: p.deviceId, ts: p.ts, want: p.want },
    body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  const want = new Set(
    p.want.split(",").map((s) => s.trim()).filter((s) => s.length > 0),
  );

  // 테넌트는 한 번만 구해 board/leaderboard/공지가 공유한다 — 각 endpoint가 따로 부르던 걸 아낀다.
  let tenant = "public";
  const t = await resolveTenant(db, deviceId);
  if (t) tenant = t;

  // 응답 조립. 섹션별로 독립 try — 하나가 죽어도 나머지는 내려간다.
  const out: Record<string, unknown> = {};

  // --- 인박스 (배지는 항상, 목록은 창이 열렸을 때만) ---
  let dmUnread = 0;
  let invites: Awaited<ReturnType<typeof listPendingInvites>> = [];
  try {
    if (want.has("inbox")) {
      const inbox = await fetchInbox(db, deviceId);
      dmUnread = inbox.totalUnread;
      invites = inbox.invites;
      out.inbox = { threads: inbox.threads };
    } else {
      // 배지만 필요할 땐 500건 스캔 대신 count 두 방으로 끝낸다.
      const { count } = await db
        .from("direct_messages")
        .select("id", { count: "exact", head: true })
        .eq("recipient_device", deviceId)
        .eq("del_recipient", false)
        .is("read_at", null);
      dmUnread = count ?? 0;
      invites = await listPendingInvites(db, deviceId);
    }
  } catch (error) {
    console.error("sync inbox section failed", error);
  }

  // --- 게시판 미확인 수 ---
  // 본인 글은 제외한다(클라의 기존 unread 규칙과 동일). boardSeenAt이 0이면 아직 시드 전이라 0.
  let boardUnread = 0;
  try {
    if (p.boardSeenAt > 0) {
      const since = new Date(p.boardSeenAt * 1000).toISOString();
      const { count } = await db
        .from("board_posts")
        .select("id", { count: "exact", head: true })
        .eq("tenant_id", tenant)
        .gt("created_at", since)
        .neq("device_id", deviceId);
      boardUnread = count ?? 0;
    }
  } catch (error) {
    console.error("sync board unread failed", error);
  }

  out.badges = { dmUnread, boardUnread };
  out.invites = invites;

  // --- 게시판 본문 (창이 열렸을 때만) ---
  if (want.has("board")) {
    try {
      out.board = await fetchBoard(db, { tenant, deviceId, deviceIdLower: deviceId });
    } catch (error) {
      console.error("sync board section failed", error);
    }
  }

  // --- 랭킹 + 테넌트 공지 (창이 열렸을 때만) ---
  if (want.has("ranking")) {
    try {
      out.leaderboard = await fetchLeaderboard(db, { tenant, deviceId });
    } catch (error) {
      console.error("sync leaderboard section failed", error);
    }
    try {
      const { data } = await db
        .from("tenant_announcements")
        .select("id, title, body, published_at")
        .eq("tenant_slug", tenant)
        .eq("is_active", true)
        .order("published_at", { ascending: false })
        .limit(ANNOUNCEMENT_LIMIT);
      out.tenantAnnouncements = (data ?? []).map((a) => ({
        id: a.id,
        title: a.title,
        body: a.body,
        publishedAt: a.published_at,
      }));
    } catch (error) {
      console.error("sync announcements section failed", error);
    }
  }

  out.tenant = tenant;
  return jsonResponse(out);
});
