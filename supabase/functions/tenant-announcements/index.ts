// GET /tenant-announcements?deviceId=<uuid> — 테넌트 전용 공지(전역 announcements와 분리, D7).
//
// 호출자 테넌트의 활성 공지를 최신순으로. 버전 무관(전역 패치노트와 달리 멤버 대상 상시 공지).
// deviceId 없으면 기본(public) 테넌트 공지. read-only라 서명 불필요(board/leaderboard 패턴).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { resolveTenant } from "../_shared/tenant.ts";

const LIMIT = 50;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const deviceIdRaw = url.searchParams.get("deviceId");
  if (deviceIdRaw && !isValidUUID(deviceIdRaw)) return errorResponse(400, "invalid_device_id");
  const deviceId = deviceIdRaw ? deviceIdRaw.toLowerCase() : null;

  const db = getDb();
  let tenant = "public";
  if (deviceId) {
    const t = await resolveTenant(db, deviceId);
    if (t) tenant = t;
  }

  const { data, error } = await db
    .from("tenant_announcements")
    .select("id, title, body, published_at")
    .eq("tenant_slug", tenant)
    .eq("is_active", true)
    .order("published_at", { ascending: false })
    .limit(LIMIT);
  if (error) {
    console.error("tenant-announcements fetch failed", error);
    return errorResponse(500, "fetch_failed");
  }

  return jsonResponse({
    tenant,
    announcements: (data ?? []).map((a) => ({
      id: a.id,
      title: a.title,
      body: a.body,
      publishedAt: a.published_at,
    })),
  });
});
