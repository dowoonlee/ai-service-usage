// AIUsage 요청 프록시 — Supabase 앞단 게이트.
//
// 왜 필요한가: Edge Function은 426/403을 반환해도 "이미 실행된 것"이라 invocation으로 과금된다.
// 구버전 클라가 8초 주기로 폴링하면 서버가 무엇을 응답하든 쿼터가 깎인다(2026-08 실측: 구버전
// 3대가 월 ~69만건 유발, 무료 한도 50만). 요청을 Supabase에 닿기 **전에** 끊어야 실효가 있고,
// 그게 이 Worker의 존재 이유다.
//
// 차단은 두 축이다:
//   1) 버전 — 클라가 X-App-Version 헤더로 자기 버전을 보낸다. DB 조회가 필요 없다.
//   2) deviceId — 개별 지목 차단. 요청에 이미 실려 있다(GET은 쿼리, POST는 payload).
//
// ⚠ 한계: 이 게이트는 **프록시를 경유하는 클라에만** 걸린다. 이미 배포된 구버전은 Info.plist에
//   박힌 supabase.co로 직행하므로 여기 오지 않는다. 즉 지금 문제인 구버전 9명에게는 소급되지
//   않고, 이 구조는 "다음에 같은 일이 생겼을 때 서버 비용 없이 끊기 위한" 장치다.

const SUPABASE_HOST = "wzqqpqxetsmauntgwttf.supabase.co";

/** dotted numeric 비교. 클라 min_version.ts / 대시보드 cmpVersion과 같은 규칙. */
function cmpVersion(a, b) {
  const pa = String(a).split(".").map((s) => parseInt(s, 10) || 0);
  const pb = String(b).split(".").map((s) => parseInt(s, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? 0, y = pb[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

/** 쉼표/공백 구분 목록 → 소문자 Set. deviceId는 클라가 대문자로 보내기도 한다. */
function parseList(raw) {
  return new Set(
    String(raw ?? "").split(/[,\s]+/).map((s) => s.trim().toLowerCase()).filter(Boolean),
  );
}

/**
 * 요청에서 deviceId를 뽑는다. GET은 쿼리스트링, POST는 서명 payload 안에 있다.
 * body를 읽으면 스트림이 소비되므로 호출자가 넘긴 텍스트를 재사용한다.
 */
function extractDeviceId(url, bodyText) {
  const q = url.searchParams.get("deviceId");
  if (q) return q.toLowerCase();
  if (!bodyText) return null;
  try {
    const j = JSON.parse(bodyText);
    const d = j?.payload?.deviceId ?? j?.deviceId;
    return typeof d === "string" ? d.toLowerCase() : null;
  } catch {
    return null;
  }
}

// 차단 응답은 평문이다. 구버전 클라의 에러 매핑이 403/409/412/429를 각각 다른 문구로 고정
// 해석하므로(min_version.ts 주석 참조) JSON을 주면 원문이 그대로 사용자에게 노출된다.
const textResponse = (status, msg) =>
  new Response(msg, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // 프록시가 살아 있는지 확인용 — 배포 검증에 쓴다. Supabase로 넘기지 않는다.
    if (url.pathname === "/__health") {
      return Response.json({
        ok: true,
        minVersion: env.MIN_APP_VERSION ?? null,
        blockedDevices: parseList(env.BLOCKED_DEVICE_IDS).size,
      });
    }

    // CORS preflight는 Supabase까지 보내지 않고 여기서 끝낸다 — 그것도 invocation이다.
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-app-version",
          "access-control-allow-methods": "GET, POST, OPTIONS",
        },
      });
    }

    // ── 1) 버전 게이트. 헤더가 없으면 통과시킨다(fail-open) — 헤더를 안 보내는 클라는
    //       애초에 프록시 URL을 모르므로 여기 올 수 없고, 누락으로 정상 사용자를 막는 사고가
    //       차단 실패보다 비싸다. 실제 차단은 아래 deviceId 목록이 확실하게 맡는다.
    const clientVersion = request.headers.get("X-App-Version");
    const minVersion = env.MIN_APP_VERSION;
    if (clientVersion && minVersion && cmpVersion(clientVersion, minVersion) < 0) {
      return textResponse(426, `업데이트가 필요합니다 (최소 ${minVersion}, 현재 ${clientVersion})`);
    }

    // ── 2) deviceId 차단. POST는 body를 읽어야 하므로 한 번만 읽어 뒤에서 재사용한다.
    const blocked = parseList(env.BLOCKED_DEVICE_IDS);
    let bodyText = null;
    if (blocked.size > 0) {
      if (request.method === "POST") bodyText = await request.text();
      const deviceId = extractDeviceId(url, bodyText);
      if (deviceId && blocked.has(deviceId)) {
        return textResponse(403, "차단된 디바이스입니다");
      }
    }

    // ── 3) 통과 → Supabase로 포워딩. 호스트만 갈아끼우고 경로·쿼리·헤더는 그대로 넘긴다.
    const target = new URL(url.pathname + url.search, `https://${SUPABASE_HOST}`);
    const headers = new Headers(request.headers);
    headers.set("host", SUPABASE_HOST);

    return fetch(new Request(target, {
      method: request.method,
      headers,
      // body를 이미 읽었으면 그 텍스트를, 아니면 원본 스트림을 그대로 전달한다.
      body: request.method === "GET" || request.method === "HEAD"
        ? undefined
        : (bodyText ?? request.body),
      redirect: "manual",
    }));
  },
};
