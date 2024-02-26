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
  __account_reputations reptracker_app.AccountReputation[];
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
    ROW(default_values.account_id, COALESCE(ad.reputation, 0), COALESCE(ad.is_implicit, true), false)::reptracker_app.AccountReputation 
  FROM 
    (
      SELECT ar.account_id, ar.reputation, ar.is_implicit  
      FROM reptracker_app.account_reputations ar
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

IF __debug_log THEN
  raise notice 'Block: % - Preprocessing a vote: author: %, voter: % permlink: %', _block_num, _author, _voter, _permlink;

  --- Author must have set explicit reputation to allow its correction
IF NOT __implicit_author_rep AND __prev_rshares != 0 THEN
    raise notice 'Author % reputation (pre-correction): %', _author, __author_rep;
    raise notice 'Author % - Correcting a vote: (voter: %) rshares: %', _author, _voter, __prev_rshares;
    raise notice 'Author % - Voter % reputation: %', _author, _voter, __voter_rep;
  END IF;
END IF;

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

  __account_reputations[1] := ROW(_author_id, __author_rep, __implicit_author_rep, true)::reptracker_app.AccountReputation;

IF __debug_log THEN 
    IF __implicit_author_rep THEN
      raise notice 'Author % reputation (past-correction): implicit-0', _author;
    ELSE
      raise notice 'Author % reputation (past-correction): %', _author, __author_rep;
    END IF;
  END IF;

END IF;

IF __debug_log THEN 
  raise notice 'Block: % - Author % - Processing a vote: (voter: %) rshares: %', _block_num, _author, _voter, __rshares;
  raise notice 'Author % - Voter % reputation: %', _author, _voter, __voter_rep;
END IF;

IF __voter_rep >= 0 AND (__rshares >= 0 OR (__rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep)) THEN

  __new_author_rep = __author_rep + (__rshares >> 6)::BIGINT;
  __account_reputations[1] := ROW(_author_id, __new_author_rep, false, true)::reptracker_app.AccountReputation;

IF __debug_log THEN 
    IF __implicit_author_rep THEN
      raise notice 'Setting a reputation of author: % to %', _author, __new_author_rep;
    ELSE
      raise notice 'Changing reputation of author: % from % to %', _author, __author_rep, __new_author_rep;
    END IF;
  END IF;

END IF;

INSERT INTO reptracker_app.account_reputations
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
$BODY$
;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reptracker_app TO reputation_tracker_writer_group;

RESET ROLE;
