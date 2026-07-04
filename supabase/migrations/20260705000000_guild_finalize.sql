-- 길드 월간 정산 (P2a) — docs/plans/guild.md §2 랭킹/정산·보상.
--
-- 직전 KST 월의 길드 랭킹(멤버 상위 5명 VP 합산)을 확정해:
--   1) Top3 길드를 guild_monthly_winners에 동결 (길드 시상대 표시용 스냅샷)
--   2) Top3 길드의 **자격 멤버(해당 월 VP > 0)** 전원에게 rp_rewards 지급 (500/300/200)
--      — 인원 무제한 + 전원 보상 조합의 무임승차(코드만 받고 수령)를 막는 최소 가드.
--
-- 개인 정산(finalize_monthly_rp_if_needed)과 동일한 lazy 패턴 — guild-leaderboard가
-- 첫 호출 시 트리거, EXISTS 가드 + UNIQUE로 race-safe/멱등. pg_cron 없음.
--
-- 집계 대상 멤버 = 정산 시점의 현재 멤버 (기획 §2 — 이적 악용은 7일 쿨다운으로 완화).

-- rp_rewards의 기간 타입에 길드 트랙 추가. 컬럼 인라인 CHECK의 기본 이름 규칙 사용.
ALTER TABLE rp_rewards DROP CONSTRAINT rp_rewards_period_type_check;
ALTER TABLE rp_rewards ADD CONSTRAINT rp_rewards_period_type_check
    CHECK (period_type IN ('monthly', 'weekly', 'guild-monthly'));

-- ===========================================================================
-- guild_monthly_winners — 직전 달 Top3 길드 동결 (개인 monthly_winners의 길드판)
-- ===========================================================================
CREATE TABLE guild_monthly_winners (
    id                           BIGSERIAL PRIMARY KEY,
    period                       TEXT NOT NULL,          -- "YYYY-MM" (KST)
    rank                         INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 3),
    guild_id                     UUID REFERENCES guilds(id) ON DELETE SET NULL, -- 해체돼도 기록 유지
    name_snapshot                TEXT NOT NULL,
    score                        BIGINT NOT NULL,
    member_count                 INTEGER NOT NULL,
    -- 시상대 아바타용 — 정산 시점 길드장. 계정 삭제돼도 시상대는 유지되도록 스냅샷.
    leader_nickname_snapshot     TEXT,
    leader_profile_json_snapshot JSONB,
    finalized_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (period, rank)                                -- 재정산 race 차단
);

ALTER TABLE guild_monthly_winners ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon 차단, Edge Function(service_role)만.

-- ===========================================================================
-- finalize_monthly_guild_rp_if_needed()
-- ===========================================================================
CREATE OR REPLACE FUNCTION finalize_monthly_guild_rp_if_needed() RETURNS VOID AS $$
DECLARE
    this_month_start TIMESTAMPTZ;
    prev_month_start TIMESTAMPTZ;
    prev_period TEXT;
BEGIN
    -- 달(달력) 빼기는 naive Seoul timestamp에서 수행 — timestamptz에서 빼면 KST 자정이
    -- UTC 전월 15:00이라 한 달 밀리는 버그 (#99 fix_monthly_finalize_tz와 동일 공식).
    this_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul')) AT TIME ZONE 'Asia/Seoul';
    prev_month_start := (date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month') AT TIME ZONE 'Asia/Seoul';
    prev_period := to_char(date_trunc('month', NOW() AT TIME ZONE 'Asia/Seoul') - INTERVAL '1 month', 'YYYY-MM');

    -- 이미 정산됐으면 no-op (guild-leaderboard 매 호출마다 여기서 즉시 return).
    IF EXISTS (SELECT 1 FROM guild_monthly_winners WHERE period = prev_period LIMIT 1) THEN
        RETURN;
    END IF;

    -- 직전 달 멤버별 VP(현재 멤버 기준) → 길드별 상위 5명 합산 → Top3.
    -- guild_member_monthly_vp 뷰는 "이번 달" 고정이라 재사용 불가 — 기간을 파라미터로 갖는
    -- 동일 셰이프 쿼리를 여기 인라인한다 (TOP 5는 guild_policy.ts TOP_CONTRIBUTORS와 쌍).
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

    CREATE TEMP TABLE _guild_prev_top3 ON COMMIT DROP AS
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
        HAVING SUM(v.monthly_vp) FILTER (WHERE v.rn <= 5) > 0   -- 0점 길드는 시상 제외
    ) ranked
    WHERE ranked.rank <= 3;

    -- 1) 시상대 동결 — 길드장 스냅샷 포함.
    INSERT INTO guild_monthly_winners
        (period, rank, guild_id, name_snapshot, score, member_count,
         leader_nickname_snapshot, leader_profile_json_snapshot)
    SELECT
        prev_period, t.rank, g.id, g.name, t.score,
        (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id),
        lu.nickname,
        lu.profile_json
    FROM _guild_prev_top3 t
    JOIN guilds g ON g.id = t.guild_id
    LEFT JOIN users lu ON lu.device_id = g.leader_device_id
    ON CONFLICT (period, rank) DO NOTHING;

    -- 2) RP 지급 — Top3 길드의 자격 멤버(해당 월 VP > 0) 전원. rank = 길드 순위.
    INSERT INTO rp_rewards (period, period_type, device_id, rank, rp_amount)
    SELECT
        prev_period, 'guild-monthly', v.device_id, t.rank,
        CASE t.rank WHEN 1 THEN 500 WHEN 2 THEN 300 ELSE 200 END
    FROM _guild_prev_top3 t
    JOIN _guild_prev_vp v ON v.guild_id = t.guild_id
    WHERE v.monthly_vp > 0
    ON CONFLICT (period_type, period, device_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;
