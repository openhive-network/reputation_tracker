/**
 * Reputation Tracker Core Application Schema
 * ==========================================
 *
 * This file defines the core Reputation Tracker HAF application, including:
 * - HAF context registration and synchronization stages
 * - All database tables for tracking account reputations
 * - Control functions for application lifecycle
 * - Block processing dispatch functions
 *
 * Table Groups:
 * -------------
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
 * @see backend/operation_parsers/vote_operations.sql for vote parsing
 */

-- noqa: disable=CP03
SET ROLE reptracker_owner;

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

  RAISE NOTICE 'Attempting to create an application schema tables...';

  ------------- CONTROL TABLES ----------------
  -- Indicates whether the application should continue processing blocks
  -- Stopped using stopProcessing() function
  CREATE TABLE IF NOT EXISTS reptracker_app_status
  (
    continue_processing BOOLEAN NOT NULL, -- TRUE to continue, FALSE to stop
    is_accounts_copied  BOOLEAN           -- Flag for account migration status
  );
  -- Initialize control table
  INSERT INTO reptracker_app_status (continue_processing, is_accounts_copied) VALUES (True, False);

  -- Version tracking table
  CREATE TABLE IF NOT EXISTS version
  (
    git_hash TEXT -- Git commit hash of the installed version
  );

  ------------- ACCOUNT REPUTATIONS ----------------
  CREATE TABLE IF NOT EXISTS account_reputations
  (
    account_id  INT     NOT NULL, -- hive.accounts_view.id
    reputation  BIGINT  NOT NULL, -- Raw reputation value (before log transformation)
    is_implicit BOOLEAN,          -- TRUE if reputation was never explicitly set by a vote

    CONSTRAINT pk_account_reputations PRIMARY KEY (account_id)
  );
  PERFORM hive.app_register_table( __schema_name, 'account_reputations', __schema_name );

  ------------- PERMLINKS ----------------
  -- Dictionary table for post permlinks to reduce storage
  CREATE TABLE IF NOT EXISTS permlinks
  (
    permlink_id SERIAL PRIMARY KEY, -- Auto-incrementing ID
    permlink    TEXT UNIQUE         -- The actual permlink string
  );
  PERFORM hive.app_register_table( __schema_name, 'permlinks', __schema_name );

  ------------- ACTIVE VOTES ----------------
  -- Tracks votes on posts for reputation calculation
  CREATE TABLE IF NOT EXISTS active_votes
  (
    author_id          INT    NOT NULL, -- hive.accounts_view.id of the post author
    voter_id           INT    NOT NULL, -- hive.accounts_view.id of the voter
    permlink_serial_id INT    NOT NULL, -- Foreign key to permlinks table
    rshares            BIGINT NOT NULL, -- Vote weight in rshares (reward shares)

    CONSTRAINT pk_active_votes PRIMARY KEY (author_id, permlink_serial_id, voter_id),
    CONSTRAINT fk_active_votes_permlink FOREIGN KEY (permlink_serial_id) REFERENCES permlinks (permlink_id) DEFERRABLE
  );
  PERFORM hive.app_register_table( __schema_name, 'active_votes', __schema_name );

END
$$;

-- ============================================================================
-- CONTROL FUNCTIONS
-- ============================================================================
-- These functions manage the application processing lifecycle.
-- Used by scripts/process_blocks.sh to control block processing.

/**
 * continueProcessing()
 * --------------------
 * Check if the application should continue processing blocks.
 * Called in the main loop to allow graceful shutdown.
 *
 * @returns TRUE if processing should continue, FALSE to stop
 */
CREATE OR REPLACE FUNCTION continueProcessing()
RETURNS BOOLEAN
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN continue_processing FROM reptracker_app_status LIMIT 1;
END
$$;

/**
 * allowProcessing()
 * -----------------
 * Enable block processing. Called at application startup
 * to reset the processing flag after a previous stop.
 */
CREATE OR REPLACE FUNCTION allowProcessing()
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
BEGIN
  UPDATE reptracker_app_status SET continue_processing = True;
END
$$;

/**
 * stopProcessing()
 * ----------------
 * Signal the application to stop processing after the current block.
 * Must be called from a separate session and committed to take effect.
 * The main loop will exit gracefully on next iteration check.
 *
 * Usage: Call from psql or separate connection, then COMMIT.
 */
