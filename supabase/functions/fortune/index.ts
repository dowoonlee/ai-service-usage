// POST /fortune
// 오늘의 개발 운세 — 단일 호출로 fetch + (캐시 미스 시) OpenAI 호출 + save 모두 처리.
//
// 보안 모델:
//   * OpenAI 키는 `Deno.env.get("OPENAI_API_KEY")` 로 — 앱 바이너리에 절대 노출되지 않음.
//     ad-hoc 서명 데스크톱 앱은 strings/lldb 로 키 추출이 너무 쉬워 클라이언트 보관 불가.
//   * 명리학 사주 계산은 클라이언트가 결정론적으로 수행 (외부 의존 0) → 서버는 그 결과를
//     OpenAI 프롬프트에 전달만 함. 서버에서 사주 재계산하지 않음.
//   * Rate limit 은 KST 오늘 날짜 + (device_id, fortune_date) 캐시가 자연 제약.
//     같은 날 두 번째 호출은 같은 프롬프트 버전이면 OpenAI 비호출.
//
// HMAC: payload 전체 canonicalize → device 의 hmac_key_b64 로 verify. submit/post 와 동일.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

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
// 서버측 모델 고정 — 사용자가 비용 의식할 필요 없게 가장 저렴한 모델로.
const OPENAI_MODEL = "gpt-4o-mini";
const PROMPT_VERSION = "fortune-v2";
const MODEL_LABEL = `${OPENAI_MODEL}:${PROMPT_VERSION}`;

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

  // 3) OpenAI 호출
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    console.error("OPENAI_API_KEY env missing");
    return errorResponse(503, "openai_not_configured");
  }

  let fortuneText: string;
  try {
    fortuneText = await callOpenAI(saju, daily, OPENAI_MODEL, apiKey);
  } catch (e) {
    console.error("OpenAI call failed", e);
    const msg = e instanceof Error ? e.message : "unknown";
    return errorResponse(502, `openai_error: ${msg.slice(0, 200)}`);
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

async function callOpenAI(
  saju: Record<string, unknown>,
  daily: Record<string, unknown>,
  model: string,
  apiKey: string,
): Promise<string> {
  const style = styleGuideFor(saju, daily);
  const systemPrompt = [
    "당신은 사주 명리학 변수를 개발자의 하루로 재해석하는 운세 작가입니다.",
    "한국어로 200-300자, 3문장. 캐주얼하지만 매번 문장 구조와 비유가 달라야 합니다.",
    "첫 문장은 오늘의 개발 장면을 구체적으로 열고, 둘째 문장은 리스크나 흐름을 짚고, 셋째 문장은 바로 실행할 작은 행동을 제안하세요.",
    "코드 리뷰/배포/디버깅/페어 프로그래밍/리팩토링/문서화/테스트/자동화 중 입력된 테마에 맞춰 풀어내세요.",
    "예언/단정형(\"반드시 ~한다\", \"~할 것이다\")은 피하고 권유형으로 쓰세요.",
    "사주 변수 이름을 나열하지 말고 해석된 결과만 자연스러운 문장으로 쓰세요.",
    "\"좋은 날입니다\", \"흐름이 좋습니다\", \"차분히\", \"에너지가\" 같은 뻔한 표현은 피하세요.",
    "이모지 없이. 사용자의 출생시는 GitHub 가입 시각 근사값이므로 시주는 참고 정도로만 활용하세요.",
  ].join(" ");

  const userPrompt = buildUserPrompt(saju, daily, style);

  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      temperature: 0.85,
      presence_penalty: 0.35,
      frequency_penalty: 0.35,
      max_tokens: 400,
    }),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`HTTP ${resp.status}: ${text.slice(0, 200)}`);
  }
  const data = await resp.json();
  const text = data?.choices?.[0]?.message?.content;
  if (typeof text !== "string" || text.trim().length === 0) {
    throw new Error("empty_response");
  }
  return text.trim();
}

function buildUserPrompt(
  saju: Record<string, unknown>,
  daily: Record<string, unknown>,
  style: FortuneStyleGuide,
): string {
  const year = pillarName(saju.year);
  const month = pillarName(saju.month);
  const day = pillarName(saju.day);
  const hour = pillarName(saju.hour);
  const dayStem = stemName(saju.day);
  const elements = parseElementCounts(saju.fiveElementCounts);
  const todayPillar = pillarName(daily.today);
  const relation = String(daily.relation ?? "?");
  return [
    "다음은 명리학적으로 계산된 변수입니다. 이를 종합해 오늘의 개발 운세를 작성해주세요.",
    "",
    `- 본인 사주팔자(년/월/일/시주): ${year} · ${month} · ${day} · ${hour}`,
    `- 일간(본인 핵심 오행): ${dayStem}`,
    `- 오행 분포: ${elementsLine(elements)}`,
    `- 강한 오행/부족한 오행: ${elementExtremesLine(elements)}`,
    `- 오늘 일진: ${todayPillar}`,
    `- 일간 vs 오늘 천간 관계: ${relation}`,
    `- 오늘의 개발 테마: ${style.theme}`,
    `- 권장 장면: ${style.scene}`,
    `- 피해야 할 클리셰: ${style.avoid}`,
  ].join("\n");
}

