-- 20260819000000 후속 — finalize_previous_month_pvp_if_needed 의 PUBLIC EXECUTE 회수.
--
-- 이 함수는 SECURITY INVOKER 라 Supabase 어드바이저 lint 0028/0029(정의자 권한 함수)가 잡지
-- 않는다. 그러나 실측 ACL 이 `=X/postgres`(PUBLIC) + anon + authenticated 로, 클라 Info.plist 에
-- 평문 동봉되는 anon 키만으로 /rest/v1/rpc/ 로 호출할 수 있었다.
--
-- 현재로선 실피해가 없다: 하부 테이블이 전부 RLS enabled + 정책 0개라 anon 이 호출하면
--   * 조기 return 가드(SELECT FROM pvp_seasons)가 0행을 보고 통과해 본문을 끝까지 타지만,
--   * reward_grants/enhance_items INSERT ... SELECT 는 소스가 0행이라 no-op,
--   * 마지막 INSERT INTO pvp_seasons 에서 RLS 위반으로 에러 — RP 부정지급도 시즌 조기 정산도 없다.
-- 잠그는 이유는 그 무해함이 "정책이 0개"라는 조건에만 기대고 있기 때문이다. 어느 테이블에든
-- permissive 정책이 하나 붙는 순간 외부인이 시즌 정산(RP 지급 + 레이팅 소프트 리셋)을 임의
-- 시점에 격발할 수 있는 상태로 승격된다. 20260716000000 은 이 계열을 search_path 만 고정하고
-- EXECUTE 는 열어 뒀는데, 이 함수는 유일하게 통화(RP)와 시즌 상태를 동시에 쓰므로 예외로 둔다.
--
-- 호출처는 supabase/functions/pvp-leaderboard/index.ts:50 한 곳(service_role)뿐이고 트리거
-- 참조는 0건(pg_trigger 실측)이라 회수 후 동작 변화는 없다.
REVOKE ALL ON FUNCTION finalize_previous_month_pvp_if_needed() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION finalize_previous_month_pvp_if_needed() TO service_role;
