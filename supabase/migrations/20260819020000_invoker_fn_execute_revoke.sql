-- 20260819010000 후속 — 남은 SECURITY INVOKER 함수 6개의 PUBLIC EXECUTE 회수.
--
-- 어드바이저 lint 0028/0029 는 SECURITY DEFINER 만 잡으므로 이 계열은 한 번도 리포트된 적이
-- 없다. has_function_privilege 실측 결과 6개 전부 anon=true — 클라 Info.plist 에 평문 동봉되는
-- 공개 anon 키로 /rest/v1/rpc/<fn> 직접 호출이 가능한 상태였다.
--
-- 지금 실피해가 없는 이유는 하부 테이블이 전부 RLS enabled + 정책 0개이기 때문이다. anon 이
-- 부르면 SELECT 가 0행이라 정산 대상이 비고 상태 마커 INSERT 에서 RLS 위반으로 끝난다.
-- 즉 안전의 근거가 "정책이 하나도 없다"는 조건 하나에 통째로 걸려 있다. 어느 테이블에든
-- permissive 정책이 붙는 순간 외부인이 월간/주간 정산(coins·RP 지급)과 테넌트 전환을 임의
-- 시점에 격발할 수 있는 상태로 승격된다 — 전부 통화나 소속을 쓰는 함수다.
--
-- 호출처는 전부 Edge Function(service_role) 이라 회수 후 동작 변화가 없다:
--   finalize_previous_month_if_needed   ← leaderboard/index.ts:34 · _shared/leaderboard_query.ts:36
--   finalize_monthly_rp_if_needed       ← leaderboard/index.ts:36 · _shared/leaderboard_query.ts:38
--   finalize_weekly_rp_if_needed        ← leaderboard/index.ts:37 · _shared/leaderboard_query.ts:39
--   finalize_monthly_guild_rp_if_needed ← guild-leaderboard/index.ts:35
--   apply_tenant_switch                 ← tenant-verify-confirm/index.ts:111
REVOKE ALL ON FUNCTION finalize_previous_month_if_needed()    FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION finalize_monthly_rp_if_needed()        FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION finalize_weekly_rp_if_needed()         FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION finalize_monthly_guild_rp_if_needed()  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION apply_tenant_switch(uuid, text)        FROM public, anon, authenticated;

GRANT EXECUTE ON FUNCTION finalize_previous_month_if_needed()   TO service_role;
GRANT EXECUTE ON FUNCTION finalize_monthly_rp_if_needed()       TO service_role;
GRANT EXECUTE ON FUNCTION finalize_weekly_rp_if_needed()        TO service_role;
GRANT EXECUTE ON FUNCTION finalize_monthly_guild_rp_if_needed() TO service_role;
GRANT EXECUTE ON FUNCTION apply_tenant_switch(uuid, text)       TO service_role;

-- admin_owned_pets — 20260810000000:283 이 `REVOKE ALL ... FROM anon, authenticated` 만 하고
-- PUBLIC 그랜트(`=X/postgres`)를 남겨 둬서 **회수가 무효**였다. anon 은 자기 앞으로 된 권한이
-- 없어도 PUBLIC 을 통해 계속 실행할 수 있었다(실측 anon=true). 입력 jsonb 를 가공해 돌려주는
-- 순수 함수라 정보 노출은 없지만, 당시 의도대로 실제로 잠근다.
-- 호출처는 admin_* 뷰 정의 내부뿐(20260810000000:140,265 · 20260810010000:88 · 20260810020000:196)
-- 이고 그 뷰들은 security_invoker + anon/authenticated REVOKE 상태다. 코드 경로는 없고 대시보드
-- (postgres, 소유자)에서만 조회하므로 영향 없다.
REVOKE ALL ON FUNCTION admin_owned_pets(jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_owned_pets(jsonb) TO service_role;

-- guild_member_exit_fixup() 도 같은 노출 상태(anon=true)지만 RETURNS trigger 라 PostgREST 가
-- RPC 로 노출하지 않는다 — 외부 호출 경로가 없어 이번 회수 대상에서 뺀다.
