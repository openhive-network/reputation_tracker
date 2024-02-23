DO $$
BEGIN
CREATE ROLE reptracker_owner WITH LOGIN INHERIT IN ROLE hive_applications_owner_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

DO $$
BEGIN
-- Group role (to inherit from) which allows to perform data sync
CREATE ROLE reputation_tracker_writer_group WITH NOLOGIN INHERIT IN ROLE hive_applications_group;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

--- Allow to create schemas
GRANT reputation_tracker_writer_group TO reptracker_owner;

