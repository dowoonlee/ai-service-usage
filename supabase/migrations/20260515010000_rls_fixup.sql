-- monthly_winners RLS 일관성 보강.
--
-- 20260513030000_monthly_winners.sql에서 RLS ENABLE을 누락 — 다른 ranking 테이블(users,
-- submissions, abuse_flags, board_posts, board_post_likes)은 모두 RLS ENABLE + 정책 없음으로
-- anon 직접 접근을 차단하는데 monthly_winners만 anon에게 노출되어 있었음.
--
-- nickname/score/profile_json은 leaderboard endpoint를 통해 어차피 공개되는 정보지만,
-- (1) RLS 정책이 한 곳에 통일되지 않으면 향후 변경 시 누락 위험, (2) reward_claimed_at은
-- 본인 수령 여부라는 운영 정보 — 직접 노출 부적절.
--
-- 영향:
--   * Edge Function leaderboard (service_role)는 RLS bypass — 동작 변화 없음.
--   * anon이 PostgREST로 /rest/v1/monthly_winners 직접 호출 시 빈 결과.

ALTER TABLE monthly_winners ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon은 SELECT/INSERT/UPDATE/DELETE 모두 거부.
