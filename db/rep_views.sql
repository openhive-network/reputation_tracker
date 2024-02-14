SET ROLE reptracker_owner;

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

RESET ROLE;
