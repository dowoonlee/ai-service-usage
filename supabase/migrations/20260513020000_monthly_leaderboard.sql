-- 월간 랭킹 — submissions의 시계열 데이터를 KST 기준 월 단위로 집계.
-- 매월 1일 00:00 KST에 자동으로 새 윈도우가 시작 (data 자체는 안 지움).
-- 별도 cron job 불필요 — 쿼리만 정상이면 자연스럽게 갱신.

-- 1) public_leaderboard 제거 — 누적 보드는 더 이상 노출 안 함.
DROP VIEW IF EXISTS public_leaderboard;

-- 2) monthly_leaderboard view 신규.
-- 시간대 처리: NOW() 는 timestamptz(UTC). 'Asia/Seoul'으로 변환 → date_trunc('month') →
-- 다시 KST로 해석해 timestamptz 복귀. 결과: 정확히 그 달 1일 00:00 KST부터의 윈도우.
CREATE VIEW monthly_leaderboard AS
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
    m.monthly_coins,
    ROW_NUMBER() OVER (ORDER BY m.monthly_coins DESC, u.registered_at ASC) AS rank
FROM users u
JOIN monthly m ON m.device_id = u.device_id
WHERE u.status = 'active' AND m.monthly_coins > 0;

-- 3) 기존 사용자 backfill — total_coins > 0 인데 accepted submission이 없는 경우 (옛 register
-- 코드로 등록됐거나 admin이 수동 보정한 경우)에 한해 synthetic 행 1개 insert.
-- 이로 인해 이번 달 보드에 즉시 등장.
INSERT INTO submissions (device_id, delta_coins, accepted_coins, elapsed_seconds, accepted, cap_applied, reject_reason)
SELECT
    u.device_id,
    u.total_coins,
    u.total_coins,
    0,
    TRUE,
    FALSE,
    NULL
FROM users u
WHERE u.total_coins > 0
  AND NOT EXISTS (
      SELECT 1 FROM submissions s
      WHERE s.device_id = u.device_id AND s.accepted = TRUE
  );
