// POST /guild-request
// 가입신청(신청자 액션) — 길드 리스트를 보고 가입을 신청/취소/조회. 모두 신청자 device가 서명.
// (수락·거절은 길드장 액션이라 guild-manage에 있음. 초대장의 대칭 흐름.)
//
// payload(서명 대상, flat): { action, deviceId, [guildId,] [requestId,] ts }
//   - create: { action:"create", deviceId, guildId, ts }
//   - cancel: { action:"cancel", deviceId, requestId, ts }
//   - list:   { action:"list", deviceId, ts }
//   guildId/requestId 키는 해당 액션일 때만 직렬화 — canonical 재현도 present-only.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import {
  REQUEST_EXPIRE_SEC,
  REQUEST_REDECLINE_COOLDOWN_SEC,
  REQUEST_MAX_PENDING_PER_GUILD,
  REQUEST_MAX_PENDING_PER_USER,
  checkJoinCooldown,
} from "../_shared/guild_policy.ts";

type RequestAction = "create" | "cancel" | "list";
const REQUEST_ACTIONS: ReadonlySet<string> = new Set(["create", "cancel", "list"]);

interface RequestPayload {
  action: RequestAction;
  deviceId: string;
  guildId?: string;
  requestId?: string;
  ts: number;
}
interface RequestBody {
  payload: RequestPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!REQUEST_ACTIONS.has(p.action)) return errorResponse(400, "invalid_action");
  if (p.action === "create" && !isValidUUID(p.guildId ?? "")) {
    return errorResponse(400, "invalid_guild_id");
  }
  if (p.action === "cancel" && !isValidUUID(p.requestId ?? "")) {
    return errorResponse(400, "invalid_request_id");
  }
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status, tenant_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  // 액션별로만 키를 직렬화 → canonical 재현도 present-only (서버 verify 객체 = 클라 서명 대상).
  const verifyObj: Record<string, unknown> = {
    action: p.action,
    deviceId: p.deviceId,
    ts: p.ts,
  };
  if (typeof p.guildId === "string") verifyObj.guildId = p.guildId;
  if (typeof p.requestId === "string") verifyObj.requestId = p.requestId;
  const ok = await verifyHmac(verifyObj, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  const nowIso = new Date().toISOString();

  // ---- list: 내가 보낸 대기중 + 미만료 신청 (길드명·멤버수 embed). ----
  if (p.action === "list") {
    const { data: reqs, error } = await db
      .from("guild_join_requests")
      .select("id, guild_id, expires_at, created_at, guilds(name)")
      .eq("requester_device_id", deviceId)
      .eq("status", "pending")
      .gt("expires_at", nowIso)
      .order("created_at", { ascending: false });
    if (error) {
      console.error("guild-request list failed", error);
      return errorResponse(500, "list_failed");
    }
    const rows = reqs ?? [];
    const guildIds = [...new Set(rows.map((r) => r.guild_id))];
    const countByGuild = new Map<string, number>();
    for (const gid of guildIds) {
      const { count } = await db
        .from("guild_members")
        .select("device_id", { count: "exact", head: true })
        .eq("guild_id", gid);
      countByGuild.set(gid, count ?? 0);
    }
    return jsonResponse({
      requests: rows.map((r) => ({
        requestId: r.id,
        guildId: r.guild_id,
        // deno-lint-ignore no-explicit-any
        guildName: (r.guilds as any)?.name ?? "",
        memberCount: countByGuild.get(r.guild_id) ?? 0,
        expiresAt: r.expires_at,
      })),
    });
  }

  // ---- cancel: 내 대기중 신청만 취소. ----
  if (p.action === "cancel") {
    const { data: reqRow } = await db
      .from("guild_join_requests")
      .select("id, requester_device_id, status")
      .eq("id", p.requestId!)
      .maybeSingle();
    if (!reqRow || reqRow.requester_device_id !== deviceId || reqRow.status !== "pending") {
      return errorResponse(404, "request_not_found");
    }
    const { error: updErr } = await db
      .from("guild_join_requests")
      .update({ status: "cancelled", responded_at: nowIso })
      .eq("id", reqRow.id);
    if (updErr) {
      console.error("guild-request cancel failed", updErr);
      return errorResponse(500, "cancel_failed");
    }
    return jsonResponse({ ok: true });
  }

  // ---- create: 가입 자격 검사 후 신청 등록. 실제 가입은 길드장 수락(guild-manage) 시. ----
  // 이미 어떤 길드 소속이면 신청 불가.
  const { data: existingMember } = await db
    .from("guild_members")
    .select("device_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (existingMember) return errorResponse(409, "already_in_guild");

  // 재가입 쿨다운(탈퇴/추방 7일) 중이면 신청 불가.
  const cooldownResp = await checkJoinCooldown(db, deviceId);
  if (cooldownResp) return cooldownResp;

  // 대상 길드 존재 + 같은 테넌트 (타 테넌트 길드는 "존재하지 않음"으로 뭉갠다).
  const { data: guild } = await db
    .from("guilds")
    .select("id, tenant_id")
    .eq("id", p.guildId!)
    .maybeSingle();
  if (!guild || guild.tenant_id !== user.tenant_id) return errorResponse(404, "guild_not_found");

  // 거절 재신청 쿨다운 — 이 길드가 이 신청을 최근 거절했으면 24h 대기.
  const reReqFloor = new Date(Date.now() - REQUEST_REDECLINE_COOLDOWN_SEC * 1000).toISOString();
  const { data: recentDecline } = await db
    .from("guild_join_requests")
    .select("id")
    .eq("guild_id", guild.id)
    .eq("requester_device_id", deviceId)
    .eq("status", "declined")
    .gt("responded_at", reReqFloor)
    .limit(1)
    .maybeSingle();
  if (recentDecline) return errorResponse(429, "redecline_cooldown");

  // 길드당 대기중 신청 상한 (수신함 스팸 방지).
  const { count: guildPending } = await db
    .from("guild_join_requests")
    .select("id", { count: "exact", head: true })
    .eq("guild_id", guild.id)
    .eq("status", "pending");
  if ((guildPending ?? 0) >= REQUEST_MAX_PENDING_PER_GUILD) {
    return errorResponse(429, "too_many_pending");
  }

  // 유저당 보낸 신청 상한 (전 길드 무차별 신청 방지).
  const { count: userPending } = await db
    .from("guild_join_requests")
    .select("id", { count: "exact", head: true })
    .eq("requester_device_id", deviceId)
    .eq("status", "pending");
  if ((userPending ?? 0) >= REQUEST_MAX_PENDING_PER_USER) {
    return errorResponse(429, "too_many_requests");
  }

  const expiresAt = new Date(Date.now() + REQUEST_EXPIRE_SEC * 1000).toISOString();
  const { error: insErr } = await db.from("guild_join_requests").insert({
    guild_id: guild.id,
    requester_device_id: deviceId,
    expires_at: expiresAt,
  });
  if (insErr) {
    if (insErr.code === "23505") return errorResponse(409, "already_requested"); // pending 중복
    console.error("guild-request create insert failed", insErr);
    return errorResponse(500, "request_failed");
  }
  return jsonResponse({ ok: true });
});
