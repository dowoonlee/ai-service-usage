-- 사용자별 클라이언트 버전 텔레메트리.
--
-- 목적: "어떤 버전을 쓰는지" 분포 파악 + 이슈 응대 시 "이 사람 구버전 아냐?" 즉답.
--   예) SELECT app_version, count(*) FROM users WHERE status='active' GROUP BY 1 ORDER BY 2 DESC;
--
-- 수집 경로: submit Edge Function이 매 제출마다 갱신 (display data, HMAC 서명 대상 아님).
--   register(첫 등록)에서는 보내지 않음 — submit이 곧바로 따라오므로 '현재 버전'은 submit이 truth.
--   기존 사용자는 NULL → 다음 submit에서 채워짐.
--
-- app_version: CFBundleShortVersionString (예: "0.11.4"). dev 실행(번들 없음)은 NULL.
-- os_version:  macOS major.minor.patch (예: "14.4.1"). build 번호는 분포 over-fragment 방지 위해 제외.

ALTER TABLE users ADD COLUMN app_version TEXT;
ALTER TABLE users ADD COLUMN os_version  TEXT;
