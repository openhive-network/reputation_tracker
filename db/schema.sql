SET ROLE reputation_tracker_app_owner;

DO $$
BEGIN

CREATE SCHEMA reputation_tracker_app AUTHORIZATION reputation_tracker_app_owner;

RAISE NOTICE 'Attempting to create an application schema tables...';

IF NOT hive.app_context_exists('reputation_tracker_app') THEN
    RAISE NOTICE 'Attempting to create a HAF application context...';
    PERFORM hive.app_create_context('reputation_tracker_app');
END IF;

CREATE TABLE IF NOT EXISTS reputation_tracker_app.app_status
(
  continue_processing BOOLEAN NOT NULL,
  last_processed_block INT NOT NULL
);

INSERT INTO reputation_tracker_app.app_status
(continue_processing, last_processed_block)
VALUES
(True, 0)
;

CREATE TABLE IF NOT EXISTS reputation_tracker_app.account_reputations
(
    account_id INT NOT NULL,
    reputation BIGINT NOT NULL,
    is_implicit boolean,
    CONSTRAINT PK_account_reputations PRIMARY KEY (account_id)
)
INHERITS (hive.reputation_tracker_app)
;

CREATE UNLOGGED TABLE IF NOT EXISTS reputation_tracker_app.__new_reputation_data
(
    id bigint,
    author_id int,
    voter_id int,
    rshares bigint,
    prev_rshares bigint
)
;

CREATE UNLOGGED TABLE IF NOT EXISTS reputation_tracker_app.__tmp_accounts
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

CREATE OR REPLACE VIEW reputation_tracker_app.deleted_comment_operation_view
 AS
 SELECT ((o.block_num::bigint << 36) | (case o.trx_in_block = -1
                      when true then
                        32768::bigint << 20
                      else
                        o.trx_in_block::bigint << 20
                     end
                     )
     | (o.op_pos::bigint & '000011111111111111111111'::"bit"::bigint)) AS id,
    o.block_num,
    o.trx_in_block,
    o.op_pos,
    (o.body::jsonb -> 'value'::text) ->> 'author'::text AS author,
    (o.body::jsonb -> 'value'::text) ->> 'permlink'::text AS permlink
   FROM hive.reputation_tracker_app_operations_view o
  WHERE o.op_type_id in (17, 61); -- include delete_comment_operation and comment_payout_update_operation

create or replace view reputation_tracker_app.hive_reputation_data_view as
select ((block_num::bigint << 36) |
CASE trx_in_block = '-1'::integer
    WHEN true THEN 32768::bigint << 20
    ELSE trx_in_block::bigint << 20
END
 | (op_pos::bigint & '000011111111111111111111'::"bit"::bigint)) as id,
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

from hive.reputation_tracker_app_operations_view o
where o.op_type_id = 72
  ;



GRANT USAGE ON SCHEMA reputation_tracker_app TO reputation_tracker_writer_group;

--- Only data writers can write to such table(s)
GRANT ALL ON reputation_tracker_app.app_status TO reputation_tracker_writer_group;
GRANT ALL ON reputation_tracker_app.account_reputations TO reputation_tracker_writer_group;
GRANT ALL ON reputation_tracker_app.__new_reputation_data TO reputation_tracker_writer_group;
GRANT ALL ON reputation_tracker_app.__tmp_accounts TO reputation_tracker_writer_group;

RESET ROLE;

CREATE INDEX IF NOT EXISTS stable_id_block_num_effective_vote_idx
    ON hive.operations USING btree
	 (
((block_num::bigint << 36) |
CASE trx_in_block = '-1'::integer
    WHEN true THEN 32768::bigint << 20
    ELSE trx_in_block::bigint << 20
END
 | (op_pos::bigint & '000011111111111111111111'::"bit"::bigint)),
	block_num
)
    TABLESPACE haf_tablespace
    WHERE op_type_id = 72;


--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS effective_comment_vote_idx ON hive.operations USING btree
    (
   (body::jsonb -> 'value' ->> 'author'::text),
   (body::jsonb -> 'value' ->> 'voter'::text),
   (body::jsonb -> 'value' ->> 'permlink'::text),
   (CAST( block_num as BIGINT ) << 36
       | ( trx_in_block::BIGINT << 20 )
       | ( op_pos::BIGINT & CAST( x'0FFFFF' as BIGINT) )) desc
  )
    WHERE op_type_id = 72
  ;

--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS delete_comment_op_idx ON hive.operations USING btree
 (
   (body::jsonb -> 'value' ->> 'author'::text),
   (body::jsonb -> 'value' ->> 'permlink'::text),
   ((block_num::bigint << 36)
    | (case trx_in_block = -1
      when true then
        32768::bigint << 20
      else
        trx_in_block::bigint << 20
    end
    )
    | (op_pos::bigint & '000011111111111111111111'::"bit"::bigint)) desc
  )
  WHERE op_type_id in (17, 61)
  ;

ANALYZE hive.operations;
