// GET /announcements
// 버전별 패치 공지. 업데이트 후 첫 실행 시 클라이언트가 (since, current] 구간 활성 공지를 받아
// 별도 창으로 표시한다. deviceId 불필요, 읽기 전용 public (pet-metadata와 동일 패턴).
//
// Query:
//   ?current=0.14.0  — 클라이언트 현재 버전. 주면 version <= current 만 후보.
//   ?since=0.13.3    — 클라이언트가 마지막으로 본 버전. (since, current]=새 공지, since 이하=이전 공지.
//   ?previous=3      — 함께 내려줄 이전(이미 본) 공지 개수. 0..10로 클램프.
// 응답: { announcements: [새 공지 최신순], previous: [이전 공지 최신순 N개] }
// 둘 다 생략하면 활성 공지 전체가 announcements로, previous는 빈 배열.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";

// "a.b.c" semver 단순 비교 — 숫자 컴포넌트만. 클라이언트 Announcements.compare와 동일 규칙.
// a<b → -1, a==b → 0, a>b → 1.
function cmpVersion(a: string, b: string): number {
  const pa = a.split(".").map((s) => parseInt(s, 10) || 0);
  const pb = b.split(".").map((s) => parseInt(s, 10) || 0);
  const n = Math.max(pa.length, pb.length);
  for (let i = 0; i < n; i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

interface Row {
  version: string;
  title: string;
  body: string;
  published_at: string;
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const current = url.searchParams.get("current");
  const since = url.searchParams.get("since");
  // 함께 내려줄 이전(이미 본) 공지 개수. 클라가 정책값 전달, 서버는 0..10로 클램프.
  const prevParam = parseInt(url.searchParams.get("previous") ?? "0", 10);
  const previousLimit = Math.max(0, Math.min(10, Number.isNaN(prevParam) ? 0 : prevParam));

  const db = getDb();
  const { data, error } = await db
    .from("announcements")
    .select("version, title, body, published_at")
    .eq("is_active", true);

  if (error) {
    console.error("announcements fetch failed", error);
    return errorResponse(500, "fetch_failed");
  }

  let rows = (data ?? []) as Row[];
  if (current) rows = rows.filter((r) => cmpVersion(r.version, current) <= 0);
  rows.sort((a, b) => cmpVersion(b.version, a.version)); // 최신 버전 먼저

  // new: (since, current] 미열람 구간. previous: since 이하(이미 본) 중 최근 previousLimit개.
  const newRows = since ? rows.filter((r) => cmpVersion(r.version, since) > 0) : rows;
  const prevRows = since
    ? rows.filter((r) => cmpVersion(r.version, since) <= 0).slice(0, previousLimit)
    : [];

  const mapRow = (r: Row) => ({
    version: r.version,
    title: r.title,
    body: r.body,
    publishedAt: r.published_at,
  });

  return jsonResponse({
    announcements: newRows.map(mapRow),
    previous: prevRows.map(mapRow),
  });
});
