-- 펫 메타데이터 — 이름/대사/설명 (전 사용자 공통, read-only public 콘텐츠).
--
-- 디자인 노트:
--   * PK `kind`는 클라이언트 PetKind.rawValue ("fox", "jellySlime", ...) — 1:1 매핑.
--   * 텍스트 콘텐츠만 저장. 등급(tier)/스프라이트 렌더 메타는 클라 코드에 고정(서버로 안 옴).
--   * 클라는 feature flag(experimentalRemotePetMeta)가 켜졌을 때만 이 값을 override로 사용.
--     DB에 없는 kind / flag off / 네트워크 실패 → 클라 하드코딩 fallback. 즉 이 테이블이
--     비어 있어도 앱은 정상 동작.
--   * 운영자만 INSERT/UPDATE (수동 큐레이션 또는 seed 스크립트). 클라는 read-only.
--   * RLS 활성 + 정책 없음 → anon 직접 접근 차단. 모든 read는 Edge Function(service_role) 경유
--     (기존 leaderboard/board와 동일 패턴).

CREATE TABLE pet_metadata (
    kind         TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    description  TEXT NOT NULL,
    quotes       JSONB NOT NULL DEFAULT '[]'::jsonb,   -- ["대사1","대사2",...]
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pet_metadata_kind_not_empty   CHECK (LENGTH(kind) > 0),
    CONSTRAINT pet_metadata_display_not_empty CHECK (LENGTH(display_name) > 0),
    CONSTRAINT pet_metadata_quotes_is_array   CHECK (jsonb_typeof(quotes) = 'array')
);

ALTER TABLE pet_metadata ENABLE ROW LEVEL SECURITY;
-- 명시적 정책 없음 → anon 차단. Edge Function(service_role)만 접근.
