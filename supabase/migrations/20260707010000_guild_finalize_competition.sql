-- 길드 월간 정산 보정 — 무경쟁 무임 지급 + 소급 재실행 버그 수정.
--
-- 문제: 정산은 "직전 달"만 처리하지만 두 가지가 겹쳐 "이번 달에 만든 길드가 지난 달을
--   무경쟁 우승"하는 이상 지급이 발생했다.
--   ① 소급 반영: 현재 멤버의 지난달 개인 사용량을 그 멤버의 현재 길드 점수로 집계 → 갓 만든
--      길드도 창립자의 지난달 VP로 즉시 "지난달 점수"를 가짐.
--   ② 빈 정산 재실행: "정산 완료"를 guild_monthly_winners 행 존재로 판정 → 자격 길드 0개면
--      행이 안 생겨 완료로 안 찍힘 → 이후 호출마다 재정산 → 나중에 만든 길드가 소급 진입.
--
-- 수정:
--   (A) 정산 완료를 별도 로그(guild_settlement_log)로 판정 — 승자/보상 유무와 무관하게 1회 기록.
--       → 이미 지난 달은 한 번 정산되면 다시 안 돈다(소급 진입 차단).
--   (B) 경쟁 가드: 순위 r은 자기 아래 최소 1개 자격 길드가 있을 때만 시상/지급(rank ≤ Q-1, ≤3).
--       → 자격 길드 1개뿐이면 아무도 못 받음. 2개→1위만, 3개→1·2위, 4개+→1·2·3위.

-- ===========================================================================
-- guild_settlement_log — 정산 완료 마커 (period당 1행). 승자 0명이어도 기록된다.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS guild_settlement_log (
    period       TEXT PRIMARY KEY,               -- "YYYY-MM" (KST)
    finalized_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE guild_settlement_log ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon 차단, Edge Function(service_role)만.

-- 이미 시상 동결된 과거 period는 정산 완료로 소급 기록(재실행 방지). 이후 신설 길드가
-- 지난 달에 진입하지 못하게 한다. (승자 없던 달은 로그가 없어 다음 호출 때 1회 재정산되며
-- 경쟁 가드 적용 후 로그가 찍혀 종료된다.)
INSERT INTO guild_settlement_log (period)
SELECT DISTINCT period FROM guild_monthly_winners
ON CONFLICT (period) DO NOTHING;

-- ===========================================================================
-- finalize_monthly_guild_rp_if_needed() — 로그 가드 + 경쟁 가드로 교체
-- ===========================================================================
CREATE OR REPLACE FUNCTION finalize_monthly_guild_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
    qual_count INTEGER;
    pay_max_rank INTEGER;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    -- 이미 정산됐으면 no-op — 승자/보상 유무와 무관하게 로그로 판정(빈 정산 재실행 방지).
    IF EXISTS (SELECT 1 FROM guild_settlement_log WHERE period = prev_period) THEN
        RETURN;
    END IF;

    -- 직전 달 멤버별 VP(현재 멤버 기준).
    CREATE TEMP TABLE _guild_prev_vp ON COMMIT DROP AS
    SELECT
        gm.guild_id,
        gm.device_id,
        COALESCE(SUM(s.accepted_coins), 0)::BIGINT AS monthly_vp
    FROM guild_members gm
    JOIN users u ON u.device_id = gm.device_id AND u.status = 'active'
    LEFT JOIN submissions s ON s.device_id = gm.device_id
        AND s.accepted = TRUE
        AND s.submitted_at >= prev_month_start
        AND s.submitted_at <  this_month_start
    GROUP BY gm.guild_id, gm.device_id;

    -- 자격 길드(상위 5명 합산 VP > 0) 전체 랭킹.
    CREATE TEMP TABLE _guild_prev_ranked ON COMMIT DROP AS
    SELECT guild_id, score, rank FROM (
        SELECT
            v.guild_id,
            SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5)::BIGINT AS score,
            ROW_NUMBER() OVER (
                ORDER BY SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) DESC,
                         MIN(g.created_at) ASC
            ) AS rank
        FROM (
            SELECT guild_id, device_id, monthly_vp,
                   ROW_NUMBER() OVER (PARTITION BY guild_id ORDER BY monthly_vp DESC, device_id ASC) AS rn
            FROM _guild_prev_vp
        ) v
        JOIN guilds g ON g.id = v.guild_id
        GROUP BY v.guild_id
        HAVING SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) > 0
    ) ranked;

    -- 경쟁 가드 — 순위 r은 자기 아래 최소 1개 길드가 있을 때만(rank ≤ Q-1), 최대 Top3.
    SELECT COUNT(*) INTO qual_count FROM _guild_prev_ranked;
    pay_max_rank := LEAST(3, qual_count - 1);   -- Q≤1 → 0 → 아무도 시상/지급 안 됨

    -- 1) 시상대 동결 — 경쟁 가드 적용, 길드장 스냅샷 포함.
    INSERT INTO guild_monthly_winners
        (period, rank, guild_id, name_snapshot, score, member_count,
         leader_nickname_snapshot, leader_profile_json_snapshot)
    SELECT
        prev_period, t.rank, g.id, g.name, t.score,
        (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id),
        lu.nickname,
        lu.profile_json
    FROM _guild_prev_ranked t
    JOIN guilds g ON g.id = t.guild_id
    LEFT JOIN users lu ON lu.device_id = g.leader_device_id
    WHERE t.rank <= pay_max_rank
    ON CONFLICT (period, rank) DO NOTHING;

    -- 2) RP 지급 — 경쟁 가드 + 자격 멤버(해당 월 VP > 0). rank = 길드 순위.
    INSERT INTO rp_rewards (period, period_type, device_id, rank, rp_amount)
    SELECT
        prev_period, 'guild-monthly', v.device_id, t.rank,
        CASE t.rank WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 200 END
    FROM _guild_prev_ranked t
    JOIN _guild_prev_vp v ON v.guild_id = t.guild_id
    WHERE t.rank <= pay_max_rank AND v.monthly_vp > 0
    ON CONFLICT (period_type, period, device_id) DO NOTHING;

    -- 3) 정산 완료 마킹 — 승자 유무와 무관하게 항상. 재실행/소급 진입을 종료.
    INSERT INTO guild_settlement_log (period) VALUES (prev_period)
    ON CONFLICT (period) DO NOTHING;
END;
$$ LANGUAGE plpgsql;
