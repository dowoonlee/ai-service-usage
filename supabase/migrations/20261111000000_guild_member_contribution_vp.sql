-- 도장 Guild·Contribution 지표 소급 — 멤버별 "현재 길드 가입 이후" 누적 VP.
--
-- guild_member_monthly_vp는 이번 달만 내려줘서, 클라이언트가 v0.19.4에서 적립을 연결했을 때
-- 그 이전 달의 기여가 빠졌다. submissions에는 건별 이력이 그대로 남아 있으므로(보존 기한 없음)
-- 가입 시각(guild_members.joined_at) 이후의 accepted 합을 서버가 직접 계산해 준다.
--
--   - 경계는 가입 "시각"이다(월 시작이 아님) — 가입 전 제출은 이 길드에 대한 기여가 아니다.
--   - 탈퇴하면 guild_members 행이 사라지므로 이전 길드의 기여는 복원할 수 없다(현재 길드분만).
--   - shadow_banned/banned는 월간 뷰와 같은 취급(u.status = 'active')으로 행이 나오지 않는다.
--
-- guild-info가 호출자 본인 행만 device_id로 조회한다 — submissions_device_time 인덱스를 탄다.
CREATE VIEW guild_member_contribution_vp
WITH (security_invoker = true) AS
SELECT
    gm.guild_id,
    gm.device_id,
    COALESCE(SUM(s.accepted_coins), 0)::BIGINT AS contribution_vp
FROM guild_members gm
JOIN users u ON u.device_id = gm.device_id AND u.status = 'active'
LEFT JOIN submissions s ON s.device_id = gm.device_id
    AND s.accepted = TRUE
    AND s.submitted_at >= gm.joined_at
GROUP BY gm.guild_id, gm.device_id;

-- 20260716 보안 감사와 같은 심층 방어 — invoker + anon 계열 SELECT 회수.
REVOKE ALL ON guild_member_contribution_vp FROM public, anon, authenticated;
GRANT SELECT ON guild_member_contribution_vp TO service_role;
