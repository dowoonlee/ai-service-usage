-- Codex(OpenAI) wham/usage 파싱 검증용 익명 샘플 수집 (이슈 #36).
--
-- 배경: 개발 환경이 Codex free 계정이라 Plus/Pro의 5h+7d 동시 케이스를 실응답으로 검증하지
-- 못했다. 배포 전 Plus/Pro 사용자가 "진단 제출" 버튼으로 자기 응답 구조를 익명 제출해주면,
-- 파서가 실제로 맞는지(틀리면 어떤 구조로 오는지) 확정할 수 있다.
--
-- 프라이버시: PII(email/user_id)·잔액(credits.balance)은 클라이언트에서 제거 후 전송한다.
-- 여기엔 rate_limit window 구조 + plan_type + 우리 파서 결과만 들어온다.
--
-- RLS enable + 정책 없음 → anon 직접 접근 불가, Edge Function(service_role) 경유만 (board 패턴과 동일).

CREATE TABLE codex_usage_samples (
    id           BIGSERIAL PRIMARY KEY,
    device_id    TEXT,                    -- 익명 식별자 (랭킹 deviceID 또는 미등록 시 null). FK 없음 — 미등록자도 제출 가능.
    app_version  TEXT,
    plan_type    TEXT,                    -- "plus" / "pro" / "free" 등 (PII 아님)
    rate_limit   JSONB,                   -- redact된 rate_limit 객체 (primary/secondary window 구조 원본 — 새 필드 감지용)
    parsed       JSONB,                   -- 우리 파서 결과 {fiveHourPct, sevenDayPct, monthlyPct} — 원본 구조와 대조
    raw_top_keys TEXT[],                  -- 응답 최상위 키 목록 (스키마 드리프트/새 필드 감지)
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX codex_usage_samples_created ON codex_usage_samples (created_at DESC);

ALTER TABLE codex_usage_samples ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon 직접 거부. 모든 write는 Edge Function(service_role) 경유.
