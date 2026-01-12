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
AS $BODY$
DECLARE
  __rep_change INT := 0;
  __delete_votes INT;
  __upsert_votes INT;
  __vote_rec RECORD;

  -- Operation type IDs (cached to avoid repeated function calls during query execution)
  -- These map to hafd.operation_types entries for vote-related operations
  __op_vote   INT := reptracker_backend.op_effective_comment_vote();  -- Vote cast/changed
  __op_delete INT := reptracker_backend.op_delete_comment();          -- Post deleted
  __op_payout INT := reptracker_backend.op_comment_payout_update();   -- Post paid out (votes finalized)
BEGIN

--=====================================================================================
-- TEMP TABLE: Storage for reputation changes to process sequentially
--=====================================================================================
-- Reputation must be calculated in blockchain order (by source_op) because each vote's
-- effect depends on the voter's current reputation at that moment. Batch UPDATE would
-- process in arbitrary order, causing incorrect results.
CREATE TEMP TABLE IF NOT EXISTS _votes_to_process (
  author_id INT,
  voter_id INT,
  rshares BIGINT,
  prev_rshares BIGINT,
  source_op BIGINT        -- Operation ID determines processing order
) ON COMMIT DROP;
TRUNCATE _votes_to_process;

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
    ov.body,
    ov.op_type_id,
    ov.id AS source_op
  FROM operations_view ov
  WHERE ov.op_type_id IN (__op_vote, __op_delete, __op_payout)
    AND ov.block_num BETWEEN _first_block_num AND _last_block_num
),

-----------------------------------------------------------------------------------
-- PHASE 1b: Parse JSON operation bodies into structured data
-----------------------------------------------------------------------------------
-- CROSS JOIN LATERAL parses each operation's JSON body.
-- Inline CASE avoids wrapper function overhead (process_vote_impacting_operations).
-- MATERIALIZED prevents multiple scans that would re-execute JSON parsing.
vote_operations_raw AS MATERIALIZED (
  SELECT
    ev.author,
    ev.voter,
    ev.permlink,
    ev.rshares,
    ov.op_type_id,
    ov.source_op
  FROM operations_in_range ov
  CROSS JOIN LATERAL (
    SELECT (
      CASE
        WHEN ov.op_type_id = __op_vote THEN
          reptracker_backend.process_effective_vote_operation(ov.body)
        ELSE
          -- Delete and payout operations share same parser (only need author/permlink)
          reptracker_backend.process_deleted_comment_operation(ov.body)
      END
    ).*
  ) AS ev
),

-----------------------------------------------------------------------------------
-- PHASE 2: Resolve account names to IDs (batched for efficiency)
-----------------------------------------------------------------------------------
-- Instead of N correlated subqueries (one per operation), we:
--   1. Collect unique account names
--   2. Single bulk lookup against accounts_view
--   3. Join IDs back to operations
-- This reduces account lookups from O(N*2) to O(unique_accounts)

unique_accounts AS (
  SELECT DISTINCT name FROM (
    SELECT author AS name FROM vote_operations_raw
    UNION ALL
    SELECT voter FROM vote_operations_raw WHERE voter IS NOT NULL
  ) accounts
),

account_ids AS (
  SELECT ua.name, ha.id
  FROM unique_accounts ua
  JOIN accounts_view ha ON ha.name = ua.name
),

-- Reassemble operations with integer IDs instead of text names
vote_operations AS (
  SELECT
    author_acc.id AS author_id,
    voter_acc.id AS voter_id,
    vo.permlink,
    vo.rshares,
    vo.op_type_id,
    vo.source_op
  FROM vote_operations_raw vo
  JOIN account_ids author_acc ON author_acc.name = vo.author
  -- LEFT JOIN because delete operations have NULL voter
  LEFT JOIN account_ids voter_acc ON voter_acc.name = vo.voter
),

-----------------------------------------------------------------------------------
-- PHASE 3: Manage permlink dictionary
-----------------------------------------------------------------------------------
-- Permlinks are stored as TEXT but referenced by INT id for efficient joins.
-- Insert any new permlinks we haven't seen before.

-- DO NOTHING avoids lock contention on existing permlinks
insert_new_permlinks AS (
  INSERT INTO permlinks (permlink)
  SELECT DISTINCT permlink
  FROM vote_operations
  ON CONFLICT (permlink) DO NOTHING
  RETURNING permlink_id, permlink
),

