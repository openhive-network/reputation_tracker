SET ROLE reptracker_app_owner;

DROP TYPE IF EXISTS reptracker_app.AccountReputation CASCADE;

CREATE TYPE reptracker_app.AccountReputation AS (id int, reputation bigint, is_implicit boolean, changed boolean);

DROP FUNCTION IF EXISTS reptracker_app.calculate_account_reputations;

-- 1. 3.44s -- podstawa
-- 2. 3.08s -- zmiana na CTE w update_account_reputations
-- 3. 2.32s -- zmiana na CTE w calculate_account_reputations
-- 4. 2.30s -- zmiana na id w indexach i views z calculate_operation_stable_id

--- Massive version of account reputation calculation.
CREATE OR REPLACE FUNCTION reptracker_app.calculate_account_reputations(
  IN _first_block_num integer,
  IN _last_block_num integer,
  IN _reporting_step integer,
  OUT _last_processed_block INTEGER,
  _tracked_account character varying DEFAULT NULL::character varying)
    RETURNS INT
    LANGUAGE 'plpgsql'
    VOLATILE 
    SET from_collapse_limit = 16
    SET join_collapse_limit = 16
    SET jit = OFF
    SET cursor_tuple_fraction=0.9
AS $BODY$
DECLARE
  __vote_data RECORD;
  __account_reputations reptracker_app.AccountReputation[];
  __author_rep bigint;
  __new_author_rep bigint;
  __voter_rep bigint;
  __implicit_voter_rep boolean;
  __implicit_author_rep boolean;
  __rshares bigint;
  __prev_rshares bigint;
  __rep_delta bigint;
  __prev_rep_delta bigint;
  __account_name varchar;
  __author_idx int;
  __voter_idx int;
  __last_reported_block int := 0;
  __first_vote_processed boolean := false;
  __debug_log boolean := false;
