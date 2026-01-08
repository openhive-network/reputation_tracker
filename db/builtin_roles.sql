DO $$
BEGIN
CREATE ROLE reptracker_owner WITH LOGIN INHERIT IN ROLE hive_applications_owner_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

DO $$
BEGIN
  CREATE ROLE reptracker_user WITH LOGIN INHERIT IN ROLE hive_applications_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

--- Allow to create schemas
GRANT reptracker_owner TO haf_admin;
GRANT reptracker_user TO reptracker_owner;