CREATE OR REPLACE FUNCTION stopProcessing()
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
BEGIN
  UPDATE reptracker_app_status SET continue_processing = False;
END
$$;

/**
 * get_version()
 * -------------
 * Get the currently installed runtime version hash.
 *
 * @returns Text containing the git hash of the running version
 */
CREATE OR REPLACE FUNCTION get_version()
RETURNS TEXT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN runtime_hash FROM version LIMIT 1;
END;
$$;

/**
 * set_version()
 * -------------
 * Set the runtime version hash. Called during installation
 * to record the deployed git commit.
 *
 * @param _git_hash  Git commit hash to store
 */
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

/**
 * do_rep_indexes_exist()
 * ----------------------
 * Check if the partial op_type index for reputation tracker exists and is valid.
 * The index is created by db/create_indexes.sql via hive.create_op_type_partial_index().
 * Index name convention: hive_operations_op_types_{id1}_{id2}_{id3}_idx (sorted IDs).
 *
 * Returns TRUE if:
 *   - hive.create_op_type_partial_index() is not available (older HAF, no index needed)
 *   - The partial index exists and is valid
 * Returns FALSE if the function exists but the index is missing or invalid.
 */
CREATE OR REPLACE FUNCTION do_rep_indexes_exist()
RETURNS BOOLEAN
LANGUAGE 'plpgsql' VOLATILE
AS
$$
DECLARE
  __expected_name TEXT;
  __op_ids SMALLINT[];
BEGIN
  -- If the HAF function doesn't exist, indexes aren't applicable
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'hive' AND p.proname = 'create_op_type_partial_index'
  ) THEN
    RETURN TRUE;
  END IF;

  -- Build the expected index name from the same op types used in create_indexes.sql
  SELECT array_agg(id ORDER BY id)
  INTO __op_ids
  FROM hafd.operation_types
  WHERE name IN (
    'hive::protocol::delete_comment_operation',
    'hive::protocol::comment_payout_update_operation',
    'hive::protocol::effective_comment_vote_operation'
  );

  IF __op_ids IS NULL OR array_length(__op_ids, 1) != 3 THEN
    RETURN FALSE;
  END IF;

  __expected_name := 'hive_operations_op_types_' || array_to_string(__op_ids, '_') || '_idx';

  -- Check the index exists and is valid
  RETURN EXISTS (
    SELECT 1
    FROM pg_indexes pi
    JOIN pg_class c ON c.relname = pi.indexname
    JOIN pg_index i ON c.oid = i.indexrelid
    WHERE pi.indexname = __expected_name AND i.indisvalid
  );
END
$$;

-- ============================================================================
-- BLOCK PROCESSING FUNCTIONS
-- ============================================================================
-- These functions handle block processing dispatch and execution.
-- Called by the main loop for each block range to sync.

/**
 * reptracker_massive_processing()
 * -------------------------------
 * Process a range of blocks during initial sync (MASSIVE_PROCESSING stage).
 * Optimized for throughput with synchronous_commit OFF.
 *
 * @param _from  First block number to process
 * @param _to    Last block number to process
 * @param _logs  Enable progress logging
 */
