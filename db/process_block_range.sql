SET ROLE reptracker_owner;

CREATE OR REPLACE FUNCTION reptracker_block_range_data(
    IN _first_block_num INT,
    IN _last_block_num INT
)
RETURNS VOID
LANGUAGE 'plpgsql'
VOLATILE
-- Query planner hints for complex CTE chains
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET jit = OFF
-- Plan the CTE chain on every call: a generic plan cached early in a sync keeps the
-- estimates of the then-small active_votes for the rest of the session, as nothing
-- invalidates it while the sync runs.
SET plan_cache_mode = force_custom_plan
AS $BODY$
DECLARE
  __rep_change INT := 0;
  __delete_votes INT;
  __upsert_votes INT;
  __author_ids INT[];
  __voter_ids INT[];
  __rshares BIGINT[];
  __prev_rshares BIGINT[];

  -- Operation type IDs (cached to avoid repeated function calls during query execution)
  -- These map to hafd.operation_types entries for vote-related operations
  __op_vote   INT := reptracker_backend.op_effective_comment_vote();  -- Vote cast/changed
  __op_delete INT := reptracker_backend.op_delete_comment();          -- Post deleted
  __op_payout INT := reptracker_backend.op_comment_payout_update();   -- Post paid out (votes finalized)
BEGIN

-- Permlinks seen for the first time go in first, in a statement of their own, so the
-- CTE chain below finds every permlink of the batch in the table (rows a data-modifying
-- CTE inserts are not visible to the rest of its statement).
-- DO NOTHING avoids lock contention on existing permlinks
INSERT INTO permlinks (permlink)
SELECT DISTINCT p.permlink
FROM operations_view ov
-- Every operation's body carries author and permlink at its top level
CROSS JOIN LATERAL reptracker_backend.process_deleted_comment_operation(ov.body_value) AS p
WHERE ov.op_type_id IN (__op_vote, __op_delete, __op_payout)
  AND ov.block_num BETWEEN _first_block_num AND _last_block_num
ON CONFLICT (permlink) DO NOTHING;

--=====================================================================================
-- MAIN CTE CHAIN: Extract, transform, and load vote operations
--=====================================================================================
WITH

-----------------------------------------------------------------------------------
-- PHASE 1a: Gather relevant operations from blockchain
-----------------------------------------------------------------------------------
-- Filter to only vote-related operations in the block range.
-- MATERIALIZED ensures this is computed once before JSON parsing.
-- Three operation types affect reputation:
--   - effective_comment_vote (72): Vote was cast or changed (has rshares)
--   - delete_comment (17): Post deleted, all votes on it are canceled
--   - comment_payout_update (61): Post paid out, votes are finalized
operations_in_range AS MATERIALIZED (
  SELECT
    ov.body_value,
    ov.op_type_id,
    ov.id AS source_op
  FROM operations_view ov
  WHERE ov.op_type_id IN (__op_vote, __op_delete, __op_payout)
    AND ov.block_num BETWEEN _first_block_num AND _last_block_num
),

-----------------------------------------------------------------------------------
-- PHASE 1b: Parse JSON operation bodies into structured data
-----------------------------------------------------------------------------------
-- CROSS JOIN LATERAL parses each operation's JSONB body_value.
-- Inline CASE avoids wrapper function overhead (process_vote_impacting_operations).
-- MATERIALIZED prevents multiple scans that would re-execute JSON parsing.
-- The parsed row is a column of an OFFSET 0 subquery and its fields are read from
-- there: `(CASE ... END).*` would expand into one CASE, so one parser call, per field.
vote_operations_raw AS MATERIALIZED (
  SELECT
    (p.ev).author,
    (p.ev).voter,
    (p.ev).permlink,
    (p.ev).rshares,
    ov.op_type_id,
    ov.source_op
  FROM operations_in_range ov
  CROSS JOIN LATERAL (
    SELECT
      CASE
        WHEN ov.op_type_id = __op_vote THEN
          reptracker_backend.process_effective_vote_operation(ov.body_value)
        ELSE
          -- Delete and payout operations share same parser (only need author/permlink)
          reptracker_backend.process_deleted_comment_operation(ov.body_value)
      END AS ev
    OFFSET 0
  ) AS p
),

