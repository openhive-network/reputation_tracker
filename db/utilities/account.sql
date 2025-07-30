SET ROLE reptracker_owner;

CREATE OR REPLACE FUNCTION reptracker_backend.get_account_id(_account_name TEXT, _required BOOLEAN)
RETURNS INT STABLE
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  _account_id INT := (SELECT av.id FROM hive.accounts_view av WHERE av.name = _account_name);
BEGIN
  PERFORM reptracker_backend.validate_account(_account_id, _account_name, _required);

  RETURN _account_id;
END
$$;

RESET ROLE;
