-- 패치 공지(announcements) — 버전별 패치노트.
--
-- 업데이트 후 첫 실행 시 클라이언트가 (직전 본 버전, 현재 버전] 구간의 활성 공지를 받아
-- 별도 창으로 표시한다. deviceId 불필요, 읽기 전용 public 콘텐츠.
--
-- 디자인 노트:
--   * PK `version`은 클라이언트 CFBundleShortVersionString ("0.14.0") — semver 텍스트.
--     비교는 Edge Function(cmpVersion)/클라(Announcements.compare)가 숫자 컴포넌트로 수행.
--   * 운영자만 INSERT/UPDATE (릴리스 때 수동 또는 스크립트 큐레이션). 클라는 read-only.
--   * is_active=false 면 표시 제외 — 삭제 없이 숨김.
--   * RLS 활성 + 정책 없음 → anon 직접 접근 차단. 모든 read는 Edge Function(service_role) 경유
--     (pet_metadata/leaderboard와 동일 패턴).
--   * 이 테이블이 비어 있거나 fetch 실패해도 앱은 정상 동작 — 공지만 안 뜬다.

CREATE TABLE announcements (
    version       TEXT PRIMARY KEY,
    title         TEXT NOT NULL,
    body          TEXT NOT NULL,                       -- 마크다운/플레인. 줄바꿈 보존, "- "는 불릿.
    published_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active     BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT announcements_version_not_empty CHECK (LENGTH(version) > 0),
    CONSTRAINT announcements_title_not_empty   CHECK (LENGTH(title) > 0),
    CONSTRAINT announcements_body_not_empty    CHECK (LENGTH(body) > 0)
);

ALTER TABLE announcements ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon 차단. Edge Function(service_role)만 접근.
