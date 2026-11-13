// Claude Messages API 호출 + 운세 프롬프트.
//
// fortune/index.ts(HTTP·HMAC·DB)와 분리한 이유: 서버 없이 `scripts/fortune_smoke.ts`가 이 모듈만
// import 해서 키 유효성과 문장 품질을 바로 확인할 수 있게 하기 위함. index.ts는 이 파일의
// `generateFortune`만 쓴다.
//
// 규격 메모 (anthropic-version 2026-10-21):
//   * `temperature`/`top_p` 같은 샘플링 파라미터는 이 버전에서 400이라 보내지 않는다 — 다양성은
//     프롬프트(테마/장면/금지 클리셰 시드)로 유도한다. OpenAI 시절의 penalty 설정은 대응물이 없다.
//   * Opus 5.5는 thinking이 항상 켜져 있고 `output_config.effort`로만 깊이를 조절한다. 3문장 운세는
//     `low`면 충분하고 지연·비용이 가장 작다.
//   * 안전 분류기가 거절하면 HTTP 200 + `stop_reason: "refusal"`로 온다. `fallbacks: "default"`를
//     켜 두면 서버가 거절 범주에 맞는 다른 모델로 같은 요청을 재실행한다(그래도 거절이면 refusal).
//   * workspace에 묶이지 않은 조직 키(Console에서 workspace 없이 만든 키)는 요청마다
//     `anthropic-workspace-id: wrkspc_...` 헤더로 실행 workspace를 지정해야 한다(없으면 400
//     "This API key is not scoped to a workspace"). workspace 키는 이 헤더가 필요 없다.
//   * SDK(npm:@anthropic-ai/sdk) 대신 fetch를 쓰는 건 기존 함수들(OpenAI·RSS·GitHub)과 같은 관례이고
//     Edge 번들에 의존성을 더하지 않기 위해서다. 응답 본문은 로그에 남기지 않는다(상태·토큰 수만).

export const CLAUDE_MODEL = "claude-opus-5-5";
export const PROMPT_VERSION = "fortune-v4";
/** daily_fortunes.model — 같은 날 캐시 판정 키. 모델/프롬프트가 바뀌면 그날 한 번 재생성된다. */
export const MODEL_LABEL = `${CLAUDE_MODEL}:${PROMPT_VERSION}`;

const ANTHROPIC_VERSION = "2026-10-21";
const FALLBACK_BETA = "server-side-fallback-2026-07-01";
const DEFAULT_BASE_URL = "https://api.anthropic.com";
// 한국어 300자 ≈ 600 토큰. 넉넉히 잡아 max_tokens 절단을 피한다(비용은 실제 출력량만 과금).
const MAX_TOKENS = 1024;

export interface FortuneGeneration {
  text: string;
  /** 실제 응답한 모델 — fallback이 돌면 요청 모델과 다를 수 있다. */
  model: string;
  stopReason: string;
  inputTokens: number;
  outputTokens: number;
}

export interface GenerateOptions {
  /** 사내 게이트웨이 등 — 기본 api.anthropic.com. `ANTHROPIC_BASE_URL`로 주입. */
  baseUrl?: string;
  /** 조직 키일 때 실행 workspace(`wrkspc_...`). `ANTHROPIC_WORKSPACE_ID`로 주입. workspace 키면 생략. */
  workspaceId?: string;
  /** 이 사용자의 최근 운세 본문(최신순). 구조·소재·어미 반복을 피하게 하는 유일한 수단 — 모델은 어제 쓴 글을 모른다. */
  recentTexts?: string[];
  /** 시기 힌트(새해 첫 사흘 등, `_shared/season.ts`의 `fortuneSeasonHint`). 없으면 평소 프롬프트 그대로. */
  seasonHint?: string | null;
}

export function buildSystemPrompt(): string {
  return [
    "당신은 사주 명리학 변수를 개발자의 하루로 재해석하는 운세 작가입니다.",
    "입력의 '오늘의 성격'과 '오행 해석'이 글의 내용을 정합니다. 그 해석에서 출발해 오늘 하루에만 해당하는 이야기를 쓰세요.",
    "입력의 '형식'을 그대로 따르세요. 형식이 문장 수와 전개 순서를 정합니다. 따로 지정이 없으면 한국어 150-300자입니다.",
    "'소재 힌트'는 참고일 뿐입니다. 오늘의 성격과 어울리지 않으면 다른 개발 소재를 고르세요.",
    "'최근 운세'가 주어지면 그 글들과 첫 어절, 문장 구조, 소재, 비유, 마무리 어미가 겹치지 않게 쓰세요. 같은 소재를 다시 꺼내지 마세요.",
    "예언/단정형(\"반드시 ~한다\", \"~할 것이다\")은 피하고 권유형으로 쓰되, 문장마다 같은 어미(\"~해보세요\", \"~좋겠어요\")를 반복하지 마세요.",
    "사주 변수 이름(오행, 일간, 상생 등)을 본문에 쓰지 말고 해석된 결과만 자연스러운 문장으로 쓰세요.",
    "\"좋은 날입니다\", \"흐름이 좋습니다\", \"차분히\", \"에너지가\", \"~하기에 잘 맞는 하루\" 같은 뻔한 표현은 피하세요.",
    "이모지 없이. 사용자의 출생시는 GitHub 가입 시각 근사값이므로 시주는 참고 정도로만 활용하세요.",
    "응답은 운세 본문만 출력하세요. 제목, 인사말, 따옴표, 설명, 마크다운을 붙이지 마세요.",
  ].join(" ");
}

