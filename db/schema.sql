SET ROLE reptracker_app_owner;

DO $$
BEGIN

CREATE SCHEMA reptracker_app AUTHORIZATION reptracker_app_owner;

RAISE NOTICE 'Attempting to create an application schema tables...';

IF NOT hive.app_context_exists('reptracker_app') THEN
    RAISE NOTICE 'Attempting to create a HAF application context...';
    PERFORM hive.app_create_context('reptracker_app');
END IF;

CREATE TABLE IF NOT EXISTS reptracker_app.app_status
(
  continue_processing BOOLEAN NOT NULL,
  last_processed_block INT NOT NULL
);

INSERT INTO reptracker_app.app_status
(continue_processing, last_processed_block)
VALUES
(True, 0)
;

CREATE TABLE IF NOT EXISTS reptracker_app.account_reputations
(
    account_id INT NOT NULL,
    reputation BIGINT NOT NULL,
    is_implicit boolean,
    CONSTRAINT PK_account_reputations PRIMARY KEY (account_id)
)
INHERITS (hive.reptracker_app)
;

CREATE UNLOGGED TABLE IF NOT EXISTS reptracker_app.__new_reputation_data
(
    id bigint,
    author_id int,
    voter_id int,
    rshares bigint,
    prev_rshares bigint
)
;

CREATE UNLOGGED TABLE IF NOT EXISTS reptracker_app.__tmp_accounts
(
    id integer,
    reputation bigint,
    is_implicit boolean,
    changed boolean
)
;

EXCEPTION WHEN duplicate_schema THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

CREATE SCHEMA IF NOT EXISTS reputation_tracker_helpers;

CREATE OR REPLACE FUNCTION reputation_tracker_helpers.calculate_operation_stable_id(_block_num hive.operations.block_num%TYPE,
  _trx_in_block hive.operations.trx_in_block%TYPE, _op_pos hive.operations.op_pos%TYPE)
RETURNS BIGINT
LANGUAGE 'sql'
IMMUTABLE
AS $BODY$
    SELECT ((_block_num::BIGINT << 36)
           |(CASE _trx_in_block = -1
               WHEN TRUE THEN
                 32768::BIGINT << 20
               ELSE
                 _trx_in_block::BIGINT << 20
             END
            )
          | (_op_pos::bigint & '000011111111111111111111'::"bit"::BIGINT)
          )
    END;
$BODY$;


CREATE OR REPLACE VIEW reptracker_app.deleted_comment_operation_view
 AS
 SELECT reputation_tracker_helpers.calculate_operation_stable_id(o.block_num, o.trx_in_block, o.op_pos) AS id,
    o.block_num,
    o.trx_in_block,
    o.op_pos,
    (o.body::jsonb -> 'value'::text) ->> 'author'::text AS author,
    (o.body::jsonb -> 'value'::text) ->> 'permlink'::text AS permlink
   FROM hive.reptracker_app_operations_view o
  WHERE o.op_type_id in (17, 61); -- include delete_comment_operation and comment_payout_update_operation

CREATE OR REPLACE VIEW reptracker_app.hive_reputation_data_view as
  SELECT reputation_tracker_helpers.calculate_operation_stable_id(o.block_num, o.trx_in_block, o.op_pos) AS id,
  o.block_num, o.trx_in_block, o.op_pos, (o.body::jsonb -> 'value' ->> 'author') as author, (o.body::jsonb -> 'value' ->> 'voter') as voter,
  (o.body::jsonb -> 'value' ->> 'permlink') as permlink,
  case jsonb_typeof (o.body::jsonb -> 'value' -> 'rshares')
    when 'number' then
     (o.body::jsonb -> 'value' -> 'rshares')::bigint
  when 'string' then
      trim(both '"' from (o.body::jsonb -> 'value' ->> 'rshares'))::bigint
  else
     null::bigint
  end as rshares

from hive.reptracker_app_operations_view o
where o.op_type_id = 72
  ;



GRANT USAGE ON SCHEMA reptracker_app TO reputation_tracker_writer_group;

--- Only data writers can write to such table(s)
GRANT ALL ON reptracker_app.app_status TO reputation_tracker_writer_group;
GRANT ALL ON reptracker_app.account_reputations TO reputation_tracker_writer_group;
GRANT ALL ON reptracker_app.__new_reputation_data TO reputation_tracker_writer_group;
GRANT ALL ON reptracker_app.__tmp_accounts TO reputation_tracker_writer_group;

RESET ROLE;

CREATE INDEX IF NOT EXISTS stable_id_block_num_effective_vote_idx
    ON hive.operations USING btree
   (
     (reputation_tracker_helpers.calculate_operation_stable_id(block_num, trx_in_block, op_pos)),
     block_num
   )
    TABLESPACE haf_tablespace
    WHERE op_type_id = 72;


--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS effective_comment_vote_idx ON hive.operations USING btree
    (
   (body_binary::jsonb -> 'value' ->> 'author'::text),
   (body_binary::jsonb -> 'value' ->> 'voter'::text),
   (body_binary::jsonb -> 'value' ->> 'permlink'::text),
   (reputation_tracker_helpers.calculate_operation_stable_id(block_num, trx_in_block, op_pos)) desc
   )
    WHERE op_type_id = 72
  ;

--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS delete_comment_op_idx ON hive.operations USING btree
 (
   (body_binary::jsonb -> 'value' ->> 'author'::text),
   (body_binary::jsonb -> 'value' ->> 'permlink'::text),
   (reputation_tracker_helpers.calculate_operation_stable_id(block_num, trx_in_block, op_pos)) desc
  )
  WHERE op_type_id in (17, 61)
  ;

ANALYZE hive.operations;
