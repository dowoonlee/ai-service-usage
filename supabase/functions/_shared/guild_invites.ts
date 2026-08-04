// 받은 길드 초대 조회 — guild-invite(list)와 dm-inbox가 공유.
//
// 클라의 통합 인박스는 "미확인 쪽지 + 대기중 초대"를 한 배지로 묶어 보여준다. 예전엔 배지
// 하나를 갱신하려고 dm-inbox와 guild-invite를 각각 호출했는데, 300s 배경 폴링이 곱해지면서
// 무료 플랜 invocation 쿼터의 8%를 배지 하나가 먹었다. 그래서 dm-inbox 응답에 초대를 얹고,
// guild-invite(list)는 구버전 클라를 위해 그대로 남겨 둔 뒤 여기로 구현을 모았다.

import { SupabaseClient } from "jsr:@supabase/supabase-js@2";

export interface ReceivedInvite {
  inviteId: string;
  guildId: string;
  guildName: string;
  inviterNickname: string | null;
  memberCount: number;
  expiresAt: string;
}

/// 대기중 + 미만료 초대를 최신순으로. `deviceId`는 호출부에서 lowercase 정규화된 값이어야 한다.
export async function listPendingInvites(
  db: SupabaseClient,
  deviceId: string,
): Promise<ReceivedInvite[]> {
  const nowIso = new Date().toISOString();
  // guild_id는 FK라 embed로 길드명, inviter는 FK 없어 별도 조회.
  const { data: invites, error } = await db
    .from("guild_invites")
    .select("id, guild_id, inviter_device_id, expires_at, created_at, guilds(name)")
    .eq("invitee_device_id", deviceId)
    .eq("status", "pending")
    .gt("expires_at", nowIso)
    .order("created_at", { ascending: false });
  if (error) throw error;

  const rows = invites ?? [];
  if (rows.length === 0) return [];

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

  return rows.map((r) => ({
    inviteId: r.id,
    guildId: r.guild_id,
    // deno-lint-ignore no-explicit-any
    guildName: (r.guilds as any)?.name ?? "",
    inviterNickname: nickById.get(r.inviter_device_id) ?? null,
    memberCount: countByGuild.get(r.guild_id) ?? 0,
    expiresAt: r.expires_at,
  }));
}
