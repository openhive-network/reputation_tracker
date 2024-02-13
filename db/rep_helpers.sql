SET ROLE reptracker_owner;

CREATE OR REPLACE FUNCTION reptracker_app.continueProcessing()
RETURNS BOOLEAN
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  RETURN continue_processing FROM reptracker_app.app_status LIMIT 1;
END
$$
;

CREATE OR REPLACE FUNCTION reptracker_app.allowProcessing()
RETURNS VOID
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  UPDATE reptracker_app.app_status SET continue_processing = True;
END
$$
;

--- Helper function to be called from separate transaction (must be committed) to safely stop execution of the application.
CREATE OR REPLACE FUNCTION reptracker_app.stopProcessing()
RETURNS VOID
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  UPDATE reptracker_app.app_status SET continue_processing = False;
END
$$
;

CREATE OR REPLACE FUNCTION reptracker_app.storeLastProcessedBlock(IN _lastBlock INT)
RETURNS VOID
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  UPDATE reptracker_app.app_status SET last_processed_block = _lastBlock;
END
$$
;

CREATE OR REPLACE FUNCTION reptracker_app.lastProcessedBlock()
RETURNS INT
LANGUAGE 'plpgsql'
AS
$$
BEGIN
  RETURN last_processed_block FROM reptracker_app.app_status LIMIT 1;
END
$$
;

RESET ROLE;