-----------------------------------------------------------------------------------
-- PHASE 2: Resolve account names and permlinks to IDs
-----------------------------------------------------------------------------------
-- One index probe per operation against accounts_view and permlinks, instead of a join
-- of the operations against a dictionary CTE: the operations_view estimate can be 75x
-- low (a payout wave puts 35k payouts in one batch), and such a join then plans as a
-- nested loop rescanning the CTE for every operation. A probe is linear in the batch
-- whatever the estimate.
-- The lateral LIMIT 1 form keeps each lookup an index probe: the HAF context
-- view's block_num predicate is badly overestimated, which otherwise makes a
-- plain join plan as a hash join over a seq scan of the whole table.
vote_operations AS (
  SELECT
    author_acc.id AS author_id,
    voter_acc.id AS voter_id,
    pl.permlink_id,
    vo.rshares,
    vo.op_type_id,
    vo.source_op
  FROM vote_operations_raw vo
  CROSS JOIN LATERAL (SELECT av.id FROM accounts_view av WHERE av.name = vo.author LIMIT 1) author_acc
  -- LEFT JOIN because delete operations have NULL voter
  LEFT JOIN LATERAL (SELECT av.id FROM accounts_view av WHERE av.name = vo.voter LIMIT 1) voter_acc ON TRUE
  CROSS JOIN LATERAL (SELECT p.permlink_id FROM permlinks p WHERE p.permlink = vo.permlink LIMIT 1) pl
),

-----------------------------------------------------------------------------------
-- PHASE 3: Rank operations and find previous votes
-----------------------------------------------------------------------------------
-- When a user changes their vote, we need to:
--   1. Undo the previous vote's reputation impact
--   2. Apply the new vote's impact
-- ROW_NUMBER finds the most recent operation per (author, voter, permlink), LEAD over
-- the same window the vote before it within this batch.
-- Deletes and payouts are matched to votes by window aggregates over (author, permlink)
-- rather than by joins on source_op ranges, which an underestimated batch plans as
-- nested loops over CTE scans, quadratic in the batch's operations (see PHASE 2).

ranked_data AS MATERIALIZED (
  SELECT
    author_id,
    voter_id,
    permlink_id,
    rshares,
    source_op,
    op_type_id,
    -- row_num=1 is most recent, row_num=2 is second most recent, etc.
    ROW_NUMBER() OVER voter_ops AS row_num,
    LEAD(rshares) OVER voter_ops AS prev_rshares,       -- NULL if no previous vote in batch
    COALESCE(LEAD(source_op) OVER voter_ops, 0) AS prev_source_op,
    -- Latest delete/payout of the post at or before this operation
    max(source_op) FILTER (WHERE op_type_id != __op_vote) OVER post_ops_so_far AS last_delete_source_op,
    -- Latest delete/payout of the post in this batch
    max(source_op) FILTER (WHERE op_type_id != __op_vote) OVER post_ops AS final_delete_source_op
  FROM vote_operations
  WINDOW
    voter_ops AS (PARTITION BY author_id, voter_id, permlink_id ORDER BY source_op DESC),
    post_ops AS (PARTITION BY author_id, permlink_id),
    post_ops_so_far AS (PARTITION BY author_id, permlink_id ORDER BY source_op)
),

-- If no previous vote in batch, check active_votes table for historical vote
find_prev_votes_in_table AS (
  SELECT
    q.author_id,
    q.voter_id,
    q.permlink_id,
    q.rshares,
    -- Priority: batch prev_rshares > table rshares > 0 (no previous)
    COALESCE(q.prev_rshares, av.rshares, 0) AS prev_rshares,
    q.source_op,
    q.prev_source_op,
    q.last_delete_source_op,
    q.row_num
  FROM ranked_data q
  -- Only lookup if we didn't find prev vote in batch
  LEFT JOIN active_votes av ON
    q.prev_rshares IS NULL AND
    q.author_id = av.author_id AND
    q.voter_id = av.voter_id AND
    q.permlink_id = av.permlink_serial_id
  WHERE q.op_type_id = __op_vote
),