BEGIN
  raise notice 'Gathering data to process block range: %, %', _first_block_num, _last_block_num;

  --- In case when pointed range is empty
  _last_processed_block := _last_block_num;

  SELECT INTO __account_reputations ARRAY(SELECT ROW(a.account_id, a.reputation, a.is_implicit, false)::reptracker_app.AccountReputation 
  FROM reptracker_app.account_reputations a
  ORDER BY a.account_id);

  FOR __vote_data IN
  WITH select_ef_vote_ops AS MATERIALIZED
  (
  SELECT o.id,
      o.block_num,
      o.trx_in_block,
      o.op_pos,
      o.body_binary::JSONB as body
  FROM hive.reptracker_app_operations_view o WHERE o.op_type_id = 72 
  WHERE (_first_block_num IS NULL AND _last_block_num IS NULL) OR (o.block_num BETWEEN _first_block_num AND _last_block_num)  ),
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
  SELECT up.id AS up_id, up.block_num, up.author, up.permlink, up.voter, up.rshares AS up_rshares,
    (
      SELECT prd.id  
      FROM reptracker_app.hive_reputation_data_view prd
      WHERE prd.author = up.author AND prd.voter = up.voter
      AND prd.permlink = up.permlink AND prd.id < up.id
      ORDER BY prd.id DESC LIMIT 1
    ) AS prd_id
  FROM selected_range up
  ),
  filter_deleted_comments AS MATERIALIZED 
  (
  SELECT prd.up_id, prd.block_num, prd.author, prd.permlink, prd.voter, prd.up_rshares, prd.prd_id,
    COALESCE(
      (SELECT 1 
      FROM 
        reptracker_app.deleted_comment_operation_view dp
      WHERE 
        dp.author = prd.author 
        AND dp.permlink = prd.permlink 
        AND prd.prd_id IS NOT NULL
        AND dp.id between prd.prd_id AND prd.up_id
      LIMIT 1),0) as filtered
  FROM filtered_range prd 
  )
  SELECT 
  fdc.up_id AS id,
  fdc.block_num, 
  fdc.author, 
  fdc.permlink, 
  (SELECT av.id FROM hive.accounts_view av WHERE av.name = fdc.author) as author_id, 
  fdc.voter, 
  (SELECT av.id FROM hive.accounts_view av WHERE av.name = fdc.voter) as voter_id, 
  fdc.up_rshares AS rshares, 
  COALESCE(
        (
          SELECT rshares  
          FROM reptracker_app.hive_reputation_data_view 
          WHERE id = fdc.prd_id AND fdc.filtered = 1
        ), 0
    ) AS prev_rshares
  FROM filter_deleted_comments fdc
  ORDER BY fdc.up_id

    LOOP
      IF NOT __first_vote_processed THEN
        raise notice 'Data gathered. Starting block range processing...';
        __first_vote_processed := True;
      END IF;

      __author_idx := __vote_data.author_id+1;
      __voter_idx := __vote_data.voter_id+1;

      __voter_rep := __account_reputations[__voter_idx].reputation;
      __implicit_author_rep := __account_reputations[__author_idx].is_implicit;

      __implicit_voter_rep := __account_reputations[__voter_idx].is_implicit;
    
      __author_rep := __account_reputations[__author_idx].reputation;
      __rshares := __vote_data.rshares;
      __prev_rshares := __vote_data.prev_rshares;
      __prev_rep_delta := (__prev_rshares >> 6)::bigint;

      IF __debug_log THEN
        raise notice 'Block: % - Preprocessing a vote: author: `%`, voter: `%` permlink: %', __vote_data.block_num-1, __vote_data.author, __vote_data.voter, __vote_data.permlink;

        --- Author must have set explicit reputation to allow its correction
        IF NOT __implicit_author_rep AND __prev_rshares != 0 THEN
          raise notice 'Author `%` reputation (pre-correction): %', __vote_data.author, __author_rep;
          raise notice 'Author `%` - Correcting a vote: (voter: `%`) rshares: %', __vote_data.author, __vote_data.voter, __vote_data.prev_rshares;
          raise notice 'Author `%` - Voter `%` reputation: %', __vote_data.author, __vote_data.voter, __voter_rep;
        END IF;
      END IF;
    
      --- Author must have set explicit reputation to allow its correction
      IF NOT __implicit_author_rep AND __voter_rep >= 0 AND
         (__prev_rshares > 0 OR
          --- Voter must have explicitly set reputation to match hived old conditions
         (__prev_rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep - __prev_rep_delta)) THEN
            __author_rep := __author_rep - __prev_rep_delta;
            __implicit_author_rep := __author_rep = 0;

            __account_reputations[__author_idx] := ROW(__vote_data.author_id, __author_rep, __implicit_author_rep, true)::reptracker_app.AccountReputation;
            
          IF __debug_log THEN 
            IF __implicit_author_rep THEN
              raise notice 'Author `%` reputation (past-correction): implicit-0', __vote_data.author;
            ELSE
              raise notice 'Author `%` reputation (past-correction): %', __vote_data.author, __author_rep;
            END IF;
          END IF;
      END IF;

      __implicit_voter_rep := __account_reputations[__voter_idx].is_implicit;
      --- reread voter's rep. since it can change above if author == voter
      __voter_rep := __account_reputations[__voter_idx].reputation;

      IF __debug_log THEN 
        raise notice 'Block: % - Author `%` - Processing a vote: (voter: `%`) rshares: %', __vote_data.block_num-1, __vote_data.author, __vote_data.voter, __vote_data.rshares;
        raise notice 'Author `%` - Voter `%` reputation: %', __vote_data.author, __vote_data.voter, __voter_rep;
      END IF;

      IF __voter_rep >= 0 AND (__rshares > 0 OR
         (__rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep)) THEN

        __rep_delta := (__rshares >> 6)::bigint;
        __new_author_rep = __author_rep + __rep_delta;
        __account_reputations[__author_idx] := ROW(__vote_data.author_id, __new_author_rep, False, true)::reptracker_app.AccountReputation;

        IF __debug_log THEN 
          IF __implicit_author_rep THEN
            raise notice 'Setting a reputation of author: `%` to %', __vote_data.author, __new_author_rep;
          ELSE
            raise notice 'Changing reputation of author: `%` from % to %', __vote_data.author, __author_rep, __new_author_rep;
          END IF;
        END IF;
      END IF;

      _last_processed_block := __vote_data.block_num;
    END LOOP;

  INSERT INTO reptracker_app.account_reputations
    (account_id, reputation, is_implicit)
  SELECT ds.id, ds.reputation, ds.is_implicit
  FROM unnest(__account_reputations) ds
  WHERE ds.Reputation IS NOT NULL AND ds.Changed
  ON CONFLICT (account_id) DO UPDATE
  SET 
      reputation = EXCLUDED.reputation,
      is_implicit = EXCLUDED.is_implicit
  ;

