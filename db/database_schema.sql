SET ROLE reptracker_owner;

DO $$
BEGIN

CREATE SCHEMA reptracker_app AUTHORIZATION reptracker_owner;

RAISE NOTICE 'Attempting to create an application schema tables...';

IF NOT hive.app_context_exists('reptracker_app') THEN
    RAISE NOTICE 'Attempting to create a HAF application context...';
    PERFORM hive.app_create_context('reptracker_app',
    TRUE, -- _if_forking
    FALSE -- _is_attached
    );
END IF;

CREATE TABLE IF NOT EXISTS reptracker_app.app_status
(
  continue_processing BOOLEAN NOT NULL,
  last_processed_block INT NOT NULL
);

INSERT INTO reptracker_app.app_status
(continue_processing, last_processed_block)
VALUES
(True, 0)
;

CREATE TABLE IF NOT EXISTS reptracker_app.account_reputations
(
    account_id INT NOT NULL,
    reputation BIGINT NOT NULL,
    is_implicit boolean,
    CONSTRAINT PK_account_reputations PRIMARY KEY (account_id)
)
INHERITS (hive.reptracker_app)
;

CREATE TABLE IF NOT EXISTS reptracker_app.version(
  schema_hash TEXT,
  runtime_hash TEXT
);

DROP TYPE IF EXISTS reptracker_app.AccountReputation CASCADE;

CREATE TYPE reptracker_app.id_prev_shares AS (id BIGINT, prev_rshares BIGINT);

CREATE TYPE reptracker_app.AccountReputation AS (id INT, reputation BIGINT, is_implicit BOOLEAN, changed BOOLEAN);

EXCEPTION WHEN duplicate_schema THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

GRANT USAGE ON SCHEMA reptracker_app TO reputation_tracker_writer_group;
--- Only data writers can write to such table(s)
GRANT ALL ON reptracker_app.app_status TO reputation_tracker_writer_group;
GRANT ALL ON reptracker_app.account_reputations TO reputation_tracker_writer_group;

RESET ROLE;
