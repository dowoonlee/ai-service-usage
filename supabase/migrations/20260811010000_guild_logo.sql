-- 길드 로고 (66×44 도트, 3:2 — 국기에서 가장 흔한 비율)
--
-- 저장 형식은 한 컬럼에 두 가지를 접두사로 구분해 담는다 (office_furniture와 같은 방식):
--   's:<0..9>'   샘플 로고 — 클라이언트가 절차적으로 그리므로 인덱스만 저장
--   'p:<base64>' 커스텀 로고 — 사용자 업로드분을 66×44로 픽셀화한 PNG (상한 8KB)
--
-- 샘플을 인덱스로만 두는 이유: 대부분의 길드가 기본 로고를 쓰는데 그때마다 2KB짜리
-- base64를 DB·리더보드 응답·HMAC canonical에 실어 나를 이유가 없다.

alter table guilds add column if not exists logo text;

-- 기존 길드에 샘플 로고 무작위 배정 (길드장이 나중에 바꿀 수 있다).
-- hashtext는 id마다 안정적이라 재실행해도 같은 값이 나온다 — 멱등.
update guilds
   set logo = 's:' || (abs(hashtext(id::text)) % 10)::text
 where logo is null;

-- 리더보드/길드 목록이 로고를 함께 내려주도록 뷰에 컬럼 추가.
-- CREATE OR REPLACE VIEW는 컬럼을 맨 뒤에 붙이는 것만 허용하므로 logo를 마지막에 둔다.
create or replace view guild_monthly_scores as
 SELECT g.id AS guild_id,
    g.tenant_id,
    g.name,
    g.created_at,
    COALESCE(s.score, 0::numeric)::bigint AS score,
    COALESCE(mc.member_count, 0::bigint)::integer AS member_count,
    row_number() OVER (PARTITION BY g.tenant_id ORDER BY (COALESCE(s.score, 0::numeric)) DESC, g.created_at) AS rank,
    g.logo
   FROM guilds g
     LEFT JOIN ( SELECT guild_member_monthly_vp.guild_id,
            sum(guild_member_monthly_vp.monthly_vp) FILTER (WHERE guild_member_monthly_vp.rn <= 5) AS score
           FROM guild_member_monthly_vp
          GROUP BY guild_member_monthly_vp.guild_id) s ON s.guild_id = g.id
     LEFT JOIN ( SELECT guild_members.guild_id,
            count(*) AS member_count
           FROM guild_members
          GROUP BY guild_members.guild_id) mc ON mc.guild_id = g.id;