END
$BODY$
;

DROP FUNCTION IF EXISTS reptracker_app.calculate_account_reputations_for_block;


CREATE OR REPLACE FUNCTION reptracker_app.calculate_account_reputations_for_block(IN _block_num INT, OUT _last_processed_block INT, IN _tracked_account VARCHAR DEFAULT NULL::VARCHAR)
  RETURNS INT
  LANGUAGE 'plpgsql'
  VOLATILE
  SET from_collapse_limit = 16
  SET join_collapse_limit = 16
  SET jit = OFF
  SET cursor_tuple_fraction=0.9
AS $BODY$
DECLARE
  __vote_data RECORD;
  __author_rep bigint;
  __new_author_rep bigint;
  __voter_rep bigint;
  __implicit_voter_rep boolean;
  __implicit_author_rep boolean;
  __author_rep_changed boolean := false;
  __rshares bigint;
  __prev_rshares bigint;
  __rep_delta bigint;
  __prev_rep_delta bigint;
  __traced_author int;
  __account_name varchar;
BEGIN

  DELETE FROM reptracker_app.__new_reputation_data;

  INSERT INTO reptracker_app.__new_reputation_data
    with source_data as materialized
    (
    SELECT rd.id, rd.block_num, rd.author, rd.voter, rd.rshares,
          COALESCE((SELECT prd.rshares
                   FROM reptracker_app.hive_reputation_data_view prd
                   WHERE prd.author = rd.author AND prd.voter = rd.voter
                         AND prd.permlink = rd.permlink AND prd.id < rd.id
                         --- warning previous votes targeting posts which have been next deleted (before voting again) must be ignored
                         AND NOT EXISTS (SELECT NULL FROM reptracker_app.deleted_comment_operation_view dp
                                         WHERE dp.author = rd.author and dp.permlink = rd.permlink and dp.id between prd.id and rd.id)
                   ORDER BY prd.id DESC LIMIT 1), 0
          ) AS prev_rshares
        FROM reptracker_app.hive_reputation_data_view rd
        WHERE rd.block_num = _block_num
    )
    select s.id, ha.id as author_id, hv.id as voter_id, s.rshares, s.prev_rshares
    from source_data s
    join hive.accounts_view ha on ha.name = s.author
    join hive.accounts_view hv on hv.name = s.voter
    ORDER BY s.id 
    ;


  DELETE FROM reptracker_app.__tmp_accounts;

  INSERT INTO reptracker_app.__tmp_accounts
  SELECT ha.account_id, ha.reputation, ha.is_implicit, false AS changed
  FROM reptracker_app.__new_reputation_data rd
  JOIN reptracker_app.account_reputations ha on rd.author_id = ha.account_id
  UNION
  SELECT hv.account_id, hv.reputation, hv.is_implicit, false as changed
  FROM reptracker_app.__new_reputation_data rd
  JOIN reptracker_app.account_reputations hv on rd.voter_id = hv.account_id
  ;

  SELECT COALESCE((SELECT ha.id FROM hive.accounts ha WHERE ha.name = _tracked_account), 0) INTO __traced_author;

  FOR __vote_data IN
      SELECT rd.id, rd.author_id, rd.voter_id, rd.rshares, rd.prev_rshares
      FROM reptracker_app.__new_reputation_data rd
      ORDER BY rd.id
    LOOP
      SELECT INTO __voter_rep, __implicit_voter_rep ha.reputation, ha.is_implicit 
      FROM reptracker_app.__tmp_accounts ha where ha.id = __vote_data.voter_id;
      SELECT INTO __author_rep, __implicit_author_rep ha.reputation, ha.is_implicit 
      FROM reptracker_app.__tmp_accounts ha where ha.id = __vote_data.author_id;

      IF __vote_data.author_id = __traced_author THEN
           raise notice 'Processing vote <%> rshares: %, prev_rshares: %', __vote_data.id, __vote_data.rshares, __vote_data.prev_rshares;
       select ha.name into __account_name from hive.accounts ha where ha.id = __vote_data.voter_id;
       raise notice 'Voter `%` (%) reputation: %', __account_name, __vote_data.voter_id,  __voter_rep;
      END IF;
      CONTINUE WHEN __voter_rep < 0;
    
      __rshares := __vote_data.rshares;
      __prev_rshares := __vote_data.prev_rshares;
      __prev_rep_delta := (__prev_rshares >> 6)::bigint;

      IF NOT __implicit_author_rep AND --- Author must have set explicit reputation to allow its correction
         (__prev_rshares > 0 OR
          --- Voter must have explicitly set reputation to match hived old conditions
         (__prev_rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep - __prev_rep_delta)) THEN
            __author_rep := __author_rep - __prev_rep_delta;
            __implicit_author_rep := __author_rep = 0;
            __author_rep_changed = true;
            if __vote_data.author_id = __vote_data.voter_id THEN
              __implicit_voter_rep := __implicit_author_rep;
              __voter_rep := __author_rep;
            end if;

            IF __vote_data.author_id = __traced_author THEN
             raise notice 'Corrected author_rep by prev_rep_delta: % to have reputation: %', __prev_rep_delta, __author_rep;
            END IF;
      END IF;
    
      IF __rshares > 0 OR
         (__rshares < 0 AND NOT __implicit_voter_rep AND __voter_rep > __author_rep) THEN

        __rep_delta := (__rshares >> 6)::bigint;
        __new_author_rep = __author_rep + __rep_delta;
        __author_rep_changed = true;

        UPDATE reptracker_app.__tmp_accounts
        SET reputation = __new_author_rep,
            is_implicit = False,
            changed = true
        WHERE id = __vote_data.author_id;

        IF __vote_data.author_id = __traced_author THEN
          raise notice 'Changing account: <%> reputation from % to %', __vote_data.author_id, __author_rep, __new_author_rep;
        END IF;
      ELSE
        IF __vote_data.author_id = __traced_author THEN
            raise notice 'Ignoring reputation change due to unmet conditions... Author_rep: %, Voter_rep: %', __author_rep, __voter_rep;
        END IF;
      END IF;
    END LOOP;

    _last_processed_block := _block_num;

  INSERT INTO reptracker_app.account_reputations
    (account_id, reputation, is_implicit)
  SELECT ds.id, ds.reputation, ds.is_implicit
  FROM reptracker_app.__tmp_accounts ds
  WHERE ds.Reputation IS NOT NULL AND ds.Changed
  ON CONFLICT (account_id) DO UPDATE
  SET 
      reputation = EXCLUDED.reputation,
      is_implicit = EXCLUDED.is_implicit
  ;

