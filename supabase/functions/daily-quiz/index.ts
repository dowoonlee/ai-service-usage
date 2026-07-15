// POST /daily-quiz
// 오늘의 AI 뉴스 퀴즈 — usage 독립 코인 수급. fortune 함수를 템플릿으로 한다.
//
// 보안/비용 모델 (fortune과 동일 골격):
//   * OpenAI 키는 `Deno.env.get("OPENAI_API_KEY")` — 앱 바이너리에 노출 없음.
//   * 전역 1세트/일: quiz_date(KST) PK 캐시. 하루 첫 요청만 RSS fetch + OpenAI 호출, 이후는 캐시.
//   * 정답 보호: `answers`(정답 index)는 DB에만. 클라엔 문제·보기만 내려가고 채점도 서버에서 한다.
//   * 지급: 채점 결과 → reward_grants(currency='coin', grant_key='quiz-<date>') INSERT.
//     UNIQUE(device_id, grant_key)가 하루 1회 이중지급을 막고, 클라는 기존 leaderboard
//     pendingGrant → claim-reward 경로로 자동 수령(신규 지급 코드 불필요).
//
// HMAC: fortune과 동일하게 flat payload canonicalize → device hmac_key_b64로 verify.
//
// action:
//   "today"  — 오늘 퀴즈(문제만) + 내 제출 상태 반환. 캐시 미스면 생성.
//   "submit" — 답안 채점 + reward_grants 지급. 이미 제출했으면 기존 결과 반환(재지급 없음).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface QuizPayload {
  action: string;        // "today" | "submit"
  date: string;          // "YYYY-MM-DD" (KST) — 서버가 오늘로 강제 검증
  deviceId: string;
  answersJson?: string;  // submit 전용: "[0,2,1]" (선택 index 배열)
  ts: number;
}

