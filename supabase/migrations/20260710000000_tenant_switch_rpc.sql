-- 멀티테넌시 P1 — 테넌트 편입(switch) 원자 처리 RPC. docs/plans/tenant.md §3-4.
--
-- tenant-verify-confirm이 OTP 검증에 성공하면 이 함수를 호출한다. one-way 게이트 편입:
--   * 현재가 기본(default) 테넌트일 때만 편입 허용 (이미 gated면 거부).
--   * 타 테넌트 길드에서 자동 탈퇴 — 승계/해체는 guild_member_exit_fixup 트리거가 처리(§2-4-1).
--   * status(밴)는 건드리지 않는다 — 전환으로 밴 회피 불가.
-- 반환: 'ok' | 'not_registered' | 'already_gated'.

CREATE OR REPLACE FUNCTION apply_tenant_switch(p_device UUID, p_tenant TEXT) RETURNS TEXT AS $$
DECLARE
    cur          TEXT;
    default_slug TEXT;
BEGIN
    -- 행 잠금 — 동시 confirm race 방지.
    SELECT tenant_id INTO cur FROM users WHERE device_id = p_device FOR UPDATE;
    IF cur IS NULL THEN
        RETURN 'not_registered';
    END IF;

    SELECT slug INTO default_slug FROM tenants WHERE is_default LIMIT 1;
    -- 기본 테넌트에서만 편입 가능(one-way). 이미 gated면 재편입 거부.
    IF cur <> default_slug THEN
        RETURN 'already_gated';
    END IF;

    -- 타 테넌트 길드에서 자동 탈퇴 (device당 최대 1길드라 사실상 0~1행). 트리거가 승계/해체 처리.
    DELETE FROM guild_members gm
        USING guilds g
        WHERE gm.device_id = p_device
          AND gm.guild_id = g.id
          AND g.tenant_id <> p_tenant;

    UPDATE users SET tenant_id = p_tenant WHERE device_id = p_device;
    RETURN 'ok';
END;
$$ LANGUAGE plpgsql;
