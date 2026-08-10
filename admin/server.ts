// AIUsage 운영 대시보드 — 로컬 전용 프록시.
//
// 브라우저에 service_role 키를 절대 내리지 않기 위한 얇은 중계 계층. 브라우저는 이 서버의
// /api/<view> 만 호출하고, 키를 들고 PostgREST를 때리는 건 이 프로세스다.
//
// 실행:
//   deno run --allow-net --allow-read --allow-env admin/server.ts
//   → http://127.0.0.1:8787
//
// 사내망(TLS inspection) 환경에서 fetch가 `invalid peer certificate`로 죽으면:
//   DENO_TLS_CA_STORE=system deno run --allow-net --allow-read --allow-env admin/server.ts
//   (macOS 시스템 키체인의 사내 CA를 신뢰. 그래도 안 되면 최후수단으로 아래 플래그 —
//    호스트를 반드시 한정할 것. 전역 무효화 금지.)
//   deno run --unsafely-ignore-certificate-errors=<ref>.supabase.co ... admin/server.ts
//
// 보안 전제 (로컬 전용 설계 — 이 셋 중 하나라도 깨면 재설계 대상):
//   1. 127.0.0.1 에만 바인드. 0.0.0.0 으로 바꾸면 같은 네트워크의 누구나 service_role
//      권한으로 전 사용자 데이터를 읽는다.
//   2. 인증 없음. 위 1번이 유일한 접근 통제다.
//   3. 키는 scripts/ranking.env(gitignore됨)에서 읽는다. 이 파일에 하드코딩 금지.

const PORT = 8787;
const ENV_PATH = new URL("../scripts/ranking.env", import.meta.url).pathname;
const HTML_PATH = new URL("./index.html", import.meta.url).pathname;

// 프록시 허용 뷰 화이트리스트. admin_* 뷰 외의 임의 테이블 조회를 막는다 —
// 로컬 전용이라 공격면은 좁지만, 오타 한 번으로 users 원본(백업 blob 포함)을
// 브라우저로 끌어오는 사고를 구조적으로 차단한다.
const ALLOWED_VIEWS = new Set([
  "admin_overview",
  "admin_user_progress",
  "admin_daily_activity",
  "admin_abuse_queue",
  "admin_version_spread",
  "admin_pet_popularity",
  "admin_badge_progress",
]);

/** shell 형식 env 파일 파서 — `KEY=value` / `export KEY="value"` 만 인식. */
function loadEnv(path: string): Record<string, string> {
  let text: string;
  try {
    text = Deno.readTextFileSync(path);
  } catch {
    console.error(`✗ ${path} 를 읽을 수 없습니다. scripts/ranking.env.example 참고해 채우세요.`);
    Deno.exit(1);
  }
  const out: Record<string, string> = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const m = line.match(/^(?:export\s+)?([A-Z0-9_]+)=(.*)$/);
    if (!m) continue;
    out[m[1]] = m[2].trim().replace(/^["']|["']$/g, "");
  }
  return out;
}

const env = loadEnv(ENV_PATH);
const SUPABASE_URL = env.SUPABASE_URL;
const SERVICE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("✗ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 가 scripts/ranking.env 에 없습니다.");
  Deno.exit(1);
}

async function handler(req: Request): Promise<Response> {
  const url = new URL(req.url);

  if (url.pathname === "/" || url.pathname === "/index.html") {
    try {
      // 매 요청마다 읽는다 — 대시보드를 고치고 새로고침만 하면 반영되도록.
      const html = await Deno.readTextFile(HTML_PATH);
      return new Response(html, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    } catch {
      return new Response("index.html not found", { status: 500 });
    }
  }

  if (url.pathname.startsWith("/api/")) {
    const view = url.pathname.slice("/api/".length);
    if (!ALLOWED_VIEWS.has(view)) {
      return Response.json({ error: `view not allowed: ${view}` }, { status: 403 });
    }
    // PostgREST 쿼리 파라미터(select/order/limit/필터)는 그대로 통과시킨다.
    const target = `${SUPABASE_URL}/rest/v1/${view}?${url.searchParams.toString()}`;
    try {
      const res = await fetch(target, {
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          Accept: "application/json",
        },
      });
      const body = await res.text();
      return new Response(body, {
        status: res.status,
        headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // TLS inspection 환경에서 가장 흔한 실패 — 해결법을 응답에 직접 실어 보낸다.
      const hint = /certificate|tls|ssl/i.test(msg)
        ? " — TLS 오류입니다. DENO_TLS_CA_STORE=system 으로 재실행해 보세요 (파일 상단 주석 참조)."
        : "";
      return Response.json({ error: msg + hint }, { status: 502 });
    }
  }

  return new Response("not found", { status: 404 });
}

console.log(`AIUsage admin dashboard → http://127.0.0.1:${PORT}`);
console.log(`  target: ${SUPABASE_URL}  (service_role, 로컬 전용)`);
Deno.serve({ port: PORT, hostname: "127.0.0.1" }, handler);
