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


RESET ROLE;
