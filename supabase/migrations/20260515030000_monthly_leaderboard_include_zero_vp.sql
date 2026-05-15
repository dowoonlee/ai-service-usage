-- monthly_leaderboard — 0 VP active 사용자도 노출.
--
-- 기존 view는 INNER JOIN + `m.monthly_coins > 0` 필터로 이번 달 적립이 0인 사용자를 숨겼다.
-- 결과: 옵트인은 했지만 첫 submit 전이거나(Cursor Free/Pro · Claude 비사용자) 월 시작 직후라
-- delta 누적이 없는 사용자가 보드에서 사라져, 신규 가입자 입장에서 "다른 사람이 안 보임" 현상.
--
-- 변경: LEFT JOIN + COALESCE(monthly_coins, 0). 옵트인했고 status=active 면 0 VP라도 항상 노출.
-- rank tie-breaker는 기존과 동일 (registered_at ASC) — 0 VP 동점자는 등록 빠른 쪽이 상위.
--
-- 영향:
--   * leaderboard endpoint의 `total` 카운트 의미 변화: "이번 달 적립한 사용자" → "참여 중인 사용자"
--     (모든 active 사용자). 사용자 관점에서 더 직관적.
--   * monthly_winners finalize 로직은 별도 raw SQL로 `HAVING SUM(...) > 0` 유지 — 보상 지급은
--     실제 적립자만.

CREATE OR REPLACE VIEW monthly_leaderboard AS
WITH period_start AS (
    SELECT (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul' AS start_at
),
monthly AS (
    SELECT
        s.device_id,
        SUM(s.accepted_coins)::BIGINT AS monthly_coins
    FROM submissions s, period_start
    WHERE s.accepted = TRUE
      AND s.submitted_at >= period_start.start_at
    GROUP BY s.device_id
)
SELECT
    u.device_id,
    u.nickname,
    u.github_login,
    u.profile_json,
    COALESCE(m.monthly_coins, 0)::BIGINT AS monthly_coins,
    ROW_NUMBER() OVER (ORDER BY COALESCE(m.monthly_coins, 0) DESC, u.registered_at ASC) AS rank
FROM users u
LEFT JOIN monthly m ON m.device_id = u.device_id
WHERE u.status = 'active';
