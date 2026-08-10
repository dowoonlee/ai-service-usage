// POST /dm-inbox — 내 쪽지 스레드 요약 (상대별 최근 1건 + 미확인 수). 요청자 서명.
//
// payload(서명 대상, flat): { deviceId, ts }
//
// 서버는 나와 얽힌 메시지(발신/수신)를 상대(peer)별로 묶어 최근 1건을 요약해 준다. 본문은
// E2EE라 서버가 못 읽으므로 ciphertext 그대로 내려주고, 클라가 복호(수신분)하거나 로컬 echo
// (발신분)로 미리보기를 만든다. 삭제(tombstone)된 내 쪽은 제외.
//
// 응답의 `invites`는 받은 길드 초대 — 클라의 통합 인박스 배지가 "미확인 쪽지 + 대기중 초대"
// 라서 예전엔 guild-invite(list)를 따로 한 번 더 호출했다. 배지 하나에 함수 호출 두 개는
// 배경 폴링에 곱해지면 무료 플랜 쿼터를 갉아먹어서 여기로 합쳤다.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { fetchInbox } from "../_shared/dm_inbox_query.ts";

interface InboxPayload {
  deviceId: string;
  ts: number;
}
interface InboxRequest {
  payload: InboxPayload;
  signature: string;
}
const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: InboxRequest;
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
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, ts: p.ts }, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 조회 본체는 `_shared/dm_inbox_query.ts` — sync가 같은 로직을 쓴다.
  // `invites`는 받은 길드 초대. 구버전 클라는 이 필드를 무시하고 guild-invite(list)를 계속
  // 쓰므로 응답 추가는 하위호환이다.
  const { threads, invites } = await fetchInbox(db, deviceId);
  return jsonResponse({ invites, threads });
});
