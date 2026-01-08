SET ROLE reptracker_owner;

DROP TYPE IF EXISTS reptracker_backend.effective_vote_return CASCADE;
CREATE TYPE reptracker_backend.effective_vote_return AS
(
    author TEXT,
    voter TEXT,
    permlink TEXT,
    rshares BIGINT
);

CREATE OR REPLACE FUNCTION reptracker_backend.process_vote_impacting_operations(IN _operation_body JSONB, IN _op_type_id INT)
RETURNS reptracker_backend.effective_vote_return
LANGUAGE plpgsql
STABLE
AS
$BODY$
BEGIN
  RETURN (
    CASE 
      WHEN _op_type_id = 72 THEN
        reptracker_backend.process_effective_vote_operation(_operation_body)

      ELSE
        reptracker_backend.process_deleted_comment_operation(_operation_body)
    END
  );

END;
$BODY$;

--72
CREATE OR REPLACE FUNCTION reptracker_backend.process_effective_vote_operation(IN _operation_body JSONB)
RETURNS reptracker_backend.effective_vote_return
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    ((_operation_body)->'value'->>'author')::TEXT,
    ((_operation_body)->'value'->>'voter')::TEXT,
    ((_operation_body)->'value'->>'permlink')::TEXT,
    (
        CASE jsonb_typeof(_operation_body -> 'value' -> 'rshares')
        WHEN 'number' THEN
        (_operation_body -> 'value' -> 'rshares')::BIGINT
        WHEN 'string' THEN
            trim(both '"' FROM (_operation_body -> 'value' ->> 'rshares'))::BIGINT
        ELSE
          NULL::BIGINT
        END
    ) 
  )::reptracker_backend.effective_vote_return;
  
END
$$;

--17,61
CREATE OR REPLACE FUNCTION reptracker_backend.process_deleted_comment_operation(IN _operation_body JSONB)
RETURNS reptracker_backend.effective_vote_return
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    ((_operation_body)->'value'->>'author')::TEXT,
    NULL,
    ((_operation_body)->'value'->>'permlink')::TEXT,
    NULL
  )::reptracker_backend.effective_vote_return;
  
END
$$;

CREATE OR REPLACE FUNCTION reptracker_backend.calculate_account_reputations(
    _author_id INT,
    _voter_id INT,
    _rshares BIGINT,
    _prev_rshares BIGINT
)
RETURNS VOID
LANGUAGE 'plpgsql'
VOLATILE
SET jit = OFF
AS $BODY$
DECLARE
  _is_changed BOOLEAN := FALSE;

  _author_reputation BIGINT;
  _author_is_implicit BOOLEAN;
  _voter_reputation BIGINT;
  _voter_is_implicit BOOLEAN;
BEGIN

  SELECT ar.reputation, ar.is_implicit
  INTO _author_reputation, _author_is_implicit
  FROM account_reputations ar WHERE ar.account_id = _author_id;

  SELECT ar.reputation, ar.is_implicit
  INTO _voter_reputation, _voter_is_implicit
  FROM account_reputations ar WHERE ar.account_id = _voter_id;

  _author_reputation := COALESCE(_author_reputation, 0);
  _author_is_implicit := COALESCE(_author_is_implicit, TRUE);
  
  _voter_reputation := COALESCE(_voter_reputation,0);
  _voter_is_implicit := COALESCE(_voter_is_implicit, TRUE);

--- Author must have set explicit reputation to allow its correction
--- Voter must have explicitly set reputation to match hived old conditions
IF NOT _author_is_implicit AND _voter_reputation >= 0 AND 
  (_prev_rshares >= 0 OR (_prev_rshares < 0 AND NOT _voter_is_implicit AND _voter_reputation > _author_reputation - (_prev_rshares >> 6)::BIGINT)) THEN

  _author_reputation := _author_reputation - (_prev_rshares >> 6)::BIGINT;
  _author_is_implicit := _author_reputation = 0;
  _is_changed := TRUE;

  IF _author_id = _voter_id THEN 
    --- reread voter's rep. since it can change above if author == voter
    _voter_is_implicit := _author_is_implicit;
    _voter_reputation := _author_reputation;
  END IF;

END IF;

IF _voter_reputation >= 0 AND (_rshares >= 0 OR (_rshares < 0 AND NOT _voter_is_implicit AND _voter_reputation > _author_reputation)) THEN

  _is_changed := TRUE;
  _author_reputation := _author_reputation + (_rshares >> 6)::BIGINT;
  _author_is_implicit := false;

END IF;

IF _is_changed THEN

  INSERT INTO account_reputations (account_id, reputation, is_implicit)
  SELECT _author_id, _author_reputation, _author_is_implicit
  ON CONFLICT (account_id) DO UPDATE
  SET 
      reputation = EXCLUDED.reputation, 
      is_implicit = EXCLUDED.is_implicit;

END IF;

END
$BODY$;

RESET ROLE;
