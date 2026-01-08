SET ROLE reptracker_owner;

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
  (_prev_rshares >= 0 OR (_prev_rshares < 0 AND NOT _voter_is_implicit AND
   _voter_reputation > _author_reputation - (_prev_rshares >> reptracker_backend.reputation_scaling_bits())::BIGINT)) THEN

  _author_reputation := _author_reputation - (_prev_rshares >> reptracker_backend.reputation_scaling_bits())::BIGINT;
  _author_is_implicit := _author_reputation = 0;
  _is_changed := TRUE;

  IF _author_id = _voter_id THEN
    --- reread voter's rep. since it can change above if author == voter
    _voter_is_implicit := _author_is_implicit;
    _voter_reputation := _author_reputation;
  END IF;

END IF;

IF _voter_reputation >= 0 AND
  (_rshares >= 0 OR (_rshares < 0 AND NOT _voter_is_implicit AND
   _voter_reputation > _author_reputation)) THEN

  _is_changed := TRUE;
  _author_reputation := _author_reputation + (_rshares >> reptracker_backend.reputation_scaling_bits())::BIGINT;
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
