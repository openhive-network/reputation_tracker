SET ROLE reptracker_owner;

DO $$
BEGIN

CREATE SCHEMA reptracker_app AUTHORIZATION reptracker_owner;

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

EXCEPTION WHEN duplicate_schema THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

CREATE SCHEMA IF NOT EXISTS reputation_tracker_helpers;


CREATE OR REPLACE VIEW reptracker_app.deleted_comment_operation_view AS 
SELECT 
  o.id,
  o.block_num,
  o.trx_in_block,
  o.op_pos,
  (o.body::jsonb -> 'value') ->> 'author' AS author,
  (o.body::jsonb -> 'value') ->> 'permlink' AS permlink
FROM hive.reptracker_app_operations_view o
WHERE o.op_type_id in (17, 61); -- include delete_comment_operation and comment_payout_update_operation

CREATE OR REPLACE VIEW reptracker_app.hive_reputation_data_view AS 
SELECT 
  o.id,
  o.block_num, 
  o.trx_in_block, 
  o.op_pos, 
  (o.body::jsonb -> 'value' ->> 'author') as author, 
  (o.body::jsonb -> 'value' ->> 'voter') as voter,
  (o.body::jsonb -> 'value' ->> 'permlink') as permlink,
  (
    CASE jsonb_typeof (o.body::jsonb -> 'value' -> 'rshares')
    WHEN 'number' THEN
     (o.body::jsonb -> 'value' -> 'rshares')::BIGINT
    WHEN 'string' THEN
        trim(both '"' FROM (o.body::jsonb -> 'value' ->> 'rshares'))::BIGINT
    ELSE
      NULL::BIGINT
    END
  ) AS rshares

FROM hive.reptracker_app_operations_view o
WHERE o.op_type_id = 72
;

GRANT USAGE ON SCHEMA reptracker_app TO reputation_tracker_writer_group;

--- Only data writers can write to such table(s)
GRANT ALL ON reptracker_app.app_status TO reputation_tracker_writer_group;
GRANT ALL ON reptracker_app.account_reputations TO reputation_tracker_writer_group;
RESET ROLE;

CREATE INDEX IF NOT EXISTS stable_id_block_num_effective_vote_idx
    ON hive.operations USING btree
   (
     id,
     block_num
   )
    TABLESPACE haf_tablespace
    WHERE op_type_id = 72;


--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS effective_comment_vote_idx ON hive.operations USING btree
    (
   (body_binary::jsonb -> 'value' ->> 'author'),
   (body_binary::jsonb -> 'value' ->> 'voter'),
   (body_binary::jsonb -> 'value' ->> 'permlink'),
   id desc 
   )
    WHERE op_type_id = 72
  ;

--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS delete_comment_op_idx ON hive.operations USING btree
 (
   (body_binary::jsonb -> 'value' ->> 'author'),
   (body_binary::jsonb -> 'value' ->> 'permlink'),
   id desc
  )
  WHERE op_type_id in (17, 61)
  ;

ANALYZE hive.operations;
