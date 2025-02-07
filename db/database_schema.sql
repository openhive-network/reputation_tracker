-- noqa: disable=CP03
SET ROLE reptracker_owner;

DO $$
DECLARE 
  __schema_name VARCHAR;
  v_is_forking BOOLEAN;
  synchronization_stages hive.application_stages;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  synchronization_stages := ARRAY[( 'MASSIVE_PROCESSING', 101, 10000 ), hive.live_stage()]::hive.application_stages;

  v_is_forking := current_setting('custom.is_forking')::BOOLEAN;

  RAISE NOTICE 'reputation_tracker will be installed in schema % with context %', __schema_name, __schema_name;

  IF hive.app_context_exists(__schema_name) THEN
      RAISE NOTICE 'Context % already exists, it means all tables are already created and data installing is skipped', __schema_name;
      RETURN;
  END IF;

  PERFORM hive.app_create_context(
    _name =>__schema_name,
    _schema => __schema_name,
    _is_forking => v_is_forking,
    _stages => synchronization_stages
  );

CREATE TABLE IF NOT EXISTS reptracker_app_status
(
  continue_processing BOOLEAN NOT NULL,
  is_accounts_copied BOOLEAN
);

CREATE TABLE IF NOT EXISTS version(
  schema_hash TEXT,
  runtime_hash TEXT
);

CREATE TABLE IF NOT EXISTS account_reputations
(
    account_id INT NOT NULL,
    reputation BIGINT NOT NULL,
    is_implicit boolean,
    CONSTRAINT pk_reputations PRIMARY KEY (account_id)
);

PERFORM hive.app_register_table( __schema_name, 'account_reputations', __schema_name );

CREATE TABLE IF NOT EXISTS permlinks
(
    permlink_id SERIAL PRIMARY KEY,
    permlink TEXT UNIQUE
);

PERFORM hive.app_register_table( __schema_name, 'permlinks', __schema_name );

CREATE TABLE IF NOT EXISTS active_votes
(
    author_id INT NOT NULL,
    voter_id INT NOT NULL,
    permlink_serial_id INT NOT NULL,
    rshares BIGINT NOT NULL,

    CONSTRAINT pk_active_votes PRIMARY KEY (author_id, permlink_serial_id, voter_id),
    CONSTRAINT fk_active_votes_permlink FOREIGN KEY (permlink_serial_id) REFERENCES permlinks (permlink_id) deferrable
);

PERFORM hive.app_register_table( __schema_name, 'active_votes', __schema_name );

DROP TYPE IF EXISTS AccountReputation CASCADE;
CREATE TYPE AccountReputation AS 
(
  id INT,
  reputation BIGINT,
  is_implicit BOOLEAN, 
  changed BOOLEAN
);


END
$$;

-- the current version of sqlfluff doesn't understand 'GRANT MAINTAIN'
GRANT MAINTAIN ON ALL TABLES IN SCHEMA reptracker_app TO hived_group; -- noqa: PRS
GRANT ALL ON SCHEMA reptracker_app TO hived_group;

INSERT INTO reptracker_app_status
(continue_processing, is_accounts_copied)
VALUES
(True, False)
;

RESET ROLE;
