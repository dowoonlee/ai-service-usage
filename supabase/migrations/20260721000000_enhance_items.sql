-- 강화 완화 아이템 인벤토리 — 서버 SSOT (기획 §2-9 리스크 완화).
--
-- 강화 보호권(protect): 1회 파괴 방지(파괴→유지). 확정 강화권(guarantee): RNG 우회 확정 +1.
-- 둘 다 VP로 구매(서버 검증 sink) — pet-enhance 의 buy 액션이 VP 차감 + 카운트 증가를 원자 처리.
-- (시즌 보상·이벤트에서 카운트를 추가 지급하는 경로는 T6에서 같은 컬럼에 얹으면 됨.)
--
-- 가용 VP = ... − Σ pet_enhancements.spent_vp − enhance_items.spent_vp (아이템 구매분도 차감).

CREATE TABLE enhance_items (
    device_id       UUID     NOT NULL REFERENCES users(device_id) ON DELETE CASCADE PRIMARY KEY,
    protect_count   SMALLINT NOT NULL DEFAULT 0 CHECK (protect_count   >= 0),
    guarantee_count SMALLINT NOT NULL DEFAULT 0 CHECK (guarantee_count >= 0),
    spent_vp        BIGINT   NOT NULL DEFAULT 0 CHECK (spent_vp >= 0),   -- 아이템 구매 누적 VP(가용 산출)
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE enhance_items ENABLE ROW LEVEL SECURITY;
