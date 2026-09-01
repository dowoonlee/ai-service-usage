-- 길드 RP 경쟁 가드 정정 — "꼴찌 배제"가 아니라 "무경쟁 배제"로.
--
-- 20260707010000이 넣은 `rank <= LEAST(3, qual_count - 1)`은 의도를 잘못 구현했다.
-- 가드의 목적은 자격 길드가 하나뿐인 달에 무경쟁으로 상을 가져가는 것을 막는 것이고,
-- 점수 없는 길드는 이미 자격 판정(`HAVING SUM(...) > 0`)이 거른다. 그런데 저 식은
-- 자격 길드 수와 무관하게 항상 꼴찌를 잘라서, 길드가 3개인 테넌트에선 3위가 시상·지급
-- 양쪽에서 영구히 빠졌다 (2026-08 skax: @deprecated 2427VP가 3위인데 RP 미지급).
--
-- 정정: 자격 길드가 2개 이상이면(=경쟁이 성립하면) Top3 전부 지급한다.
-- 표시(guild_monthly_winners)는 직전 마이그레이션에서 이미 Top3 전부로 풀었다.

CREATE OR REPLACE FUNCTION finalize_monthly_guild_rp_if_needed() RETURNS VOID
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    IF EXISTS (SELECT 1 FROM guild_settlement_log WHERE period = prev_period) THEN
        RETURN;
    END IF;

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

    -- 자격 = 상위 5명 합산 VP > 0. 점수 없는 길드는 여기서 이미 빠진다.
    CREATE TEMP TABLE _guild_prev_ranked ON COMMIT DROP AS
    SELECT guild_id, tenant_id, score, rank, qual_count FROM (
        SELECT
            v.guild_id,
            g.tenant_id,
            SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5)::BIGINT AS score,
            ROW_NUMBER() OVER (
                PARTITION BY g.tenant_id
                ORDER BY SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) DESC, MIN(g.created_at) ASC
            ) AS rank,
            COUNT(*) OVER (PARTITION BY g.tenant_id) AS qual_count
        FROM (
            SELECT guild_id, device_id, monthly_vp,
                   ROW_NUMBER() OVER (PARTITION BY guild_id ORDER BY monthly_vp DESC, device_id ASC) AS rn
            FROM _guild_prev_vp
        ) v
        JOIN guilds g ON g.id = v.guild_id
        GROUP BY v.guild_id, g.tenant_id
        HAVING SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) > 0
    ) ranked;

    -- 1) 시상대 동결 — Top3 전부.
    INSERT INTO guild_monthly_winners
        (period, tenant_id, rank, guild_id, name_snapshot, score, member_count,
         leader_nickname_snapshot, leader_profile_json_snapshot)
    SELECT
        prev_period, t.tenant_id, t.rank, g.id, g.name, t.score,
        (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id),
        lu.nickname,
        CASE WHEN jsonb_typeof(lu.profile_json) = 'object'
             THEN lu.profile_json - 'backup'
             ELSE lu.profile_json
        END
    FROM _guild_prev_ranked t
    JOIN guilds g ON g.id = t.guild_id
    LEFT JOIN users lu ON lu.device_id = g.leader_device_id
    WHERE t.rank <= 3
    ON CONFLICT (tenant_id, period, rank) DO NOTHING;

    -- 2) RP 지급 — 경쟁이 성립하는 달(자격 길드 2개 이상)이면 Top3 전부.
    --    자격 길드가 하나뿐이면 무경쟁이라 아무도 받지 않는다.
    INSERT INTO rp_rewards (period, period_type, tenant_id, device_id, rank, rp_amount)
    SELECT
        prev_period, 'guild-monthly', t.tenant_id, v.device_id, t.rank,
        CASE t.rank WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 200 END
    FROM _guild_prev_ranked t
    JOIN _guild_prev_vp v ON v.guild_id = t.guild_id
    WHERE t.qual_count >= 2 AND t.rank <= 3 AND v.monthly_vp > 0
    ON CONFLICT (period_type, period, device_id) DO NOTHING;

    INSERT INTO guild_settlement_log (period) VALUES (prev_period)
    ON CONFLICT (period) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION finalize_monthly_guild_rp_if_needed() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION finalize_monthly_guild_rp_if_needed() TO service_role;

-- ===========================================================================
-- 백필 — 옛 가드에 잘려 지급되지 않은 등수의 RP를 채운다.
-- ===========================================================================
-- 정산 로그 가드 때문에 지난 달은 함수가 다시 돌지 않으므로 여기서 한 번 지급한다.
-- 대상은 이미 동결된 시상대(guild_monthly_winners) 기준 — 그 달에 2팀 이상 동결됐고
-- (경쟁 성립), 해당 길드에서 그 달 VP > 0이었던 멤버. 이미 지급된 건은 유니크 제약
-- (period_type, period, device_id)에서 걸러진다. claimed_at은 NULL이라 기존 claim-reward
-- 경로로 사용자가 직접 수령한다.
WITH periods AS (
    SELECT DISTINCT
        period,
        (to_date(period || '-01', 'YYYY-MM-DD')::TIMESTAMP) AT TIME ZONE 'Asia/Seoul' AS m_start,
        (to_date(period || '-01', 'YYYY-MM-DD')::TIMESTAMP + INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul' AS m_end
    FROM guild_monthly_winners
),
frozen AS (
    SELECT w.period, w.tenant_id, w.rank, w.guild_id
    FROM guild_monthly_winners w
    WHERE w.rank <= 3
      AND (SELECT COUNT(*) FROM guild_monthly_winners w2
            WHERE w2.tenant_id = w.tenant_id AND w2.period = w.period) >= 2
),
vp AS (
    SELECT p.period, gm.guild_id, gm.device_id,
           COALESCE(SUM(s.accepted_coins), 0)::BIGINT AS monthly_vp
    FROM periods p
    CROSS JOIN guild_members gm
    JOIN users u ON u.device_id = gm.device_id AND u.status = 'active'
    LEFT JOIN submissions s ON s.device_id = gm.device_id
        AND s.accepted = TRUE
        AND s.submitted_at >= p.m_start
        AND s.submitted_at <  p.m_end
    GROUP BY p.period, gm.guild_id, gm.device_id
)
INSERT INTO rp_rewards (period, period_type, tenant_id, device_id, rank, rp_amount)
SELECT
    f.period, 'guild-monthly', f.tenant_id, v.device_id, f.rank,
    CASE f.rank WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 200 END
FROM frozen f
JOIN vp v ON v.guild_id = f.guild_id AND v.period = f.period
WHERE v.monthly_vp > 0
ON CONFLICT (period_type, period, device_id) DO NOTHING;
