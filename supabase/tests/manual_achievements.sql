INSERT INTO public.users VALUES ('00000000-0000-0000-0000-000000000003', 'public', 'active');
INSERT INTO public.users VALUES ('00000000-0000-0000-0000-000000000004', 'public', 'active');
DO $$ BEGIN
    ASSERT NOT has_table_privilege('anon', 'public.manual_achievements', 'INSERT');
    ASSERT NOT has_table_privilege('authenticated', 'public.manual_achievements', 'SELECT');
    ASSERT NOT has_function_privilege('anon', 'public.manual_arena_record_achievements()', 'EXECUTE');
END $$;
SET ROLE service_role;
DO $$
DECLARE owner_id uuid := '00000000-0000-0000-0000-000000000003'; battle uuid; request uuid;
    state jsonb; events jsonb; grade integer; result jsonb; repeated jsonb;
BEGIN
    events := '[{"kind":"comebackWindow","side":0},
        {"kind":"achievementFact","moveID":"switch_counter","side":0},
        {"kind":"achievementFact","moveID":"speed_planner","side":0},
        {"kind":"achievementFact","moveID":"ultimate_reserve","side":0},
        {"kind":"achievementFact","moveID":"team_recovery","side":0}]'::jsonb;
    FOR i IN 1..5 LOOP
        events := events || '[{"kind":"achievementFact","moveID":"type_expert","side":0}]'::jsonb;
    END LOOP;
    FOR i IN 1..4 LOOP
        battle := gen_random_uuid(); request := gen_random_uuid();
        state := jsonb_build_object('id', battle, 'rulesVersion', 1, 'revision', 0, 'achievementsEligible', i <> 1);
        PERFORM public.manual_arena_start(battle, owner_id, 'public', gen_random_uuid(), 'start', state,
            CASE WHEN i = 1 THEN '{}'::text[] ELSE ARRAY['fox'] END);
        state := state || jsonb_build_object('revision', 1, 'outcome', jsonb_build_object('winner', 0,
            'reason', CASE WHEN i = 4 THEN 'surrender' ELSE 'knockout' END), 'events', events,
            'teams', jsonb_build_array(jsonb_build_object('fighters', jsonb_build_array(jsonb_build_object(
                'pet', jsonb_build_object('kind', 'fox', 'variant', 4), 'participated', true,
                'ultimateUsed', true, 'branch', CASE WHEN i = 3 THEN 'alternate' ELSE 'original' END)))));
        result := public.manual_arena_commit(battle, owner_id, 'public', request, 'command', 0, state, '{"ok":true}');
        repeated := public.manual_arena_commit(battle, owner_id, 'public', request, 'command', 0, state, '{"ok":false}');
        ASSERT result = repeated;
        IF i = 1 THEN
            ASSERT NOT EXISTS (SELECT 1 FROM public.manual_achievements WHERE device_id = owner_id), 'unverified team cannot earn achievements';
        ELSIF i = 2 THEN
            SELECT progress INTO grade FROM public.manual_achievements WHERE device_id = owner_id AND achievement_id = 'type_expert';
            ASSERT grade = 5, 'duplicate request cannot double type KOs';
            ASSERT NOT EXISTS (SELECT 1 FROM public.manual_achievements WHERE device_id = owner_id AND achievement_id = 'dual_ultimate');
            ASSERT (SELECT unlocked_at IS NULL FROM public.manual_achievements WHERE device_id = owner_id AND achievement_id = 'type_expert');
        END IF;
    END LOOP;
    ASSERT (SELECT count(*) FROM public.manual_achievements WHERE device_id = owner_id AND unlocked_at IS NOT NULL) = 8;
    ASSERT (SELECT progress FROM public.manual_achievements WHERE device_id = owner_id AND achievement_id = 'type_expert') = 10;
    ASSERT (SELECT count(*) FROM public.manual_achievement_receipts WHERE device_id = owner_id) = 2;
    ASSERT (SELECT wins FROM public.manual_pet_mastery WHERE device_id = owner_id AND kind = 'fox') = 2;

    -- A fully verified non-rainbow team can earn trainer achievements without any eligible rainbow pets.
    owner_id := '00000000-0000-0000-0000-000000000004'; battle := gen_random_uuid();
    state := jsonb_build_object('id', battle, 'rulesVersion', 1, 'revision', 0, 'achievementsEligible', true);
    PERFORM public.manual_arena_start(battle, owner_id, 'public', gen_random_uuid(), 'start', state, '{}');
    state := state || '{"revision":1,"outcome":{"winner":0,"reason":"knockout"},"teams":[{"fighters":[]}],"events":[]}'::jsonb;
    PERFORM public.manual_arena_commit(battle, owner_id, 'public', gen_random_uuid(), 'command', 0, state, '{}');
    ASSERT (SELECT progress FROM public.manual_achievements WHERE device_id = owner_id AND achievement_id = 'first_command') = 1;
    ASSERT NOT EXISTS (SELECT 1 FROM public.manual_pet_mastery WHERE device_id = owner_id);
END $$;
RESET ROLE;
SELECT 'manual achievement settlement tests passed' AS result;
