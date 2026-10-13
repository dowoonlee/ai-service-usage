-- v0.18: 길드 가구 보관함·배치 프리셋. 기존 가구는 첫 편집에서 원자적으로 이전한다.
-- office_furniture는 방문/구버전 조회용 배치 문자열을 유지한다.
-- 기존 guilds의 RLS(anon/authenticated 직접 접근 거부)와 service_role 경로를 그대로 따른다.
ALTER TABLE public.guilds
    ADD COLUMN office_studio JSONB,
    ADD COLUMN office_revision BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT guild_office_revision_nonnegative CHECK (office_revision >= 0),
    ADD CONSTRAINT guild_office_studio_shape CHECK (
        office_studio IS NULL OR (
            jsonb_typeof(office_studio) = 'object'
            AND octet_length(office_studio::text) <= 120000
        )
    );
COMMENT ON COLUMN public.guilds.office_studio IS '가구 소유 인스턴스와 프리셋. null은 기존 office_furniture에서 첫 저장 시 이전.';
COMMENT ON COLUMN public.guilds.office_revision IS '가구·보관함·프리셋 전체에 대한 낙관적 동시 수정 검사 버전.';
