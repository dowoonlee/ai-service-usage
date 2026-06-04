// GET /pet-metadata
// 전 사용자 공통 펫 메타데이터(이름/대사/설명). deviceId 불필요, 읽기 전용 public.
//
// 클라이언트는 feature flag(experimentalRemotePetMeta)가 켜졌을 때만 이 응답을 코드
// 하드코딩 위의 override로 사용한다. 응답이 비거나 일부 kind가 빠져도 클라는 fallback으로
// 정상 동작하므로, 여기서는 단순히 테이블 전체를 반환한다.
//
// 등급(tier)/스프라이트 렌더 메타는 의도적으로 포함하지 않는다 — 클라 코드에 고정.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const db = getDb();
  const { data, error } = await db
    .from("pet_metadata")
    .select("kind, display_name, description, quotes")
    .order("kind", { ascending: true });

  if (error) {
    console.error("pet_metadata fetch failed", error);
    return errorResponse(500, "fetch_failed");
  }

  const pets = (data ?? []).map((r) => ({
    kind: r.kind as string,
    displayName: r.display_name as string,
    description: r.description as string,
    quotes: (r.quotes ?? []) as string[],
  }));

  return jsonResponse({ pets });
});
