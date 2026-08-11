-- 테넌트 재인증 + 인증 이력 로그.
--
-- 배경: 게시판 어뷰징 대응 과정에서 작성자를 식별할 수단이 device_id뿐이라는 게 드러났다.
-- 기존 설계(docs/plans/tenant.md §2 [D8])는 이메일을 저장하지 않았기 때문에 인증을 통과한
-- 계정조차 실제 신원과 연결할 수 없었다. 운영자 결정으로 D8을 뒤집고, 인증 시점의 이메일을
-- 이력으로 남긴다.
--
-- ⚠️ 개인정보 수집 항목이 늘어나는 변경이다. 앱 처리방침에 "소속 인증 이메일" 항목과 보관
--    기간을 함께 반영해야 한다(고지 없이 수집만 켜면 안 됨).
--
-- 소급 불가: 기존 인증자들의 이메일은 애초에 저장된 적이 없어 복원할 수 없다. 그래서 기존
-- 게이트 사용자 전원에게 재인증을 요구하고, 재인증 시점부터 이력이 쌓인다.

-- ===========================================================================
-- 1) 재인증 요구 — 유예 기한 방식
-- ===========================================================================
-- NULL           = 재인증 불필요(정상)
-- 미래 timestamp = 재인증 대상. 기한까지는 기존 테넌트 권한을 그대로 쓴다(유예).
-- 과거 timestamp = 기한 만료. resolveTenant가 기본 테넌트로 강등 → 게이트 콘텐츠 접근 차단.
--
-- tenant_id를 즉시 되돌리지 않는 이유: 길드 소속·랭킹 귀속이 함께 깨지고, 재인증하면 어차피
-- 원상 복구되는 왕복이 된다. 플래그만 세우면 유예 중 데이터는 손대지 않아도 된다.
ALTER TABLE users ADD COLUMN IF NOT EXISTS tenant_reverify_due_at TIMESTAMPTZ;

COMMENT ON COLUMN users.tenant_reverify_due_at IS
    '테넌트 재인증 기한. NULL=불필요, 미래=유예중, 과거=만료(기본 테넌트로 강등)';

-- 만료 판정이 모든 상호작용 함수의 resolveTenant에서 매번 돌아가므로 부분 인덱스로 받쳐준다.
CREATE INDEX IF NOT EXISTS users_reverify_due
    ON users (tenant_reverify_due_at)
    WHERE tenant_reverify_due_at IS NOT NULL;

-- ===========================================================================
-- 2) 인증 이력 로그 — 신원 확인용 (D8 예외)
-- ===========================================================================
-- append-only. 인증에 성공한 건만 기록한다(실패 시도는 남기지 않음 — 남의 이메일을 적어
-- 넣고 실패한 기록까지 쌓으면 무관한 사람의 주소를 보관하게 된다).
CREATE TABLE IF NOT EXISTS tenant_verification_log (
    id           BIGSERIAL PRIMARY KEY,
    device_id    UUID NOT NULL,                  -- FK 없음: 계정 삭제 후에도 이력은 보존
    tenant_slug  TEXT NOT NULL REFERENCES tenants(slug),
    email        TEXT NOT NULL,                  -- 인증에 실제로 사용된 주소(평문 — 신원 확인 목적)
    is_reverify  BOOLEAN NOT NULL DEFAULT FALSE, -- 최초 편입 vs 재인증 구분
    verified_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- device_id → 최근 인증 이력 (게시글 작성자 역추적의 진입점).
CREATE INDEX IF NOT EXISTS tenant_verification_log_device
    ON tenant_verification_log (device_id, verified_at DESC);
-- 이메일 → 그 사람이 쓰는 device 목록 (한 사람이 여러 기기를 등록한 경우 확인).
CREATE INDEX IF NOT EXISTS tenant_verification_log_email
    ON tenant_verification_log (LOWER(email));

-- ===========================================================================
-- 3) OTP에 이메일 — request → confirm 전달 매개
-- ===========================================================================
-- 이메일은 request 단계에서만 들어오고 confirm payload엔 없다(코드만 보냄). 인증 성공 시점에
-- 주소를 알아야 로그를 남길 수 있으므로 OTP row에 잠시 얹어 둔다.
-- confirm이 로그로 옮긴 뒤 NULL로 지운다 → 이 컬럼에 값이 남아 있는 건 미완료 OTP뿐이고,
-- 완료된 인증의 주소는 tenant_verification_log 한 곳에만 존재한다.
ALTER TABLE tenant_otp ADD COLUMN IF NOT EXISTS email TEXT;

COMMENT ON COLUMN tenant_otp.email IS
    'confirm에서 로그 이관 후 NULL 처리되는 임시 보관 필드. 완료된 인증의 SSOT는 tenant_verification_log';

-- ===========================================================================
-- 4) RLS — Edge Function(service_role) 경유만 허용. 기존 tenant_* 테이블과 동일.
-- ===========================================================================
ALTER TABLE tenant_verification_log ENABLE ROW LEVEL SECURITY;