CREATE OR REPLACE PROCEDURE reptracker_massive_processing(
    IN _from INT,
    IN _to INT,
    IN _logs BOOLEAN
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __start_ts TIMESTAMPTZ;
  __end_ts   TIMESTAMPTZ;
BEGIN
  PERFORM set_config('synchronous_commit', 'OFF', false);

  IF _logs THEN
    RAISE NOTICE 'Reptracker is attempting to process a block range: <%, %>', _from, _to;
    __start_ts := clock_timestamp();
  END IF;

  PERFORM reptracker_block_range_data(_from, _to);

  IF _logs THEN
    __end_ts := clock_timestamp();
    RAISE NOTICE 'Reptracker processed block range: <%, %> successfully in % s', _from, _to, (EXTRACT(EPOCH FROM __end_ts - __start_ts));
  END IF;
END
$$;

/**
 * reptracker_single_processing()
 * ------------------------------
 * Process a single block during LIVE sync stage.
 * Uses synchronous_commit ON for data safety.
 *
 * Called for each new block after initial sync is complete.
 *
 * @param _from  Block number to process
 * @param _to    Block number to process (same as _from in LIVE mode)
 * @param _logs  Enable progress logging
 */
CREATE OR REPLACE PROCEDURE reptracker_single_processing(
    IN _from INT,
    IN _to INT,
    IN _logs BOOLEAN
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __start_ts TIMESTAMPTZ;
  __end_ts   TIMESTAMPTZ;
BEGIN
  PERFORM set_config('synchronous_commit', 'ON', false);

  IF _logs THEN
    RAISE NOTICE 'Reptracker processing block: %...', _from;
    __start_ts := clock_timestamp();
  END IF;

  PERFORM reptracker_block_range_data(_from, _to);

  IF _logs THEN
    __end_ts := clock_timestamp();
    RAISE NOTICE 'Reptracker processed block % successfully in % s', _from, (EXTRACT(EPOCH FROM __end_ts - __start_ts));
  END IF;
END
$$;

/**
 * continueProcessingLoop()
 * ------------------------
 * Check if the main loop should continue iterating.
 * Handles both block limit and stop signal checks.
 *
 * @param _appContext     HAF context name
 * @param _maxBlockLimit  Optional maximum block to process
 * @param _blocks_range   Current block range (NULL when waiting)
 * @returns TRUE to continue, FALSE to exit the loop
 */
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
  -- Check if we've reached the block limit
  IF _blocks_range IS NULL AND _maxBlockLimit IS NOT NULL THEN
    IF hive.app_get_current_block_num(_appContext) >= _maxBlockLimit THEN
      RAISE NOTICE 'Blocks limit reached. Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
      RETURN FALSE;
    END IF;
  END IF;

  -- Check if stop was requested
  IF NOT continueProcessing() THEN
    RAISE NOTICE 'Exiting application main loop at processed block: %.', hive.app_get_current_block_num(_appContext);
    RETURN FALSE;
  END IF;

  RETURN TRUE;
END
$$;

-- ============================================================================
-- APPLICATION ENTRY POINT
-- ============================================================================

/**
 * main()
 * ------
 * Application entry point that starts the block processing loop.
 * Called by scripts/process_blocks.sh to begin syncing.
 *
 * Behavior:
 * 1. Enables processing via allowProcessing()
 * 2. Enters infinite loop calling hive.app_next_iteration()
 * 3. Processes each block range via reptracker_process_blocks()
 * 4. Exits when continueProcessing() returns FALSE
 *
 * To stop: Call stopProcessing() from another session and commit.
 *
 * @param _appContext    HAF context name
 * @param _maxBlockLimit Optional maximum block to process (for testing)
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
      _limit => _maxBlockLimit
    );

    IF NOT continueProcessingLoop(_appContext, _maxBlockLimit, _blocks_range) THEN
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

/**
 * reptracker_process_blocks()
 * ---------------------------
 * Main dispatch function for block processing.
 * Routes to either massive or single processing based on current HAF stage.
 *
 * Behavior by stage:
 * - MASSIVE_PROCESSING: Calls reptracker_massive_processing() with table vacuums
 * - LIVE: Calls reptracker_single_processing()
 *
 * @param _context_name  HAF context name (typically schema name)
 * @param _block_range   Range of blocks to process (first_block, last_block)
 * @param _logs          Enable progress logging (default: true)
 */
DO $$
DECLARE
  __schema_name VARCHAR;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  EXECUTE format(
    $BODY$
      CREATE OR REPLACE PROCEDURE %I.reptracker_process_blocks(
        _context_name hive.context_name,
        _block_range hive.blocks_range,
        _logs BOOLEAN = true
      )
      LANGUAGE 'plpgsql'
      AS
      $pb$
      BEGIN
        IF hive.get_current_stage_name(_context_name) = 'MASSIVE_PROCESSING' THEN
          CALL reptracker_massive_processing(_block_range.first_block, _block_range.last_block, _logs);
          -- Request periodic table vacuums during bulk processing
          PERFORM hive.app_request_table_vacuum('%s', 'account_reputations', interval '10 minutes');
          PERFORM hive.app_request_table_vacuum('%s', 'active_votes', interval '10 minutes');
          PERFORM hive.app_request_table_vacuum('%s', 'permlinks', interval '100 minutes');
          RETURN;
        END IF;

        CALL reptracker_single_processing(_block_range.first_block, _block_range.last_block, _logs);
      END
      $pb$
    $BODY$, __schema_name, __schema_name, __schema_name, __schema_name);
END
$$;

RESET ROLE;
