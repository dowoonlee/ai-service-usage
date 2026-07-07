-- 완전 격리형 멀티테넌시 P0-c — 길드 하위 로직 테넌트화. docs/plans/tenant.md.
--
-- P0-a에서 guilds/guild_monthly_winners에 tenant_id 컬럼은 이미 추가됨(전원 public 백필).
-- 여기선 길드 랭킹/정산/이름유니크를 테넌트별로 파티션한다 — 길드는 자기 테넌트 안에서만 경쟁.
-- 배포 시점엔 전원 public이라 무변화(단일 파티션 = 기존 전역 로직과 동치).
--
-- 설계 노트:
--   * 길드 멤버십은 가입 경로(create/join/invite-accept)에서 device.tenant == guild.tenant를 강제하므로
--     "한 길드 = 한 테넌트"가 성립. 따라서 뷰/정산은 guilds.tenant_id로 파티션하면 충분.
--   * 정산은 개인 finalize처럼 한 period를 전 테넌트 한 번에 처리(원자) — settlement_log는 period 단위 유지.
--   * 경쟁 가드(자기 아래 1개 이상 있을 때만 시상)를 테넌트별로 재계산.

-- ===========================================================================
-- 1) 길드명 유니크 — 전역 → 테넌트별 (public 전원이라 동치, 데이터 충돌 없음)
-- ===========================================================================
DROP INDEX guilds_name_normalized_uniq;
CREATE UNIQUE INDEX guilds_tenant_name_uniq ON guilds (tenant_id, name_normalized);

-- ===========================================================================
-- 2) guild_monthly_winners 유니크 (period,rank) → (tenant_id,period,rank)
--    finalize의 ON CONFLICT과 원자적으로 함께 교체(아래 함수 재정의).
-- ===========================================================================
ALTER TABLE guild_monthly_winners DROP CONSTRAINT guild_monthly_winners_period_rank_key;
CREATE UNIQUE INDEX guild_monthly_winners_tenant_period_rank
    ON guild_monthly_winners (tenant_id, period, rank);

-- ===========================================================================
-- 3) guild_monthly_scores 뷰 — 테넌트별 순위(rank를 tenant로 파티션 + tenant_id 노출).
--    guild_member_monthly_vp(멤버별, guild 파티션)는 그대로 — 길드가 곧 한 테넌트라 무변경.
-- ===========================================================================
DROP VIEW IF EXISTS guild_monthly_scores;
CREATE VIEW guild_monthly_scores AS
SELECT
    g.id AS guild_id,
    g.tenant_id,
    g.name,
    g.created_at,
    COALESCE(s.score, 0)::BIGINT AS score,
    COALESCE(mc.member_count, 0)::INT AS member_count,
    ROW_NUMBER() OVER (
        PARTITION BY g.tenant_id
        ORDER BY COALESCE(s.score, 0) DESC, g.created_at ASC
    ) AS rank
FROM guilds g
LEFT JOIN (
    SELECT
        guild_id,
        SUM(monthly_vp) FILTER (WHERE rn <= 5) AS score  -- TOP_CONTRIBUTORS = 5
    FROM guild_member_monthly_vp
    GROUP BY guild_id
) s ON s.guild_id = g.id
LEFT JOIN (
    SELECT guild_id, COUNT(*) AS member_count
    FROM guild_members
    GROUP BY guild_id
) mc ON mc.guild_id = g.id;

-- ===========================================================================
-- 4) finalize_monthly_guild_rp_if_needed() — 테넌트별 경쟁으로 재작성.
--    직전 달 Top3/보상을 테넌트마다 독립 산출. 경쟁 가드(rank ≤ Q-1, ≤3)도 테넌트별 Q로.
--    날짜 계산·자격(상위5명 합산 VP>0)·정산로그 판정은 기존과 동일.
-- ===========================================================================
CREATE OR REPLACE FUNCTION finalize_monthly_guild_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    -- 이미 정산됐으면 no-op — 승자/보상 유무와 무관하게 로그로 판정(빈 정산 재실행 방지).
    -- 한 period를 전 테넌트 한 번에 처리하므로 로그는 period 단위로 충분.
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

    -- 자격 길드(상위 5명 합산 VP > 0)를 **테넌트별로** 랭킹 + 테넌트별 자격 길드 수(qual_count).
    -- 윈도우 함수는 HAVING 이후 rows(자격 길드)에 대해 계산되므로 qual_count는 테넌트별 자격 길드 수.
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

    -- 1) 시상대 동결 — 테넌트별 경쟁 가드(rank ≤ LEAST(3, qual_count-1)), 길드장 스냅샷 포함.
    INSERT INTO guild_monthly_winners
        (period, tenant_id, rank, guild_id, name_snapshot, score, member_count,
         leader_nickname_snapshot, leader_profile_json_snapshot)
    SELECT
        prev_period, t.tenant_id, t.rank, g.id, g.name, t.score,
        (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id),
        lu.nickname,
        lu.profile_json
    FROM _guild_prev_ranked t
    JOIN guilds g ON g.id = t.guild_id
    LEFT JOIN users lu ON lu.device_id = g.leader_device_id
    WHERE t.rank <= LEAST(3, t.qual_count - 1)
    ON CONFLICT (tenant_id, period, rank) DO NOTHING;

    -- 2) RP 지급 — 경쟁 가드 + 자격 멤버(해당 월 VP > 0). rank = 테넌트 내 길드 순위.
    INSERT INTO rp_rewards (period, period_type, tenant_id, device_id, rank, rp_amount)
    SELECT
        prev_period, 'guild-monthly', t.tenant_id, v.device_id, t.rank,
        CASE t.rank WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 200 END
    FROM _guild_prev_ranked t
    JOIN _guild_prev_vp v ON v.guild_id = t.guild_id
    WHERE t.rank <= LEAST(3, t.qual_count - 1) AND v.monthly_vp > 0
    ON CONFLICT (period_type, period, device_id) DO NOTHING;

    -- 3) 정산 완료 마킹 — 승자 유무와 무관하게 항상.
    INSERT INTO guild_settlement_log (period) VALUES (prev_period)
    ON CONFLICT (period) DO NOTHING;
END;
$$ LANGUAGE plpgsql;
