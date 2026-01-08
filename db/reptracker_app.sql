/**
 * Reputation Tracker Core Application Schema
 * ==========================================
 *
 * This file defines the core Reputation Tracker HAF application, including:
 * - HAF context registration and synchronization stages
 * - Database tables for tracking account reputations
 * - Control functions for application lifecycle
 * - Block processing dispatch functions
 *
 * Tables:
 * -------
 * 1. CONTROL TABLES
 *    - reptracker_app_status: Processing control flag
 *    - version: Schema version tracking
 *
 * 2. REPUTATION DATA
 *    - account_reputations: Reputation scores per account
 *    - active_votes: Vote tracking for reputation calculation
 *    - permlinks: Post identifier dictionary
 *
 * HAF Synchronization Stages:
 * ---------------------------
 * - MASSIVE_PROCESSING: Initial sync, processes blocks in batches of 10000
 * - LIVE: Real-time sync, processes blocks one at a time
 *
 * Processing Flow:
 * ----------------
 * 1. main() starts the application loop
 * 2. reptracker_process_blocks() dispatches based on current stage
 * 3. reptracker_massive_processing() or reptracker_single_processing() calls
 *    reptracker_block_range_data() for actual processing
 *
 * @see builtin_roles.sql for database role definitions
 * @see process_block_range.sql for block processing logic
 */

-- noqa: disable=CP03
SET ROLE reptracker_owner;

-- =============================================================================
-- SECTION 1: HAF CONTEXT AND TABLE DEFINITIONS
-- =============================================================================

DO $$
DECLARE
  __schema_name VARCHAR;
  v_is_forking BOOLEAN;
  synchronization_stages hive.application_stages;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  synchronization_stages := ARRAY[hive.stage( 'MASSIVE_PROCESSING', 101, 10000, '10 seconds' ), hive.live_stage()]::hive.application_stages;

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
  git_hash TEXT
);

