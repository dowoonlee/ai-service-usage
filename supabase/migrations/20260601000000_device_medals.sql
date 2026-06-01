-- device별 누적 메달 집계 — monthly_winners(rank 1/2/3)를 device 단위로 롤업.
-- 리포트 트레이너 카드의 금/은/동 표시용. leaderboard Edge Function이 조회한다.
-- 진실은 monthly_winners 한 곳 — 본 view는 파생 집계라 별도 갱신/cron 불필요.
-- INTEGER 캐스팅: COUNT은 bigint라 PostgREST 직렬화가 애매 — 메달 수는 작으므로 int로 좁힘.

CREATE VIEW device_medals AS
SELECT
    device_id,
    (COUNT(*) FILTER (WHERE rank = 1))::INTEGER AS gold,
    (COUNT(*) FILTER (WHERE rank = 2))::INTEGER AS silver,
    (COUNT(*) FILTER (WHERE rank = 3))::INTEGER AS bronze
FROM monthly_winners
WHERE device_id IS NOT NULL
GROUP BY device_id;
