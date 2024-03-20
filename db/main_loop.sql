SET ROLE reptracker_owner;


CREATE OR REPLACE PROCEDURE reptracker_app.do_massive_processing(IN _appContext VARCHAR, in _from INT, in _to INT, IN _step INT, INOUT _last_block integer)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  _final_block integer;
BEGIN
  RAISE NOTICE 'Entering massive processing of block range: <%, %>...', _from, _to;
  RAISE NOTICE 'Detaching HAF application context...';
  PERFORM hive.app_context_detach(_appContext);

  WITH select_account_reputations AS MATERIALIZED
  (
  SELECT ha.id AS ha_id, 0, true, ar.account_id as ar_id
  FROM hive.accounts_view ha
  LEFT JOIN reptracker_app.account_reputations ar ON ar.account_id = ha.id
  )
  INSERT INTO reptracker_app.account_reputations
    (account_id, reputation, is_implicit)
  SELECT sar.ha_id, 0, true
  FROM select_account_reputations sar
  WHERE sar.ar_id IS NULL
  ;

  --- You can do here also other things to speedup your app, i.e. disable constrains, remove indexes etc.

  FOR b IN _from .. _to BY _step LOOP
    _last_block := b + _step - 1;

    IF _last_block > _to THEN --- in case the _step is larger than range length
      _last_block := _to;
    END IF;

    RAISE NOTICE 'Attempting to process a block range: <%, %>', b, _last_block;

    PERFORM reptracker_app.process_block_range_data_a(b, _last_block);

    PERFORM hive.app_set_current_block_num(_appContext, _last_block);
    COMMIT;

    RAISE NOTICE 'Block range: <%, %> processed successfully.
    ', b, _last_block;

    EXIT WHEN NOT reptracker_app.continueProcessing();

  END LOOP;

  RAISE NOTICE 'Attaching HAF application context at block: %.', _last_block;
  PERFORM hive.app_context_attach(_appContext);

 --- You should enable here all things previously disabled at begin of this function...

 RAISE NOTICE 'Leaving massive processing of block range: <%, %>...', _from, _last_block;
END
$$
;

CREATE OR REPLACE PROCEDURE reptracker_app.processBlock(in _block INT)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __start_ts timestamptz;
  __end_ts   timestamptz;
BEGIN
  RAISE NOTICE 'Processing block: %...', _block;
  __start_ts := clock_timestamp();
  PERFORM reptracker_app.process_block_range_data_a(_block, _block);
  COMMIT; -- For single block processing we want to commit all changes for each one.
  __end_ts := clock_timestamp();

  RAISE NOTICE 'Done in time: % ms
  ', 1000 * (extract(epoch FROM __end_ts - __start_ts));
END
$$
;

/** Application entry point, which:
  - defines its data schema,
  - creates HAF application context,
  - starts application main-loop (which iterates infinitely). To stop it call `reptracker_app.stopProcessing();` from another session and commit its trasaction.
*/
CREATE OR REPLACE PROCEDURE reptracker_app.main(IN _appContext VARCHAR = 'reptracker_app', IN _maxBlockLimit INT = 0)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __last_block INT := 0;
  __next_block_range hive.blocks_range;
  __block_range_len INT := 0;
  __massive_processing_threshold INT := 100;
  __original_commit_mode TEXT;
  __commit_mode_changed BOOLEAN := false;
BEGIN
  IF _maxBlockLimit != 0 THEN
    RAISE NOTICE 'Max block limit is specified as: %', _maxBlockLimit;
  END IF;

  PERFORM reptracker_app.allowProcessing();
  COMMIT;

  SELECT current_setting('synchronous_commit') into __original_commit_mode;


  SELECT hive.app_get_current_block_num(_appContext) INTO __last_block;
  RAISE NOTICE 'Last block processed by application: %', __last_block;


  IF NOT hive.app_context_is_attached(_appContext) THEN
    CALL hive.appproc_context_attach(_appContext);
  END IF;
  RAISE NOTICE 'Entering application main loop...';

  WHILE reptracker_app.continueProcessing() AND (_maxBlockLimit = 0 OR __last_block < _maxBlockLimit) LOOP
    __next_block_range := hive.app_next_block(_appContext);

    IF __next_block_range IS NULL THEN
      RAISE WARNING 'Waiting for next block...';
    ELSE
      IF _maxBlockLimit != 0 and __next_block_range.first_block > _maxBlockLimit THEN
        __next_block_range.first_block  := _maxBlockLimit;
      END IF;

      IF _maxBlockLimit != 0 and __next_block_range.last_block > _maxBlockLimit THEN
        __next_block_range.last_block  := _maxBlockLimit;
      END IF;

      --RAISE NOTICE 'Attempting to process block range: <%,%>', __next_block_range.first_block, __next_block_range.last_block;

      __block_range_len := __next_block_range.last_block - __next_block_range.first_block + 1;

      IF __block_range_len >= __massive_processing_threshold THEN
        IF NOT __commit_mode_changed AND __original_commit_mode != 'OFF' THEN
          PERFORM set_config('synchronous_commit', 'OFF', false);
          __commit_mode_changed := true;
        END IF;
        CALL reptracker_app.do_massive_processing(_appContext, __next_block_range.first_block, __next_block_range.last_block, 10000, __last_block);
      ELSE
        IF __commit_mode_changed THEN
          PERFORM set_config('synchronous_commit', __original_commit_mode, false);
          __commit_mode_changed := false;
        END IF;
          CALL reptracker_app.processBlock(__next_block_range.first_block);
          __last_block := __next_block_range.first_block;
      END IF;

    END IF;

  COMMIT;
  END LOOP;

  RAISE NOTICE 'Exiting application main loop at processed block: %.', __last_block;
END
$$
;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reptracker_app TO reputation_tracker_writer_group;

RESET ROLE;
