// POST /guild-invite
// 초대받은 유저(피초대자) 전용 액션 — 받은 초대 목록/수락/거절. 모두 피초대자 device가 서명.
// (초대 발송·취소는 길드장 액션이라 guild-manage에 있음.)
//
// payload(서명 대상, flat): { action, deviceId, [inviteId,] ts }
//   - list:    { action:"list", deviceId, ts }
//   - accept:  { action:"accept", deviceId, inviteId, ts }
//   - decline: { action:"decline", deviceId, inviteId, ts }
//   inviteId 키는 accept/decline일 때만 직렬화 — canonical 재현도 present-only.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { checkJoinCooldown } from "../_shared/guild_policy.ts";

type InviteAction = "list" | "accept" | "decline";
const INVITE_ACTIONS: ReadonlySet<string> = new Set(["list", "accept", "decline"]);

interface InvitePayload {
  action: InviteAction;
  deviceId: string;
  inviteId?: string;
  ts: number;
}
interface InviteRequest {
  payload: InvitePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: InviteRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!INVITE_ACTIONS.has(p.action)) return errorResponse(400, "invalid_action");
  if ((p.action === "accept" || p.action === "decline") && !isValidUUID(p.inviteId ?? "")) {
    return errorResponse(400, "invalid_invite_id");
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

  const verifyObj: Record<string, unknown> = {
    action: p.action,
    deviceId: p.deviceId,
    ts: p.ts,
  };
  if (typeof p.inviteId === "string") verifyObj.inviteId = p.inviteId;
  const ok = await verifyHmac(verifyObj, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  const nowIso = new Date().toISOString();

  if (p.action === "list") {
    // 대기중 + 미만료 초대. guild_id는 FK라 embed로 길드명, inviter는 FK 없어 별도 조회.
    const { data: invites, error } = await db
      .from("guild_invites")
      .select("id, guild_id, inviter_device_id, expires_at, created_at, guilds(name)")
      .eq("invitee_device_id", deviceId)
      .eq("status", "pending")
      .gt("expires_at", nowIso)
      .order("created_at", { ascending: false });
    if (error) {
      console.error("guild-invite list failed", error);
      return errorResponse(500, "list_failed");
    }
    const rows = invites ?? [];
    // inviter 닉네임 일괄 조회.
    const inviterIds = [...new Set(rows.map((r) => r.inviter_device_id))];
    const nickById = new Map<string, string>();
    if (inviterIds.length > 0) {
      const { data: inviters } = await db
        .from("users")
        .select("device_id, nickname")
        .in("device_id", inviterIds);
      for (const u of inviters ?? []) nickById.set(u.device_id, u.nickname);
    }
    // 멤버 수 — 초대에 걸린 길드들만.
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
      invites: rows.map((r) => ({
        inviteId: r.id,
        guildId: r.guild_id,
        // deno-lint-ignore no-explicit-any
        guildName: (r.guilds as any)?.name ?? "",
        inviterNickname: nickById.get(r.inviter_device_id) ?? null,
        memberCount: countByGuild.get(r.guild_id) ?? 0,
        expiresAt: r.expires_at,
      })),
    });
  }

  // accept / decline — 이 초대가 내 것(피초대자=나) + 대기중 + 미만료여야.
  const { data: inv } = await db
    .from("guild_invites")
    .select("id, guild_id, invitee_device_id, status, expires_at")
    .eq("id", p.inviteId!)
    .maybeSingle();
  if (!inv || inv.invitee_device_id !== deviceId || inv.status !== "pending") {
    return errorResponse(404, "invite_not_found");
  }
  if (new Date(inv.expires_at).getTime() <= Date.now()) {
    return errorResponse(410, "invite_expired");
  }

  if (p.action === "decline") {
    const { error: updErr } = await db
      .from("guild_invites")
      .update({ status: "declined", responded_at: nowIso })
      .eq("id", inv.id);
    if (updErr) {
      console.error("guild-invite decline failed", updErr);
      return errorResponse(500, "decline_failed");
    }
    return jsonResponse({ ok: true });
  }

  // accept — 가입 자격 재검사(쿨다운/무소속) 후 가입. guild-join과 동일 정책.
  const cooldownResp = await checkJoinCooldown(db, deviceId);
  if (cooldownResp) return cooldownResp;

  const { data: guild } = await db
    .from("guilds")
    .select("id, name, tenant_id")
    .eq("id", inv.guild_id)
    .maybeSingle();
  if (!guild) return errorResponse(404, "guild_not_found"); // 초대 후 해체됨
  // 전환(one-way) 등으로 초대 당시와 테넌트가 달라졌으면 가입 불가 — 타 테넌트 길드엔 못 들어간다.
  if (guild.tenant_id !== user.tenant_id) return errorResponse(404, "guild_not_found");

  const { error: insErr } = await db
    .from("guild_members")
    .insert({ guild_id: guild.id, device_id: deviceId });
  if (insErr) {
    if (insErr.code === "23505") return errorResponse(409, "already_in_guild");
    console.error("guild-invite accept insert failed", insErr);
    return errorResponse(500, "accept_failed");
  }

  // 이 초대는 accepted, 이 유저의 다른 대기중 초대는 무의미 → cancelled로 정리.
  // 멤버십은 위 INSERT로 이미 확정 — 정리 실패는 pending 잔존(UX 불일치)이므로 로그로 추적.
  const { error: acceptErr } = await db.from("guild_invites")
    .update({ status: "accepted", responded_at: nowIso })
    .eq("id", inv.id);
  if (acceptErr) console.error("guild-invite accept: mark accepted failed", acceptErr);
  const { error: cancelErr } = await db.from("guild_invites")
    .update({ status: "cancelled", responded_at: nowIso })
    .eq("invitee_device_id", deviceId)
    .eq("status", "pending");
  if (cancelErr) console.error("guild-invite accept: cancel others failed", cancelErr);

  const { count: memberCount } = await db
    .from("guild_members")
    .select("device_id", { count: "exact", head: true })
    .eq("guild_id", guild.id);

  return jsonResponse({ guildId: guild.id, name: guild.name, memberCount: memberCount ?? 1 });
});
