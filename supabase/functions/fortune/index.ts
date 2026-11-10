// POST /fortune
// 오늘의 개발 운세 — 단일 호출로 fetch + (캐시 미스 시) Claude 호출 + save 모두 처리.
//
// 보안 모델:
//   * Claude 키는 `Deno.env.get("ANTHROPIC_API_KEY")` 로 — 앱 바이너리에 절대 노출되지 않음.
//     조직 키면 `ANTHROPIC_WORKSPACE_ID`(wrkspc_...)도 secret으로 — 실행 workspace 지정 헤더용.
//     ad-hoc 서명 데스크톱 앱은 strings/lldb 로 키 추출이 너무 쉬워 클라이언트 보관 불가.
//   * 명리학 사주 계산은 클라이언트가 결정론적으로 수행 (외부 의존 0) → 서버는 그 결과를
//     Claude 프롬프트에 전달만 함. 서버에서 사주 재계산하지 않음.
//   * Rate limit 은 KST 오늘 날짜 + (device_id, fortune_date) 캐시가 자연 제약.
//     같은 날 두 번째 호출은 같은 프롬프트 버전이면 Claude 비호출.
//
// HMAC: payload 전체 canonicalize → device 의 hmac_key_b64 로 verify. submit/post 와 동일.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { MODEL_LABEL, generateFortune } from "./claude.ts";

interface FortunePayload {
  date: string;        // "YYYY-MM-DD"
  dailyJson: string;   // DailyFortune JSON (오늘 일진 + 일간 vs 일진 관계)
  deviceId: string;
  sajuJson: string;    // SajuChart JSON (사주팔자 + 오행 분포)
  ts: number;
}

interface FortuneRequest {
  payload: FortunePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const MAX_SAJU_JSON_LEN = 4000;
const MAX_DAILY_JSON_LEN = 1000;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
// 모델/프롬프트 버전과 캐시 라벨(MODEL_LABEL)은 ./claude.ts 에 있다.

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: FortuneRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.date !== "string" || !DATE_RE.test(p.date)) return errorResponse(400, "invalid_date");
  if (p.date !== todayKstDateString()) return errorResponse(400, "date_must_be_today_kst");
  if (typeof p.sajuJson !== "string" || p.sajuJson.length === 0 || p.sajuJson.length > MAX_SAJU_JSON_LEN) {
    return errorResponse(400, "invalid_saju_json");
  }
  if (typeof p.dailyJson !== "string" || p.dailyJson.length === 0 || p.dailyJson.length > MAX_DAILY_JSON_LEN) {
    return errorResponse(400, "invalid_daily_json");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const db = getDb();
  const { data: user, error: userErr } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", p.deviceId)
    .single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const hmacPayload: Record<string, unknown> = {
    date: p.date,
    dailyJson: p.dailyJson,
    deviceId: p.deviceId,
    sajuJson: p.sajuJson,
    ts: p.ts,
  };
  const ok = await verifyHmac(hmacPayload, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 1) 캐시 hit? 같은 프롬프트 버전으로 만든 오늘 row 가 있으면 그대로 반환.
  const { data: existing, error: selErr } = await db
    .from("daily_fortunes")
    .select("device_id, fortune_date, saju_json, fortune_text, model, created_at")
    .eq("device_id", p.deviceId)
    .eq("fortune_date", p.date)
    .maybeSingle();
  if (selErr) {
    console.error("fortune select failed", selErr);
    return errorResponse(500, "select_failed");
  }
  if (existing && existing.model === MODEL_LABEL) {
    return jsonResponse({
      row: rowResponse(existing, /* cached */ true),
    });
  }
  // 기존 프롬프트로 만든 오늘 캐시가 있으면 한 번만 재생성한다.
  // 품질 개선 배포 직후 사용자가 같은 날 다시 열어도 새 프롬프트를 체감하게 하기 위함.

  // 2) sajuJson / dailyJson parse — 프롬프트 구성을 위해.
  let saju: Record<string, unknown>;
  let daily: Record<string, unknown>;
  try {
    saju = JSON.parse(p.sajuJson);
  } catch {
    return errorResponse(400, "saju_json_not_json");
  }
  try {
    daily = JSON.parse(p.dailyJson);
  } catch {
    return errorResponse(400, "daily_json_not_json");
  }

  // 3) Claude 호출
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    console.error("ANTHROPIC_API_KEY env missing");
    return errorResponse(503, "claude_not_configured");
  }

  // 최근 운세 — 모델이 이전 글과 구조·소재가 겹치지 않게 참고한다. 실패해도 생성은 진행(부가 정보).
  const { data: recentRows, error: recentErr } = await db
    .from("daily_fortunes")
    .select("fortune_text")
    .eq("device_id", p.deviceId)
    .lt("fortune_date", p.date)
    .order("fortune_date", { ascending: false })
    .limit(5);
  if (recentErr) console.error("fortune recent select failed (continuing without)", recentErr);
  const recentTexts = (recentRows ?? [])
    .map((r) => r.fortune_text)
    .filter((x): x is string => typeof x === "string");

  let fortuneText: string;
  try {
    const gen = await generateFortune(saju, daily, apiKey, {
      baseUrl: Deno.env.get("ANTHROPIC_BASE_URL") || undefined,
      workspaceId: Deno.env.get("ANTHROPIC_WORKSPACE_ID") || undefined,
      recentTexts,
    });
    fortuneText = gen.text;
    // 본문은 남기지 않는다 — 모델·종료 사유·토큰 수만.
    console.log(`fortune claude model=${gen.model} stop=${gen.stopReason} in=${gen.inputTokens} out=${gen.outputTokens}`);
  } catch (e) {
    console.error("Claude call failed", e);
    const msg = e instanceof Error ? e.message : "unknown";
    return errorResponse(502, `claude_error: ${msg.slice(0, 200)}`);
  }

  // 4) row upsert. 프롬프트 버전이 바뀐 날에는 기존 캐시를 새 문장으로 갱신한다.
  const { error: insErr } = await db.from("daily_fortunes").upsert(
    {
      device_id: p.deviceId,
      fortune_date: p.date,
      saju_json: saju,
      fortune_text: fortuneText,
      model: MODEL_LABEL,
    },
    { onConflict: "device_id,fortune_date" },
  );
  if (insErr) {
    // 저장 실패해도 사용자에겐 텍스트 반환 — UX 우선. 같은 비용 다시 들이는 일은 거의 없음 (네트워크 transient).
    console.error("fortune upsert failed (returning text anyway)", insErr);
  }

  return jsonResponse({
    row: {
      deviceId: p.deviceId,
      fortuneDate: p.date,
      sajuJson: p.sajuJson,
      fortuneText,
      model: MODEL_LABEL,
      createdAt: new Date().toISOString(),
      cached: false,
    },
  });
});

function rowResponse(data: Record<string, unknown>, cached: boolean) {
  return {
    deviceId: data.device_id,
    fortuneDate: data.fortune_date,
    sajuJson:
      typeof data.saju_json === "string"
        ? data.saju_json
        : JSON.stringify(data.saju_json),
    fortuneText: data.fortune_text,
    model: data.model,
    createdAt: data.created_at,
    cached,
  };
}

function todayKstDateString(): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
  return `${get("year")}-${get("month")}-${get("day")}`;
}