interface QuizRequest {
  payload: QuizPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const OPENAI_MODEL = "gpt-4o-mini";
const PROMPT_VERSION = "quiz-v2";  // v2: 5건 종합 → 기사 1건 기반 출제로 변경
const MODEL_LABEL = `${OPENAI_MODEL}:${PROMPT_VERSION}`;
const NUM_QUESTIONS = 3;
const NUM_CHOICES = 4;

// RSS 소스 — 모두 실제 최신 기사(신선도 보장). item(RSS2.0)/entry(Atom) 범용 파싱.
// 날짜 seed로 시작 인덱스를 돌려 매일 다른 소스를 우선한다. 첫 성공 피드를 사용.
const FEEDS: { name: string; url: string }[] = [
  { name: "TechCrunch AI", url: "https://techcrunch.com/category/artificial-intelligence/feed/" },
  { name: "VentureBeat AI", url: "https://venturebeat.com/category/ai/feed/" },
  { name: "The Verge AI", url: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml" },
  { name: "MIT Technology Review AI", url: "https://www.technologyreview.com/topic/artificial-intelligence/feed" },
];

// 맞은 개수 → 지급 코인 (누진). 0개는 0.
function rewardFor(correct: number): number {
  switch (correct) {
    case 1: return 100;
    case 2: return 300;
    case 3: return 1000;
    default: return 0;
  }
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: QuizRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (p.action !== "today" && p.action !== "submit") return errorResponse(400, "invalid_action");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.date !== "string" || !DATE_RE.test(p.date)) return errorResponse(400, "invalid_date");
  const today = todayKstDateString();
  if (p.date !== today) return errorResponse(400, "date_must_be_today_kst");
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_payload_types");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  // submit이면 answersJson 필수 + 형식 검증.
  let submittedAnswers: number[] | null = null;
  if (p.action === "submit") {
    if (typeof p.answersJson !== "string" || p.answersJson.length > 200) {
      return errorResponse(400, "invalid_answers");
    }
    try {
      const arr = JSON.parse(p.answersJson);
      if (!Array.isArray(arr) || arr.length !== NUM_QUESTIONS) throw new Error("shape");
      submittedAnswers = arr.map((x) => {
        const n = Number(x);
        if (!Number.isInteger(n) || n < 0 || n >= NUM_CHOICES) throw new Error("range");
        return n;
      });
    } catch {
      return errorResponse(400, "invalid_answers");
    }
  }

  const db = getDb();

  // HMAC 검증 — device의 hmac_key_b64로. (fortune/submit과 동일.)
  const { data: user, error: userErr } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", p.deviceId)
    .single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const hmacPayload: Record<string, unknown> = p.action === "submit"
    ? { action: p.action, answersJson: p.answersJson, date: p.date, deviceId: p.deviceId, ts: p.ts }
    : { action: p.action, date: p.date, deviceId: p.deviceId, ts: p.ts };
  const ok = await verifyHmac(hmacPayload, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 오늘 퀴즈 확보 (캐시 hit 또는 생성).
  let quiz: QuizRow;
  try {
    quiz = await ensureTodayQuiz(db, today);
  } catch (e) {
    console.error("ensureTodayQuiz failed", e);
    const msg = e instanceof Error ? e.message : "unknown";
    return errorResponse(502, `quiz_unavailable: ${msg.slice(0, 160)}`);
  }

  // ---- action: today ----
  if (p.action === "today") {
    const sub = await fetchSubmission(db, p.deviceId, today);
    return jsonResponse({
      date: today,
      brief: quiz.brief,
      sourceName: quiz.source_name,
      sourceTitle: quiz.source_title,
      sourceUrl: quiz.source_url,
      questions: quiz.questions,             // 정답 제외
      // 이미 제출했으면 정답(correct)도 함께 — 클라가 결과/해설을 표시. 미제출이면 null.
      submission: sub ? { ...sub, correct: quiz.answers } : null,
    });
  }

  // ---- action: submit ----
  // 이미 제출했으면 재채점/재지급 없이 기존 결과 반환.
  const existing = await fetchSubmission(db, p.deviceId, today);
  if (existing) {
    return jsonResponse({
      alreadySubmitted: true,
      correctCount: existing.correctCount,
      rewardCoins: existing.rewardCoins,
      correct: quiz.answers,                  // 제출 후엔 정답 공개
      submitted: existing.answers,
    });
  }

  const answerKey = quiz.answers;
  let correctCount = 0;
  for (let i = 0; i < NUM_QUESTIONS; i++) {
    if (submittedAnswers![i] === answerKey[i]) correctCount++;
  }
  const reward = rewardFor(correctCount);

  // 제출 기록 저장 — PK(device_id, quiz_date)가 하루 1회 dedup. race로 충돌하면 기존 결과 반환.
  const { error: subErr } = await db.from("daily_quiz_submissions").insert({
    device_id: p.deviceId,
    quiz_date: today,
    correct_count: correctCount,
    reward_coins: reward,
    submitted: submittedAnswers,
  });
  if (subErr) {
    // 동시 제출 race — 기존 행을 읽어 반환(재지급 없음).
    const again = await fetchSubmission(db, p.deviceId, today);
    if (again) {
      return jsonResponse({
        alreadySubmitted: true,
        correctCount: again.correctCount,
        rewardCoins: again.rewardCoins,
        correct: quiz.answers,
        submitted: again.answers,
      });
    }
    console.error("submission insert failed", subErr);
    return errorResponse(500, "submit_failed");
  }

  // 코인 지급 — reward_grants에 미수령 행 INSERT. 클라가 leaderboard pendingGrant로 자동 수령.
  if (reward > 0) {
    const { error: grantErr } = await db.from("reward_grants").insert({
      device_id: p.deviceId,
      currency: "coin",
      amount: reward,
      reason: `daily-quiz ${today} ${correctCount}/${NUM_QUESTIONS}`,
      grant_key: `quiz-${today}`,
    });
    if (grantErr) {
      // UNIQUE(device_id, grant_key) 충돌 = 이미 지급됨(방어적). 로깅만.
      console.error("reward_grants insert (likely dup, ignored)", grantErr);
    }
  }

  return jsonResponse({
    alreadySubmitted: false,
    correctCount,
    rewardCoins: reward,
    correct: quiz.answers,
    submitted: submittedAnswers,
  });
});

// ============================================================================
// 퀴즈 확보 (캐시 or 생성)
// ============================================================================

interface QuizRow {
  brief: string;
  source_name: string;
  source_title: string;
  source_url: string;
  questions: { question: string; choices: string[] }[];
  answers: number[];
}

async function ensureTodayQuiz(db: ReturnType<typeof getDb>, date: string): Promise<QuizRow> {
  const { data: existing, error: selErr } = await db
    .from("daily_quiz")
    .select("brief, source_name, source_title, source_url, questions, answers, model_label")
    .eq("quiz_date", date)
    .maybeSingle();
  if (selErr) throw new Error(`select: ${selErr.message}`);
  if (existing && existing.model_label === MODEL_LABEL) {
    return existing as QuizRow;
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new Error("openai_not_configured");

  // 1) RSS에서 후보 확보 → 최신 1건 선택. 문제는 이 기사 하나에서만 출제(출처 링크와 정확히 일치).
  const articles = await fetchArticles(date);
  if (articles.length === 0) throw new Error("no_articles");
  const article = articles[0];

  // 2) OpenAI로 그 기사 하나에서 브리핑 + 3문항 생성.
  const generated = await generateQuiz(article, apiKey);

  // 3) 정답 분리 저장. questions(클라용)엔 answer 제거.
  const questions = generated.questions.map((q) => ({ question: q.question, choices: q.choices }));
  const answers = generated.questions.map((q) => q.answer);

  const row: QuizRow & { model_label: string } = {
    brief: generated.brief,
    source_name: article.source,
    source_title: article.title,
    source_url: article.link,
    questions,
    answers,
    model_label: MODEL_LABEL,
  };

  const { error: insErr } = await db.from("daily_quiz").upsert(
    {
      quiz_date: date,
      source_title: row.source_title,
      source_url: row.source_url,
      source_name: row.source_name,
      brief: row.brief,
      questions: row.questions,
      answers: row.answers,
      model_label: MODEL_LABEL,
    },
    { onConflict: "quiz_date" },
  );
  if (insErr) console.error("daily_quiz upsert failed (serving anyway)", insErr);

  return row;
}

interface Article { title: string; link: string; summary: string; source: string; }

async function fetchArticles(date: string): Promise<Article[]> {
  // 날짜 문자열 해시로 시작 인덱스 → 매일 다른 소스 우선.
  const seed = [...date].reduce((a, c) => a + c.charCodeAt(0), 0);
  const order = FEEDS.map((_, i) => FEEDS[(seed + i) % FEEDS.length]);
  for (const feed of order) {
    try {
      const resp = await fetch(feed.url, {
        headers: { "User-Agent": "AIUsage-DailyQuiz/1.0", "Accept": "application/rss+xml, application/xml, text/xml" },
        signal: AbortSignal.timeout(8000),
      });
      if (!resp.ok) continue;
      const xml = await resp.text();
      const items = parseFeed(xml).slice(0, 5).map((it) => ({ ...it, source: feed.name }));
      if (items.length >= 2) return items;
    } catch (e) {
      console.error(`feed fetch failed: ${feed.url}`, e);
    }
  }
  return [];
}

function parseFeed(xml: string): { title: string; link: string; summary: string }[] {
  const out: { title: string; link: string; summary: string }[] = [];
  const blocks = xml.matchAll(/<(item|entry)\b[^>]*>([\s\S]*?)<\/\1>/g);
  for (const b of blocks) {
    const body = b[2];
    const title = cleanText(extractTag(body, "title"));
    if (!title) continue;
    const link = extractLink(body);
    const summary = cleanText(
      extractTag(body, "description") || extractTag(body, "summary") || extractTag(body, "content"),
    ).slice(0, 600);
    out.push({ title, link, summary });
  }
  return out;
}

function extractTag(body: string, tag: string): string {
  const m = body.match(new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i"));
  return m ? m[1] : "";
}

// RSS: <link>URL</link>. Atom: <link href="URL"/>.
function extractLink(body: string): string {
  const atom = body.match(/<link\b[^>]*\bhref=["']([^"']+)["'][^>]*\/?>/i);
  if (atom) return atom[1];
  const rss = body.match(/<link\b[^>]*>([\s\S]*?)<\/link>/i);
  return rss ? cleanText(rss[1]) : "";
}

function cleanText(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")  // CDATA 벗기기
    .replace(/<[^>]+>/g, " ")                        // HTML 태그 제거
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// ============================================================================
// OpenAI 퀴즈 생성
// ============================================================================

interface GeneratedQuestion { question: string; choices: string[]; answer: number; }
interface GeneratedQuiz { brief: string; questions: GeneratedQuestion[]; }

async function generateQuiz(article: Article, apiKey: string): Promise<GeneratedQuiz> {
  const articleText = `제목: ${article.title}\n\n요약: ${article.summary}`;

  const systemPrompt = [
    "당신은 최신 AI 뉴스 기사 하나를 개발자용 퀴즈로 만드는 출제자입니다.",
    "입력으로 AI 관련 뉴스 기사 한 건의 제목과 요약이 주어집니다.",
    `이 기사 하나를 바탕으로 (1) 기사 핵심을 한국어 2-3문장으로 요약한 brief, (2) ${NUM_QUESTIONS}개의 4지선다 객관식 문제를 만드세요.`,
    "문제는 이 기사 내용에 근거해야 하며, 기사 요약만 읽어도 풀 수 있어야 합니다(기사에 없는 지엽적 사실 금지).",
    "각 문제는 보기 4개 중 정답 1개. 오답도 그럴듯해야 합니다.",
    "정답 위치(index)는 문제마다 고르게 섞으세요.",
    "출력은 반드시 JSON: {\"brief\": string, \"questions\": [{\"question\": string, \"choices\": [4개 string], \"answer\": 0-3 정수}]}.",
    "모든 텍스트는 한국어. 이모지 없이.",
  ].join(" ");

  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: articleText },
      ],
      temperature: 0.4,
      max_tokens: 1200,
      response_format: { type: "json_object" },
    }),
    signal: AbortSignal.timeout(30000),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`openai HTTP ${resp.status}: ${text.slice(0, 160)}`);
  }
  const data = await resp.json();
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new Error("openai_empty");

  let parsed: GeneratedQuiz;
  try {
    parsed = JSON.parse(content);
  } catch {
    throw new Error("openai_bad_json");
  }
  validateQuiz(parsed);
  return parsed;
}

