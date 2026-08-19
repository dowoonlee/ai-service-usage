-- 보안 어드바이저(2026-08-17) 대응 — contributors 캐시 하드닝.
--
-- 20260811020000_contributors_cache.sql 이 테이블 2개를 만들면서 이 저장소의 관행
-- (RLS enable + 정책 0개 = service_role 전용)을 빠뜨렸다. 그 결과 lint 0013_rls_disabled_in_public
-- ERROR 2건 — 클라 Info.plist에 평문 동봉되는 anon 키만으로 두 테이블을 SELECT/INSERT/UPDATE/
-- DELETE/TRUNCATE 할 수 있었다(실측: anon 에 7개 권한 전부 부여 + relrowsecurity=false).
-- 내용 자체는 공개 정보(GitHub 로그인·머지된 PR)라 유출 피해는 없지만 위변조·삭제가 열려 있고,
-- contributors_sync.last_success_at 을 미래로 써 넣으면 갱신을 영구 차단할 수 있다.
--
-- 유일한 접근 경로는 Edge Function `contributors`(_shared/db.ts = service_role, RLS bypass)이고
-- 클라는 functions/v1/contributors 만 호출한다(RankingAPI.swift). PostgREST 직접 접근 경로는 없다.
-- 따라서 아래 변경의 런타임 영향은 없다.
ALTER TABLE contributors      ENABLE ROW LEVEL SECURITY;
ALTER TABLE contributors_sync ENABLE ROW LEVEL SECURITY;

-- 심층 방어 — 정책이 0개라 RLS만으로도 anon 은 0행이지만, 테이블 권한 자체도 회수한다.
-- (향후 누군가 실수로 permissive 정책을 붙여도 grant 가 없으면 뚫리지 않는다. 20260716000000 의
--  뷰 REVOKE 와 같은 취지.) service_role/postgres 는 영향 없음.
REVOKE ALL ON contributors, contributors_sync FROM anon, authenticated;

-- lint 0028/0029 — SECURITY DEFINER 함수가 anon/authenticated 에게 열려 있었다(ACL `=X/postgres`).
-- claim_contributors_sync 는 동기화 슬롯을 선점하는 함수라, 외부에서 RETRY_SECONDS(30분)보다
-- 짧은 주기로 계속 호출하면 last_attempt_at 이 갱신되어 Edge Function 이 슬롯을 못 잡는다
-- → GitHub 갱신이 무기한 정지(기존 캐시로 응답은 계속되나 목록이 굳는다).
-- 호출처는 supabase/functions/contributors/index.ts 한 곳(service_role)뿐.
-- 20260812000000_pvp_atomic_counters 의 pvp_claim_daily/pvp_apply_rating 과 동일 패턴.
REVOKE ALL ON FUNCTION claim_contributors_sync(integer, integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION claim_contributors_sync(integer, integer) TO service_role;

-- lint 0011_function_search_path_mutable — 20260716000000 의 search_path 고정 스윕(6개) 이후에
-- 만들어진 함수(20260722000000)라 누락됐다. SECURITY INVOKER + service_role 호출
-- (pvp-leaderboard/index.ts:50)이라 실위험은 낮지만, 호출 role 의 search_path 에 따라 다른
-- 스키마의 동명 객체로 바인딩될 여지를 제거한다. 본문은 public 테이블 + pg_catalog 내장함수만
-- 참조하므로(pg_catalog 은 항상 암묵 검색) 해석이 바뀌는 객체는 없다.
ALTER FUNCTION finalize_previous_month_pvp_if_needed() SET search_path = public;
