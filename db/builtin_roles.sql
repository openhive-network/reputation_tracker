DO $$
BEGIN

CREATE ROLE reputation_tracker_app_owner WITH LOGIN INHERIT IN ROLE haf_app_admin;
-- Group role (to inherit from) which allows to perform data sync
CREATE ROLE reputation_tracker_writer_group WITH NOLOGIN INHERIT IN ROLE hive_applications_group;

--- Allow to create schemas
GRANT CREATE ON DATABASE haf_block_log TO reputation_tracker_app_owner;

GRANT reputation_tracker_writer_group TO reputation_tracker_app_owner;
GRANT reputation_tracker_writer_group TO haf_app_admin;

EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;
