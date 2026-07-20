-- 아레나(PvP) + 펫 강화 서버 스키마 — 기획 docs/plans/pet-battle.md §3.
--
-- 설계 축: 배틀 승패·강화 결과는 서버가 authoritative로 확정(클라 위조 불가). 강화 레벨(배틀
-- 파워 메인축)은 pet_enhancements 가 SSOT이고 서버 RNG(pet-enhance)로만 변동한다. 배틀은
-- pvp-challenge 가 결정적 시뮬(_shared/battle_engine.ts)로 확정한다.
--
-- 전 테이블 RLS ENABLE + 정책 0개(anon 차단, Edge Function service_role 전용) — reward_grants/
-- guild 테이블과 동일 관례. device_id 는 UUID(타입상 정규화)지만, Edge Function JS 비교 시엔
-- lowercase 정규화 필수(memory: ranking-deviceid-uuid-case).

-- ── 0) reward_grants 에 'vp' 통화 추가 (이벤트/보상 VP 지급 → 강화 가용 풀).
--    지급 VP는 가용 풀에만 들어가고 랭킹 점수엔 미반영(사용량 아니므로). 기존 dedup 파이프라인 재사용.
ALTER TABLE reward_grants DROP CONSTRAINT IF EXISTS reward_grants_currency_check;
ALTER TABLE reward_grants ADD  CONSTRAINT reward_grants_currency_check
    CHECK (currency IN ('rp', 'coin', 'vp'));

-- ── 1) 펫별 강화 레벨 — 서버 SSOT (배틀 스탯 메인 성장축, §2-9).
--    가용 VP = users.total_coins(제출VP) + granted_vp − SUM(spent_vp). pet-enhance 가 매 시도 재계산.
CREATE TABLE pet_enhancements (
    device_id   UUID     NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    kind        TEXT     NOT NULL,                                  -- PetKind rawValue
    level       SMALLINT NOT NULL DEFAULT 0 CHECK (level >= 0 AND level <= 15),  -- 서버 RNG로만 변동
    spent_vp    BIGINT   NOT NULL DEFAULT 0 CHECK (spent_vp >= 0), -- 누적 투입 VP(가용 산출·감사)
    fail_streak SMALLINT NOT NULL DEFAULT 0 CHECK (fail_streak >= 0), -- soft-pity 카운터(P2a)
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (device_id, kind)
);

-- ── 2) 등록된 배틀 팀 스냅샷 — 다른 유저의 도전 상대(고스트 방어 대상). §2-6.
--    team_json = [{kind, variant}] ×3 + 리드 순서. 강화 레벨은 등록 시점 pet_enhancements join해 동결.
CREATE TABLE pvp_teams (
    device_id  UUID    PRIMARY KEY REFERENCES users(device_id) ON DELETE CASCADE,
    tenant_id  TEXT    NOT NULL DEFAULT 'public' REFERENCES tenants(slug),  -- 매칭 파티션
    team_json  JSONB   NOT NULL,
    power      INTEGER NOT NULL,                    -- 매칭용 요약 전투력(서버가 강화 포함 재계산)
    rating     INTEGER NOT NULL DEFAULT 1000,       -- 캐시 미러(진실은 pvp_ratings)
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- 매칭: 같은 테넌트 · 유사 레이팅 상대 추출.
CREATE INDEX pvp_teams_tenant_rating ON pvp_teams (tenant_id, rating);

-- ── 3) 시즌 레이팅 (Elo, 1000 시작, 테넌트 스코프). §2-7.
CREATE TABLE pvp_ratings (
    device_id  UUID    PRIMARY KEY REFERENCES users(device_id) ON DELETE CASCADE,
    tenant_id  TEXT    NOT NULL DEFAULT 'public' REFERENCES tenants(slug),
    rating     INTEGER NOT NULL DEFAULT 1000,
    wins       INTEGER NOT NULL DEFAULT 0 CHECK (wins   >= 0),
    losses     INTEGER NOT NULL DEFAULT 0 CHECK (losses >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- 리더보드 정렬 — 테넌트별 레이팅 내림차순.
CREATE INDEX pvp_ratings_tenant_rating ON pvp_ratings (tenant_id, rating DESC);

-- ── 4) 매치 결과 감사 로그 — 재생용. challenger/defender/winner 는 FK 없는 UUID(상대 탈퇴해도
--    기록 보존, direct_messages.sender_device 선례). UUID 타입이라 대소문자 정규화는 자동 —
--    JS 비교 시엔 여전히 lowercase 정규화 필요(memory: ranking-deviceid-uuid-case). §3.
CREATE TABLE pvp_matches (
    id               UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        TEXT    NOT NULL DEFAULT 'public' REFERENCES tenants(slug),
    challenger       UUID    NOT NULL,               -- 도전자(FK 없음)
    defender         UUID    NOT NULL,               -- 방어자 고스트 소유자(FK 없음)
    seed             BIGINT  NOT NULL,               -- 결정적 시뮬 시드
    winner           UUID,                           -- 승자 device_id, NULL = 무승부
    challenger_delta INTEGER,
    defender_delta   INTEGER,
    log_json         JSONB,                          -- 배틀 로그(재생). 커지면 요약/TTL 삭제 검토.
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- 내 전적 조회(pvp-history) — 도전자/방어자 양방향.
CREATE INDEX pvp_matches_challenger ON pvp_matches (challenger, created_at DESC);
CREATE INDEX pvp_matches_defender   ON pvp_matches (defender,   created_at DESC);

-- ── 5) 일일 랭크전 제한 (device, KST 일자) 카운트. §2-7.
CREATE TABLE pvp_daily_counts (
    device_id UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE,
    kst_date  DATE NOT NULL,
    count     INTEGER NOT NULL DEFAULT 0 CHECK (count >= 0),
    PRIMARY KEY (device_id, kst_date)
);

-- RLS — 전부 anon 차단, Edge Function(service_role)만.
ALTER TABLE pet_enhancements  ENABLE ROW LEVEL SECURITY;
ALTER TABLE pvp_teams         ENABLE ROW LEVEL SECURITY;
ALTER TABLE pvp_ratings       ENABLE ROW LEVEL SECURITY;
ALTER TABLE pvp_matches       ENABLE ROW LEVEL SECURITY;
ALTER TABLE pvp_daily_counts  ENABLE ROW LEVEL SECURITY;
