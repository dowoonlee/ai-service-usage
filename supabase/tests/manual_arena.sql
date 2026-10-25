-- Invoker permissions, idempotency, ownership and finalization regression tests.
DO $$ BEGIN
    ASSERT NOT has_table_privilege('anon', 'public.manual_verified_pets', 'INSERT');
    ASSERT NOT has_table_privilege('authenticated', 'public.manual_arena_sessions', 'SELECT');
    ASSERT NOT has_function_privilege('anon', 'public.manual_arena_commit(uuid,uuid,text,uuid,text,integer,jsonb,jsonb)', 'EXECUTE');
END $$;
SET ROLE service_role;
DO $$
DECLARE owner_id uuid := '00000000-0000-0000-0000-000000000001';
    battle uuid := '00000000-0000-0000-0000-000000000010';
    request uuid := '00000000-0000-0000-0000-000000000020';
    next_request uuid := '00000000-0000-0000-0000-000000000021';
    state jsonb; result jsonb; repeated jsonb; record_row record;
BEGIN
    state := jsonb_build_object('id', battle, 'rulesVersion', 1, 'revision', 0);
    result := public.manual_arena_start(battle, owner_id, 'public', request, 'start', state, ARRAY['fox']);
    repeated := public.manual_arena_start(battle, owner_id, 'public', request, 'start', state, ARRAY['fox']);
    ASSERT result = repeated, 'start must be idempotent';
    BEGIN
        PERFORM public.manual_arena_start(battle, owner_id, 'public', request, 'changed', state, ARRAY['fox']);
        RAISE EXCEPTION 'missing request conflict';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'request_conflict'; END;
    BEGIN
        PERFORM public.manual_arena_start(gen_random_uuid(), owner_id, 'public', gen_random_uuid(), 'new', state, ARRAY['fox']);
        RAISE EXCEPTION 'missing active session guard';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'active_battle'; END;
    state := jsonb_build_object('id', battle, 'rulesVersion', 1, 'revision', 1, 'outcome',
        jsonb_build_object('winner', 0, 'reason', 'knockout'), 'teams', jsonb_build_array(jsonb_build_object('fighters',
            jsonb_build_array(jsonb_build_object('pet', jsonb_build_object('kind', 'fox', 'variant', 4),
                'participated', true, 'ultimateUsed', true, 'branch', 'alternate'),
            jsonb_build_object('pet', jsonb_build_object('kind', 'wolf', 'variant', 4),
                'participated', true, 'ultimateUsed', true, 'branch', 'original')))));
    result := public.manual_arena_commit(battle, owner_id, 'public', next_request, 'command', 0, state, '{"ok":true}');
    repeated := public.manual_arena_commit(battle, owner_id, 'public', next_request, 'command', 0, state, '{"ok":false}');
    ASSERT result = repeated, 'duplicate returns originally committed response';
    SELECT * INTO record_row FROM public.manual_pet_mastery WHERE device_id = owner_id AND kind = 'fox';
    ASSERT record_row.wins = 1 AND record_row.alternate_wins = 1 AND record_row.original_wins = 0;
    ASSERT NOT EXISTS (SELECT 1 FROM public.manual_pet_mastery WHERE kind = 'wolf'), 'unverified kind must not earn';
    ASSERT (SELECT count(*) FROM public.manual_mastery_awards) = 1;
    BEGIN
        PERFORM public.manual_arena_commit(battle, gen_random_uuid(), 'public', next_request, 'command', 0, state, '{}');
        RAISE EXCEPTION 'missing ownership check';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'battle_not_found'; END;
    BEGIN
        PERFORM public.manual_arena_commit(battle, owner_id, 'public', next_request, 'different', 0, state, '{}');
        RAISE EXCEPTION 'missing payload conflict';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'request_conflict'; END;
END $$;
RESET ROLE;
SET ROLE service_role;
DO $$
DECLARE owner_id uuid := '00000000-0000-0000-0000-000000000001';
    battle uuid := gen_random_uuid(); state jsonb; request uuid := gen_random_uuid();
BEGIN
    state := jsonb_build_object('id', battle, 'rulesVersion', 1, 'revision', 0);
    PERFORM public.manual_arena_start(battle, owner_id, 'public', request, 'start2', state, '{}');
    state := jsonb_set(state, '{revision}', '1');
    PERFORM public.manual_arena_commit(battle, owner_id, 'public', gen_random_uuid(), 'turn1', 0, state, '{"revision":1}');
    BEGIN
        PERFORM public.manual_arena_commit(battle, owner_id, 'public', gen_random_uuid(), 'stale', 0, state, '{}');
        RAISE EXCEPTION 'missing revision guard';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'revision_conflict'; END;
    UPDATE public.manual_arena_sessions SET expires_at = now() - interval '1 second' WHERE id = battle;
    BEGIN
        PERFORM public.manual_arena_commit(battle, owner_id, 'public', gen_random_uuid(), 'expired', 1,
            jsonb_set(state, '{revision}', '2'), '{}');
        RAISE EXCEPTION 'missing expiry guard';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'battle_closed'; END;
    -- Sessions 3..10: cap must remain effective even when every prior session is already closed.
    FOR i IN 3..10 LOOP
        battle := gen_random_uuid();
        state := jsonb_build_object('id', battle, 'rulesVersion', 1, 'revision', 0);
        PERFORM public.manual_arena_start(battle, owner_id, 'public', gen_random_uuid(), 'new', state, '{}');
        state := jsonb_set(state, '{revision}', '1') || '{"outcome":{"winner":1,"reason":"surrender"}}'::jsonb;
        PERFORM public.manual_arena_commit(battle, owner_id, 'public', gen_random_uuid(), 'surrender', 0, state, '{}');
    END LOOP;
    BEGIN
        PERFORM public.manual_arena_start(gen_random_uuid(), owner_id, 'public', gen_random_uuid(), 'eleventh', state, '{}');
        RAISE EXCEPTION 'missing daily limit';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM = 'daily_limit'; END;
    ASSERT (SELECT wins FROM public.manual_pet_mastery WHERE device_id = owner_id AND kind = 'fox') = 1;
END $$;
RESET ROLE;
SELECT 'manual arena database tests passed' AS result;
