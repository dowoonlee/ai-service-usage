// GET /contributors
// 외부 PR 기여자 목록. deviceId 불필요, 읽기 전용 public (announcements/pet-metadata와 동일 패턴).
//
// 클라이언트가 각자 GitHub을 치던 것을 서버 한 곳으로 모았다. 이유는 두 가지다:
//   1) 비인증 GitHub API는 **IP 단위** 60req/h — 사내망 NAT이면 전 사용자가 한 IP를 공유해 소진된다.
//   2) 옛 클라가 쓰던 `/pulls?state=closed&per_page=100`은 생성 역순 100개만 준다. 리포 PR이
//      215개까지 늘면서 외부 기여자 PR(#3·#8·#45·#59)이 창 밖으로 밀려 목록이 조용히 비었다.
//      Search API는 PR 수와 무관하게 조건에 맞는 것만 주므로 이 문제가 재발하지 않는다.
//
// 갱신은 pg_cron 없이 lazy 트리거 — 첫 호출자가 TTL 만료를 관측하면 슬롯을 원자적으로 선점해
// (claim_contributors_sync) GitHub을 한 번만 호출한다. 실패해도 기존 캐시를 그대로 응답한다.
//
// 응답: { contributors: [{ login, avatarURL, prs: [{number,title,mergedAt}] }], syncedAt }

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";

const REPO = "dowoonlee/ai-service-usage";
/** repo owner는 외부 기여자가 아니므로 집계에서 제외. */
const OWNER = "dowoonlee";
/** 갱신 주기. 기여자 목록은 몇 주 단위로 바뀌는 데이터라 길게 잡는다. */
const TTL_SECONDS = 24 * 3600;
/** 실패 시 재시도 간격 — TTL보다 훨씬 짧게 둬서 "하루 종일 빈 목록"에 갇히지 않게. */
const RETRY_SECONDS = 30 * 60;
/** Search API 1회 상한. 현재 외부 기여 PR은 4건이라 여유가 크다. */
const PER_PAGE = 100;

interface SearchItem {
  number: number;
  title: string;
  closed_at: string | null;
  user: { login: string; avatar_url: string | null } | null;
  pull_request?: { merged_at: string | null };
}

interface PR {
  number: number;
  title: string;
  mergedAt: string;
}

/** GitHub Search API로 "머지된 + 오너가 아닌" PR만 가져온다. */
async function fetchFromGitHub(): Promise<Map<string, { avatar: string | null; prs: PR[] }>> {
  const q = `repo:${REPO} is:pr is:merged -author:${OWNER}`;
  const url = `https://api.github.com/search/issues?q=${encodeURIComponent(q)}` +
    `&per_page=${PER_PAGE}&sort=created&order=desc`;

  const headers: Record<string, string> = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "aiusage-contributors-sync",
  };
  // 토큰이 있으면 인증 요청(Search 분당 30회). 없어도 동작한다(분당 10회) — 하루 1회 호출엔 충분.
  const token = Deno.env.get("GITHUB_TOKEN");
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(url, { headers });
  if (!res.ok) {
    throw new Error(`github ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const body = await res.json() as { items?: SearchItem[] };

  const bucket = new Map<string, { avatar: string | null; prs: PR[] }>();
  for (const it of body.items ?? []) {
    const login = it.user?.login;
    if (!login || login === OWNER) continue;
    // is:merged로 걸렀으므로 merged_at이 정상이지만, 누락 시 closed_at으로 폴백.
    const mergedAt = it.pull_request?.merged_at ?? it.closed_at;
    if (!mergedAt) continue;
    const entry = bucket.get(login) ?? { avatar: it.user?.avatar_url ?? null, prs: [] };
    entry.prs.push({ number: it.number, title: it.title, mergedAt });
    if (!entry.avatar) entry.avatar = it.user?.avatar_url ?? null;
    bucket.set(login, entry);
  }
  return bucket;
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const db = getDb();

  // TTL 만료 시 한 요청만 갱신을 맡는다(동시 호출이 GitHub을 중복으로 두드리지 않게).
  const { data: claimed } = await db.rpc("claim_contributors_sync", {
    ttl_seconds: TTL_SECONDS,
    retry_seconds: RETRY_SECONDS,
  });

  if (claimed === true) {
    try {
      const bucket = await fetchFromGitHub();
      const rows = [...bucket.entries()].map(([login, v]) => {
        const prs = v.prs.sort((a, b) => b.mergedAt.localeCompare(a.mergedAt));
        return {
          login,
          avatar_url: v.avatar,
          prs,
          pr_count: prs.length,
          latest_merged_at: prs[0]?.mergedAt ?? null,
          updated_at: new Date().toISOString(),
        };
      });

      if (rows.length > 0) {
        const { error: upErr } = await db.from("contributors").upsert(rows, { onConflict: "login" });
        if (upErr) throw new Error(`upsert: ${upErr.message}`);
        // 더 이상 조건에 맞지 않는(예: PR이 revert되어 unmerged 처리된) 기여자 정리.
        const keep = rows.map((r) => r.login);
        await db.from("contributors").delete().not("login", "in", `(${keep.map((l) => `"${l}"`).join(",")})`);
      }

      await db.from("contributors_sync")
        .update({ last_success_at: new Date().toISOString(), last_error: null })
        .eq("id", 1);
    } catch (e) {
      // 갱신 실패는 조용히 삼킨다 — 기존 캐시를 그대로 응답하는 편이 빈 목록보다 낫다.
      // last_attempt_at은 이미 갱신됐으므로 RETRY_SECONDS 뒤에 다시 시도한다.
      const msg = e instanceof Error ? e.message : String(e);
      console.error("contributors sync failed", msg);
      await db.from("contributors_sync").update({ last_error: msg.slice(0, 500) }).eq("id", 1);
    }
  }

  const { data: rows, error } = await db
    .from("contributors")
    .select("login, avatar_url, prs, pr_count, latest_merged_at")
    .order("pr_count", { ascending: false })
    .order("latest_merged_at", { ascending: false });
  if (error) {
    console.error("contributors fetch failed", error);
    return errorResponse(500, "fetch_failed");
  }

  const { data: meta } = await db
    .from("contributors_sync").select("last_success_at").eq("id", 1).maybeSingle();

  return jsonResponse({
    contributors: (rows ?? []).map((r) => ({
      login: r.login,
      avatarURL: r.avatar_url,
      prs: r.prs ?? [],
    })),
    syncedAt: meta?.last_success_at ?? null,
  });
});
