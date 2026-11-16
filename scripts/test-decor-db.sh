#!/usr/bin/env bash
# Disposable PostgreSQL only; never connects to the linked Supabase database.
set -euo pipefail
cd "$(dirname "$0")/.."
decor_container="aiusage-decor-test-$$"
decor_tmp=$(mktemp -d /tmp/aiusage-decor-db.XXXXXX)
cleanup() { docker rm -fv "$decor_container" >/dev/null 2>&1 || true; rm -rf "$decor_tmp"; }
trap cleanup EXIT
docker run -d --pull=never --name "$decor_container" --network none -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "$(pwd)/supabase/migrations:/workspace/supabase/migrations:ro" \
    -v "$(pwd)/supabase/tests:/workspace/supabase/tests:ro" "${POSTGRES_TEST_IMAGE:-postgres:17.6-alpine}" >/dev/null
ready=false
for _ in {1..60}; do
    if docker exec "$decor_container" sh -c 'test "$(cat /proc/1/comm)" = postgres && pg_isready -U postgres' >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.5
done
if [ "$ready" != true ]; then docker logs "$decor_container"; exit 1; fi
db_psql() { docker exec -i -w /workspace "$decor_container" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
db_psql >/dev/null <<'SQL'
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
CREATE TABLE public.users(device_id uuid PRIMARY KEY, status text DEFAULT 'active');
CREATE TABLE public.guild_members(device_id uuid PRIMARY KEY, guild_id uuid NOT NULL);
CREATE TABLE public.guild_furniture(guild_id uuid NOT NULL, slot_id smallint NOT NULL,
    item_kind text NOT NULL, purchased_by uuid, purchased_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(guild_id,slot_id));
ALTER TABLE public.guild_furniture ENABLE ROW LEVEL SECURITY;
GRANT SELECT, UPDATE ON public.users, public.guild_members TO service_role;
GRANT ALL ON public.guild_furniture TO service_role;
INSERT INTO public.users VALUES ('00000000-0000-0000-0000-000000000001','active');
INSERT INTO public.guild_members VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010');
INSERT INTO public.guild_furniture(guild_id,slot_id,item_kind,purchased_by) VALUES
 ('00000000-0000-0000-0000-000000000010',5,'CHRISTMAS_TREE','00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000010',0,'XMAS_LIGHTS','00000000-0000-0000-0000-000000000001');
SQL
db_psql -f supabase/migrations/20261116011236_guild_decor_positions.sql >/dev/null
db_psql -f supabase/tests/guild_decor_positions.sql
version=$(db_psql -At -c "SELECT position_version FROM public.guild_furniture WHERE slot_id=5")
set +e
db_psql -c "SET ROLE service_role; SELECT public.move_guild_decor('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010',5,'$version',120,112)" >"$decor_tmp/one.log" 2>&1 &
pid1=$!
db_psql -c "SET ROLE service_role; SELECT public.move_guild_decor('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000010',5,'$version',200,140)" >"$decor_tmp/two.log" 2>&1 &
pid2=$!
wait "$pid1"; result1=$?
wait "$pid2"; result2=$?
set -e
if { [ "$result1" -eq 0 ] && [ "$result2" -ne 0 ]; } || { [ "$result1" -ne 0 ] && [ "$result2" -eq 0 ]; }; then
    echo "Concurrent decor move: exactly one writer succeeds"
else
    cat "$decor_tmp/one.log" "$decor_tmp/two.log"
    exit 1
fi
