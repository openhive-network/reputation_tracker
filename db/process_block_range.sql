SET ROLE reptracker_owner;


--- Massive version of account reputation calculation.
DROP FUNCTION IF EXISTS reptracker_app.process_block_range_data_a;
CREATE OR REPLACE FUNCTION reptracker_app.process_block_range_data_a(
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
  _result INT;
BEGIN
RAISE NOTICE 'Gathering data to process block range: %, %', _first_block_num, _last_block_num;

WITH select_ef_vote_ops AS MATERIALIZED
(
SELECT o.id,
    o.block_num,
    o.trx_in_block,
    o.op_pos,
    o.body_binary::JSONB as body
FROM hive.reptracker_app_operations_view o WHERE o.op_type_id = 72 
AND o.block_num BETWEEN _first_block_num AND _last_block_num ),
selected_range AS MATERIALIZED 
(
SELECT 
  o.id, 
  o.block_num,     
  o.body->'value'->>'author' AS author,
  o.body->'value'->>'voter' AS voter,
  o.body->'value'->>'permlink' AS permlink,
  (CASE WHEN jsonb_typeof(o.body->'value'->'rshares') = 'number' THEN
  (o.body->'value'->'rshares')::bigint
  ELSE 
  TRIM(BOTH '"'::text FROM o.body->'value'->>'rshares')::bigint
  END) AS rshares
FROM select_ef_vote_ops o
),
filtered_range AS MATERIALIZED 
(
SELECT 
  up.id AS up_id,
  up.block_num, 
  up.author, 
  up.permlink, 
  up.voter, 
  up.rshares AS up_rshares,  
  COALESCE((
    SELECT prd.rshares
    FROM reptracker_app.hive_reputation_data_view prd
    WHERE 
      prd.author = up.author AND 
      prd.voter = up.voter AND 
      prd.permlink = up.permlink AND 
      prd.id < up.id AND 
      NOT EXISTS (SELECT NULL FROM reptracker_app.deleted_comment_operation_view dp
    WHERE dp.author = up.author and dp.permlink = up.permlink and dp.id between prd.id and up.id)
    ORDER BY prd.id DESC LIMIT 1
  ), 0) AS prev_rshares
FROM selected_range up
),
balance_change AS MATERIALIZED 
(
  SELECT reptracker_app.calculate_account_reputations(  
      ja.up_id,
      ja.block_num, 
      ja.author,
      ha.id,
      ja.permlink, 
      ja.voter, 
      hv.id,
      ja.up_rshares, 
      ja.prev_rshares)
  FROM filtered_range ja
  JOIN hive.accounts_view ha on ha.name = ja.author
  JOIN hive.accounts_view hv on hv.name = ja.voter
  ORDER BY ja.up_id
)

SELECT COUNT(*) FROM balance_change INTO _result;

END
$BODY$
;

DROP FUNCTION IF EXISTS reptracker_app.calculate_account_reputations;
CREATE OR REPLACE FUNCTION reptracker_app.calculate_account_reputations(
    _id BIGINT,
    _block_num INT,
    _author TEXT,
    _author_id INT,
    _permlink TEXT,
    _voter TEXT,
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
  __author_rep bigint;
  __voter_rep bigint;
  __implicit_voter_rep boolean;
  __implicit_author_rep boolean;
  __prev_rep_delta bigint := (_prev_rshares >> 6)::BIGINT;
  __prev_rshares BIGINT := _prev_rshares;
  __rshares BIGINT := _rshares;
  __rshares_delta BIGINT := (_rshares >> 6)::BIGINT;
  __new_author_rep BIGINT;
  __debug_log boolean := false;
BEGIN

WITH find_voter AS MATERIALIZED 
(
  SELECT 
    ar.account_id,
    ar.reputation,
    ar.is_implicit
  FROM reptracker_app.account_reputations ar
  WHERE 
    ar.account_id = _voter_id
)
  UPDATE reptracker_app.account_reputations ar
  SET 
    reputation = ar.reputation - __prev_rep_delta,
    is_implicit = (ar.reputation - __prev_rep_delta) = 0
  FROM find_voter fv 
  WHERE 
    ar.account_id = _author_id AND
    (NOT ar.is_implicit AND fv.reputation >= 0 AND 
    (__prev_rshares >= 0 OR (__prev_rshares < 0 AND NOT fv.is_implicit AND fv.reputation > ar.reputation - __prev_rep_delta)));

WITH if_voter_changed AS MATERIALIZED
(
  SELECT 
    ar.account_id,
    ar.reputation,
    ar.is_implicit
  FROM reptracker_app.account_reputations ar
  WHERE 
    ar.account_id = _voter_id
) 
UPDATE reptracker_app.account_reputations ar
SET 
  reputation = ar.reputation + __rshares_delta,
  is_implicit = false
FROM if_voter_changed avs 
WHERE 
  ar.account_id = _author_id AND
  (avs.reputation >= 0 AND (__rshares >= 0 OR (__rshares < 0 AND NOT avs.is_implicit AND avs.reputation > ar.reputation)));

END
$BODY$
;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reptracker_app TO reputation_tracker_writer_group;

RESET ROLE;
