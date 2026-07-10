-- 멀티테넌시 — 테넌트 편입 시 '리더 혼자인 길드'는 길드째 이동. 20260710000000_tenant_switch_rpc.sql 개정.
--
-- 기존: 타 테넌트 길드는 무조건 개인 탈퇴 → 리더 혼자였던 길드는 exit 트리거가 해체(길드 소멸).
--       사용자 관점에선 "인증했더니 내 길드가 사라졌다".
-- 개정: 멤버가 리더 혼자(1명)이고 목표 테넌트에 동명 길드가 없으면, 탈퇴 대신 guilds.tenant_id를
--       새 테넌트로 UPDATE해 길드가 유저를 따라 이동한다. 혼자라 cross-tenant 멤버 오염이 없어 안전.
--       멤버 2명 이상(또는 동명 충돌)은 기존대로 개인만 탈퇴(트리거가 승계/해체) — 다른 테넌트 멤버를
--       원치 않게 끌고 가거나 UNIQUE(tenant_id, name_normalized)를 위반하지 않게.
-- device당 최대 1길드(guild_members.device_id UNIQUE)라 대상은 0~1개.

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

    -- (a) 리더 혼자(멤버 1명)인 타 테넌트 길드는 길드째 새 테넌트로 이동. 단, 목표 테넌트에 동명
    --     길드가 있으면 guilds_tenant_name_uniq(tenant_id, name_normalized) 위반이라 이동을
    --     건너뛰고 아래 (b)에서 탈퇴로 처리한다.
    UPDATE guilds g
        SET tenant_id = p_tenant
        FROM guild_members gm
        WHERE gm.device_id = p_device
          AND gm.guild_id = g.id
          AND g.tenant_id <> p_tenant
          AND (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id) = 1
          AND NOT EXISTS (
              SELECT 1 FROM guilds g2
              WHERE g2.tenant_id = p_tenant
                AND g2.name_normalized = g.name_normalized
          );

    -- (b) (a)에서 이동되지 않은 타 테넌트 길드에서는 개인만 탈퇴 — 트리거가 리더 승계/해체.
    --     이동된 길드는 이미 tenant_id = p_tenant라 아래 조건에 걸리지 않는다.
    DELETE FROM guild_members gm
        USING guilds g
        WHERE gm.device_id = p_device
          AND gm.guild_id = g.id
          AND g.tenant_id <> p_tenant;

    UPDATE users SET tenant_id = p_tenant WHERE device_id = p_device;
    RETURN 'ok';
END;
$$ LANGUAGE plpgsql;
