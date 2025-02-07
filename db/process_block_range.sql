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
-- delete comments

WITH delete_vote_operations AS (
  SELECT 
    process_deleted_comment_operation(ov.body) AS deleted_comments,
    ov.id AS source_op
  FROM hive.operations_view ov
  WHERE ov.op_type_id IN (17,61)
  AND ov.block_num BETWEEN _first_block_num AND _last_block_num 
),
prepare_deleted_comment_data AS (
  SELECT 
    (dvo.deleted_comments).author AS author,
    (dvo.deleted_comments).permlink AS permlink,
    dvo.source_op
  FROM delete_vote_operations dvo
),
join_account_id_to_delete_comments AS (
  SELECT 
    pd.author,
    (SELECT ha.id FROM hive.accounts_view ha WHERE ha.name = pd.author) AS author_id,
    pd.permlink,
    pd.source_op
  FROM prepare_deleted_comment_data pd
),
---------------------------------------------------------------------------------------
-- effective votes

vote_operations AS (
  SELECT 
    process_effective_vote_operation(ov.body) AS effective_votes,
    ov.id AS source_op
  FROM hive.operations_view ov
  WHERE ov.op_type_id = 72
  AND ov.block_num BETWEEN _first_block_num AND _last_block_num 
),
prepare_vote_comment_data AS (
  SELECT 
    (vo.effective_votes).author AS author,
    (vo.effective_votes).voter AS voter,
    (vo.effective_votes).permlink AS permlink,
    (vo.effective_votes).rshares AS rshares,
    vo.source_op
  FROM vote_operations vo
),
join_account_id_to_votes AS MATERIALIZED (
  SELECT 
    author,
    (SELECT ha.id FROM hive.accounts_view ha WHERE ha.name = author) AS author_id,
    voter,
    (SELECT ha.id FROM hive.accounts_view ha WHERE ha.name = voter) AS voter_id,
    permlink,
    rshares,
    source_op
  FROM prepare_vote_comment_data 
),
---------------------------------------------------------------------------------------
-- get permlink ids
supplement_permlink_dictionary AS MATERIALIZED (
  INSERT INTO permlinks AS dict 
    (permlink)
  SELECT 
    DISTINCT ja.permlink
  FROM join_account_id_to_votes ja
  ON CONFLICT (permlink) DO UPDATE SET
    permlink = EXCLUDED.permlink 
  RETURNING (xmax = 0) as is_new_permlink, dict.permlink_id, dict.permlink
),
join_permlink_id_to_deletes AS MATERIALIZED (
  SELECT 
    ja.author_id,
    sp.permlink_id,
    ja.source_op
  FROM join_account_id_to_delete_comments ja
  JOIN supplement_permlink_dictionary sp ON ja.permlink = sp.permlink
),
prev_votes_in_query AS MATERIALIZED (
  SELECT 
    ja.author_id,
    ja.voter_id,
    sp.permlink_id,
    ja.rshares,
    ja.source_op,
    (
      SELECT prev.rshares 
      FROM join_account_id_to_votes prev 
      WHERE
        prev.author = ja.author AND 
        prev.voter = ja.voter AND 
        prev.source_op < ja.source_op AND
        NOT EXISTS (SELECT NULL FROM join_permlink_id_to_deletes dp
        WHERE dp.author_id = ja.author_id and dp.permlink_id = sp.permlink_id and dp.source_op between prev.source_op and ja.source_op)
      ORDER BY prev.source_op DESC 
      LIMIT 1
    ) AS prev_rshares
  FROM join_account_id_to_votes ja
  JOIN supplement_permlink_dictionary sp ON ja.permlink = sp.permlink
),
---------------------------------------------------------------------------------------
--prepare votes for reputation calculation
find_prev_votes_in_table AS MATERIALIZED (
  SELECT 
    q.author_id,
    q.voter_id,
    q.permlink_id,
    q.rshares,
    av.rshares AS prev_rshares,
    q.source_op
  FROM prev_votes_in_query q
  LEFT JOIN active_votes av ON 
    q.author_id = av.author_id AND 
    q.voter_id = av.voter_id AND 
    q.permlink_id = av.permlink_serial_id
  WHERE q.prev_rshares IS NULL
),
check_if_comment_was_deleted AS (
  SELECT 
    fp.author_id,
    fp.voter_id,
    fp.permlink_id,
    fp.rshares,
    (
      CASE WHEN EXISTS (SELECT NULL FROM join_permlink_id_to_deletes dp WHERE dp.author_id = fp.author_id and dp.permlink_id = fp.permlink_id and dp.source_op < fp.source_op LIMIT 1)
      THEN
        0
      ELSE
        fp.prev_rshares
      END
    ) AS prev_rshares,
    fp.source_op
  FROM find_prev_votes_in_table fp
  WHERE prev_rshares IS NOT NULL
),
union_votes AS MATERIALIZED (
  SELECT 
    author_id,
    voter_id,
    permlink_id,
    rshares,
    prev_rshares,
    source_op
  FROM prev_votes_in_query
  WHERE prev_rshares IS NOT NULL

  UNION ALL

  SELECT 
    author_id,
    voter_id,
    permlink_id,
    rshares,
    0 AS prev_rshares,
    source_op
  FROM find_prev_votes_in_table
  WHERE prev_rshares IS NULL

  UNION ALL

  SELECT 
    author_id,
    voter_id,
    permlink_id,
    rshares,
    prev_rshares,
    source_op
  FROM check_if_comment_was_deleted
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
  FROM union_votes uv
  ORDER BY uv.source_op
),
delete_votes AS (
  DELETE FROM active_votes av
  USING join_permlink_id_to_deletes dp
  WHERE 
    av.author_id = dp.author_id AND
    av.permlink_serial_id = dp.permlink_id
  RETURNING av.author_id, av.permlink_serial_id
),
------ wip 
group_by_max_op AS (
  SELECT 
    author_id,
    voter_id,
    permlink_id,
    MAX(source_op) AS source_op
  FROM union_votes
  GROUP BY author_id, voter_id,permlink_serial_id
),
------ wip 

