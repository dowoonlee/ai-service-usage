-- 길드 로고 위치 (사무실 벽에서 드래그로 이동)
--
-- 로고를 벽 좌상단에 고정해 뒀더니 창문·액자와 겹쳐 배치가 어색했다. 가구처럼 재배치 모드에서
-- 드래그로 옮길 수 있게 좌표를 저장한다.
--
-- 좌표계는 가구와 동일한 씬 논리 좌표(280×150)이고, 값은 로고 **중심**이다.
-- (가구는 x=중심/y=baseline이지만 로고는 벽에 걸린 판이라 중심 기준이 다루기 쉽다.)
-- NULL이면 클라이언트 기본 위치를 쓴다 — 기존 길드는 마이그레이션 없이 그대로 동작한다.

alter table guilds add column if not exists logo_x smallint;
alter table guilds add column if not exists logo_y smallint;

-- 벽 밴드(y 0..60) 밖으로 새는 값을 DB 차원에서도 막는다. 서버 검증(guild_policy.ts)과 쌍이며,
-- 클라 클램프까지 3중이지만 좌표는 한 번 어긋나면 화면 밖으로 사라져 복구가 번거로우니 남겨 둔다.
alter table guilds drop constraint if exists guilds_logo_pos_range;
alter table guilds add constraint guilds_logo_pos_range check (
  (logo_x is null or (logo_x >= 0 and logo_x <= 280)) and
  (logo_y is null or (logo_y >= 0 and logo_y <= 60))
);
