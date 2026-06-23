// POST /codex-sample
// 범용 진단 샘플 수집 (이슈 #36 + 버그리포트 통합 후속).
//
// 두 가지 origin 을 한 테이블(codex_usage_samples)로 받는다:
//   'codex_voluntary' — Codex 섹션 "진단 제출" 버튼. rate_limit 구조 익명 집계 (정상 사용자 포함).
//   'bug_report'      — 버그리포트 "사용량 이슈" 템플릿. raw·로그를 비공개로 적재하고, GitHub
//                       공개 이슈에는 이 row 의 UUID 만 적어 개발자가 역참조한다.
//
// 보상이 없는 단순 수집이라 HMAC 서명을 받지 않는다 (랭킹 submit과 다른 점). 어뷰징 가치가
// 낮고 미등록 사용자도 제출 가능해야 하므로 device 등록 검증도 생략. 대신 payload 크기 상한과
// 필드별 길이 cap 으로 남용을 제한한다.
//
// 프라이버시: 클라이언트가 이미 PII(email/user_id/org uuid)·잔액(credits/cost)을 제거하고
// 보낸다. rate_limit / claude_usage / cursor_usage 는 사용률 서브트리 원본 구조 그대로(JSON
// 문자열) 받아 jsonb 로 저장 — 우리가 모르는 새 필드도 보존돼야 "어떻게 오는지" 확인이 되기 때문.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";

interface SampleRequest {
  id?: string;             // 클라이언트 생성 UUID (GitHub 이슈 역참조용). 누락/무효 시 DB default.
  origin?: string;         // 'codex_voluntary' | 'bug_report' (누락 시 codex_voluntary — 기존 클라 호환)
  category?: string;       // bug_report 세분류 (예: 'usage')
  deviceId?: string;
  appVersion?: string;
  osVersion?: string;
  planType?: string;
  rateLimitJson?: string;  // Codex rate_limit 객체 직렬화 JSON 문자열 (서버에서 parse → jsonb)
  claudeUsageJson?: string;// Claude usage 사용률 서브트리 직렬화 JSON 문자열
  cursorUsageJson?: string;// Cursor usage 사용률 서브트리 직렬화 JSON 문자열
  parsed?: { fiveHourPct?: number | null; sevenDayPct?: number | null; monthlyPct?: number | null };
  rawTopKeys?: string[];
  logTail?: string;        // 디버그 로그 마지막 N줄 (사용자 첨부 동의 시에만)
}

// UUID v4 형식만 통과 (위조해도 무가치하지만, GitHub 이슈에 박을 식별자라 형식은 강제).
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 문자열 JSON → jsonb 후보. 길이 cap 초과/파싱 실패 시 null (나머지는 저장 — 진단 가치 유지).
function parseJsonCapped(v: unknown, maxLen: number): unknown {
  if (typeof v !== "string" || v.length === 0 || v.length > maxLen) return null;
  try { return JSON.parse(v); } catch { return null; }
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

  // 남용 방지 — 전체 payload 크기 상한. 로그 + 다중 소스 raw 를 담는 bug_report 를 고려해
  // codex_voluntary(16KB) 대비 넉넉히 잡되, log_tail/usage 서브트리 합산 한계 안쪽으로 65KB.
  if (JSON.stringify(body).length > 65536) return errorResponse(413, "payload_too_large");

  const origin = body.origin === "bug_report" ? "bug_report" : "codex_voluntary";

  const str = (v: unknown, max: number) =>
    typeof v === "string" ? v.slice(0, max) : null;

  const db = getDb();
  const row: Record<string, unknown> = {
    origin,
    category: str(body.category, 32),
    device_id: str(body.deviceId, 64),
    app_version: str(body.appVersion, 32),
    os_version: str(body.osVersion, 64),
    plan_type: str(body.planType, 32),
    rate_limit: parseJsonCapped(body.rateLimitJson, 8192),
    claude_usage: parseJsonCapped(body.claudeUsageJson, 8192),
    cursor_usage: parseJsonCapped(body.cursorUsageJson, 8192),
    parsed: body.parsed && typeof body.parsed === "object" ? body.parsed : null,
    raw_top_keys: Array.isArray(body.rawTopKeys)
      ? body.rawTopKeys.slice(0, 64).map((k) => String(k).slice(0, 64))
      : null,
    log_tail: str(body.logTail, 4096),
  };
  // 클라가 보낸 UUID 가 유효하면 그대로 PK 로 사용 (이슈에 미리 박은 값과 일치 보장).
  // 무효/누락이면 컬럼 키 자체를 빼서 DB default(gen_random_uuid())에 맡긴다.
  if (typeof body.id === "string" && UUID_RE.test(body.id)) row.id = body.id.toLowerCase();

  const { data, error } = await db
    .from("codex_usage_samples")
    .insert(row)
    .select("id")
    .single();
  if (error) {
    console.error("codex-sample insert failed", error);
    return errorResponse(500, "insert_failed");
  }
  // id 를 돌려준다 — 클라가 클라생성 UUID 를 쓰지 않은 경우(서버 default)에도 이슈에 박을 값 확보.
  return jsonResponse({ ok: true, id: data?.id ?? body.id ?? null });
});