export async function generateFortune(
  saju: Record<string, unknown>,
  daily: Record<string, unknown>,
  apiKey: string,
  opts: GenerateOptions = {},
): Promise<FortuneGeneration> {
  const style = styleGuideFor(saju, daily);
  const userPrompt = buildUserPrompt(saju, daily, style, opts.recentTexts ?? [], opts.seasonHint ?? null);
  const base = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");

  const headers: Record<string, string> = {
    "x-api-key": apiKey,
    "anthropic-version": ANTHROPIC_VERSION,
    "anthropic-beta": FALLBACK_BETA,
    "content-type": "application/json",
  };
  if (opts.workspaceId) headers["anthropic-workspace-id"] = opts.workspaceId;

  const resp = await fetch(`${base}/v1/messages`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      model: CLAUDE_MODEL,
      max_tokens: MAX_TOKENS,
      system: buildSystemPrompt(),
      messages: [{ role: "user", content: userPrompt }],
      output_config: { effort: "low" },
      fallbacks: "default",
    }),
  });
  if (!resp.ok) {
    const text = await resp.text();
    // 에러 본문은 키/식별자를 담지 않지만 길이는 자른다.
    throw new Error(`HTTP ${resp.status}: ${text.slice(0, 200)}`);
  }
  const data = await resp.json();
  const stopReason = typeof data?.stop_reason === "string" ? data.stop_reason : "unknown";
  if (stopReason === "refusal") {
    const category = data?.stop_details?.category ?? "unspecified";
    throw new Error(`refusal:${category}`);
  }
  const blocks: unknown[] = Array.isArray(data?.content) ? data.content : [];
  const text = blocks
    .filter((b): b is { type: string; text: string } =>
      !!b && typeof b === "object" && (b as Record<string, unknown>).type === "text" &&
      typeof (b as Record<string, unknown>).text === "string")
    .map((b) => b.text)
    .join("")
    .trim();
  if (text.length === 0) throw new Error(`empty_response(stop=${stopReason})`);
  return {
    text,
    model: typeof data?.model === "string" ? data.model : CLAUDE_MODEL,
    stopReason,
    inputTokens: Number(data?.usage?.input_tokens) || 0,
    outputTokens: Number(data?.usage?.output_tokens) || 0,
  };
}

/** 최근 운세는 반복 회피용 참고라 길게 줄 필요가 없다 — 건수·길이를 잘라 입력 토큰을 묶는다. */
const MAX_RECENT = 5;
const MAX_RECENT_CHARS = 400;

export function buildUserPrompt(
  saju: Record<string, unknown>,
  daily: Record<string, unknown>,
  style: FortuneStyleGuide,
  recentTexts: string[] = [],
  seasonHint: string | null = null,
): string {
  const year = pillarName(saju.year);
  const month = pillarName(saju.month);
  const day = pillarName(saju.day);
  const hour = pillarName(saju.hour);
  const dayStem = stemName(saju.day);
  const elements = parseElementCounts(saju.fiveElementCounts);
  const todayPillar = pillarName(daily.today);
  const relation = String(daily.relation ?? "?");
  const lines = [
    "다음은 명리학적으로 계산된 변수와 그 해석입니다. 이를 종합해 오늘의 개발 운세를 작성해주세요.",
    "",
    `- 본인 사주팔자(년/월/일/시주): ${year} · ${month} · ${day} · ${hour}`,
    `- 일간(본인 핵심 오행): ${dayStem}`,
    `- 오행 분포: ${elementsLine(elements)}`,
    `- 오늘 일진: ${todayPillar}`,
    `- 일간 vs 오늘 천간 관계: ${relation}`,
    "",
    `[오늘의 성격] ${relationMeaning(relation)}`,
    `[오행 해석] ${elementReading(elements, daily.today)}`,
    `[형식] ${style.format}`,
    `[소재 힌트] ${style.theme}`,
  ];
  if (seasonHint) lines.push(`[시기] ${seasonHint}`);
  const recent = recentTexts
    .filter((t) => typeof t === "string" && t.trim().length > 0)
    .slice(0, MAX_RECENT)
    .map((t, i) => `${i + 1}. ${t.trim().replace(/\s+/g, " ").slice(0, MAX_RECENT_CHARS)}`);
  if (recent.length > 0) {
    lines.push("", "[최근 운세 — 아래 글들과 구조·소재·첫 어절·어미가 겹치지 않게]", ...recent);
  }
  return lines.join("\n");
}

