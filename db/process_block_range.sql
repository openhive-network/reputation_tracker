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
---------------------------------------------------------------------------------------
WITH vote_operations AS (
  SELECT 
    (SELECT ha.id FROM accounts_view ha WHERE ha.name = effective_votes.author) AS author_id,
    (SELECT ha.id FROM accounts_view ha WHERE ha.name = effective_votes.voter) AS voter_id,
    effective_votes.permlink,
    effective_votes.rshares,
    ov.op_type_id,
    ov.id AS source_op
  FROM operations_view ov
  CROSS JOIN reptracker_backend.process_vote_impacting_operations(ov.body, ov.op_type_id) AS effective_votes
  WHERE ov.op_type_id IN (72, 17, 61)
  AND ov.block_num BETWEEN _first_block_num AND _last_block_num 
),
---------------------------------------------------------------------------------------
-- Insert currently processed permlinks and reuse it in the following steps
supplement_permlink_dictionary AS (
  INSERT INTO permlinks AS dict 
    (permlink)
  SELECT DISTINCT permlink
  FROM vote_operations 
  ON CONFLICT (permlink) DO UPDATE SET
    permlink = EXCLUDED.permlink 
  RETURNING (xmax = 0) as is_new_permlink, dict.permlink_id, dict.permlink
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
-- Check and reset previous rshares
check_if_prev_balances_canceled AS (
  SELECT 
    ja.author_id,
    ja.voter_id,
    ja.permlink_id,
    ja.rshares,
    ja.source_op,
    CASE
      WHEN ja.prev_rshares != 0 AND NOT EXISTS (
        SELECT NULL
        FROM join_permlink_id_to_deletes dp 
        WHERE 
          dp.author_id = ja.author_id AND
          dp.permlink_id = ja.permlink_id AND
          dp.source_op BETWEEN ja.prev_source_op AND ja.source_op
        LIMIT 1
      ) THEN ja.prev_rshares
      ELSE 0
    END AS prev_rshares,
    ja.row_num
  FROM find_prev_votes_in_table ja
),
---------------------------------------------------------------------------------------
-- Use cursor to guarantee sequential processing order for deterministic results
votes_to_process AS (
  SELECT author_id, voter_id, rshares, prev_rshares, source_op
  FROM check_if_prev_balances_canceled
  ORDER BY source_op
),
delete_votes AS (
  DELETE FROM active_votes av
  USING join_permlink_id_to_deletes dp
  WHERE 
    av.author_id = dp.author_id AND
    av.permlink_serial_id = dp.permlink_id AND
    dp.row_num = 1
  RETURNING av.author_id, av.permlink_serial_id
),
upsert_votes AS (
  INSERT INTO active_votes AS av 
    (author_id, voter_id, permlink_serial_id, rshares)
  SELECT 
    author_id,
    voter_id,
    permlink_id,
    rshares
  FROM ranked_data uv
  WHERE 
    uv.row_num = 1 AND 
    uv.op_type_id = 72 AND
    NOT EXISTS (
      SELECT NULL 
      FROM join_permlink_id_to_deletes dv 
      WHERE dv.author_id = uv.author_id AND dv.permlink_id = uv.permlink_id AND dv.source_op > uv.source_op
      LIMIT 1
    )
  ON CONFLICT ON CONSTRAINT pk_active_votes DO UPDATE SET
    rshares = EXCLUDED.rshares
  RETURNING av.author_id, av.voter_id, av.permlink_serial_id
)

SELECT
  (SELECT count(*) FROM delete_votes) AS delete_votes,
  (SELECT count(*) FROM upsert_votes) AS upsert_votes
INTO __delete_votes, __upsert_votes;

-- Process reputation changes sequentially using cursor to guarantee order
FOR __vote_rec IN (SELECT * FROM votes_to_process) LOOP
  PERFORM reptracker_backend.calculate_account_reputations(
    __vote_rec.author_id,
    __vote_rec.voter_id,
    __vote_rec.rshares,
    __vote_rec.prev_rshares
  );
  __rep_change := __rep_change + 1;
END LOOP;

END
$BODY$;

RESET ROLE;
