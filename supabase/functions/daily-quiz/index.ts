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
const PROMPT_VERSION = "quiz-v5";  // v5: 최근 N일 출제 이력 제외(동일 URL 하드필터 + 최근 주제 LLM 회피)
const RECENT_HISTORY_DAYS = 7;     // 이 일수 내 출제된 기사(URL/주제)는 재출제 회피
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

  // 0) 최근 N일 출제 이력(URL/제목) — 같은 주제 반복 출제 방지(#179). 조회 실패는 무시(빈 이력으로 진행).
  const recent = await fetchRecentHistory(db, date);

  // 1) 여러 AI 피드에서 최신 기사 제목을 모아, LLM이 화제성 높고 AI 핵심인 1건을 고른다.
  //    (RSS엔 조회수가 없어 실제 인기순 정렬은 불가 — 화제성/중요도 판단을 LLM에 위임.)
  const allArticles = await fetchAllArticles();
  if (allArticles.length === 0) throw new Error("no_articles");
  // 동일 URL은 코드로 하드 필터(가장 확실한 중복 차단). 전부 걸러지면 폴백으로 원본 유지.
  const recentUrls = new Set(recent.map((h) => h.url));
  const filtered = allArticles.filter((a) => !recentUrls.has(a.link));
  const articles = filtered.length > 0 ? filtered : allArticles;
  const article = await selectBestArticle(articles, apiKey, recent.map((h) => h.title));

  // 2) OpenAI로 그 기사 하나에서 브리핑 + 3문항 생성. 문제는 이 기사에서만 출제(출처 링크와 일치).
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

  // 저장은 "선점" 방식 — 하루 첫 캐시미스에 동시 요청이 겹치면 둘 다 생성까지는 하지만,
  // DB에는 한 버전만 남기고 모두가 그 승자 버전을 서빙해야 한다. 무조건 upsert(last-write-wins)
  // 였다면 패자 버전을 본 사용자의 이후 submit 채점이 승자의 answers와 어긋난다.
  const values = {
    quiz_date: date,
    source_title: row.source_title,
    source_url: row.source_url,
    source_name: row.source_name,
    brief: row.brief,
    questions: row.questions,
    answers: row.answers,
    model_label: MODEL_LABEL,
  };
  let persisted = false;
  if (!existing) {
    // 신규 — INSERT로 선점. PK(quiz_date) 충돌(23505)이면 경쟁자가 이미 이겼다는 뜻.
    const { error: insErr } = await db.from("daily_quiz").insert(values);
    if (!insErr) persisted = true;
    else if (insErr.code !== "23505") console.error("daily_quiz insert failed", insErr);
  } else {
    // 구 model_label 갱신 — 기대값 조건부 UPDATE. 0행이면 경쟁자가 먼저 갱신한 것.
    const { data: updRows, error: updErr } = await db
      .from("daily_quiz")
      .update(values)
      .eq("quiz_date", date)
      .eq("model_label", existing.model_label)
      .select("quiz_date");
    if (updErr) console.error("daily_quiz update failed", updErr);
    else if (updRows && updRows.length > 0) persisted = true;
  }
  if (!persisted) {
    // 레이스 패배 — 승자 버전을 다시 읽어 서빙 (submit 채점과 일치 보장).
    const { data: winner } = await db
      .from("daily_quiz")
      .select("brief, source_name, source_title, source_url, questions, answers, model_label")
      .eq("quiz_date", date)
      .maybeSingle();
    if (winner && winner.model_label === MODEL_LABEL) return winner as QuizRow;
    // 재조회까지 실패하면 방금 생성본이라도 서빙 (기존 폴백 동작 유지).
  }

  return row;
}

interface Article { title: string; link: string; summary: string; source: string; }
interface HistoryEntry { url: string; title: string; }

// 최근 N일 출제 이력(오늘 제외) — 반복 주제 회피용(#179). URL은 하드필터, 제목은 LLM 회피 힌트.
// 조회 실패는 치명적 아님 → 빈 배열 반환(이력 없이 진행, 퀴즈 생성이 막히지 않게).
async function fetchRecentHistory(db: ReturnType<typeof getDb>, today: string): Promise<HistoryEntry[]> {
  const since = new Date(`${today}T00:00:00Z`);
  since.setUTCDate(since.getUTCDate() - RECENT_HISTORY_DAYS);
  const sinceDate = since.toISOString().slice(0, 10);   // YYYY-MM-DD
  const { data, error } = await db
    .from("daily_quiz")
    .select("source_url, source_title")
    .gte("quiz_date", sinceDate)
    .lt("quiz_date", today)   // 오늘(생성 중)은 제외
    .order("quiz_date", { ascending: false });
  if (error) { console.error("fetchRecentHistory failed", error); return []; }
  return (data ?? [])
    .map((r) => ({ url: (r.source_url ?? "") as string, title: (r.source_title ?? "") as string }))
    .filter((h) => h.url || h.title);
}

