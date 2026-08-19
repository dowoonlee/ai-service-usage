-- 운영 대시보드 — 유저별 VP·RP·코인 획득 내역.
--
-- 배경: admin_user_progress 는 해금 진척(펫·뱃지·컬렉션) 중심이라 "누가 무엇으로 얼마를
--       벌었나"가 안 보인다. total_coins 단일 숫자만 있어서 사용량 적립인지 이벤트 지급인지
--       구분이 안 됐고, RP 는 아예 컬럼이 없었다.
--
-- ⚠ 통화가 셋인데 이름이 헷갈리게 붙어 있다. 컬럼 설계의 핵심이라 먼저 정리한다:
--
--   1) VP (랭킹 점수) — 서버 authoritative. 클라가 Settings.rankingScoreEarnedVP 의 delta 를
--      submit 하고 서버가 캡을 적용해 users.total_coins 에 누적한다. **컬럼명이 coins 지만
--      가챠 코인이 아니다** (레거시 명명). 리더보드 순위가 이 값이다.
--
--   2) 가챠 코인 — **서버는 사용량 적립분을 못 본다.** CoinLedger 가 클라에서 적립하고
--      잔액은 profile_json.backup.coins 에만 있다. 서버가 아는 건 자기가 지급한 것뿐:
--      reward_grants(currency='coin') 와 monthly_winners.reward_coins.
--      → 그래서 coin_* 는 "서버 지급분"과 "클라 자가 보고분"을 반드시 분리한다. 합치면
--        대시보드가 거짓말을 한다.
--
--   3) RP — 서버 지급만 존재. rp_rewards(정산) + reward_grants(currency='rp', ops 지급).
--
-- rp_rewards 의 period 에는 실존하지 않는 sentinel 월이 섞여 있다(2026-00 = v0.15.1 버그보상,
-- 2099-00 = v0.16.2 인증캠페인). period_type 은 'monthly' 인데 정기 정산이 아니므로 정규식으로
-- 갈라 캠페인 지급을 따로 센다 — 안 나누면 max(period) 가 2099-00 으로 잡혀 "8월 정산 됐나"
-- 같은 판단이 통째로 어긋난다.
--
-- 합계 대조 시 주의 — 이 뷰의 rp_total 합은 rp_rewards 원본 합보다 **작다**(실측 75,650 vs
-- 81,650). 버그가 아니다: rp_rewards.device_id 는 ON DELETE SET NULL 이라(reward_grants 는
-- CASCADE) 탈퇴한 유저의 정산 기록이 device_id=NULL 로 남는다. 유저별 뷰는 그 행을 누구에게도
-- 귀속시킬 수 없다. 현재 고아는 2건(2099-00 캠페인 3000RP ×2, 수령 완료).
-- VP·코인·시상대는 원본과 정확히 일치한다.
--
-- 보안 — 20260716000000 / 20260810000000 의 결론 그대로: security_invoker = true +
-- anon/authenticated REVOKE + service_role GRANT. 신규 뷰라 기존 뷰 재정의는 없다.
CREATE VIEW admin_user_earnings AS
SELECT
    u.device_id,
    u.nickname,
    u.tenant_id,
    u.status,
    u.registered_at,
    u.last_submitted_at,

    -- ── VP (랭킹 점수) — 서버가 진실을 안다 ────────────────────────────────
    u.total_coins                                        AS vp_total,
    COALESCE(s.submitted_sum, 0)                         AS vp_submitted_raw,
    -- 제출했으나 반영되지 않은 양 = 캡으로 깎인 분 + 거부된 제출의 delta 합.
    -- 둘을 가르려면 submissions_capped / submissions_rejected 를 함께 볼 것.
    COALESCE(s.submitted_sum, 0) - COALESCE(s.accepted_sum, 0) AS vp_trimmed,
    COALESCE(s.submissions, 0)                           AS submissions,
    COALESCE(s.rejected, 0)                              AS submissions_rejected,
    COALESCE(s.capped, 0)                                AS submissions_capped,
    s.first_submitted_at,

    -- ── RP — 전부 서버 지급 ────────────────────────────────────────────────
    COALESCE(r.rp_monthly, 0)                            AS rp_monthly,
    COALESCE(r.rp_weekly, 0)                             AS rp_weekly,
    -- sentinel period(2026-00·2099-00 등) = 캠페인/보상 지급. 정기 정산과 섞지 않는다.
    COALESCE(r.rp_campaign, 0)                           AS rp_campaign,
    COALESCE(g.rp_granted, 0)                            AS rp_ops_granted,
    COALESCE(r.rp_monthly, 0) + COALESCE(r.rp_weekly, 0)
      + COALESCE(r.rp_campaign, 0) + COALESCE(g.rp_granted, 0) AS rp_total,
    COALESCE(r.rp_unclaimed, 0) + COALESCE(g.rp_unclaimed, 0)  AS rp_unclaimed,

    -- ── 가챠 코인 — 서버 지급분만. 사용량 적립분은 서버에 없다 ──────────────
    COALESCE(g.coin_granted, 0)                          AS coin_ops_granted,
    COALESCE(w.coin_podium, 0)                           AS coin_podium,
    COALESCE(g.coin_granted, 0) + COALESCE(w.coin_podium, 0)   AS coin_server_total,
    COALESCE(g.coin_unclaimed, 0) + COALESCE(w.coin_unclaimed, 0) AS coin_unclaimed,
    -- 클라 자가 보고 — 서버가 검증하지 못하는 값이다. 위 coin_server_total 과 더하지 말 것.
    NULLIF(u.profile_json #>> '{stats,coinsTotalEarned}', '')::BIGINT AS coin_client_earned,
    NULLIF(u.profile_json #>> '{backup,coins}', '')::BIGINT           AS coin_client_balance,

    -- ── 시상대 ─────────────────────────────────────────────────────────────
    COALESCE(w.podiums, 0)                               AS podiums

FROM users u
LEFT JOIN LATERAL (
    SELECT COUNT(*)                                             AS submissions,
           SUM(sub.delta_coins)                                 AS submitted_sum,
           SUM(sub.accepted_coins) FILTER (WHERE sub.accepted)  AS accepted_sum,
           COUNT(*) FILTER (WHERE NOT sub.accepted)             AS rejected,
           COUNT(*) FILTER (WHERE sub.cap_applied)              AS capped,
           MIN(sub.submitted_at)                                AS first_submitted_at
    FROM submissions sub WHERE sub.device_id = u.device_id
) s ON TRUE
LEFT JOIN LATERAL (
    SELECT
        SUM(rr.rp_amount) FILTER (
            WHERE rr.period_type = 'monthly'
              AND rr.period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$')      AS rp_monthly,
        SUM(rr.rp_amount) FILTER (WHERE rr.period_type = 'weekly') AS rp_weekly,
        SUM(rr.rp_amount) FILTER (
            WHERE rr.period_type = 'monthly'
              AND rr.period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$')      AS rp_campaign,
        SUM(rr.rp_amount) FILTER (WHERE rr.claimed_at IS NULL)     AS rp_unclaimed
    FROM rp_rewards rr WHERE rr.device_id = u.device_id
) r ON TRUE
LEFT JOIN LATERAL (
    SELECT
        SUM(rg.amount) FILTER (WHERE rg.currency = 'rp')          AS rp_granted,
        SUM(rg.amount) FILTER (WHERE rg.currency = 'coin')        AS coin_granted,
        SUM(rg.amount) FILTER (WHERE rg.currency = 'rp'   AND rg.claimed_at IS NULL) AS rp_unclaimed,
        SUM(rg.amount) FILTER (WHERE rg.currency = 'coin' AND rg.claimed_at IS NULL) AS coin_unclaimed
    FROM reward_grants rg WHERE rg.device_id = u.device_id
) g ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)                                                       AS podiums,
           SUM(mw.reward_coins)                                           AS coin_podium,
           SUM(mw.reward_coins) FILTER (WHERE mw.reward_claimed_at IS NULL) AS coin_unclaimed
    FROM monthly_winners mw WHERE mw.device_id = u.device_id
) w ON TRUE;

ALTER VIEW admin_user_earnings SET (security_invoker = true);
REVOKE ALL ON admin_user_earnings FROM anon, authenticated;
GRANT SELECT ON admin_user_earnings TO service_role;
