-- noqa: disable=CP03

SET ROLE reptracker_owner;

DO $$
  DECLARE __schema_name VARCHAR;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  RAISE NOTICE 'reputation_tracker will be installed in schema % with context %', __schema_name, __schema_name;

  IF hive.app_context_exists(__schema_name) THEN
      RAISE NOTICE 'Context % already exists, it means all tables are already created and data installing is skipped', __schema_name;
      RETURN;
  END IF;

  PERFORM hive.app_create_context(
    _name =>__schema_name,
    _schema => __schema_name,
    _is_forking => TRUE,
    _is_attached => FALSE
  );

CREATE TABLE IF NOT EXISTS app_status
(
  continue_processing BOOLEAN NOT NULL,
  last_processed_block INT NOT NULL
);

INSERT INTO app_status
(continue_processing, last_processed_block)
VALUES
(True, 0)
;

CREATE TABLE IF NOT EXISTS version(
  schema_hash TEXT,
  runtime_hash TEXT
);

CREATE TABLE IF NOT EXISTS account_reputations
(
    account_id INT NOT NULL,
    reputation BIGINT NOT NULL,
    is_implicit boolean,
    CONSTRAINT PK_account_reputations PRIMARY KEY (account_id)
)
;

PERFORM hive.app_register_table( __schema_name, 'account_reputations', __schema_name );

DROP TYPE IF EXISTS AccountReputation CASCADE;
CREATE TYPE AccountReputation AS 
(
  id INT,
  reputation BIGINT,
  is_implicit BOOLEAN, 
  changed BOOLEAN
)
;

END
$$;

GRANT USAGE ON SCHEMA reptracker_app TO reputation_tracker_writer_group;
--- Only data writers can write to such table(s)
GRANT ALL ON app_status TO reputation_tracker_writer_group;
GRANT ALL ON account_reputations TO reputation_tracker_writer_group;

RESET ROLE;
