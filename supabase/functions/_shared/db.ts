// Supabase Postgres client. service_role로 RLS bypass (Edge Function 안에서만 사용).
//
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY는 Supabase가 함수 런타임에 자동 주입.
// `supabase secrets set`으로 별도 등록할 필요 없음.

// 일부 네트워크 환경(SSL inspection / corporate proxy)에서 esm.sh 인증서 검증이 실패하면
// `jsr:@supabase/supabase-js@2`로 교체. Deno 네이티브 레지스트리라 SSL 이슈 회피.
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

let cached: SupabaseClient | null = null;

export function getDb(): SupabaseClient {
  if (cached) return cached;
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing in Edge Function env");
  }
  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}