END
$BODY$
;

DROP FUNCTION IF EXISTS reptracker_app.update_account_reputations;

CREATE OR REPLACE FUNCTION reptracker_app.update_account_reputations(
  in _first_block_num INTEGER,
  in _last_block_num INTEGER,
  IN _reporting_step INTEGER,
  OUT _last_processed_block INTEGER)
  RETURNS INT
  LANGUAGE 'plpgsql'
  VOLATILE
  SET from_collapse_limit = 16
  SET join_collapse_limit = 16
  SET jit = OFF
AS $BODY$
BEGIN
WITH select_account_reputations AS MATERIALIZED
(
SELECT ha.id AS ha_id, 0, true, ar.account_id as ar_id
FROM hive.accounts_view ha
LEFT JOIN reptracker_app.account_reputations ar ON ar.account_id = ha.id
)
INSERT INTO reptracker_app.account_reputations
  (account_id, reputation, is_implicit)
SELECT sar.ha_id, 0, true
FROM select_account_reputations sar
WHERE sar.ar_id IS NULL
;

  IF _first_block_num IS NULL OR _last_block_num IS NULL OR _first_block_num != _last_block_num THEN
    _last_processed_block := reptracker_app.calculate_account_reputations(_first_block_num, _last_block_num, _reporting_step);
  ELSE
    _last_processed_block := reptracker_app.calculate_account_reputations_for_block(_first_block_num);
  END IF;

END
$BODY$
;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reptracker_app TO reputation_tracker_writer_group;



RESET ROLE;
