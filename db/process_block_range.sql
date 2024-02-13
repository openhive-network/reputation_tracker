SET ROLE reptracker_owner;

DROP TYPE IF EXISTS reptracker_app.AccountReputation CASCADE;

CREATE TYPE reptracker_app.AccountReputation AS (id int, reputation bigint, is_implicit boolean, changed boolean);

DROP FUNCTION IF EXISTS reptracker_app.calculate_account_reputations;

--- Massive version of account reputation calculation.
CREATE OR REPLACE FUNCTION reptracker_app.calculate_account_reputations(
  IN _first_block_num integer,
  IN _last_block_num integer
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
  raise notice 'Gathering data to process block range: %, %', _first_block_num, _last_block_num;

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
    SELECT reptracker_app.calculate_account_reputations_a(  
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

DROP FUNCTION IF EXISTS reptracker_app.calculate_account_reputations_a;

CREATE OR REPLACE FUNCTION reptracker_app.calculate_account_reputations_a(
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
BEGIN

WITH selected_author_voter AS MATERIALIZED 
( 
  SELECT 
    default_values.account_id, 
    COALESCE(ad.reputation, 0) as reputation, 
    COALESCE(ad.is_implicit, true) as is_implicit, 
    false AS changed
  FROM 
    (
      SELECT * FROM reptracker_app.account_reputations WHERE account_id = _author_id or account_id = _voter_id
    ) AS ad
  RIGHT JOIN 
    (
      SELECT _author_id as account_id
	    UNION ALL  
	    SELECT _voter_id as account_id
    ) AS default_values
  ON 
    ad.account_id = default_values.account_id

),
select_variables AS MATERIALIZED
(
  SELECT 
    _rshares AS __rshares,
    _prev_rshares AS __prev_rshares,
    (_prev_rshares >> 6)::bigint AS __prev_rep_delta,
    _author_id,
    _author,
    author.reputation AS __author_rep,
    author.is_implicit AS __implicit_author_rep,
    author.changed AS __author_changed,
    _voter_id,
    _voter,
    voter.reputation AS __voter_rep,
    voter.is_implicit AS __implicit_voter_rep
  FROM 
    (
      SELECT account_id, reputation, is_implicit, changed FROM selected_author_voter WHERE account_id = _author_id LIMIT 1
    ) AS author,
    (
      SELECT account_id, reputation, is_implicit, changed FROM selected_author_voter WHERE account_id = _voter_id LIMIT 1
    ) AS voter

),
first_condition AS MATERIALIZED 
(
  SELECT
    (CASE WHEN (NOT sv.__implicit_author_rep AND sv.__voter_rep >= 0 AND (sv.__prev_rshares > 0 OR (sv.__prev_rshares < 0 AND NOT sv.__implicit_voter_rep AND sv.__voter_rep > sv.__author_rep - sv.__prev_rep_delta))) 
    THEN true ELSE false END) AS condition,
    sv.__rshares,
    sv.__prev_rshares,
    sv.__prev_rep_delta,
    sv._author_id,
    sv._author,
    sv.__author_rep,
    sv.__implicit_author_rep,
    sv.__author_changed,
    sv._voter_id,
    sv._voter,
    sv.__voter_rep,
    sv.__implicit_voter_rep

  FROM select_variables sv
),
case_when_first AS MATERIALIZED 
(
  SELECT 
    -- Voter must have explicitly set reputation to match hived old conditions
    sv.__rshares,
    sv.__prev_rshares,
    sv.__prev_rep_delta,
    sv._author_id,
    sv._author,
    (CASE WHEN sv.condition THEN (sv.__author_rep - sv.__prev_rep_delta) ELSE sv.__author_rep END ) AS __author_rep,
    (CASE WHEN sv.condition THEN false ELSE sv.__implicit_author_rep END ) AS __implicit_author_rep,
    (CASE WHEN sv.condition THEN true ELSE sv.__author_changed END ) AS __author_changed,
    sv._voter_id,
    sv._voter,
    sv.__voter_rep,
    sv.__implicit_voter_rep

  FROM first_condition sv

),
second_condition AS MATERIALIZED 
(
  SELECT
    (CASE WHEN (sv._voter_id = sv._author_id)
    THEN true ELSE false END) AS condition,
    sv.__rshares,
    sv.__prev_rshares,
    sv.__prev_rep_delta,
    sv._author_id,
    sv._author,
    sv.__author_rep,
    sv.__implicit_author_rep,
    sv.__author_changed,
    sv._voter_id,
    sv._voter,
    sv.__voter_rep,
    sv.__implicit_voter_rep

  FROM case_when_first sv

),
case_when_second AS MATERIALIZED 
(
  SELECT 
    sv.__rshares,
    sv.__prev_rshares,
    sv.__prev_rep_delta,
    sv._author_id,
    sv._author,
    sv.__author_rep,
    sv.__implicit_author_rep,
    sv.__author_changed,
    sv._voter_id,
    sv._voter,
    (CASE WHEN sv.condition THEN sv.__author_rep ELSE sv.__voter_rep END ) AS __voter_rep,
    (CASE WHEN sv.condition THEN sv.__implicit_author_rep ELSE sv.__implicit_voter_rep END ) AS __implicit_voter_rep

  FROM second_condition sv

),
third_condition AS MATERIALIZED
(
  SELECT
    (CASE WHEN (sv.__voter_rep >= 0 AND (sv.__rshares > 0 OR (sv.__rshares < 0 AND NOT sv.__implicit_voter_rep AND sv.__voter_rep > sv.__author_rep))) 
    THEN true ELSE false END) AS condition,
    sv.__rshares,
    sv.__prev_rshares,
    sv.__prev_rep_delta,
    sv._author_id,
    sv._author,
    sv.__author_rep,
    sv.__implicit_author_rep,
    sv.__author_changed,
    sv._voter_id,
    sv._voter,
    sv.__voter_rep,
    sv.__implicit_voter_rep

  FROM case_when_second sv

),
case_when_third AS MATERIALIZED 
(
  SELECT 
    sv.__rshares,
    sv.__prev_rshares,
    sv.__prev_rep_delta,
    sv._author_id,
    sv._author,
    (CASE WHEN sv.condition THEN (sv.__author_rep + (sv.__rshares >> 6)::bigint) ELSE sv.__author_rep END ) AS __author_rep,
    (CASE WHEN sv.condition THEN false ELSE sv.__implicit_author_rep END ) AS __implicit_author_rep,
    (CASE WHEN sv.condition THEN true ELSE sv.__author_changed END ) AS __author_changed,
    sv._voter_id,
    sv._voter,
    sv.__voter_rep,
    sv.__implicit_voter_rep 

  FROM third_condition sv

)
  INSERT INTO reptracker_app.account_reputations
    (account_id, reputation, is_implicit)
  SELECT ds._author_id, ds.__author_rep, ds.__implicit_author_rep
  FROM case_when_third ds
  WHERE ds.__author_rep IS NOT NULL AND ds.__author_changed
  ON CONFLICT (account_id) DO UPDATE
  SET 
      reputation = EXCLUDED.reputation,
      is_implicit = EXCLUDED.is_implicit
  ;
END
$BODY$
;

/*
__author_idx := __vote_data.author_id+1;
__voter_idx := __vote_data.voter_id+1;

__voter_rep := __account_reputations[__voter_idx].reputation;
__implicit_author_rep := __account_reputations[__author_idx].is_implicit;

__implicit_voter_rep := __account_reputations[__voter_idx].is_implicit;

__author_rep := __account_reputations[__author_idx].reputation;
__rshares := __vote_data.rshares;
__prev_rshares := __vote_data.prev_rshares;
__prev_rep_delta := (__prev_rshares >> 6)::bigint;


--- Author must have set explicit reputation to allow its correction
IF 
NOT __implicit_author_rep AND __voter_rep >= 0 AND (__prev_rshares > 0 OR
    --- Voter must have explicitly set reputation to match hived old conditions
    (__prev_rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep - __prev_rep_delta)) THEN

  __author_rep := __author_rep - __prev_rep_delta;
  __implicit_author_rep := __author_rep = 0;

  __account_reputations[__author_idx] := ROW(__vote_data.author_id, __author_rep, __implicit_author_rep, true)::reputation_tracker_app.AccountReputation;
      
END IF;

__implicit_voter_rep := __account_reputations[__voter_idx].is_implicit;
--- reread voter's rep. since it can change above if author == voter
__voter_rep := __account_reputations[__voter_idx].reputation;


IF 
__voter_rep >= 0 AND 
(__rshares > 0 OR
(__rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep)) THEN

  __rep_delta := (__rshares >> 6)::bigint;
  __new_author_rep = __author_rep + __rep_delta;
  __account_reputations[__author_idx] := ROW(__vote_data.author_id, __new_author_rep, False, true)::reputation_tracker_app.AccountReputation;

END IF;

*/

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reptracker_app TO reputation_tracker_writer_group;


RESET ROLE;
