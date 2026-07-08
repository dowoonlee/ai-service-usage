// GET /tenant-domains — 인증 폼의 도메인 드롭다운 소스. docs/plans/tenant.md §3-4 (D9).
//
// 활성 tenant_email_domains ⨝ tenants → 선택 가능한 도메인 목록. deviceId 불필요(공개 목록).
// 클라는 이 목록으로 "[로컬파트] @ [도메인 ▼]" 드롭다운을 채운다. 선택 도메인의 tenant가 편입 대상.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const db = getDb();
  const { data, error } = await db
    .from("tenant_email_domains")
    .select("domain, label, tenant_slug, tenants(display_name)")
    .eq("is_active", true)
    .order("domain", { ascending: true });
  if (error) {
    console.error("tenant-domains fetch failed", error);
    return errorResponse(500, "fetch_failed");
  }

  const domains = (data ?? []).map((d) => ({
    domain: d.domain,
    label: (d.label as string | null) ?? (d.domain as string),
    tenant: d.tenant_slug,
    // deno-lint-ignore no-explicit-any
    tenantName: (d.tenants as any)?.display_name ?? d.tenant_slug,
  }));
  return jsonResponse({ domains });
});