// 관계 5종(Swift ElementRelation raw value)에 하루의 성격을 붙인다. 이게 없으면 모델은 관계를
// 해석할 근거가 없어 '소재 힌트'만 보고 쓰고, 날마다 성격이 같은 글이 나온다.
const RELATION_MEANING: Record<string, string> = {
  "비화": "나와 같은 결의 날. 큰 변수 없이 평소 페이스가 그대로 통한다. 새 일을 벌이기보다 하던 일을 끝까지 밀거나, 비슷한 고민을 하는 동료와 나란히 일하기에 맞다. 고집이 세지기 쉬운 점이 리스크.",
  "상생": "내가 밖으로 내보내는 날. 만들고, 쓰고, 설명하고, 공유하는 일이 잘 풀린다. 대신 쏟아내느라 체력과 집중이 빨리 닳으니 범위를 벌리지 않는 게 관건.",
  "피생": "도움과 재료가 들어오는 날. 질문하고, 리뷰받고, 남이 만든 것을 가져다 쓰기에 맞다. 혼자 붙들고 있으면 손해이고, 받기만 하다 결정을 미루는 게 리스크.",
  "상극": "내가 다스리는 날. 미뤄둔 결정, 잘라내기, 정리, 규칙 세우기처럼 통제가 필요한 일에 힘이 실린다. 밀어붙이다 주변을 놓치거나 과하게 손대는 게 리스크.",
  "피극": "바깥에서 압박이 들어오는 날. 일정, 장애, 요청, 지적이 몰리기 쉽다. 맞서기보다 범위를 줄이고 지킬 것 하나를 정해 버티는 쪽이 낫고, 큰 변경과 무리한 약속은 피한다.",
};

function relationMeaning(relation: string): string {
  return RELATION_MEANING[relation] ?? "특별한 쏠림 없는 날. 평소대로 하되 작은 것 하나를 마무리한다.";
}

// 오행을 개발 행동으로 옮긴 사전. 강한 오행은 '과해지기 쉬운 것', 부족한 오행은 '의식해서 채울 것'.
const ELEMENT_TRAIT: Record<string, { strong: string; weak: string; today: string }> = {
  "목": { strong: "시작과 확장이 앞서 벌여놓은 일이 많아지기 쉽다", weak: "새로 시작하는 추진력이 달려 첫 삽을 뜨는 데 시간이 걸린다", today: "새로 시작하고 뻗어나가는 기운" },
  "화": { strong: "속도와 표현이 앞서 검증보다 출시가 빨라지기 쉽다", weak: "드러내고 알리는 일이 약해 해놓고도 공유를 안 하기 쉽다", today: "빠르게 드러내고 보여주는 기운" },
  "토": { strong: "안정과 유지에 무게가 실려 바꿔야 할 것도 그대로 두기 쉽다", weak: "기반 다지기가 약해 정리와 문서가 뒤로 밀리기 쉽다", today: "다지고 정리하고 받쳐주는 기운" },
  "금": { strong: "판단과 잘라내기가 날카로워 리뷰와 기준이 엄격해지기 쉽다", weak: "끊고 결정하는 힘이 약해 선택지를 오래 열어두기 쉽다", today: "가르고 결정하고 마감하는 기운" },
  "수": { strong: "탐색과 생각이 깊어 조사만 하다 손이 늦어지기 쉽다", weak: "유연함과 탐색이 약해 처음 떠올린 방법을 고집하기 쉽다", today: "살피고 흐르고 돌아가는 기운" },
};

const STEM_ELEMENT = ["목", "목", "화", "화", "토", "토", "금", "금", "수", "수"];

