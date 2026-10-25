CREATE TABLE public.manual_achievements (
    device_id uuid NOT NULL REFERENCES public.users(device_id) ON DELETE CASCADE,
    achievement_id text NOT NULL CHECK (achievement_id IN ('first_command', 'type_expert', 'switch_counter',
        'speed_planner', 'ultimate_reserve', 'dual_ultimate', 'last_stand', 'team_recovery')),
    progress integer NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 10),
    unlocked_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, achievement_id)
);
CREATE TABLE public.manual_achievement_receipts (
    battle_id uuid PRIMARY KEY REFERENCES public.manual_arena_sessions(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES public.users(device_id) ON DELETE CASCADE,
    recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX manual_achievement_receipts_owner ON public.manual_achievement_receipts(device_id);
ALTER TABLE public.manual_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_achievement_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.manual_achievements, public.manual_achievement_receipts FROM anon, authenticated;
GRANT ALL ON public.manual_achievements, public.manual_achievement_receipts TO service_role;

-- Run after the existing commit RPC has recorded both the final state AND per-pet mastery.
-- This trigger is in that same transaction; retries cannot issue progress or titles twice.
CREATE FUNCTION public.manual_arena_record_achievements()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE session public.manual_arena_sessions%ROWTYPE;
    achievement text; increase integer; goal integer; won boolean; events jsonb;
BEGIN
    SELECT * INTO session FROM public.manual_arena_sessions WHERE id = NEW.battle_id;
    IF NOT FOUND OR session.status <> 'finished'
        OR session.state_json->>'achievementsEligible' IS DISTINCT FROM 'true'
        OR session.state_json->>'tutorial' = 'true'
        OR coalesce(session.state_json#>>'{outcome,reason}', '') NOT IN ('knockout', 'turnLimit') THEN RETURN NEW; END IF;
    INSERT INTO public.manual_achievement_receipts(battle_id, device_id) VALUES(session.id, session.device_id)
        ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN RETURN NEW; END IF;
    won := coalesce(session.state_json#>>'{outcome,winner}' = '0', false);
    events := CASE WHEN jsonb_typeof(session.state_json->'events') = 'array' THEN session.state_json->'events' ELSE '[]'::jsonb END;
    FOREACH achievement IN ARRAY ARRAY['first_command', 'type_expert', 'switch_counter', 'speed_planner',
        'ultimate_reserve', 'dual_ultimate', 'last_stand', 'team_recovery'] LOOP
        goal := CASE WHEN achievement = 'type_expert' THEN 10 ELSE 1 END;
        IF achievement = 'first_command' THEN increase := CASE WHEN won THEN 1 ELSE 0 END;
        ELSIF achievement = 'dual_ultimate' THEN
            increase := CASE WHEN EXISTS (SELECT 1 FROM public.manual_pet_mastery WHERE device_id = session.device_id
                AND original_wins > 0 AND alternate_wins > 0) THEN 1 ELSE 0 END;
        ELSIF achievement = 'last_stand' THEN
            increase := CASE WHEN won AND EXISTS (SELECT 1 FROM jsonb_array_elements(events) e
                WHERE e->>'kind' = 'comebackWindow' AND e->>'side' = '0') THEN 1 ELSE 0 END;
        ELSE
            SELECT least(CASE WHEN achievement = 'type_expert' THEN 5 ELSE 1 END, count(*))::integer INTO increase
                FROM jsonb_array_elements(events) e WHERE e->>'kind' = 'achievementFact'
                    AND e->>'moveID' = achievement AND e->>'side' = '0';
            IF achievement = 'team_recovery' AND NOT won THEN increase := 0; END IF;
        END IF;
        IF increase > 0 THEN
            INSERT INTO public.manual_achievements(device_id, achievement_id, progress, unlocked_at)
                VALUES(session.device_id, achievement, least(goal, increase), CASE WHEN increase >= goal THEN now() ELSE NULL END)
                ON CONFLICT(device_id, achievement_id) DO UPDATE SET
                    progress = least(goal, public.manual_achievements.progress + EXCLUDED.progress),
                    unlocked_at = coalesce(public.manual_achievements.unlocked_at,
                        CASE WHEN public.manual_achievements.progress + EXCLUDED.progress >= goal THEN now() ELSE NULL END),
                    updated_at = now();
        END IF;
    END LOOP;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.manual_arena_record_achievements() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_arena_record_achievements() TO service_role;
CREATE TRIGGER manual_arena_achievement_settlement
    AFTER INSERT ON public.manual_arena_requests FOR EACH ROW
    EXECUTE FUNCTION public.manual_arena_record_achievements();