-----------------------------------------------------------------------------------
-- PHASE 4: Handle vote cancellations from delete operations
-----------------------------------------------------------------------------------
-- If a post was deleted (or paid out) between the previous vote and current vote,
-- the previous vote was already canceled and shouldn't be undone again.
-- A delete/payout lies between them when the post's latest one at or before the
-- current vote is not older than the previous vote (prev_source_op is 0 for a
-- previous vote from active_votes, so any delete/payout in the batch counts).
check_if_prev_balances_canceled AS (
  SELECT
    ja.author_id,
    ja.voter_id,
    ja.permlink_id,
    ja.rshares,
    ja.source_op,
    CASE
      WHEN ja.prev_rshares != 0
        AND (ja.last_delete_source_op IS NULL OR ja.last_delete_source_op < ja.prev_source_op)
        THEN ja.prev_rshares
      ELSE 0  -- Delete occurred, previous vote already canceled
    END AS prev_rshares,
    ja.row_num
  FROM find_prev_votes_in_table ja
),

-----------------------------------------------------------------------------------
-- PHASE 5: Update active_votes table
-----------------------------------------------------------------------------------

-- Delete votes for posts that were deleted/paid out
delete_votes AS (
  DELETE FROM active_votes av
  USING ranked_data dp
  WHERE
    av.author_id = dp.author_id AND
    av.permlink_serial_id = dp.permlink_id AND
    dp.op_type_id != __op_vote AND
    dp.row_num = 1  -- Only most recent delete matters
  RETURNING av.author_id, av.permlink_serial_id
),

-- Insert/update votes that should persist (no subsequent delete in batch)
upsert_votes AS (
  INSERT INTO active_votes AS av
    (author_id, voter_id, permlink_serial_id, rshares)
  SELECT
    uv.author_id,
    uv.voter_id,
    uv.permlink_id,
    uv.rshares
  FROM ranked_data uv
  WHERE
    uv.row_num = 1 AND              -- Only most recent vote per (author, voter, permlink)
    uv.op_type_id = __op_vote AND   -- Only actual votes, not deletes
    -- No subsequent delete/payout in this batch (it would remove the vote again)
    (uv.final_delete_source_op IS NULL OR uv.final_delete_source_op < uv.source_op)
  ON CONFLICT ON CONSTRAINT pk_active_votes DO UPDATE SET
    rshares = EXCLUDED.rshares
  RETURNING av.author_id, av.voter_id, av.permlink_serial_id
),

-----------------------------------------------------------------------------------
-- PHASE 6: Collect reputation changes, in blockchain order, for the batch calculation
-----------------------------------------------------------------------------------
votes_to_process AS (
  SELECT
    array_agg(author_id ORDER BY source_op) AS author_ids,
    array_agg(voter_id ORDER BY source_op) AS voter_ids,
    array_agg(rshares ORDER BY source_op) AS rshares,
    array_agg(prev_rshares ORDER BY source_op) AS prev_rshares,
    count(*) AS vote_count
  FROM check_if_prev_balances_canceled
)

-- Execute all CTEs and capture counts for debugging/logging
SELECT
  (SELECT count(*) FROM delete_votes),
  (SELECT count(*) FROM upsert_votes),
  vtp.vote_count,
  vtp.author_ids,
  vtp.voter_ids,
  vtp.rshares,
  vtp.prev_rshares
INTO __delete_votes, __upsert_votes, __rep_change, __author_ids, __voter_ids, __rshares, __prev_rshares
FROM votes_to_process vtp;

--=====================================================================================
-- REPUTATION PROCESSING
--=====================================================================================
-- Reputation changes MUST be applied in blockchain order (by source_op).
-- Each vote's effect depends on the voter's reputation at that moment.
-- Example: If Alice downvotes Bob, then Carol upvotes Alice, the order matters:
--   - If Alice's downvote processed first: Alice has low rep, downvote might be ignored
--   - If Carol's upvote processed first: Alice has higher rep, downvote counts
-- calculate_account_reputations applies the ordered arrays in memory and writes the
-- changed accounts back in one statement.
PERFORM reptracker_backend.calculate_account_reputations(
  __author_ids,
  __voter_ids,
  __rshares,
  __prev_rshares
);

END
$BODY$;

RESET ROLE;
