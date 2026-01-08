SET ROLE reptracker_owner;

CREATE OR REPLACE FUNCTION reptracker_backend.validate_account(_account_id INT, _account_name TEXT, _required BOOLEAN)
RETURNS VOID
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  IF (_required AND _account_id IS NULL) OR (NOT _required AND _account_name IS NOT NULL AND _account_id IS NULL) THEN
    PERFORM reptracker_backend.rest_raise_missing_account(_account_name);
  END IF;
END
$$;

RESET ROLE;
