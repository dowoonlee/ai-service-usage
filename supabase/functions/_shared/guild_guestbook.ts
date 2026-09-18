// 길드 방명록 공용 조회 — guild-visit(30개)·guild-info(10개)·guild-guestbook(작성 응답)이 같은
// 모양을 내려보내도록 여기서 매핑한다 (docs/plans/guild-visit.md M2).

import { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import {
  GUESTBOOK_GLOBAL_COOLDOWN_SEC,
  GUESTBOOK_GUILD_COOLDOWN_SEC,
} from "./guild_policy.ts";

export interface GuestbookEntry {
  id: number;
  nickname: string;
  guildName: string | null;
  petKind: string | null;
  petVariant: number;
  content: string;
  createdAt: string;
  isMine: boolean;
}

interface GuestbookRow {
  id: number;
  author_device_id: string | null;
  author_nickname_snapshot: string;
  author_guild_name_snapshot: string | null;
  author_pet_kind: string | null;
  author_pet_variant: number | null;
  content: string;
  created_at: string;
}

export function mapGuestbookRow(row: GuestbookRow, viewerDeviceId: string): GuestbookEntry {
  return {
    id: row.id,
    nickname: row.author_nickname_snapshot,
    guildName: row.author_guild_name_snapshot,
    petKind: row.author_pet_kind,
    petVariant: row.author_pet_variant ?? 0,
    content: row.content,
    createdAt: row.created_at,
    isMine: row.author_device_id != null &&
      String(row.author_device_id).toLowerCase() === viewerDeviceId.toLowerCase(),
  };
}

/** 최신순 `limit`개. 실패해도 빈 배열 — 방명록이 사무실 응답을 죽이면 안 된다. */
export async function fetchGuestbook(
  db: SupabaseClient,
  guildId: string,
  limit: number,
  viewerDeviceId: string,
): Promise<GuestbookEntry[]> {
  const { data, error } = await db
    .from("guild_guestbook")
    .select("id, author_device_id, author_nickname_snapshot, author_guild_name_snapshot, author_pet_kind, author_pet_variant, content, created_at")
    .eq("guild_id", guildId)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) {
    console.error("guestbook fetch failed", error);
    return [];
  }
  return ((data ?? []) as GuestbookRow[]).map((r) => mapGuestbookRow(r, viewerDeviceId));
}

/**
 * 작성 가능까지 남은 초 — 길드별(24h)·전역(10분) 중 큰 값. 0이면 지금 쓸 수 있다.
 * 표시용 추정치다 — 실제 선점은 guild_guestbook_write RPC가 원자적으로 한다.
 */
export async function guestbookCooldownRemainingSec(
  db: SupabaseClient,
  deviceId: string,
  guildId: string,
  userLastGuestbookAt: string | null | undefined,
): Promise<number> {
  const now = Date.now();
  let remaining = 0;
  if (userLastGuestbookAt) {
    const until = new Date(userLastGuestbookAt).getTime() + GUESTBOOK_GLOBAL_COOLDOWN_SEC * 1000;
    remaining = Math.max(remaining, Math.ceil((until - now) / 1000));
  }
  const { data } = await db
    .from("guild_guestbook_writes")
    .select("last_at")
    .eq("device_id", deviceId)
    .eq("guild_id", guildId)
    .maybeSingle();
  if (data?.last_at) {
    const until = new Date(data.last_at).getTime() + GUESTBOOK_GUILD_COOLDOWN_SEC * 1000;
    remaining = Math.max(remaining, Math.ceil((until - now) / 1000));
  }
  return Math.max(0, remaining);
}
