-- noqa: disable=PRS

DO $$
DECLARE 
  __schema_name VARCHAR;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;

  --FIXME indexes must be created concurrently
  PERFORM hive.register_index_dependency(
      __schema_name,
      $idx$
      CREATE UNIQUE INDEX IF NOT EXISTS delete_comment_op_idx ON hafd.operations USING btree
      (
          (body_binary::jsonb -> 'value' ->> 'author'),
          (body_binary::jsonb -> 'value' ->> 'permlink'),
          id desc
      )
      WHERE hafd.operation_id_to_type_id(id) in (17, 61)
      $idx$
  );

  PERFORM hive.register_index_dependency(
      __schema_name,
      $idx$
      CREATE UNIQUE INDEX IF NOT EXISTS effective_comment_vote_idx ON hafd.operations USING btree
      (
          (body_binary::jsonb -> 'value' ->> 'author'),
          (body_binary::jsonb -> 'value' ->> 'voter'),
          (body_binary::jsonb -> 'value' ->> 'permlink'),
          id desc 
      )
      WHERE hafd.operation_id_to_type_id(id) = 72
      $idx$
  );

END
$$;