-- Fetch all permlink IDs needed for this batch (new + existing)
-- UNION ALL ensures insert_new_permlinks CTE executes (CTE is lazy)
-- NOT EXISTS prevents duplicates from newly inserted permlinks
supplement_permlink_dictionary AS (
  SELECT permlink_id, permlink FROM insert_new_permlinks
  UNION ALL
  SELECT p.permlink_id, p.permlink
  FROM permlinks p
  WHERE p.permlink IN (SELECT DISTINCT permlink FROM vote_operations)
    AND NOT EXISTS (SELECT 1 FROM insert_new_permlinks inp WHERE inp.permlink = p.permlink)
),

-- Join permlink IDs to operations
prev_votes_in_query AS (
  SELECT
    ja.author_id,
    ja.voter_id,
    sp.permlink_id,
    ja.rshares,
    ja.source_op,
    ja.op_type_id
  FROM vote_operations ja
  JOIN supplement_permlink_dictionary sp ON ja.permlink = sp.permlink
),

-----------------------------------------------------------------------------------
-- PHASE 4: Rank operations and find previous votes
-----------------------------------------------------------------------------------
-- When a user changes their vote, we need to:
--   1. Undo the previous vote's reputation impact
--   2. Apply the new vote's impact
-- ROW_NUMBER finds the most recent operation per (author, voter, permlink)

ranked_data AS MATERIALIZED (
  SELECT
    author_id,
    voter_id,
    permlink_id,
    rshares,
    source_op,
    op_type_id,
    -- row_num=1 is most recent, row_num=2 is second most recent, etc.
    ROW_NUMBER() OVER (PARTITION BY author_id, voter_id, permlink_id ORDER BY source_op DESC) AS row_num
  FROM prev_votes_in_query
),

-- Extract delete/payout operations (used to detect vote cancellations)
join_permlink_id_to_deletes AS MATERIALIZED (
  SELECT
    author_id,
    permlink_id,
    source_op,
    row_num
  FROM ranked_data
  WHERE op_type_id != __op_vote
),

-- Self-join to find the previous vote within THIS batch
-- If user voted twice in the same batch, we link them here
add_prev_votes AS (
  SELECT
    current.author_id,
    current.voter_id,
    current.permlink_id,
    current.rshares,
    current.source_op,
    previous.rshares AS prev_rshares,       -- Previous vote's rshares (NULL if none in batch)
    COALESCE(previous.source_op, 0) AS prev_source_op,
    current.row_num
  FROM ranked_data current
  LEFT JOIN ranked_data previous ON
    current.author_id = previous.author_id AND
    current.voter_id = previous.voter_id AND
    current.permlink_id = previous.permlink_id AND
    current.op_type_id = previous.op_type_id AND
    current.row_num = previous.row_num - 1  -- Link to next-older vote
  WHERE current.op_type_id = __op_vote
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
    q.row_num
  FROM add_prev_votes q
  -- Only lookup if we didn't find prev vote in batch
  LEFT JOIN active_votes av ON
    q.prev_rshares IS NULL AND
    q.author_id = av.author_id AND
    q.voter_id = av.voter_id AND
    q.permlink_id = av.permlink_serial_id
),

-----------------------------------------------------------------------------------
-- PHASE 5: Handle vote cancellations from delete operations
-----------------------------------------------------------------------------------
-- If a post was deleted between the previous vote and current vote,
-- the previous vote was already canceled and shouldn't be undone again.

-- Find votes that have a delete operation between prev_source_op and source_op
-- Uses batch JOIN instead of per-row EXISTS (N+1 query pattern)
has_intervening_delete AS (
  SELECT DISTINCT
    fpv.author_id,
    fpv.voter_id,
    fpv.permlink_id,
    fpv.source_op
  FROM find_prev_votes_in_table fpv
  JOIN join_permlink_id_to_deletes dp ON
    dp.author_id = fpv.author_id AND
    dp.permlink_id = fpv.permlink_id AND
    dp.source_op BETWEEN fpv.prev_source_op AND fpv.source_op
  WHERE fpv.prev_rshares != 0
),

