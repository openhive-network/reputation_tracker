SET ROLE reputation_tracker_app_owner;

--- Helper function telling application main-loop to continue execution.
CREATE OR REPLACE FUNCTION reputation_tracker_app.continueProcessing()
RETURNS BOOLEAN
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  RETURN continue_processing FROM reputation_tracker_app.app_status LIMIT 1;
END
$$
;

CREATE OR REPLACE FUNCTION reputation_tracker_app.allowProcessing()
RETURNS VOID
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  UPDATE reputation_tracker_app.app_status SET continue_processing = True;
END
$$
;

--- Helper function to be called from separate transaction (must be committed) to safely stop execution of the application.
CREATE OR REPLACE FUNCTION reputation_tracker_app.stopProcessing()
RETURNS VOID
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  UPDATE reputation_tracker_app.app_status SET continue_processing = False;
END
$$
;

CREATE OR REPLACE FUNCTION reputation_tracker_app.storeLastProcessedBlock(IN _lastBlock INT)
RETURNS VOID
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  UPDATE reputation_tracker_app.app_status SET last_processed_block = _lastBlock;
END
$$
;

CREATE OR REPLACE FUNCTION reputation_tracker_app.lastProcessedBlock()
RETURNS INT
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  RETURN last_processed_block FROM reputation_tracker_app.app_status LIMIT 1;
END
$$
;


CREATE OR REPLACE PROCEDURE reputation_tracker_app.do_massive_processing(IN _appContext VARCHAR, in _from INT, in _to INT, IN _step INT, OUT _last_block integer)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  _final_block integer;
BEGIN
  RAISE NOTICE 'Entering massive processing of block range: <%, %>...', _from, _to;
  RAISE NOTICE 'Detaching HAF application context...';
  PERFORM hive.app_context_detach(_appContext);

  --- You can do here also other things to speedup your app, i.e. disable constrains, remove indexes etc.

  FOR b IN _from .. _to BY _step LOOP
    _last_block := b + _step - 1;

    IF _last_block > _to THEN --- in case the _step is larger than range length
      _last_block := _to;
    END IF;

    RAISE NOTICE 'Attempting to process a block range: <%, %>', b, _last_block;

    _last_block := reputation_tracker_app.update_account_reputations(b, _last_block, 1000);

    COMMIT;

    RAISE NOTICE 'Block range: <%, %> processed successfully.', b, _last_block;

    EXIT WHEN NOT reputation_tracker_app.continueProcessing();

  END LOOP;


  IF reputation_tracker_app.continueProcessing() AND _last_block < _to THEN
    RAISE NOTICE 'Attempting to process a block range (rest): <%, %>', _last_block+1, _to;
    
    --- Supplement last part of range if anything left.
    _final_block := reputation_tracker_app.update_account_reputations(_last_block+1, _to, 1000);

    COMMIT;
    RAISE NOTICE 'Block range: <%, %> processed successfully.', _last_block+1, _final_block;

    _last_block := _final_block;
  END IF;

  RAISE NOTICE 'Attaching HAF application context at block: %.', _last_block;
  PERFORM hive.app_context_attach(_appContext, _last_block);
  COMMIT;
 --- You should enable here all things previously disabled at begin of this function...

 RAISE NOTICE 'Leaving massive processing of block range: <%, %>...', _from, _last_block;
END
$$
;

CREATE OR REPLACE PROCEDURE reputation_tracker_app.processBlock(in _block INT)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __last_block integer;
BEGIN
  RAISE NOTICE 'Processing block: %...', _block;
  __last_block := reputation_tracker_app.update_account_reputations(_block, _block, 1000);
  PERFORM reputation_tracker_app.storeLastProcessedBlock(__last_block);
  COMMIT; -- For single block processing we want to commit all changes for each one.
  RAISE NOTICE 'Done.';
END
$$
;

/** Application entry point, which:
  - defines its data schema,
  - creates HAF application context,
  - starts application main-loop (which iterates infinitely). To stop it call `reputation_tracker_app.stopProcessing();` from another session and commit its trasaction.
*/
CREATE OR REPLACE PROCEDURE reputation_tracker_app.main(IN _appContext VARCHAR = 'reputation_tracker_app', IN _maxBlockLimit INT = 0)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  __last_block INT := 0;
  __next_block_range hive.blocks_range;
  __block_range_len INT := 0;
  __massive_processing_threshold INT := 100;
BEGIN
  IF _maxBlockLimit != 0 THEN
    RAISE NOTICE 'Max block limit is specified as: %', _maxBlockLimit;
  END IF;

  PERFORM reputation_tracker_app.allowProcessing();
  COMMIT;

  SELECT reputation_tracker_app.lastProcessedBlock() INTO __last_block;

  RAISE NOTICE 'Last block processed by application: %', __last_block;

  IF NOT hive.app_context_is_attached(_appContext) THEN
    PERFORM hive.app_context_attach(_appContext, __last_block);
  END IF;

  RAISE NOTICE 'Entering application main loop...';

  WHILE reputation_tracker_app.continueProcessing() AND (_maxBlockLimit = 0 OR __last_block < _maxBlockLimit) LOOP
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
        CALL reputation_tracker_app.do_massive_processing(_appContext, __next_block_range.first_block, __next_block_range.last_block, 5000000, __last_block);
      ELSE
        FOR __block IN __next_block_range.first_block .. __next_block_range.last_block LOOP
          CALL reputation_tracker_app.processBlock(__block);
          __last_block := __block;

          EXIT WHEN reputation_tracker_app.continueProcessing() OR (_maxBlockLimit != 0 AND __last_block >= _maxBlockLimit);
        END LOOP;
      END IF;

    END IF;

  END LOOP;

  RAISE NOTICE 'Exiting application main loop at processed block: %.', __last_block;
  PERFORM reputation_tracker_app.storeLastProcessedBlock(__last_block);

  COMMIT;
END
$$
;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reputation_tracker_app TO reputation_tracker_writer_group;

RESET ROLE;

