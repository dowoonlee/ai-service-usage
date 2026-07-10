// POST /tenant-verify-request — 게이트 테넌트(예: skax) 편입용 이메일 OTP 발송. docs/plans/tenant.md §3-4.
//
// payload(서명 대상, flat): { deviceId, email, ts }
//   이메일 도메인이 tenant_email_domains에 등록된 게이트 테넌트로 6자리 코드를 발송한다.
//   [D8] 이메일 주소는 DB에 저장하지 않는다 — 발송에만 쓰고 버린다. tenant_otp엔 code_hash만.
//   [보안] 모든 device 변경 액션과 동일하게 HMAC 서명 필수 — deviceId만 아는 제3자의 편입 방지.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { emailDomain, sha256Hex, maskEmails } from "../_shared/tenant.ts";
import { sendMail } from "../_shared/mailer.ts";

interface RequestPayload {
  deviceId: string;
  email: string;
  ts: number;
}
interface VerifyRequest {
  payload: RequestPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const OTP_TTL_SEC = 600;              // 10분
const REQ_COOLDOWN_SEC = 60;          // 같은 device 재요청 최소 간격
const REQ_MAX_PER_DAY = 5;            // 같은 device 24h 요청 상한

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: VerifyRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.email !== "string" || p.email.length > 254) return errorResponse(400, "invalid_email");
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

  const ok = await verifyHmac(
    { deviceId: p.deviceId, email: p.email, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 기본 테넌트에서만 편입 가능(one-way) — 이미 gated면 재편입 거부.
  const { data: def } = await db.from("tenants").select("slug").eq("is_default", true).maybeSingle();
  const defaultSlug = def?.slug ?? "public";
  if (user.tenant_id !== defaultSlug) return errorResponse(409, "already_gated");

  // 도메인 → 게이트 테넌트 해석. tenant_email_domains 정확 일치(is_active)만 통과.
  const domain = emailDomain(p.email);
  if (!domain) return errorResponse(400, "invalid_email");
  const { data: domRow } = await db
    .from("tenant_email_domains")
    .select("tenant_slug")
    .eq("domain", domain)
    .eq("is_active", true)
    .maybeSingle();
  if (!domRow) return errorResponse(400, "domain_not_allowed");
  const tenantSlug = domRow.tenant_slug as string;

  // rate-limit — device 기준(이메일 미저장이라 per-email 불가). 최근 60초 1회 / 24h 5회.
  const since60 = new Date(Date.now() - REQ_COOLDOWN_SEC * 1000).toISOString();
  const { count: recent } = await db
    .from("tenant_otp")
    .select("id", { count: "exact", head: true })
    .eq("device_id", deviceId)
    .gte("created_at", since60);
  if ((recent ?? 0) >= 1) return errorResponse(429, "rate_limited");
  const since24h = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count: daily } = await db
    .from("tenant_otp")
    .select("id", { count: "exact", head: true })
    .eq("device_id", deviceId)
    .gte("created_at", since24h);
  if ((daily ?? 0) >= REQ_MAX_PER_DAY) return errorResponse(429, "rate_limited");

  // 6자리 코드 → 해시만 저장. 코드는 로그 금지.
  const code = String(Math.floor(100000 + Math.random() * 900000));
  const codeHash = await sha256Hex(code);
  const expiresAt = new Date(Date.now() + OTP_TTL_SEC * 1000).toISOString();
  const { data: otpRow, error: insErr } = await db.from("tenant_otp").insert({
    device_id: deviceId,
    tenant_slug: tenantSlug,
    code_hash: codeHash,
    expires_at: expiresAt,
  }).select("id").single();
  if (insErr || !otpRow) {
    console.error("tenant_otp insert failed", insErr);
    return errorResponse(500, "otp_failed");
  }

  // Gmail SMTP 발송 — 커스텀 발신기(_shared/mailer.ts: 단일 text/html·CRLF·B-encoded 제목)로
  // Exchange/M365 호환. denomailer의 중첩 multipart 출력은 일부 사내 메일서버(SKCC)에서 raw로
  // 노출되거나 빈 본문이 돼 교체함.
  const gmailUser = Deno.env.get("GMAIL_USER");
  const gmailPass = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!gmailUser || !gmailPass) {
    console.error("GMAIL_USER/GMAIL_APP_PASSWORD missing");
    return errorResponse(500, "mail_not_configured");
  }
  const tName = tenantSlug.toUpperCase();
  const html =
    `<div style="font-family:-apple-system,'Segoe UI',sans-serif;font-size:15px;color:#111;line-height:1.5;">`
    + `<p style="margin:0 0 8px;">AIUsage <strong>${tName}</strong> 인증 코드</p>`
    + `<div style="font-size:30px;font-weight:700;letter-spacing:5px;margin:6px 0 12px;">${code}</div>`
    + `<p style="margin:0;color:#888;font-size:13px;">앱에 이 코드를 입력하세요. (10분 유효)</p></div>`;
  try {
    await sendMail({
      from: gmailUser, to: p.email.trim(), subject: "AIUsage 인증 코드",
      html, user: gmailUser, pass: gmailPass,
    });
  } catch (e) {
    // 발송 실패 시 방금 만든 OTP row를 되돌린다 — 코드도 못 받았는데 rate-limit(60초/일5회)을
    // 소모해 재시도가 막히는 것을 방지(리뷰 지적). best-effort.
    await db.from("tenant_otp").delete().eq("id", otpRow.id);
    // SMTP 거부 응답에 수신 이메일이 echo될 수 있어 마스킹 후 로깅(회사 이메일 평문 노출 방지).
    // 에러 객체를 그대로 넘기면 마스킹이 안 되므로 문자열로 만든 뒤 통과시킨다.
    const detail = (e as { message?: string })?.message ?? String(e);
    console.error("tenant-verify-request mail send failed", maskEmails(detail));
    return errorResponse(502, "mail_failed");
  }

  return jsonResponse({ ok: true, tenant: tenantSlug, expiresInSec: OTP_TTL_SEC });
});
