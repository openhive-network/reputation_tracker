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
  __rep_change INT;
  __delete_votes INT;
  __upsert_votes INT;
BEGIN
---------------------------------------------------------------------------------------
WITH vote_operations AS (
  SELECT 
    process_vote_impacting_operations(ov.body, ov.op_type_id) AS effective_votes,
    ov.op_type_id,
    ov.id AS source_op
  FROM operations_view ov
  WHERE ov.op_type_id IN (72, 17, 61)
  AND ov.block_num BETWEEN _first_block_num AND _last_block_num 
),
prepare_vote_comment_data AS MATERIALIZED (
  SELECT 
    (SELECT ha.id FROM accounts_view ha WHERE ha.name = (vo.effective_votes).author) AS author_id,
    (SELECT ha.id FROM accounts_view ha WHERE ha.name = (vo.effective_votes).voter) AS voter_id,
    (vo.effective_votes).permlink AS permlink,
    (vo.effective_votes).rshares AS rshares,
    vo.source_op,
    vo.op_type_id
  FROM vote_operations vo
),
---------------------------------------------------------------------------------------
-- Insert currently processed permlinks and reuse it in the following steps
supplement_permlink_dictionary AS (
  INSERT INTO permlinks AS dict 
    (permlink)
  SELECT DISTINCT permlink
  FROM prepare_vote_comment_data 
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
  FROM prepare_vote_comment_data ja
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
rep_change AS (
  SELECT
    calculate_account_reputations(
      uv.author_id,
      uv.voter_id,
      uv.rshares, 
      uv.prev_rshares
    )
  FROM check_if_prev_balances_canceled uv
  ORDER BY uv.source_op
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
  (SELECT count(*) FROM rep_change) AS rep_change,
  (SELECT count(*) FROM delete_votes) AS delete_votes,
  (SELECT count(*) FROM upsert_votes) AS upsert_votes
INTO __rep_change, __delete_votes, __upsert_votes;

END
$BODY$;

CREATE OR REPLACE FUNCTION calculate_account_reputations(
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
  __prev_rep_delta BIGINT := (_prev_rshares >> 6)::BIGINT;
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
IF NOT _author_is_implicit AND _voter_reputation >= 0 AND (_prev_rshares >= 0 OR (_prev_rshares < 0 AND NOT _voter_is_implicit AND _voter_reputation > _author_reputation - __prev_rep_delta)) THEN

  _author_reputation := _author_reputation - __prev_rep_delta;
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
  _author_reputation = _author_reputation + (_rshares >> 6)::BIGINT;
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
