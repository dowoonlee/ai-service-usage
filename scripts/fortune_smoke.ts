// 운세 Claude 호출 스모크 — 서버·HMAC·DB 없이 `fortune/claude.ts`만 직접 호출한다.
//
//   source scripts/ranking.env && deno run --allow-net --allow-env scripts/fortune_smoke.ts
//
// 필요 env: ANTHROPIC_API_KEY (조직 키면 ANTHROPIC_WORKSPACE_ID 필수, 선택: ANTHROPIC_BASE_URL). 키 유효성·모델·문장 품질·토큰 수를 확인한다.
// 사내망 TLS 검사 환경이면 `--unsafely-ignore-certificate-errors`를 deno 플래그에 추가.
import { CLAUDE_MODEL, MODEL_LABEL, generateFortune } from "../supabase/functions/fortune/claude.ts";

const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
if (!apiKey) {
  console.error("ANTHROPIC_API_KEY 가 비어 있습니다. scripts/ranking.env 에 넣고 source 하세요.");
  Deno.exit(2);
}

// 앱(SajuChart/DailyFortune Codable)이 보내는 모양 그대로 — pillar는 {stem, branch} 인덱스,
// fiveElementCounts는 Swift Dictionary<enum,Int> 인코딩인 [키, 값, 키, 값, ...] 배열.
const saju = {
  year: { stem: 6, branch: 7 },
  month: { stem: 3, branch: 10 },
  day: { stem: 0, branch: 2 },
  hour: { stem: 8, branch: 0 },
  fiveElementCounts: ["목", 3, "화", 1, "토", 2, "금", 1, "수", 1],
};
const daily = { today: { stem: 2, branch: 5 }, relation: "상생" };

console.log(`model=${CLAUDE_MODEL} label=${MODEL_LABEL}`);
const t0 = performance.now();
const gen = await generateFortune(saju, daily, apiKey, {
  baseUrl: Deno.env.get("ANTHROPIC_BASE_URL") || undefined,
  workspaceId: Deno.env.get("ANTHROPIC_WORKSPACE_ID") || undefined,
});
const ms = Math.round(performance.now() - t0);
console.log(`responded model=${gen.model} stop=${gen.stopReason} in=${gen.inputTokens} out=${gen.outputTokens} ${ms}ms`);
console.log(`chars=${gen.text.length} sentences≈${gen.text.split(/[.!?。]\s*/).filter(Boolean).length}`);
console.log("---");
console.log(gen.text);