async function fetchAllArticles(): Promise<Article[]> {
  // 모든 AI 피드를 병렬 fetch → 각 최신 5건을 후보 풀로 합친다 (LLM 선별 입력).
  const results = await Promise.all(FEEDS.map(async (feed): Promise<Article[]> => {
    try {
      const resp = await fetch(feed.url, {
        headers: { "User-Agent": "AIUsage-DailyQuiz/1.0", "Accept": "application/rss+xml, application/xml, text/xml" },
        signal: AbortSignal.timeout(8000),
      });
      if (!resp.ok) return [];
      const xml = await resp.text();
      return parseFeed(xml).slice(0, 5).map((it) => ({ ...it, source: feed.name }));
    } catch (e) {
      console.error(`feed fetch failed: ${feed.url}`, e);
      return [];
    }
  }));
  return results.flat();
}

// 후보 제목 목록을 LLM에 주고 퀴즈 소재로 가장 좋은 AI 기사 1건을 고르게 한다.
// RSS엔 조회수가 없어 실제 인기순 정렬이 불가하므로, 화제성·중요도·AI 관련성 판단을 LLM에 맡긴다.
// recentTitles: 최근 출제된 제목 — 같은 주제/사건은 URL이 달라도(후속 보도) 피하게 한다(#179).
// 실패(네트워크/파싱)하면 첫 기사로 폴백해 퀴즈 생성이 막히지 않게 한다.
async function selectBestArticle(articles: Article[], apiKey: string, recentTitles: string[] = []): Promise<Article> {
  if (articles.length <= 1) return articles[0];
  const list = articles.map((a, i) => `${i}. [${a.source}] ${a.title}`).join("\n");
  const recentBlock = recentTitles.length > 0
    ? " 최근 며칠간 아래 주제가 이미 출제됐습니다 — 같은 사건/주제는(제목이 달라도) 피하고 새로운 소재를 고르세요:\n"
      + recentTitles.map((t) => `- ${t}`).join("\n")
    : "";
  const systemPrompt = [
    "당신은 개발자용 'AI 뉴스 퀴즈'의 기사 선별자입니다.",
    "아래는 여러 매체의 최신 기사 제목 목록입니다 (형식: 번호. [매체] 제목).",
    "이 중 퀴즈 소재로 가장 좋은 기사 하나의 번호를 고르세요.",
    "기준: (1) AI/머신러닝이 핵심 주제일 것, (2) 화제성·중요도가 높을 것(단순 펀딩·인사·홍보성은 제외), (3) 사실관계가 분명해 문제를 낼 수 있을 것, (4) 최근 출제 주제와 겹치지 않는 새로운 소재일 것.",
    recentBlock,
    "출력은 반드시 JSON: {\"index\": 정수}.",
  ].join(" ");
  try {
    const resp = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: list },
        ],
        temperature: 0.2,
        max_tokens: 20,
        response_format: { type: "json_object" },
      }),
      signal: AbortSignal.timeout(20000),
    });
    if (!resp.ok) throw new Error(`select HTTP ${resp.status}`);
    const data = await resp.json();
    const idx = Number(JSON.parse(data?.choices?.[0]?.message?.content).index);
    if (Number.isInteger(idx) && idx >= 0 && idx < articles.length) return articles[idx];
    throw new Error(`bad index: ${idx}`);
  } catch (e) {
    console.error("selectBestArticle failed — fallback to first", e);
    return articles[0];
  }
}

function parseFeed(xml: string): { title: string; link: string; summary: string }[] {
  const out: { title: string; link: string; summary: string }[] = [];
  const blocks = xml.matchAll(/<(item|entry)\b[^>]*>([\s\S]*?)<\/\1>/g);
  for (const b of blocks) {
    const body = b[2];
    const title = cleanText(extractTag(body, "title"));
    if (!title) continue;
    const link = extractLink(body);
    // content:encoded(전문/긴 발췌)를 최우선 — description만으론 짧아 문제 근거가 부족했다.
    const summary = cleanText(
      extractTag(body, "content:encoded") || extractTag(body, "description") ||
      extractTag(body, "summary") || extractTag(body, "content"),
    ).slice(0, 2000);
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
  const articleText = `제목: ${article.title}\n\n본문: ${article.summary}`;

  const systemPrompt = [
    "당신은 최신 AI 뉴스 기사 하나를 개발자용 퀴즈로 만드는 출제자입니다.",
    "입력으로 AI 관련 뉴스 기사 한 건의 제목과 본문이 주어집니다.",
    `먼저 이 기사를 한국어 3-4문장으로 충실히 요약한 brief를 쓰고, 그 brief에 담긴 사실만으로 ${NUM_QUESTIONS}개의 4지선다 문제를 만드세요.`,
    "가장 중요한 규칙: 모든 문제와 정답은 당신이 쓴 brief 문장 안에서 반드시 확인 가능해야 합니다. brief만 읽은 사람이 답을 고를 수 없는 문제(brief에 안 나온 날짜·행사명·수치·인물·장소 등)는 절대 출제하지 마세요.",
    "기사 본문에 없는 외부 지식이나 추측으로 문제·정답을 만들지 마세요. 근거가 불확실한 소재는 아예 문제로 내지 마세요.",
    "각 문제를 만들 때 '이 정답의 근거가 brief 어느 문장에 있는가'를 스스로 확인하고, 근거가 없으면 그 문제를 버리고 다른 소재로 바꾸세요.",
    "각 문제는 보기 4개 중 정답 1개. 오답도 그럴듯하되 brief를 근거로 명확히 배제 가능해야 합니다.",
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
