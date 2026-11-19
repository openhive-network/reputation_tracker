SET ROLE reptracker_owner;

-- The per-vote signature this batch function replaced; an upgrade in place would
-- otherwise keep it as a second overload.
DROP FUNCTION IF EXISTS reptracker_backend.calculate_account_reputations(INT, INT, BIGINT, BIGINT);

/**
 * Applies a batch of votes to account_reputations, in array order.
 *
 * The four arrays are parallel, one element per vote, sorted in blockchain order
 * (source_op): _author_ids[i] received _rshares[i] from _voter_ids[i], replacing a
 * previous vote of _prev_rshares[i] (0 if none). Author ids must not be NULL.
 *
 * Each vote's effect depends on the author's and voter's reputation after every
 * earlier vote, so the votes are applied one by one, but against plpgsql arrays
 * holding the batch's accounts (one read of account_reputations), and the changed
 * accounts are written back with one upsert.
 */
CREATE OR REPLACE FUNCTION reptracker_backend.calculate_account_reputations(
    _author_ids   INT[],
    _voter_ids    INT[],
    _rshares      BIGINT[],  -- Current vote weight (positive=upvote, negative=downvote)
    _prev_rshares BIGINT[]   -- Previous vote weight (0 if first vote on this post)
)
RETURNS VOID
LANGUAGE 'plpgsql'
VOLATILE
SET jit = OFF
-- A generic plan estimates unnest() of an array parameter at a few rows and joins
-- the batch's (tens of thousands of) votes and accounts by nested loop; a custom
-- plan sees the arrays' real lengths.
SET plan_cache_mode = force_custom_plan
AS $BODY$
DECLARE
  -- The batch's accounts, indexed 1..n; votes refer to them by index.
  -- __voter_idx is 0 for a vote whose voter has no id: element 0 reads as NULL,
  -- and the arrays stay NULL-free, which keeps element access O(1).
  __account_ids        INT[];
  __reputations        BIGINT[];
  __is_implicit        BOOLEAN[];
  __is_changed         BOOLEAN[];
  __author_idx         INT[];
  __voter_idx          INT[];

  -- Flag to indicate if reputation was changed (skip DB write if no change)
  _is_changed         BOOLEAN;

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
  _scaling_bits        INT := reptracker_backend.reputation_scaling_bits();
  _prev_rshares_scaled BIGINT;
  _rshares_scaled      BIGINT;
  _prev_rshares_i      BIGINT;
  _rshares_i           BIGINT;

  __a INT;
  __v INT;
BEGIN
  IF COALESCE(cardinality(_author_ids), 0) = 0 THEN
    RETURN;
  END IF;

  -- A NULL author would drop its vote from the index join below and misalign the
  -- remaining votes with their rshares.
  IF array_position(_author_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'calculate_account_reputations: NULL author id at vote %', array_position(_author_ids, NULL);
  END IF;

  -- Load current reputation state of every account in the batch.
  -- Accounts not yet in account_reputations start at 0 / implicit.
  SELECT
    array_agg(a.account_id ORDER BY a.account_id),
    array_agg(COALESCE(ar.reputation, 0) ORDER BY a.account_id),
    array_agg(COALESCE(ar.is_implicit, TRUE) ORDER BY a.account_id),
    array_agg(FALSE ORDER BY a.account_id)
  INTO __account_ids, __reputations, __is_implicit, __is_changed
  FROM (
    SELECT DISTINCT u.account_id
    FROM unnest(_author_ids || _voter_ids) AS u(account_id)
    WHERE u.account_id IS NOT NULL
  ) a
  LEFT JOIN account_reputations ar ON ar.account_id = a.account_id;

  SELECT
    array_agg(ai.idx ORDER BY v.ord),
    array_agg(COALESCE(vi.idx, 0) ORDER BY v.ord)
  INTO __author_idx, __voter_idx
  FROM unnest(_author_ids, _voter_ids) WITH ORDINALITY AS v(author_id, voter_id, ord)
  JOIN unnest(__account_ids) WITH ORDINALITY AS ai(account_id, idx) ON ai.account_id = v.author_id
  LEFT JOIN unnest(__account_ids) WITH ORDINALITY AS vi(account_id, idx) ON vi.account_id = v.voter_id;

  FOR __i IN 1 .. cardinality(__author_idx) LOOP
    __a := __author_idx[__i];
    __v := __voter_idx[__i];
    _rshares_i := _rshares[__i];
    _prev_rshares_i := _prev_rshares[__i];
    _rshares_scaled := _rshares_i >> _scaling_bits;
    _prev_rshares_scaled := _prev_rshares_i >> _scaling_bits;
    _is_changed := FALSE;

    _author_reputation := __reputations[__a];
    _author_is_implicit := __is_implicit[__a];

    _voter_reputation := COALESCE(__reputations[__v], 0);
    _voter_is_implicit := COALESCE(__is_implicit[__v], TRUE);

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
      (_prev_rshares_i >= 0 OR (_prev_rshares_i < 0 AND NOT _voter_is_implicit AND
      _voter_reputation > _author_reputation - _prev_rshares_scaled)) THEN

      -- Subtract the previous vote's scaled impact from author's reputation
      _author_reputation := _author_reputation - _prev_rshares_scaled;
      -- If reputation drops to exactly 0, mark as implicit (edge case)
      _author_is_implicit := _author_reputation = 0;
      _is_changed := TRUE;

      -- Self-vote edge case: if author voted on their own post,
      -- voter's reputation state must be synchronized since they're the same account
      IF __a = __v THEN
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
      (_rshares_i >= 0 OR (_rshares_i < 0 AND NOT _voter_is_implicit AND
      _voter_reputation > _author_reputation)) THEN

      _is_changed := TRUE;
      -- Add the new vote's scaled impact to author's reputation
      _author_reputation := _author_reputation + _rshares_scaled;
      -- Author now has explicit reputation (received a counted vote)
      _author_is_implicit := FALSE;

    END IF;

    IF _is_changed THEN
      __reputations[__a] := _author_reputation;
      __is_implicit[__a] := _author_is_implicit;
      __is_changed[__a] := TRUE;
    END IF;
  END LOOP;

  -----------------------------------------------------------------------------------
  -- PHASE 3: Persist changed accounts (one statement for the batch)
  -----------------------------------------------------------------------------------
  -- An existing row whose final state equals its stored state is left untouched,
  -- so it leaves no dead tuple behind.
  INSERT INTO account_reputations (account_id, reputation, is_implicit)
  SELECT u.account_id, u.reputation, u.is_implicit
  FROM unnest(__account_ids, __reputations, __is_implicit, __is_changed)
    AS u(account_id, reputation, is_implicit, is_changed)
  LEFT JOIN account_reputations ar ON ar.account_id = u.account_id
  WHERE u.is_changed
    AND (ar.account_id IS NULL
      OR (ar.reputation, ar.is_implicit) IS DISTINCT FROM (u.reputation, u.is_implicit))
  ON CONFLICT (account_id) DO UPDATE SET
    reputation = EXCLUDED.reputation,
    is_implicit = EXCLUDED.is_implicit;

END
$BODY$;

RESET ROLE;
