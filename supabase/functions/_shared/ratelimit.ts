// IP 기반 rolling-window rate-limit 유틸 — register / guild-create / codex-sample이 각자
// 복붙하던 clientIp() 4줄 + window count 체크를 한 곳으로 모은다.
// IP는 완벽한 식별자가 아니라(VPN/CGNAT/공용망) 1차 방어선일 뿐 — 임계는 정상 사용자를
// 막지 않도록 넉넉히 두는 게 각 호출부의 정책. "성공 시에만 로그 행 insert"하는 타이밍은
// 함수마다 달라(등록 성공 후 vs 매 요청) 호출부에 남긴다.

import { getDb } from "./db.ts";

/** 클라이언트 IP — Supabase Edge runtime이 x-forwarded-for에 실제 IP를 넣는다(첫 항목). */
export function clientIp(req: Request): string | null {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) {
    const first = xff.split(",")[0].trim();
    if (first) return first;
  }
  return req.headers.get("x-real-ip");
}

/**
 * window(초) 내 같은 ip의 행 수가 max 이상이면 true(차단). ip가 null이면(헤더 부재) false —
 * Edge runtime에선 항상 채워지므로 실질 우회는 아니다. 테이블별 컬럼명 차이는 옵션으로 흡수
 * (register/guild-create는 ip·attempted_at, codex-sample은 client_ip·created_at).
 */
export async function ipRateLimited(
  db: ReturnType<typeof getDb>,
  opts: {
    table: string;
    ip: string | null;
    windowSec: number;
    max: number;
    ipColumn?: string;
    tsColumn?: string;
  },
): Promise<boolean> {
  if (!opts.ip) return false;
  const ipCol = opts.ipColumn ?? "ip";
  const tsCol = opts.tsColumn ?? "attempted_at";
  const since = new Date(Date.now() - opts.windowSec * 1000).toISOString();
  const { count } = await db
    .from(opts.table)
    .select("id", { count: "exact", head: true })
    .eq(ipCol, opts.ip)
    .gte(tsCol, since);
  return (count ?? 0) >= opts.max;
}
