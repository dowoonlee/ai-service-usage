-- 길드 방명록 (docs/plans/guild-visit.md M2)
--
-- 다른 길드 사무실에 놀러가서 한 줄 남기는 기능. 게시판(board_posts)과 달리 비익명 —
-- 작성자 닉네임·소속 길드명·대표 펫을 스냅샷으로 동결한다 (길드 표면은 실명 관례).
--
-- 디자인 노트:
--   * guild_id ON DELETE CASCADE — 길드 해체 시 방명록도 함께 사라진다(trigger 없이 DDL로).
--   * 쿨다운은 별도 테이블(guild_guestbook_writes) — 글을 지워도 쿨다운이 살아남아야 한다.
--     users.last_post_at이 존재하는 이유와 같다(작성→삭제→재작성 우회 차단).
--   * 전역 쿨다운(10분)은 users.last_guestbook_at, 길드별 쿨다운(24h)은 writes 테이블.
--   * guilds.last_guestbook_at은 sync 배지용 — "내 길드에 새 방명록" 신호를 count 없이 스칼라로.
--   * RLS 활성 + 정책 없음 → anon 직접 접근 불가. 모든 read/write는 Edge Function(service_role).

create table guild_guestbook (
    id                          bigserial primary key,
    guild_id                    uuid not null references guilds(id) on delete cascade,
    author_device_id            uuid references users(device_id) on delete set null,
    author_nickname_snapshot    text not null,
    author_guild_name_snapshot  text,                       -- 작성 시점 소속 길드명 (무소속이면 null)
    author_pet_kind             text,                       -- 대표 펫 스냅샷 (PetKind.rawValue)
    author_pet_variant          smallint not null default 0,
    content                     text not null,
    tenant_id                   text not null default 'public' references tenants(slug),
    created_at                  timestamptz not null default now(),
    constraint guild_guestbook_content_length check (char_length(content) between 1 and 60)
);

-- 길드별 최신순 조회 hot path (최근 30개 LIMIT).
create index guild_guestbook_guild_time on guild_guestbook (guild_id, created_at desc);
alter table guild_guestbook enable row level security;

-- (작성자, 길드)별 마지막 작성 시각 — 24h 쿨다운의 권위 source. 글 삭제와 무관하게 유지.
create table guild_guestbook_writes (
    device_id   uuid not null references users(device_id) on delete cascade,
    guild_id    uuid not null references guilds(id) on delete cascade,
    last_at     timestamptz not null default now(),
    primary key (device_id, guild_id)
);
alter table guild_guestbook_writes enable row level security;

alter table users  add column if not exists last_guestbook_at timestamptz;
alter table guilds add column if not exists last_guestbook_at timestamptz;

-- 방명록 1건 작성 — 전역 쿨다운·길드별 쿨다운·insert·배지 갱신을 한 트랜잭션에서.
--
-- 두 쿨다운 모두 "조건부 한 문장"으로 선점한다(read-modify-write 금지 — CLAUDE.md).
-- 어느 하나라도 실패하면 RAISE EXCEPTION으로 함수 전체가 롤백돼 먼저 선점한 쿨다운도 되돌아간다
-- (RETURN으로 빠지면 앞선 UPDATE가 남아 실패한 시도가 전역 쿨다운을 소모한다).
-- 예외 메시지 형식 '<code>:<retryAfterSec>' — 호출부(Edge Function)가 파싱해 429/403으로 매핑.
create or replace function guild_guestbook_write(
    p_device               uuid,
    p_guild                uuid,
    p_tenant               text,
    p_content              text,
    p_nickname             text,
    p_guild_name           text,
    p_pet_kind             text,
    p_pet_variant          integer,
    p_guild_cooldown_sec   integer,
    p_global_cooldown_sec  integer
) returns table (out_id bigint, out_created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_last     timestamptz;
    v_id       bigint;
    v_created  timestamptz;
begin
    -- 전역 쿨다운 (users.last_guestbook_at).
    update users
       set last_guestbook_at = now()
     where device_id = p_device
       and (last_guestbook_at is null
            or last_guestbook_at <= now() - make_interval(secs => p_global_cooldown_sec));
    if not found then
        select last_guestbook_at into v_last from users where device_id = p_device;
        raise exception 'rate_limited:%',
            greatest(1, ceil(extract(epoch from
                (v_last + make_interval(secs => p_global_cooldown_sec) - now()))))::integer;
    end if;

    -- 길드별 쿨다운 (guild_guestbook_writes) — ON CONFLICT의 WHERE에 걸리면 행이 없다.
    insert into guild_guestbook_writes (device_id, guild_id, last_at)
    values (p_device, p_guild, now())
    on conflict (device_id, guild_id) do update
       set last_at = now()
     where guild_guestbook_writes.last_at <= now() - make_interval(secs => p_guild_cooldown_sec);
    if not found then
        select last_at into v_last
          from guild_guestbook_writes
         where device_id = p_device and guild_id = p_guild;
        raise exception 'guestbook_cooldown:%',
            greatest(1, ceil(extract(epoch from
                (v_last + make_interval(secs => p_guild_cooldown_sec) - now()))))::integer;
    end if;

    insert into guild_guestbook (
        guild_id, author_device_id, author_nickname_snapshot, author_guild_name_snapshot,
        author_pet_kind, author_pet_variant, content, tenant_id
    ) values (
        p_guild, p_device, p_nickname, p_guild_name,
        p_pet_kind, coalesce(p_pet_variant, 0), p_content, p_tenant
    )
    returning guild_guestbook.id, guild_guestbook.created_at into v_id, v_created;

    update guilds set last_guestbook_at = v_created where guilds.id = p_guild;

    return query select v_id, v_created;
end;
$$;

-- ⚠️ security definer 함수는 생성 시 PUBLIC에 EXECUTE가 붙는다. anon key는 앱 번들에 든 공개값이라
-- 이대로 두면 누구나 임의 device로 방명록을 쓸 수 있다. Edge Function(service_role)만 호출하도록
-- 좁힌다 — public을 빼먹으면 REVOKE가 무효다(20260819020000 교훈).
revoke all on function guild_guestbook_write(uuid, uuid, text, text, text, text, text, integer, integer, integer)
    from public, anon, authenticated;
grant execute on function guild_guestbook_write(uuid, uuid, text, text, text, text, text, integer, integer, integer)
    to service_role;
