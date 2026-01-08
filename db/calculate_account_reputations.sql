SET ROLE reptracker_owner;

CREATE OR REPLACE FUNCTION reptracker_backend.calculate_account_reputations(
    _author_id INT,
    _voter_id INT,
    _rshares BIGINT,      -- Current vote weight (positive=upvote, negative=downvote)
    _prev_rshares BIGINT  -- Previous vote weight (0 if first vote on this post)
)
RETURNS VOID
LANGUAGE 'plpgsql'
VOLATILE
SET jit = OFF
AS $BODY$
DECLARE
  -- Flag to indicate if reputation was changed (skip DB write if no change)
  _is_changed         BOOLEAN := FALSE;

  -- Author reputation and implicit flag
  -- is_implicit=TRUE means account never received a vote that affected reputation
  _author_reputation  BIGINT;
  _author_is_implicit BOOLEAN;

  -- Voter reputation and implicit flag
  -- Voter's reputation determines if their vote can affect author's reputation
  _voter_reputation   BIGINT;
  _voter_is_implicit  BOOLEAN;

  -- Cached constant: reputation_scaling_bits() returns 6
  -- Scaling formula: reputation_change = rshares >> 6 (equivalent to rshares / 64)
  -- This dampens vote weight so large-stake votes don't dominate reputation
  _scaling_bits        INT    := reptracker_backend.reputation_scaling_bits();
  _prev_rshares_scaled BIGINT := (_prev_rshares >> _scaling_bits)::BIGINT;
  _rshares_scaled      BIGINT := (_rshares      >> _scaling_bits)::BIGINT;
BEGIN

  -- Fetch current reputation state for author
  -- Returns NULL if account has never had reputation recorded
  SELECT ar.reputation, ar.is_implicit
  INTO _author_reputation, _author_is_implicit
  FROM account_reputations ar WHERE ar.account_id = _author_id;

  -- Fetch current reputation state for voter
  SELECT ar.reputation, ar.is_implicit
  INTO _voter_reputation, _voter_is_implicit
  FROM account_reputations ar WHERE ar.account_id = _voter_id;

  -- Default values for accounts not yet in reputation table
  _author_reputation := COALESCE(_author_reputation, 0);
  _author_is_implicit := COALESCE(_author_is_implicit, TRUE);

  _voter_reputation := COALESCE(_voter_reputation, 0);
  _voter_is_implicit := COALESCE(_voter_is_implicit, TRUE);

  -----------------------------------------------------------------------------------
  -- PHASE 1: Undo previous vote's reputation impact (if vote changed)
  -----------------------------------------------------------------------------------
  -- This handles vote changes: if user previously voted +100 and now votes +50,
  -- we first subtract the old +100 impact, then add the new +50 impact.
  --
  -- Conditions to undo previous vote:
  --   1. Author must have explicit reputation (received at least one counted vote)
  --   2. Voter must have non-negative reputation (negative rep voters are ignored)
  --   3. For downvotes (prev_rshares < 0): voter must have explicit rep AND
  --      voter's reputation must exceed author's reputation after removing the downvote
  --      (prevents low-rep accounts from affecting high-rep accounts with downvotes)
  IF NOT _author_is_implicit AND _voter_reputation >= 0 AND
    (_prev_rshares >= 0 OR (_prev_rshares < 0 AND NOT _voter_is_implicit AND
    _voter_reputation > _author_reputation - _prev_rshares_scaled)) THEN

    -- Subtract the previous vote's scaled impact from author's reputation
    _author_reputation := _author_reputation - _prev_rshares_scaled;
    -- If reputation drops to exactly 0, mark as implicit (edge case)
    _author_is_implicit := _author_reputation = 0;
    _is_changed := TRUE;

    -- Self-vote edge case: if author voted on their own post,
    -- voter's reputation state must be synchronized since they're the same account
    IF _author_id = _voter_id THEN
      _voter_is_implicit := _author_is_implicit;
      _voter_reputation := _author_reputation;
    END IF;

  END IF;

  -----------------------------------------------------------------------------------
  -- PHASE 2: Apply new vote's reputation impact
  -----------------------------------------------------------------------------------
  -- Conditions to apply new vote:
  --   1. Voter must have non-negative reputation
  --   2. For upvotes (rshares >= 0): always apply
  --   3. For downvotes (rshares < 0): voter must have explicit rep AND
  --      voter's reputation must exceed author's (can't punch up)
  IF _voter_reputation >= 0 AND
    (_rshares >= 0 OR (_rshares < 0 AND NOT _voter_is_implicit AND
    _voter_reputation > _author_reputation)) THEN

    _is_changed := TRUE;
    -- Add the new vote's scaled impact to author's reputation
    _author_reputation := _author_reputation + _rshares_scaled;
    -- Author now has explicit reputation (received a counted vote)
    _author_is_implicit := FALSE;

  END IF;

  -----------------------------------------------------------------------------------
  -- PHASE 3: Persist changes to database (only if reputation changed)
  -----------------------------------------------------------------------------------
  IF _is_changed THEN

    INSERT INTO account_reputations (account_id, reputation, is_implicit)
    SELECT _author_id, _author_reputation, _author_is_implicit
    ON CONFLICT (account_id) DO UPDATE SET
      reputation = EXCLUDED.reputation,
      is_implicit = EXCLUDED.is_implicit;

  END IF;

END
$BODY$;

RESET ROLE;
