SET ROLE reptracker_owner;

--- Massive version of account reputation calculation.
CREATE OR REPLACE FUNCTION reptracker_block_range_data(
    IN _first_block_num INT,
    IN _last_block_num INT
)
RETURNS VOID
LANGUAGE 'plpgsql'
VOLATILE 
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET jit = OFF
AS $BODY$
DECLARE
  __rep_change INT := 0;
  __delete_votes INT;
  __upsert_votes INT;
  __vote_rec RECORD;
BEGIN
-- Create temp table to materialize votes for sequential processing
CREATE TEMP TABLE IF NOT EXISTS _votes_to_process (
  author_id INT,
  voter_id INT,
  rshares BIGINT,
  prev_rshares BIGINT,
  source_op BIGINT
) ON COMMIT DROP;
TRUNCATE _votes_to_process;
---------------------------------------------------------------------------------------
WITH vote_operations_raw AS (
  SELECT
    effective_votes.author,
    effective_votes.voter,
    effective_votes.permlink,
    effective_votes.rshares,
    ov.op_type_id,
    ov.id AS source_op
  FROM operations_view ov
  CROSS JOIN reptracker_backend.process_vote_impacting_operations(ov.body, ov.op_type_id) AS effective_votes
  WHERE ov.op_type_id IN (72, 17, 61)
  AND ov.block_num BETWEEN _first_block_num AND _last_block_num
),
-- Collect unique accounts from this batch (reduces account lookups)
unique_accounts AS (
  SELECT DISTINCT name FROM (
    SELECT author AS name FROM vote_operations_raw
    UNION ALL
    SELECT voter FROM vote_operations_raw WHERE voter IS NOT NULL
  ) accounts
),
-- Single lookup per unique account
account_ids AS (
  SELECT ua.name, ha.id
  FROM unique_accounts ua
  JOIN accounts_view ha ON ha.name = ua.name
),
-- Join IDs back to operations
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
  LEFT JOIN account_ids voter_acc ON voter_acc.name = vo.voter
),
---------------------------------------------------------------------------------------
-- Insert only new permlinks (reduces WAL writes vs DO UPDATE)
insert_new_permlinks AS (
  INSERT INTO permlinks (permlink)
  SELECT DISTINCT permlink
  FROM vote_operations
  ON CONFLICT (permlink) DO NOTHING
  RETURNING permlink_id, permlink
),
-- Fetch all permlink IDs (new and existing) - UNION ensures insert runs
supplement_permlink_dictionary AS (
  SELECT permlink_id, permlink FROM insert_new_permlinks
  UNION ALL
  SELECT p.permlink_id, p.permlink
  FROM permlinks p
  WHERE p.permlink IN (SELECT DISTINCT permlink FROM vote_operations)
    AND NOT EXISTS (SELECT 1 FROM insert_new_permlinks inp WHERE inp.permlink = p.permlink)
),
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
ranked_data AS MATERIALIZED (
  SELECT 
    author_id,
    voter_id,
    permlink_id,
    rshares,
    source_op,
    op_type_id,
    ROW_NUMBER() OVER (PARTITION BY author_id, voter_id, permlink_id ORDER BY source_op DESC) AS row_num
  FROM prev_votes_in_query
),
-- Prepare resets for reputation calculation
join_permlink_id_to_deletes AS MATERIALIZED (
  SELECT 
    author_id,
    permlink_id,
    source_op,
    row_num
  FROM ranked_data
  WHERE op_type_id != 72 
),
add_prev_votes AS (
  SELECT 
    current.author_id,
    current.voter_id,
    current.permlink_id,
    current.rshares,
    current.source_op,
    previous.rshares AS prev_rshares,
    COALESCE(previous.source_op, 0) AS prev_source_op,
    current.row_num
  FROM ranked_data current
  LEFT JOIN ranked_data previous ON 
    current.author_id = previous.author_id AND
    current.voter_id = previous.voter_id AND
    current.permlink_id = previous.permlink_id AND
    current.op_type_id = previous.op_type_id AND
    current.row_num = previous.row_num - 1
  WHERE current.op_type_id = 72
),
-- Link previous votes
find_prev_votes_in_table AS (
  SELECT
    q.author_id,
    q.voter_id,
    q.permlink_id,
    q.rshares,
    COALESCE(q.prev_rshares, av.rshares, 0) AS prev_rshares,
    q.source_op,
    q.prev_source_op,
    q.row_num
  FROM add_prev_votes q
  LEFT JOIN active_votes av ON
    q.prev_rshares IS NULL AND
    q.author_id = av.author_id AND
    q.voter_id = av.voter_id AND
    q.permlink_id = av.permlink_serial_id
),
-- Precompute which votes have intervening deletes (replaces N+1 EXISTS)
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
-- Check and reset previous rshares using LEFT ANTI-JOIN
check_if_prev_balances_canceled AS (
  SELECT
    ja.author_id,
    ja.voter_id,
    ja.permlink_id,
    ja.rshares,
    ja.source_op,
    CASE
      WHEN ja.prev_rshares != 0 AND hid.author_id IS NULL THEN ja.prev_rshares
      ELSE 0
    END AS prev_rshares,
    ja.row_num
  FROM find_prev_votes_in_table ja
  LEFT JOIN has_intervening_delete hid ON
    hid.author_id = ja.author_id AND
    hid.voter_id = ja.voter_id AND
    hid.permlink_id = ja.permlink_id AND
    hid.source_op = ja.source_op
),
---------------------------------------------------------------------------------------
delete_votes AS (
  DELETE FROM active_votes av
  USING join_permlink_id_to_deletes dp
  WHERE
    av.author_id = dp.author_id AND
    av.permlink_serial_id = dp.permlink_id AND
    dp.row_num = 1
  RETURNING av.author_id, av.permlink_serial_id
),
-- Precompute votes that have a subsequent delete (replaces N+1 EXISTS)
votes_with_subsequent_delete AS (
  SELECT DISTINCT
    rd.author_id,
    rd.permlink_id
  FROM ranked_data rd
  JOIN join_permlink_id_to_deletes dv ON
    dv.author_id = rd.author_id AND
    dv.permlink_id = rd.permlink_id AND
    dv.source_op > rd.source_op
  WHERE rd.row_num = 1 AND rd.op_type_id = 72
),
upsert_votes AS (
  INSERT INTO active_votes AS av
    (author_id, voter_id, permlink_serial_id, rshares)
  SELECT
    uv.author_id,
    uv.voter_id,
    uv.permlink_id,
    uv.rshares
  FROM ranked_data uv
  LEFT JOIN votes_with_subsequent_delete vwsd ON
    vwsd.author_id = uv.author_id AND
    vwsd.permlink_id = uv.permlink_id
  WHERE
    uv.row_num = 1 AND
    uv.op_type_id = 72 AND
    vwsd.author_id IS NULL
  ON CONFLICT ON CONSTRAINT pk_active_votes DO UPDATE SET
    rshares = EXCLUDED.rshares
  RETURNING av.author_id, av.voter_id, av.permlink_serial_id
),
-- Materialize votes data into temp table for sequential processing
materialize_votes AS (
  INSERT INTO _votes_to_process (author_id, voter_id, rshares, prev_rshares, source_op)
  SELECT author_id, voter_id, rshares, prev_rshares, source_op
  FROM check_if_prev_balances_canceled
  RETURNING 1
)

SELECT
  (SELECT count(*) FROM delete_votes),
  (SELECT count(*) FROM upsert_votes),
  (SELECT count(*) FROM materialize_votes)
INTO __delete_votes, __upsert_votes, __rep_change;

-- Process reputation changes sequentially using cursor to guarantee order
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
