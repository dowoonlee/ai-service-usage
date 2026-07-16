-- 보안 감사(2026-07-16) 대응 — 뷰 RLS 우회 차단 + 부수 하드닝.
--
-- 1) SECURITY DEFINER 뷰 4개 → security_invoker 전환.
--    모든 테이블은 RLS enabled + 정책 0개로 anon 직접 접근이 차단되어 있으나,
--    뷰는 기본적으로 소유자(postgres) 권한으로 실행되어 하부 테이블 RLS를 우회한다
--    (Supabase lint 0010_security_definer_view, 어드바이저 ERROR 4건 확인).
--    특히 monthly_leaderboard는 device_id + 원시 profile_json(backup blob 포함)을
--    노출하므로 anon 키만으로 전 사용자 백업 덤프가 가능했다.
--    security_invoker = true 로 바꾸면 호출자 권한으로 RLS가 적용되어
--    anon은 하부 테이블 정책 부재로 0행, Edge Function(service_role)은 무영향.
ALTER VIEW monthly_leaderboard      SET (security_invoker = true);
ALTER VIEW device_medals            SET (security_invoker = true);
ALTER VIEW guild_member_monthly_vp  SET (security_invoker = true);
ALTER VIEW guild_monthly_scores     SET (security_invoker = true);

-- 심층 방어 — invoker 전환과 별개로 anon/authenticated의 뷰 SELECT 권한 자체를 회수.
--   (향후 뷰를 DROP+CREATE로 재정의하면 reloption이 초기화되므로,
--    재정의하는 마이그레이션은 반드시 security_invoker + REVOKE를 함께 복원할 것.)
REVOKE SELECT ON monthly_leaderboard, device_medals, guild_member_monthly_vp, guild_monthly_scores
    FROM anon, authenticated;

-- 2) plpgsql 함수 search_path 고정 (lint 0011_function_search_path_mutable WARN 5건).
--    전부 SECURITY INVOKER라 실위험은 낮지만, 호출 role의 search_path에 따라
--    다른 스키마의 동명 객체로 바인딩될 여지를 제거한다.
ALTER FUNCTION finalize_previous_month_if_needed()      SET search_path = public;
ALTER FUNCTION finalize_weekly_rp_if_needed()           SET search_path = public;
ALTER FUNCTION finalize_monthly_rp_if_needed()          SET search_path = public;
ALTER FUNCTION finalize_monthly_guild_rp_if_needed()    SET search_path = public;
ALTER FUNCTION apply_tenant_switch(UUID, TEXT)          SET search_path = public;
ALTER FUNCTION guild_member_exit_fixup()                SET search_path = public;

-- 3) dm-inbox "sent" 탭 쿼리(sender_device 필터 + created_at DESC 정렬) 전용 인덱스.
--    기존 direct_messages_thread_idx (sender_device, recipient_device, created_at)는
--    중간 컬럼에 조건이 없어 정렬을 인덱스만으로 보장하지 못한다.
CREATE INDEX direct_messages_sent_idx ON direct_messages (sender_device, created_at DESC);

-- 4) codex-sample IP rate-limit 지원 — 유일한 완전 미인증 쓰기 경로(HMAC/등록 검증 없음,
--    설계상 의도)가 요청당 최대 65KB를 무제한 INSERT할 수 있었다(스토리지/비용 abuse).
--    register_attempts와 동일하게 IP를 1차 방어선으로 쓰되, 별도 테이블 대신 샘플 행에
--    IP를 실어 rolling window 카운트한다. IP는 rate-limit 용도로만 사용.
ALTER TABLE codex_usage_samples ADD COLUMN client_ip TEXT;
CREATE INDEX codex_usage_samples_ip_time ON codex_usage_samples (client_ip, created_at DESC);
