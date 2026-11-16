DO $$ BEGIN
    ASSERT NOT has_function_privilege('anon', 'public.move_guild_decor(uuid,uuid,integer,uuid,integer,integer)', 'EXECUTE');
    ASSERT NOT has_function_privilege('authenticated', 'public.move_guild_decor(uuid,uuid,integer,uuid,integer,integer)', 'EXECUTE');
    ASSERT (SELECT position_x IS NULL AND position_y IS NULL AND position_version IS NOT NULL FROM public.guild_furniture WHERE slot_id=5);
END $$;
SET ROLE service_role;
DO $$
DECLARE d uuid := '00000000-0000-0000-0000-000000000001';
    g uuid := '00000000-0000-0000-0000-000000000010'; v uuid; r jsonb; before_row public.guild_furniture%ROWTYPE;
BEGIN
    SELECT * INTO before_row FROM public.guild_furniture WHERE guild_id=g AND slot_id=5;
    v := before_row.position_version;
    r := public.move_guild_decor(d,g,5,v,200,140);
    ASSERT r->>'x'='200' AND r->>'y'='140';
    ASSERT (r->>'version')::uuid <> v;
    ASSERT (SELECT purchased_by = before_row.purchased_by AND purchased_at = before_row.purchased_at
        AND item_kind = before_row.item_kind AND slot_id=5 AND position_x=200 AND position_y=140
        FROM public.guild_furniture WHERE guild_id=g AND slot_id=5), 'movement preserves ownership and purchase';
    BEGIN
        PERFORM public.move_guild_decor(d,g,5,v,180,112);
        RAISE EXCEPTION 'stale version accepted';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='decor_changed'; END;
    v := (r->>'version')::uuid;
    BEGIN
        PERFORM public.move_guild_decor('00000000-0000-0000-0000-000000000002',g,5,v,180,112);
        RAISE EXCEPTION 'nonmember accepted';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='not_in_guild'; END;
    BEGIN
        PERFORM public.move_guild_decor(d,g,5,v,180,52);
        RAISE EXCEPTION 'floor decor accepted wall position';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='invalid_decor_position'; END;
    -- Replacing the same kind still invalidates the old move and resets only its position.
    UPDATE public.guild_furniture SET purchased_at=purchased_at+interval '1 second' WHERE guild_id=g AND slot_id=5;
    ASSERT (SELECT position_x IS NULL AND position_y IS NULL FROM public.guild_furniture WHERE guild_id=g AND slot_id=5);
    BEGIN
        PERFORM public.move_guild_decor(d,g,5,v,180,112);
        RAISE EXCEPTION 'move changed a replacement purchase';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='decor_changed'; END;
    SELECT position_version INTO v FROM public.guild_furniture WHERE guild_id=g AND slot_id=0;
    r := public.move_guild_decor(d,g,0,v,120,40);
    BEGIN
        PERFORM public.move_guild_decor(d,g,0,(r->>'version')::uuid,120,84);
        RAISE EXCEPTION 'wall decor accepted floor position';
    EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='invalid_decor_position'; END;
    -- Donor deletion (FK SET NULL) must not move the decoration back to its legacy slot.
    UPDATE public.guild_furniture SET purchased_by=NULL WHERE guild_id=g AND slot_id=0;
    ASSERT (SELECT position_x=120 AND position_y=40 FROM public.guild_furniture WHERE guild_id=g AND slot_id=0);
END $$;
RESET ROLE;