upsert_votes AS (
  INSERT INTO active_votes AS av 
    (author_id, voter_id, permlink_serial_id, rshares)
  SELECT 
    author_id,
    voter_id,
    permlink_id,
    rshares
  FROM union_votes uv
  WHERE NOT EXISTS (
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
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET jit = OFF
AS $BODY$
DECLARE
  __account_reputations AccountReputation[];
  __author_rep bigint;
  __voter_rep bigint;
  __implicit_voter_rep boolean;
  __implicit_author_rep boolean;
  __prev_rep_delta bigint := (_prev_rshares >> 6)::BIGINT;
  __prev_rshares BIGINT := _prev_rshares;
  __rshares BIGINT := _rshares;
  __new_author_rep BIGINT;
  __debug_log boolean := false;
BEGIN

SELECT INTO __account_reputations
ARRAY(
  SELECT 
    ROW(default_values.account_id, COALESCE(ad.reputation, 0), COALESCE(ad.is_implicit, true), false)::AccountReputation 
  FROM 
    (
      SELECT ar.account_id, ar.reputation, ar.is_implicit  
      FROM account_reputations ar
      WHERE ar.account_id = _author_id OR ar.account_id = _voter_id
    ) AS ad
  RIGHT JOIN 
    (
      SELECT _author_id AS account_id
      UNION ALL 
      SELECT _voter_id AS account_id
    ) AS default_values
  ON 
    ad.account_id = default_values.account_id);

__author_rep := __account_reputations[1].reputation;
__voter_rep := __account_reputations[2].reputation;
__implicit_author_rep := __account_reputations[1].is_implicit;
__implicit_voter_rep := __account_reputations[2].is_implicit;


--- Author must have set explicit reputation to allow its correction
--- Voter must have explicitly set reputation to match hived old conditions
IF NOT __implicit_author_rep AND __voter_rep >= 0 AND (__prev_rshares >= 0 OR (__prev_rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep - __prev_rep_delta)) THEN

  __author_rep := __author_rep - __prev_rep_delta;
__implicit_author_rep := __author_rep = 0;

  IF _voter_id = _author_id THEN 
    --- reread voter's rep. since it can change above if author == voter
    __implicit_voter_rep := __implicit_author_rep;
    __voter_rep := __author_rep;
  END IF;

  __account_reputations[1] := ROW(_author_id, __author_rep, __implicit_author_rep, true)::AccountReputation;

END IF;

IF __voter_rep >= 0 AND (__rshares >= 0 OR (__rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep)) THEN

  __new_author_rep = __author_rep + (__rshares >> 6)::BIGINT;
  __account_reputations[1] := ROW(_author_id, __new_author_rep, false, true)::AccountReputation;

END IF;

INSERT INTO account_reputations
  (account_id, reputation, is_implicit)
SELECT ds.id, ds.reputation, ds.is_implicit
FROM unnest(__account_reputations) ds
WHERE ds.reputation IS NOT NULL AND ds.changed
ON CONFLICT (account_id) DO UPDATE
SET 
    reputation = EXCLUDED.reputation,
    is_implicit = EXCLUDED.is_implicit
;
  
END
$BODY$;


RESET ROLE;