function elementReading(counts: Record<string, number>, todayPillar: unknown): string {
  const entries = ELEMENT_ORDER.map((k) => [k, counts[k] ?? 0] as const);
  const max = Math.max(...entries.map(([, v]) => v));
  const min = Math.min(...entries.map(([, v]) => v));
  const parts: string[] = [];
  if (max > min) {
    const strong = entries.filter(([, v]) => v === max).map(([k]) => k);
    const weak = entries.filter(([, v]) => v === min).map(([k]) => k);
    // 동률이 많으면 해석이 흐려진다 — 각각 앞의 하나만 쓴다(순서는 ELEMENT_ORDER 고정이라 결정적).
    parts.push(`타고난 성향: ${ELEMENT_TRAIT[strong[0]].strong}.`);
    parts.push(`보완할 점: ${ELEMENT_TRAIT[weak[0]].weak}.`);
  }
  const stemIdx = todayPillar && typeof todayPillar === "object"
    ? (todayPillar as Record<string, unknown>).stem
    : undefined;
  const todayEl = typeof stemIdx === "number" ? STEM_ELEMENT[stemIdx] : undefined;
  if (todayEl) parts.push(`오늘 들어오는 기운: ${ELEMENT_TRAIT[todayEl].today}.`);
  return parts.length > 0 ? parts.join(" ") : "뚜렷한 쏠림 없음.";
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

export interface FortuneStyleGuide {
  format: string;
  theme: string;
}

// 형식 풀 — 예전엔 "장면 → 리스크 → 행동" 3문장 하나뿐이라 내용이 달라도 읽는 리듬이 매번 같았다.
// 형식이 문장 수·전개·길이를 통째로 바꾼다. 늘릴 때는 서로 리듬이 확실히 다른 것만 추가할 것.
const FORMATS = [
  "오늘 조심할 것 하나를 첫 문장에서 바로 말하고, 왜 그런지 한 문장, 대신 할 일 한 문장. 3문장.",
  "독자에게 던지는 질문 하나로 시작하고, 그 질문이 왜 오늘 중요한지 풀어준 뒤, 작은 제안으로 닫기. 3문장.",
  "짧게 끊어 쓰는 두 문장과, 줄을 바꾸지 않고 이어 붙이는 한 줄 처방. 전체 150자 안팎으로 짧게.",
  "개발과 상관없는 일상 사물이나 장면 하나(요리, 등산, 이사, 악기, 날씨 등)를 비유로 잡고 끝까지 그 비유 하나로 끌고 가기. 3-4문장.",
  "오늘은 하지 않아도 되는 일, 미뤄도 되는 일 하나를 짚어주는 글. 해야 할 일 목록을 늘리지 말 것. 2-3문장.",
  "오전과 오후를 나눠서 쓰기. 오전에 어울리는 일과 오후에 어울리는 일이 달라야 한다. 3문장.",
  "사람 한 명과의 장면으로 쓰기 — 동료, 리뷰어, 질문해 온 후배, 혹은 6개월 뒤의 나 중 하나. 3문장.",
  "구체적인 작업 장면 하나를 눈에 보이게 묘사하고, 거기서 한 가지 행동을 권하기. 3문장.",
  "오늘 하루를 한 문장으로 단정하듯 요약하는 짧은 첫 문장으로 시작하고, 뒤의 두 문장에서 근거와 실행을 붙이기.",
  "'만약 ~라면'으로 시작하는 조건문 두 개로 쓰기 — 일이 잘 풀릴 때와 막힐 때 각각 무엇을 할지. 2-3문장.",
];

// 소재 힌트 — 느슨한 참고. 구체 장면을 지시하면 모델이 그대로 베껴 첫 문장이 풀 크기만큼만 나온다.
const THEMES = [
  "디버깅과 원인 추적", "작은 리팩토링과 이름 정리", "코드 리뷰 주고받기", "배포와 롤백",
  "테스트 보강", "문서와 인수인계", "자동화 스크립트", "페어 프로그래밍과 질문",
  "의존성 업데이트", "성능과 측정", "로그와 모니터링", "장애 대응과 회고",
  "일정 추정과 범위 조절", "회의와 비동기 소통", "새 도구나 언어 익히기", "레거시 코드 읽기",
  "API 설계와 계약", "데이터 마이그레이션", "보안과 권한 점검", "개발 환경 정비",
  "커밋과 PR 쪼개기", "기술 부채 갚기", "프로토타입과 실험", "휴식과 집중 시간 관리",
  "이슈 정리와 우선순위", "사용자 피드백 읽기", "설정과 환경변수", "에러 메시지 다듬기",
];

export function styleGuideFor(saju: Record<string, unknown>, daily: Record<string, unknown>): FortuneStyleGuide {
  const base = JSON.stringify(saju) + "|" + JSON.stringify(daily);
  // 축마다 소금을 달리해 독립적으로 뽑는다 — 한 해시를 나눠 쓰면 축끼리 묶여 같은 조합이 되풀이된다.
  return {
    format: FORMATS[stableHash(base + "|format") % FORMATS.length],
    theme: THEMES[stableHash(base + "|theme") % THEMES.length],
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
