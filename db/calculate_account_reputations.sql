SET ROLE reputation_tracker_app_owner;

DROP TYPE IF EXISTS reputation_tracker_app.AccountReputation CASCADE;

CREATE TYPE reputation_tracker_app.AccountReputation AS (id int, reputation bigint, is_implicit boolean, changed boolean);

DROP FUNCTION IF EXISTS reputation_tracker_app.calculate_account_reputations;

--- Massive version of account reputation calculation.
CREATE OR REPLACE FUNCTION reputation_tracker_app.calculate_account_reputations(
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
  __account_reputations reputation_tracker_app.AccountReputation[];
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

  SELECT INTO __account_reputations ARRAY(SELECT ROW(a.account_id, a.reputation, a.is_implicit, false)::reputation_tracker_app.AccountReputation
  FROM reputation_tracker_app.account_reputations a
  ORDER BY a.account_id);

  FOR __vote_data IN
    with source_data as materialized
    (
    SELECT rd.id, rd.block_num, rd.author, rd.permlink, rd.voter, rd.rshares,
          COALESCE((SELECT prd.rshares
                   FROM reputation_tracker_app.hive_reputation_data_view prd
                   WHERE prd.author = rd.author AND prd.voter = rd.voter
                         AND prd.permlink = rd.permlink AND prd.id < rd.id
                         --- warning previous votes targeting posts which have been next deleted (before voting again) must be ignored
                         AND NOT EXISTS (SELECT NULL FROM reputation_tracker_app.deleted_comment_operation_view dp
                                         WHERE dp.author = rd.author and dp.permlink = rd.permlink and dp.id between prd.id and rd.id)
                   ORDER BY prd.id DESC LIMIT 1), 0
          ) AS prev_rshares
        FROM reputation_tracker_app.hive_reputation_data_view rd
        WHERE (_first_block_num IS NULL AND _last_block_num IS NULL) OR (rd.block_num BETWEEN _first_block_num AND _last_block_num)
    )
    select s.id, s.block_num, s.author, s.permlink, ha.id as author_id, s.voter, hv.id as voter_id, s.rshares, s.prev_rshares
    from source_data s
    join hive.accounts_view ha on ha.name = s.author
    join hive.accounts_view hv on hv.name = s.voter
    ORDER BY s.id 
    LOOP
      IF NOT __first_vote_processed THEN
        raise notice 'Data gathered. Starting block range processing...';
        __first_vote_processed := True;
      END IF;

      IF __vote_data.block_num % _reporting_step = 0 AND __vote_data.block_num > __last_reported_block THEN
         raise notice 'Processing block: %', __vote_data.block_num;

         __last_reported_block := __vote_data.block_num;

         EXIT WHEN NOT reputation_tracker_app.continueProcessing();

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

            __account_reputations[__author_idx] := ROW(__vote_data.author_id, __author_rep, __implicit_author_rep, true)::reputation_tracker_app.AccountReputation;
            
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
        __account_reputations[__author_idx] := ROW(__vote_data.author_id, __new_author_rep, False, true)::reputation_tracker_app.AccountReputation;

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

  INSERT INTO reputation_tracker_app.account_reputations
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

DROP FUNCTION IF EXISTS reputation_tracker_app.calculate_account_reputations_for_block;


CREATE OR REPLACE FUNCTION reputation_tracker_app.calculate_account_reputations_for_block(IN _block_num INT, OUT _last_processed_block INT, IN _tracked_account VARCHAR DEFAULT NULL::VARCHAR)
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

  DELETE FROM reputation_tracker_app.__new_reputation_data;

  INSERT INTO reputation_tracker_app.__new_reputation_data
    with source_data as materialized
    (
    SELECT rd.id, rd.block_num, rd.author, rd.voter, rd.rshares,
          COALESCE((SELECT prd.rshares
                   FROM reputation_tracker_app.hive_reputation_data_view prd
                   WHERE prd.author = rd.author AND prd.voter = rd.voter
                         AND prd.permlink = rd.permlink AND prd.id < rd.id
                         --- warning previous votes targeting posts which have been next deleted (before voting again) must be ignored
                         AND NOT EXISTS (SELECT NULL FROM reputation_tracker_app.deleted_comment_operation_view dp
                                         WHERE dp.author = rd.author and dp.permlink = rd.permlink and dp.id between prd.id and rd.id)
                   ORDER BY prd.id DESC LIMIT 1), 0
          ) AS prev_rshares
        FROM reputation_tracker_app.hive_reputation_data_view rd
        WHERE rd.block_num = _block_num
    )
    select s.id, ha.id as author_id, hv.id as voter_id, s.rshares, s.prev_rshares
    from source_data s
    join hive.accounts_view ha on ha.name = s.author
    join hive.accounts_view hv on hv.name = s.voter
    ORDER BY s.id 
    ;


  DELETE FROM reputation_tracker_app.__tmp_accounts;

  INSERT INTO reputation_tracker_app.__tmp_accounts
  SELECT ha.account_id, ha.reputation, ha.is_implicit, false AS changed
  FROM reputation_tracker_app.__new_reputation_data rd
  JOIN reputation_tracker_app.account_reputations ha on rd.author_id = ha.account_id
  UNION
  SELECT hv.account_id, hv.reputation, hv.is_implicit, false as changed
  FROM reputation_tracker_app.__new_reputation_data rd
  JOIN reputation_tracker_app.account_reputations hv on rd.voter_id = hv.account_id
  ;

  SELECT COALESCE((SELECT ha.id FROM hive.accounts ha WHERE ha.name = _tracked_account), 0) INTO __traced_author;

  FOR __vote_data IN
      SELECT rd.id, rd.author_id, rd.voter_id, rd.rshares, rd.prev_rshares
      FROM reputation_tracker_app.__new_reputation_data rd
      ORDER BY rd.id
    LOOP
      SELECT INTO __voter_rep, __implicit_voter_rep ha.reputation, ha.is_implicit 
      FROM reputation_tracker_app.__tmp_accounts ha where ha.id = __vote_data.voter_id;
      SELECT INTO __author_rep, __implicit_author_rep ha.reputation, ha.is_implicit 
      FROM reputation_tracker_app.__tmp_accounts ha where ha.id = __vote_data.author_id;

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

        UPDATE reputation_tracker_app.__tmp_accounts
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

  INSERT INTO reputation_tracker_app.account_reputations
    (account_id, reputation, is_implicit)
  SELECT ds.id, ds.reputation, ds.is_implicit
  FROM reputation_tracker_app.__tmp_accounts ds
  WHERE ds.Reputation IS NOT NULL AND ds.Changed
  ON CONFLICT (account_id) DO UPDATE
  SET 
      reputation = EXCLUDED.reputation,
      is_implicit = EXCLUDED.is_implicit
  ;

END
$BODY$
;

DROP FUNCTION IF EXISTS reputation_tracker_app.update_account_reputations;

CREATE OR REPLACE FUNCTION reputation_tracker_app.update_account_reputations(
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
  INSERT INTO reputation_tracker_app.account_reputations
    (account_id, reputation, is_implicit)
  SELECT ha.id, 0, true
  FROM hive.accounts_view ha
  WHERE NOT EXISTS (SELECT NULL FROM reputation_tracker_app.account_reputations ar WHERE ar.account_id = ha.id)
  ;

  IF _first_block_num IS NULL OR _last_block_num IS NULL OR _first_block_num != _last_block_num THEN
    _last_processed_block := reputation_tracker_app.calculate_account_reputations(_first_block_num, _last_block_num, _reporting_step);
  ELSE
    _last_processed_block := reputation_tracker_app.calculate_account_reputations_for_block(_first_block_num);
  END IF;

END
$BODY$
;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reputation_tracker_app TO reputation_tracker_writer_group;

RESET ROLE;
