// POST /rename-nickname
// 등록된 device가 본인 닉네임을 변경. HMAC-signed payload로 본인 인증.
// payload(서명 대상, flat): { deviceId, nickname, ts }
//
// 배경: 클라이언트 설정 화면의 닉네임 편집이 로컬 `Settings.rankingNickname`만 바꾸고 서버엔
// 전달하지 않아, 보드엔 등록 시 닉네임이 계속 남고 본인 행 강조만 어긋나던 문제. 서버 쪽
// users.nickname은 register 외엔 쓰는 곳이 없었으므로 이 함수가 유일한 변경 경로다.
//
// 닉네임은 users.nickname 한 곳에만 live로 있고(게시판·길드·DM은 users를 join) 월간 우승
// 기록만 nickname_snapshot으로 동결돼 있다 — 과거 시상대 이름이 바뀌지 않는 건 의도.
// 유일성은 register와 같은 users_nickname_normalized_uniq(LOWER 비교)가 최종 방어.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidNickname, isValidUUID } from "../_shared/validation.ts";

interface Payload {
  deviceId: string;
  nickname: string;
  ts: number;
}
interface Req {
  payload: Payload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: Req;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!isValidNickname(p.nickname)) return errorResponse(400, "invalid_nickname");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  // UUID 소문자 정규화 — 클라(Swift)는 대문자로 보내고 DB는 소문자. 서명 검증은 클라가 보낸
  // raw 값으로 해야 하므로 p.deviceId는 그대로 두고 조회 키만 바꾼다.
  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status, nickname")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, nickname: p.nickname, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 멱등 — 같은 값이면 쓰기 없이 성공.
  if (user.nickname === p.nickname) return jsonResponse({ nickname: user.nickname });

  // 충돌 선검사 — 본인 row는 제외해야 대소문자만 바꾸는 변경(abc → ABC)이 허용된다.
  // register와 마찬가지로 .or() 문자열 보간 없이 .eq()/.neq() 조합(필터 인젝션 회피).
  const normalized = p.nickname.toLowerCase();
  const { data: clash } = await db
    .from("users")
    .select("device_id")
    .eq("nickname_normalized", normalized)
    .neq("device_id", deviceId)
    .limit(1);
  if (clash && clash.length > 0) return errorResponse(409, "nickname_taken");

  const { data: updated, error } = await db
    .from("users")
    .update({ nickname: p.nickname, nickname_normalized: normalized })
    .eq("device_id", deviceId)
    .select("nickname")
    .maybeSingle();
  if (error) {
    // UNIQUE 위반 — 선검사와 UPDATE 사이의 race. 409로 통일.
    if (error.code === "23505") return errorResponse(409, "nickname_taken");
    console.error("rename-nickname update failed", error);
    return errorResponse(500, "update_failed");
  }
  if (!updated) return errorResponse(404, "device_not_registered");

  return jsonResponse({ nickname: updated.nickname });
});
