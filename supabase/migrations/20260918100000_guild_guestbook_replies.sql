-- 길드 방명록 답글 (docs/plans/guild-visit.md M3)
--
-- 방명록 한 줄 아래 1단 답글. 권한은 그 길드 멤버(집주인) + 원글 작성자 — Edge Function이 판정.
--
-- 디자인 노트:
--   * entry_id ON DELETE CASCADE — 원글이 지워지면 답글도 함께. guild_id는 원글에서 유도되지만
--     "이 길드에 새 활동" 배지 조회를 조인 없이 하려고 비정규화해 둔다(guilds CASCADE도 그대로).
--   * entry_author_device_id도 비정규화 — 방문자 배지("내가 쓴 방명록에 답글")를 sync에서
--     단일 테이블 필터 한 방으로 뽑기 위해서다. sync는 전 사용자가 600s마다 치므로 조인을 아낀다.
--   * 쿨다운(30s)은 마지막 답글 시각으로 Edge가 판정 — 댓글(board_post_comments)과 같은 방식.
--   * RLS 활성 + 정책 없음.

create table guild_guestbook_replies (
    id                        bigserial primary key,
    entry_id                  bigint not null references guild_guestbook(id) on delete cascade,
    guild_id                  uuid not null references guilds(id) on delete cascade,
    entry_author_device_id    uuid,                                     -- 원글 작성자 (탈퇴 시 그대로 두어도 무해)
    author_device_id          uuid references users(device_id) on delete set null,
    author_nickname_snapshot  text not null,
    author_pet_kind           text,
    author_pet_variant        smallint not null default 0,
    content                   text not null,
    tenant_id                 text not null default 'public' references tenants(slug),
    created_at                timestamptz not null default now(),
    constraint guild_guestbook_replies_content_length check (char_length(content) between 1 and 60)
);

-- 원글별 시간순 (방문 응답: 원글당 최근 N개).
create index guild_guestbook_replies_entry_time on guild_guestbook_replies (entry_id, created_at);
-- 방문자 배지: 내 원글에 달린 답글 최신순 (sync).
create index guild_guestbook_replies_entry_author_time
    on guild_guestbook_replies (entry_author_device_id, created_at desc);
-- 작성자 쿨다운: 내가 쓴 마지막 답글.
create index guild_guestbook_replies_author_time
    on guild_guestbook_replies (author_device_id, created_at desc);

alter table guild_guestbook_replies enable row level security;
