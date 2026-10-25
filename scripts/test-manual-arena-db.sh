#!/usr/bin/env bash
# Disposable, Unix-socket-only PostgreSQL cluster. Never touches the linked Supabase project.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/aiusage-manual-db.XXXXXX)
test_container=""
cleanup() {
    if [ -n "$test_container" ]; then docker rm -fv "$test_container" >/dev/null 2>&1 || true
    else pg_ctl -D "$test_dir/data" -m immediate stop >/dev/null 2>&1 || true; fi
    rm -rf "$test_dir"
}
trap cleanup EXIT
if command -v postgres >/dev/null 2>&1; then
    initdb -D "$test_dir/data" -U manual_test -A trust --no-locale >/dev/null
    pg_ctl -D "$test_dir/data" -l "$test_dir/server.log" -o "-k $test_dir -h '' -p 55489" -w start >/dev/null
    db_psql() { psql -X -h "$test_dir" -p 55489 -U manual_test -d postgres -v ON_ERROR_STOP=1 "$@"; }
else
    test_container="aiusage-manual-test-$$"
    docker run -d --pull=never --name "$test_container" --network none -e POSTGRES_HOST_AUTH_METHOD=trust \
        -v "$(pwd)/supabase/migrations:/workspace/supabase/migrations:ro" \
        -v "$(pwd)/supabase/tests:/workspace/supabase/tests:ro" postgres:17.6-alpine >/dev/null
    test_ready=false
    for _ in {1..60}; do
        # The entrypoint briefly runs a temporary server during init; wait for its final exec too.
        if docker exec "$test_container" sh -c 'test "$(cat /proc/1/comm)" = postgres && pg_isready -U postgres' >/dev/null 2>&1; then test_ready=true; break; fi
        sleep 0.5
    done
    if [ "$test_ready" != true ]; then docker logs "$test_container"; exit 1; fi
    db_psql() { docker exec -i -w /workspace "$test_container" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
fi
db_psql >/dev/null <<'SQL'
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
CREATE TABLE public.tenants(slug text PRIMARY KEY);
CREATE TABLE public.users(device_id uuid PRIMARY KEY, tenant_id text REFERENCES public.tenants(slug), status text DEFAULT 'active');
GRANT SELECT, UPDATE ON public.users TO service_role;
INSERT INTO public.tenants VALUES ('public');
INSERT INTO public.users VALUES ('00000000-0000-0000-0000-000000000001', 'public', 'active');
SQL
db_psql -f supabase/migrations/20261025073446_manual_arena_sessions.sql >/dev/null
db_psql -f supabase/migrations/20261025084647_manual_arena_achievements.sql >/dev/null
db_psql -f supabase/tests/manual_arena.sql
db_psql -f supabase/tests/manual_achievements.sql
db_psql -c "INSERT INTO public.users VALUES ('00000000-0000-0000-0000-000000000002', 'public', 'active')" >/dev/null
# Two independent connections racing to start a game must produce exactly one active session.
set +e
db_psql -c "SET ROLE service_role; SELECT public.manual_arena_start(gen_random_uuid(), '00000000-0000-0000-0000-000000000002', 'public', gen_random_uuid(), 'race', '{}', '{}')" >"$test_dir/race1.log" 2>&1 &
race_pid1=$!
db_psql -c "SET ROLE service_role; SELECT public.manual_arena_start(gen_random_uuid(), '00000000-0000-0000-0000-000000000002', 'public', gen_random_uuid(), 'race', '{}', '{}')" >"$test_dir/race2.log" 2>&1 &
race_pid2=$!
wait "$race_pid1"; race_result1=$?
wait "$race_pid2"; race_result2=$?
set -e
if { [ "$race_result1" -eq 0 ] && [ "$race_result2" -ne 0 ]; } || { [ "$race_result2" -eq 0 ] && [ "$race_result1" -ne 0 ]; }; then
    echo "Concurrent start test passed"
else
    cat "$test_dir/race1.log" "$test_dir/race2.log"
    exit 1
fi