function validateQuiz(q: GeneratedQuiz): void {
  if (typeof q.brief !== "string" || q.brief.trim().length === 0) throw new Error("bad_brief");
  if (!Array.isArray(q.questions) || q.questions.length !== NUM_QUESTIONS) throw new Error("bad_questions_len");
  for (const item of q.questions) {
    if (typeof item.question !== "string" || item.question.trim().length === 0) throw new Error("bad_question");
    if (!Array.isArray(item.choices) || item.choices.length !== NUM_CHOICES) throw new Error("bad_choices");
    if (item.choices.some((c) => typeof c !== "string" || c.trim().length === 0)) throw new Error("bad_choice");
    if (!Number.isInteger(item.answer) || item.answer < 0 || item.answer >= NUM_CHOICES) throw new Error("bad_answer");
  }
}

// ============================================================================
// 제출 조회
// ============================================================================

interface Submission { correctCount: number; rewardCoins: number; answers: number[]; }

async function fetchSubmission(
  db: ReturnType<typeof getDb>,
  deviceId: string,
  date: string,
): Promise<Submission | null> {
  const { data, error } = await db
    .from("daily_quiz_submissions")
    .select("correct_count, reward_coins, submitted")
    .eq("device_id", deviceId)
    .eq("quiz_date", date)
    .maybeSingle();
  if (error || !data) return null;
  return {
    correctCount: data.correct_count as number,
    rewardCoins: data.reward_coins as number,
    answers: (data.submitted as number[]) ?? [],
  };
}

// KST 오늘 날짜 문자열.
function todayKstDateString(): string {
  const kst = new Date(Date.now() + 9 * 3600 * 1000);
  return kst.toISOString().slice(0, 10);
}
