-- 통합 보상 지급(ops grant) — RP·코인을 하나의 per-device 미수령 원장으로 지급.
--
-- 배경: 기존엔 지급 경로가 통화별로 갈렸다.
--   * RP  → rp_rewards (per-device, 조용히 적립, 금액/인원 자유) — 깔끔.
--   * 코인 → monthly_winners podium 하나뿐 — UNIQUE(period,rank)로 period당 3명 제약 +
--            device_medals가 rank를 금/은/동으로 롤업(가짜 메달) + previousMonth 표시 오염 +
--            "명예의 전당 N등" 알림(가짜 달). 운영 지급용으론 부작용투성이.
-- 개정: 통화 무관 ops 지급을 위한 전용 테이블. rp_rewards의 깔끔한 per-device 흐름을 코인까지
--       확장한다. podium/정산/메달 기계와 완전히 분리 — 진짜 우승자 시상(monthly_winners)은
--       그대로 두고, "운영이 임의 통화를 임의 인원에게 지급"하는 경로만 일원화한다.
--
-- 전달 흐름(rp_rewards와 동일 패턴):
--   1) 서버가 미수령 행(claimed_at=NULL) INSERT.
--   2) 클라가 leaderboard 폴링 때 pendingGrant(가장 오래된 1건)로 수령.
--   3) 클라가 claim-reward(rewardType='grant')로 claim → 서버가 claimed_at 세팅(idempotent).
--      claim 성공(!alreadyClaimed) 시에만 통화별 로컬 원장에 크레딧 → 백업 복원에도 이중지급 없음.

CREATE TABLE reward_grants (
    id         BIGSERIAL PRIMARY KEY,
    device_id  UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    -- 'rp' → RankPointLedger, 'coin' → CoinLedger. 클라가 이 값으로 원장을 고른다.
    currency   TEXT NOT NULL CHECK (currency IN ('rp', 'coin')),
    amount     BIGINT NOT NULL CHECK (amount > 0),
    reason     TEXT NOT NULL DEFAULT '',   -- 운영 메모(지급 사유) — 표시 안 함, 감사용.
    -- dedup 키(캠페인/사유 슬러그). 클라 claim 서명의 period 슬롯에 실려 오므로 URL/서명-safe 문자만.
    -- 같은 사람에게 같은 캠페인 재지급 방지 = UNIQUE(device_id, grant_key). 재지급은 새 grant_key로.
    grant_key  TEXT NOT NULL CHECK (grant_key ~ '^[A-Za-z0-9._-]{1,64}$'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    claimed_at TIMESTAMPTZ,
    UNIQUE (device_id, grant_key)
);

-- 미수령 조회(leaderboard pendingGrant)용 부분 인덱스.
CREATE INDEX reward_grants_pending ON reward_grants (device_id, created_at)
    WHERE claimed_at IS NULL;

-- RLS — anon 전면 차단, Edge Function(service_role)만. (guild 테이블과 동일 정책·무정책.)
ALTER TABLE reward_grants ENABLE ROW LEVEL SECURITY;
