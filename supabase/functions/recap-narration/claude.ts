import { CLAUDE_MODEL } from "../fortune/claude.ts";
import { RECAP_SCENES, recapPrompt, validateNarration, type RecapSummary } from "../_shared/recap.ts";

export interface RecapClaudeOptions {
  apiKey: string;
  baseUrl?: string;
  workspaceId?: string;
  fetcher?: typeof fetch;
}

export async function generateRecap(petKind: string, summary: RecapSummary, opts: RecapClaudeOptions) {
  const prompt = recapPrompt(petKind, summary);
  const headers: Record<string, string> = {
    "x-api-key": opts.apiKey, "anthropic-version": "2026-10-21", "content-type": "application/json",
  };
  if (opts.workspaceId) headers["anthropic-workspace-id"] = opts.workspaceId;
  const response = await (opts.fetcher ?? fetch)(`${(opts.baseUrl ?? "https://api.anthropic.com").replace(/\/+$/, "")}/v1/messages`, {
    method: "POST", headers, signal: AbortSignal.timeout(80000),
    body: JSON.stringify({
      model: CLAUDE_MODEL, max_tokens: 6144, system: prompt.system,
      messages: [{ role: "user", content: prompt.user }],
      output_config: {
        effort: "low",
        format: {
          type: "json_schema",
          schema: {
            type: "object", additionalProperties: false, required: ["persona", "lines"],
            properties: {
              persona: { type: "string", description: "펫 성격과 말투 요약, 한국어 120자 이내" },
              lines: {
                type: "object", additionalProperties: false, required: [...RECAP_SCENES],
                properties: Object.fromEntries(RECAP_SCENES.map((id) => [id, {
                  type: "string", description: "한국어 펫 대사 45~90자, 최대110자",
                }])),
              },
            },
          },
        },
      },
    }),
  });
  // API 오류 본문에는 식별자/프롬프트가 있을 수 있다. 로그나 클라이언트에 전파하지 않는다.
  if (!response.ok) { await response.body?.cancel(); throw new Error(`claude_http_${response.status}`); }
  const data = await response.json();
  if (data.stop_reason !== "end_turn") throw new Error("claude_incomplete");
  const text = (Array.isArray(data.content) ? data.content : [])
    .filter((b: { type?: string; text?: unknown }) => b.type === "text" && typeof b.text === "string")
    .map((b: { text: string }) => b.text).join("");
  const narration = validateNarration(JSON.parse(text));
  return { narration, model: typeof data.model === "string" ? data.model : CLAUDE_MODEL };
}
