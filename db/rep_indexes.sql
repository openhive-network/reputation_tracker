CREATE INDEX IF NOT EXISTS stable_id_block_num_effective_vote_idx ON hive.operations USING btree
(
    id,
    hive.operation_id_to_block_num(id)
)
WHERE hive.operation_id_to_type_id(id) = 72;

--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS effective_comment_vote_idx ON hive.operations USING btree
(
    (body_binary::jsonb -> 'value' ->> 'author'),
    (body_binary::jsonb -> 'value' ->> 'voter'),
    (body_binary::jsonb -> 'value' ->> 'permlink'),
    id desc 
)
WHERE hive.operation_id_to_type_id(id) = 72;

--- This statement must be executed by haf_block_log database owner (haf_admin)
CREATE INDEX IF NOT EXISTS delete_comment_op_idx ON hive.operations USING btree
(
    (body_binary::jsonb -> 'value' ->> 'author'),
    (body_binary::jsonb -> 'value' ->> 'permlink'),
    id desc
)
WHERE hive.operation_id_to_type_id(id) in (17, 61);

ANALYZE hive.operations;