// Swift SajuPillar Codable 자동 합성 결과: { stem: Int, branch: Int } (raw value).
// 서버에선 다시 한글로 풀어 프롬프트에 박는다.
const STEMS_KO = ["갑","을","병","정","무","기","경","신","임","계"];
const BRANCHES_KO = ["자","축","인","묘","진","사","오","미","신","유","술","해"];

function pillarName(p: unknown): string {
  if (!p || typeof p !== "object") return "?";
  const obj = p as Record<string, unknown>;
  const stemIdx = typeof obj.stem === "number" ? obj.stem : -1;
  const branchIdx = typeof obj.branch === "number" ? obj.branch : -1;
  return `${STEMS_KO[stemIdx] ?? "?"}${BRANCHES_KO[branchIdx] ?? "?"}`;
}

function stemName(p: unknown): string {
  if (!p || typeof p !== "object") return "?";
  const obj = p as Record<string, unknown>;
  const stemIdx = typeof obj.stem === "number" ? obj.stem : -1;
  return STEMS_KO[stemIdx] ?? "?";
}

const ELEMENT_ORDER = ["목", "화", "토", "금", "수"];

function parseElementCounts(counts: unknown): Record<string, number> {
  const parsed: Record<string, number> = Object.fromEntries(ELEMENT_ORDER.map((k) => [k, 0]));
  if (!counts) return parsed;

  if (Array.isArray(counts)) {
    // Swift JSONEncoder encodes Dictionary<FiveElement, Int> as ["목", 2, "화", 1, ...],
    // not as an object, because FiveElement is a Codable enum key.
    for (let i = 0; i + 1 < counts.length; i += 2) {
      const k = counts[i];
      const v = counts[i + 1];
      if (typeof k === "string" && ELEMENT_ORDER.includes(k) && typeof v === "number") {
        parsed[k] = v;
      }
    }
    return parsed;
  }

  if (typeof counts === "object") {
    const obj = counts as Record<string, unknown>;
    for (const k of ELEMENT_ORDER) {
      const v = obj[k];
      if (typeof v === "number") parsed[k] = v;
    }
  }
  return parsed;
}

function elementsLine(counts: Record<string, number>): string {
  return ELEMENT_ORDER.map((k) => `${k} ${counts[k] ?? 0}`).join(" · ");
}

function elementExtremesLine(counts: Record<string, number>): string {
  const entries = ELEMENT_ORDER.map((k) => [k, counts[k] ?? 0] as const);
  const max = Math.max(...entries.map(([, v]) => v));
  const min = Math.min(...entries.map(([, v]) => v));
  const strong = entries.filter(([, v]) => v === max).map(([k]) => k).join("/");
  const weak = entries.filter(([, v]) => v === min).map(([k]) => k).join("/");
  return `강함 ${strong}(${max}) · 부족 ${weak}(${min})`;
}

interface FortuneStyleGuide {
  theme: string;
  scene: string;
  avoid: string;
}

function styleGuideFor(saju: Record<string, unknown>, daily: Record<string, unknown>): FortuneStyleGuide {
  const themes = [
    "디버깅과 원인 추적",
    "작은 리팩토링과 이름 정리",
    "코드 리뷰와 피드백 수용",
    "배포 전 체크리스트",
    "테스트 보강과 회귀 방지",
    "문서화와 인수인계",
    "자동화 스크립트 정리",
    "페어 프로그래밍과 질문 잘하기",
  ];
  const scenes = [
    "오래 묵은 TODO 하나를 실제 작업 단위로 쪼개는 장면",
    "실패 로그에서 반복되는 패턴을 찾아내는 장면",
    "리뷰 코멘트를 방어하지 않고 설계 의도로 번역하는 장면",
    "배포 버튼을 누르기 전 롤백 경로를 확인하는 장면",
    "깨지기 쉬운 테스트 이름을 더 명확하게 바꾸는 장면",
    "동료가 바로 따라올 수 있게 맥락을 짧게 남기는 장면",
    "손으로 하던 확인을 작은 명령 하나로 고정하는 장면",
    "막힌 지점을 숨기지 않고 일찍 공유하는 장면",
  ];
  const avoids = [
    "막연한 행운/기회 표현",
    "무조건 성공한다는 단정",
    "사주 용어 나열",
    "좋은 날/나쁜 날 이분법",
    "에너지와 흐름만 반복하는 문장",
    "과장된 위기감",
    "추상적인 마음가짐 조언",
    "똑같은 첫 문장 패턴",
  ];
  const seed = stableHash(JSON.stringify(saju) + "|" + JSON.stringify(daily));
  return {
    theme: themes[seed % themes.length],
    scene: scenes[Math.floor(seed / themes.length) % scenes.length],
    avoid: avoids[Math.floor(seed / themes.length / scenes.length) % avoids.length],
  };
}

function stableHash(input: string): number {
  let h = 2166136261;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
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