CREATE TABLE IF NOT EXISTS account_reputations
(
    account_id INT NOT NULL,
    reputation BIGINT NOT NULL,
    is_implicit boolean,
    CONSTRAINT PK_account_reputations PRIMARY KEY (account_id)
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

-- =============================================================================
-- SECTION 2: CONTROL FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION continueProcessing()
RETURNS BOOLEAN
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN continue_processing FROM reptracker_app_status LIMIT 1;
END
$$;

CREATE OR REPLACE FUNCTION allowProcessing()
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
BEGIN
  UPDATE reptracker_app_status SET continue_processing = True;
END
$$;

--- Helper function to be called from separate transaction
--- (must be committed) to safely stop execution of the application.
CREATE OR REPLACE FUNCTION stopProcessing()
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
BEGIN
  UPDATE reptracker_app_status SET continue_processing = False;
END
$$;

CREATE OR REPLACE FUNCTION get_version()
RETURNS TEXT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN runtime_hash FROM version LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION set_version(_git_hash TEXT)
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
DECLARE
  _schema_hash TEXT := (SELECT schema_hash FROM version LIMIT 1);
BEGIN
TRUNCATE TABLE version;

IF _schema_hash IS NULL THEN
  INSERT INTO version(schema_hash, runtime_hash) VALUES (_git_hash, _git_hash);
ELSE
  INSERT INTO version(schema_hash, runtime_hash) VALUES (_schema_hash, _git_hash);
END IF;

END
$$;

CREATE OR REPLACE FUNCTION do_rep_indexes_exist()
RETURNS BOOLEAN
LANGUAGE 'plpgsql' VOLATILE
AS
$$
DECLARE __result BOOLEAN;
BEGIN
  select not exists(select 1
                    from (values (
                    'effective_comment_vote_idx',
                    'delete_comment_op_idx'
                    ))
                         desired_indexes(indexname)
                    left join pg_indexes using (indexname)
                    left join pg_class on desired_indexes.indexname = pg_class.relname
                    left join pg_index on pg_class.oid = indexrelid
                    where pg_indexes.indexname is null or not pg_index.indisvalid)
  into __result;
  return __result;
END
$$;

-- =============================================================================
-- SECTION 3: PROCESSING PROCEDURES
-- =============================================================================

CREATE OR REPLACE PROCEDURE reptracker_massive_processing(
    IN _from INT, IN _to INT, IN _logs BOOLEAN
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __start_ts timestamptz;
  __end_ts   timestamptz;
BEGIN
  PERFORM set_config('synchronous_commit', 'OFF', false);

  IF _logs THEN
    RAISE NOTICE 'Reptracker is attempting to process a block range: <%, %>', _from, _to;
    __start_ts := clock_timestamp();
  END IF;

  PERFORM reptracker_block_range_data(_from, _to);

  IF _logs THEN
    __end_ts := clock_timestamp();
    RAISE NOTICE 'Reptracker processed block range: <%, %> successfully in % s
    ', _from, _to, (extract(epoch FROM __end_ts - __start_ts));
  END IF;
END
$$;

CREATE OR REPLACE PROCEDURE reptracker_single_processing(
    in _from INT, in _to INT, IN _logs BOOLEAN)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __start_ts timestamptz;
  __end_ts   timestamptz;
BEGIN
  PERFORM set_config('synchronous_commit', 'ON', false);

  IF _logs THEN
    RAISE NOTICE 'Reptracker processing block: %...', _from;
    __start_ts := clock_timestamp();
  END IF;

  PERFORM reptracker_block_range_data(_from, _to);

  IF _logs THEN
    __end_ts := clock_timestamp();
    RAISE NOTICE 'Reptracker processed block % successfully in % s
    ', _from, (extract(epoch FROM __end_ts - __start_ts));
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION continueProcessingLoop(
    _appContext hive.context_name,
    _maxBlockLimit INT,
    _blocks_range hive.blocks_range
)
RETURNS BOOLEAN
LANGUAGE 'plpgsql'
AS
$$
BEGIN
    IF _blocks_range IS NULL AND _maxBlockLimit IS NOT NULL THEN
        IF hive.app_get_current_block_num(_appContext) >= _maxBlockLimit THEN
            RAISE NOTICE 'Blocks limit reached. Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
            RETURN FALSE;
        END IF;
    END IF;

    IF NOT continueProcessing() THEN
        RAISE NOTICE 'Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END
$$;

/** Application entry point, which:
  - defines its data schema,
  - creates HAF application context,
  - starts application main-loop (which iterates infinitely).
  - To stop it call `stopProcessing();` from another session and commit its trasaction.
*/
CREATE OR REPLACE PROCEDURE main(
    IN _appContext hive.context_name,
    IN _maxBlockLimit INT = NULL
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  _blocks_range hive.blocks_range := (0,0);
BEGIN
  IF _maxBlockLimit != NULL THEN
    RAISE NOTICE 'Max block limit is specified as: %', _maxBlockLimit;
  END IF;

  PERFORM allowProcessing();

  RAISE NOTICE 'Last block processed by application: %', hive.app_get_current_block_num(_appContext);

  RAISE NOTICE 'Entering application main loop...';

  LOOP
    CALL hive.app_next_iteration(
      _appContext,
      _blocks_range,
      _override_max_batch => NULL,
      _limit => _maxBlockLimit);

    IF NOT continueProcessingLoop( _appContext, _maxBlockLimit, _blocks_range ) THEN
        ROLLBACK;
        RETURN;
    END IF;

    IF _blocks_range IS NULL THEN
      RAISE INFO 'Waiting for next block...';
      CONTINUE;
    END IF;

    CALL reptracker_process_blocks(_appContext, _blocks_range);
  END LOOP;

  ASSERT FALSE, 'Cannot reach this point';
END
$$;

DO $$
DECLARE
  __schema_name VARCHAR;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  EXECUTE format(
    $BODY$
      CREATE OR REPLACE PROCEDURE %I.reptracker_process_blocks(_context_name hive.context_name, _block_range hive.blocks_range, _logs BOOLEAN = true)
      LANGUAGE 'plpgsql'
      AS
      $pb$
      BEGIN
        IF hive.get_current_stage_name(_context_name) = 'MASSIVE_PROCESSING' THEN

          CALL reptracker_massive_processing(_block_range.first_block, _block_range.last_block, _logs);
          PERFORM hive.app_request_table_vacuum('%s.account_reputations', interval '10 minutes');
          PERFORM hive.app_request_table_vacuum('%s.active_votes', interval '10 minutes');
          PERFORM hive.app_request_table_vacuum('%s.permlinks', interval '100 minutes');
          RETURN;
        END IF;

        CALL reptracker_single_processing(_block_range.first_block, _block_range.last_block, _logs);
      END
      $pb$
    $BODY$, __schema_name, __schema_name, __schema_name, __schema_name);
END
$$;

RESET ROLE;