-- Reset prev_rshares to 0 if there was an intervening delete
-- Uses LEFT ANTI-JOIN pattern: hid.author_id IS NULL means no intervening delete
check_if_prev_balances_canceled AS (
  SELECT
    ja.author_id,
    ja.voter_id,
    ja.permlink_id,
    ja.rshares,
    ja.source_op,
    CASE
      WHEN ja.prev_rshares != 0 AND hid.author_id IS NULL THEN ja.prev_rshares
      ELSE 0  -- Delete occurred, previous vote already canceled
    END AS prev_rshares,
    ja.row_num
  FROM find_prev_votes_in_table ja
  LEFT JOIN has_intervening_delete hid ON
    hid.author_id = ja.author_id AND
    hid.voter_id = ja.voter_id AND
    hid.permlink_id = ja.permlink_id AND
    hid.source_op = ja.source_op
),

-----------------------------------------------------------------------------------
-- PHASE 6: Update active_votes table
-----------------------------------------------------------------------------------

-- Delete votes for posts that were deleted/paid out
delete_votes AS (
  DELETE FROM active_votes av
  USING join_permlink_id_to_deletes dp
  WHERE
    av.author_id = dp.author_id AND
    av.permlink_serial_id = dp.permlink_id AND
    dp.row_num = 1  -- Only most recent delete matters
  RETURNING av.author_id, av.permlink_serial_id
),

-- Find votes that will be deleted later in this batch (don't bother inserting them)
-- Uses batch JOIN instead of per-row EXISTS
-- IMPORTANT: Must include voter_id because different voters may vote at different times
-- relative to the delete, so each (author, voter, permlink) triple must be checked separately
votes_with_subsequent_delete AS (
  SELECT DISTINCT
    rd.author_id,
    rd.voter_id,
    rd.permlink_id
  FROM ranked_data rd
  JOIN join_permlink_id_to_deletes dv ON
    dv.author_id = rd.author_id AND
    dv.permlink_id = rd.permlink_id AND
    dv.source_op > rd.source_op  -- Delete happens after this vote
  WHERE rd.row_num = 1 AND rd.op_type_id = __op_vote
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
  -- LEFT ANTI-JOIN: exclude votes with subsequent delete
  LEFT JOIN votes_with_subsequent_delete vwsd ON
    vwsd.author_id = uv.author_id AND
    vwsd.voter_id = uv.voter_id AND
    vwsd.permlink_id = uv.permlink_id
  WHERE
    uv.row_num = 1 AND              -- Only most recent vote per (author, voter, permlink)
    uv.op_type_id = __op_vote AND   -- Only actual votes, not deletes
    vwsd.author_id IS NULL          -- No subsequent delete
  ON CONFLICT ON CONSTRAINT pk_active_votes DO UPDATE SET
    rshares = EXCLUDED.rshares
  RETURNING av.author_id, av.voter_id, av.permlink_serial_id
),

-----------------------------------------------------------------------------------
-- PHASE 7: Materialize reputation changes for sequential processing
-----------------------------------------------------------------------------------
materialize_votes AS (
  INSERT INTO _votes_to_process (author_id, voter_id, rshares, prev_rshares, source_op)
  SELECT author_id, voter_id, rshares, prev_rshares, source_op
  FROM check_if_prev_balances_canceled
  RETURNING 1
)

-- Execute all CTEs and capture counts for debugging/logging
SELECT
  (SELECT count(*) FROM delete_votes),
  (SELECT count(*) FROM upsert_votes),
  (SELECT count(*) FROM materialize_votes)
INTO __delete_votes, __upsert_votes, __rep_change;

--=====================================================================================
-- SEQUENTIAL REPUTATION PROCESSING
--=====================================================================================
-- Reputation changes MUST be processed in blockchain order (by source_op).
-- Each vote's effect depends on the voter's reputation at that moment.
-- Example: If Alice downvotes Bob, then Carol upvotes Alice, the order matters:
--   - If Alice's downvote processed first: Alice has low rep, downvote might be ignored
--   - If Carol's upvote processed first: Alice has higher rep, downvote counts
FOR __vote_rec IN (SELECT * FROM _votes_to_process ORDER BY source_op) LOOP
  PERFORM reptracker_backend.calculate_account_reputations(
    __vote_rec.author_id,
    __vote_rec.voter_id,
    __vote_rec.rshares,
    __vote_rec.prev_rshares
  );
END LOOP;

END
$BODY$;

RESET ROLE;
