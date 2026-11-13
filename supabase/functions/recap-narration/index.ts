import { getDb } from "../_shared/db.ts";
import { RECAP_PROMPT_VERSION } from "../_shared/recap.ts";
import { generateRecap } from "./claude.ts";
import { createRecapHandler, type RecapClaim, type RecapStore } from "./handler.ts";

declare const EdgeRuntime: { waitUntil(job: Promise<void>): void };

const store: RecapStore = {
  async user(device) {
    const { data, error } = await getDb().from("users").select("hmac_key_b64,status").eq("device_id", device).maybeSingle();
    if (error) throw error;
    return data;
  },
  async read(device, year, pet) {
    const { data, error } = await getDb().from("recap_narrations")
      .select("recap_year,pet_kind,status,narration,generated_at")
      .eq("device_id", device).eq("recap_year", year).eq("pet_kind", pet).maybeSingle();
    if (error) throw error;
    return data;
  },
  async claim(device, year, pet, facts, token) {
    const { data, error } = await getDb().rpc("claim_recap_narration", {
      p_device: device, p_year: year, p_pet: pet, p_facts: facts, p_token: token, p_prompt_version: RECAP_PROMPT_VERSION,
    });
    if (error) throw error;
    return data as RecapClaim;
  },
  async finish(device, year, pet, token, narration, model) {
    const { data, error } = await getDb().rpc("finish_recap_narration", {
      p_device: device, p_year: year, p_pet: pet, p_token: token, p_narration: narration, p_model: model,
    });
    if (error) throw error;
    return data === true;
  },
  async fail(device, year, pet, token) {
    const { error } = await getDb().rpc("fail_recap_narration", { p_device: device, p_year: year, p_pet: pet, p_token: token });
    if (error) throw error;
  },
};
const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
Deno.serve(createRecapHandler({
  store,
  generate: apiKey ? (pet, facts) => generateRecap(pet, facts, {
    apiKey, baseUrl: Deno.env.get("ANTHROPIC_BASE_URL") || undefined,
    workspaceId: Deno.env.get("ANTHROPIC_WORKSPACE_ID") || undefined,
  }) : undefined,
  waitUntil: (job) => EdgeRuntime.waitUntil(job),
}));
