// 쪽지 인박스 요약 조회 — `dm-inbox`와 `sync`가 공유한다.
//
// 상대(peer)별로 최근 1건 + 미확인 수를 묶어 준다. 본문은 E2EE라 서버가 못 읽으므로 ciphertext를
// 그대로 내려주고, 클라가 복호(수신분)하거나 로컬 echo(발신분)로 미리보기를 만든다. 삭제
// (tombstone)된 내 쪽은 제외.
//
// 테넌트 필터 없음 — 전환(one-way) 후에도 본인 과거 쪽지는 열람 가능(§2-4 재검토). 교차 테넌트
// 격리는 dm-send의 발신 차단이 담당한다.

import { getDb } from "./db.ts";
import { listPendingInvites } from "./guild_invites.ts";

/** 최근 메시지 스캔 상한 (스레드 요약 조립용). */
export const DM_INBOX_SCAN_LIMIT = 500;

export interface InboxThreadRow {
  peerDevice: string;
  peerNickname: string | null;
  peerIdPub: string | null;
  lastId: string;
  lastCiphertext: string;
  lastSenderIdPub: string;
  lastFromMe: boolean;
  lastAt: string;
  unreadCount: number;
}

export interface InboxResult {
  threads: InboxThreadRow[];
  invites: Awaited<ReturnType<typeof listPendingInvites>>;
  /** 미확인 쪽지 총합 — 배지용. threads를 안 실을 때도 이 값만 쓰면 된다. */
  totalUnread: number;
}

/**
 * `deviceId`(소문자 정규화 완료)의 인박스 요약.
 *
 * 길드 초대 조회가 실패해도 쪽지 목록은 빈 배열과 함께 정상 반환한다 — 배지 하나 때문에
 * 인박스 전체가 실패하면 안 된다.
 */
export async function fetchInbox(
  db: ReturnType<typeof getDb>,
  deviceId: string,
): Promise<InboxResult> {
  const [{ data: received }, { data: sent }] = await Promise.all([
    db.from("direct_messages")
      .select("id, sender_device, ciphertext, sender_id_pub, created_at, read_at")
      .eq("recipient_device", deviceId).eq("del_recipient", false)
      .order("created_at", { ascending: false }).limit(DM_INBOX_SCAN_LIMIT),
    db.from("direct_messages")
      .select("id, recipient_device, ciphertext, sender_id_pub, created_at")
      .eq("sender_device", deviceId).eq("del_sender", false)
      .order("created_at", { ascending: false }).limit(DM_INBOX_SCAN_LIMIT),
  ]);

  interface Thread {
    peerDevice: string;
    lastId: string; lastCiphertext: string; lastSenderIdPub: string;
    lastFromMe: boolean; lastAt: string; unreadCount: number;
  }
  const threads = new Map<string, Thread>();
  const bump = (peer: string, m: {
    id: string; ciphertext: string; sender_id_pub: string; created_at: string; fromMe: boolean;
  }) => {
    const cur = threads.get(peer);
    if (!cur || m.created_at > cur.lastAt) {
      threads.set(peer, {
        peerDevice: peer, lastId: m.id, lastCiphertext: m.ciphertext,
        lastSenderIdPub: m.sender_id_pub, lastFromMe: m.fromMe, lastAt: m.created_at,
        unreadCount: cur?.unreadCount ?? 0,
      });
    }
  };
  for (const m of received ?? []) {
    bump(m.sender_device, { ...m, fromMe: false });
    if (!m.read_at) {
      const t = threads.get(m.sender_device);
      if (t) t.unreadCount += 1;
    }
  }
  for (const m of sent ?? []) bump(m.recipient_device, { ...m, fromMe: true });

  const list = [...threads.values()].sort((a, b) => (a.lastAt < b.lastAt ? 1 : -1));

  // peer 닉네임 + 공개키 일괄 조회.
  const peerIds = list.map((t) => t.peerDevice);
  const nickById = new Map<string, string>();
  const pubById = new Map<string, string>();
  if (peerIds.length > 0) {
    const [{ data: usrs }, { data: keys }] = await Promise.all([
      db.from("users").select("device_id, nickname").in("device_id", peerIds),
      db.from("user_keys").select("device_id, x25519_pub").in("device_id", peerIds),
    ]);
    for (const u of usrs ?? []) nickById.set(u.device_id, u.nickname);
    for (const k of keys ?? []) pubById.set(k.device_id, k.x25519_pub);
  }

  let invites: Awaited<ReturnType<typeof listPendingInvites>> = [];
  try {
    invites = await listPendingInvites(db, deviceId);
  } catch (error) {
    console.error("inbox invite list failed", error);
  }

  return {
    invites,
    totalUnread: list.reduce((sum, t) => sum + t.unreadCount, 0),
    threads: list.map((t) => ({
      peerDevice: t.peerDevice,
      peerNickname: nickById.get(t.peerDevice) ?? null,
      peerIdPub: pubById.get(t.peerDevice) ?? null,
      lastId: t.lastId,
      lastCiphertext: t.lastCiphertext,
      lastSenderIdPub: t.lastSenderIdPub,
      lastFromMe: t.lastFromMe,
      lastAt: t.lastAt,
      unreadCount: t.unreadCount,
    })),
  };
}
