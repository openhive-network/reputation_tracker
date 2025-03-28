SET ROLE reptracker_owner;

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

CREATE OR REPLACE FUNCTION rest_raise_missing_account(_account_name TEXT)
RETURNS VOID
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  RAISE EXCEPTION 'Account ''%'' does not exist', _account_name;
END
$$;

RESET ROLE;
