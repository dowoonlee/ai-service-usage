// POST /codex-sample
// Codex wham/usage 파싱 검증용 익명 샘플 수집 (이슈 #36).
//
// 보상이 없는 단순 수집이라 HMAC 서명을 받지 않는다 (랭킹 submit과 다른 점). 어뷰징 가치가
// 낮고 미등록 사용자도 제출 가능해야 하므로 device 등록 검증도 생략. 대신 payload 크기 상한과
// 필드별 길이 cap으로 남용을 제한한다.
//
// 프라이버시: 클라이언트가 이미 PII(email/user_id)·잔액(credits.balance)을 제거하고 보낸다.
// rate_limit 은 원본 구조 그대로(JSON 문자열) 받아 jsonb 로 저장 — 우리가 모르는 새 필드도
// 보존돼야 "어떻게 오는지" 확인이 가능하기 때문.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";

interface SampleRequest {
  deviceId?: string;
  appVersion?: string;
  planType?: string;
  rateLimitJson?: string;  // rate_limit 객체를 직렬화한 JSON 문자열 (서버에서 parse → jsonb)
  parsed?: { fiveHourPct?: number | null; sevenDayPct?: number | null; monthlyPct?: number | null };
  rawTopKeys?: string[];
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: SampleRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  if (!body || typeof body !== "object") return errorResponse(400, "missing_body");

  // 남용 방지 — 전체 payload 크기 상한.
  if (JSON.stringify(body).length > 16384) return errorResponse(413, "payload_too_large");

  // rate_limit 은 문자열로 받아 서버에서 parse (실패해도 나머지는 저장 — 진단 가치 유지).
  let rateLimit: unknown = null;
  if (typeof body.rateLimitJson === "string" && body.rateLimitJson.length > 0
      && body.rateLimitJson.length <= 8192) {
    try { rateLimit = JSON.parse(body.rateLimitJson); } catch { rateLimit = null; }
  }

  const str = (v: unknown, max: number) =>
    typeof v === "string" ? v.slice(0, max) : null;

  const db = getDb();
  const { error } = await db.from("codex_usage_samples").insert({
    device_id: str(body.deviceId, 64),
    app_version: str(body.appVersion, 32),
    plan_type: str(body.planType, 32),
    rate_limit: rateLimit,
    parsed: body.parsed && typeof body.parsed === "object" ? body.parsed : null,
    raw_top_keys: Array.isArray(body.rawTopKeys)
      ? body.rawTopKeys.slice(0, 64).map((k) => String(k).slice(0, 64))
      : null,
  });
  if (error) {
    console.error("codex-sample insert failed", error);
    return errorResponse(500, "insert_failed");
  }
  return jsonResponse({ ok: true });
});
