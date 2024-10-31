--  \ \    / /_\ | _ \ \| |_ _| \| |/ __|
--   \ \/\/ / _ \|   / .` || || .` | (_ |
--    \_/\_/_/ \_\_|_\_|\_|___|_|\_|\___|
--
-- this file is only executed at startup if the function hafbe_indexes.do_haf_indexes_exist()
-- returns true.  This function has a list of the indexes created in this file, and returns
-- true if they all exist.  If you add, remove, or rename an index created in this file, you
-- must make a corresponding change in that function
--
-- We do this because the ANALYZE at the end of this file is slow, and only needs to be run
-- if we actually created any indexes.  


-- Note, for each index below, we first check and see if it exists but is invalid; if so, we drop it.
-- That will cause it to be recreated by the subsequent CREATE IF NOT EXISTS
-- We could chec/drop all of the indexes in a single DO block at the top of the file, which might
-- look cleaner.  But I figure this way, someone doing cut & paste is more likely to grab both the
-- drop and the create.

DO $$
  BEGIN
    IF EXISTS(SELECT 1 FROM pg_index WHERE NOT indisvalid AND indexrelid = (SELECT oid FROM pg_class WHERE relname = 'effective_comment_vote_idx')) THEN
      RAISE NOTICE 'Dropping invalid index effective_comment_vote_idx, it will be recreated';
      DROP INDEX hive.effective_comment_vote_idx;
    END IF;
  END
$$;

CREATE INDEX CONCURRENTLY IF NOT EXISTS effective_comment_vote_idx ON hive.operations USING btree 
(
    (body_binary::jsonb -> 'value' ->> 'author'),
    (body_binary::jsonb -> 'value' ->> 'voter'),
    (body_binary::jsonb -> 'value' ->> 'permlink'),
    id desc 
)
WHERE hive.operation_id_to_type_id(id) = 72;

DO $$
  BEGIN
    IF EXISTS(SELECT 1 FROM pg_index WHERE NOT indisvalid AND indexrelid = (SELECT oid FROM pg_class WHERE relname = 'delete_comment_op_idx')) THEN
      RAISE NOTICE 'Dropping invalid index delete_comment_op_idx, it will be recreated';
      DROP INDEX hive.delete_comment_op_idx;
    END IF;
  END
$$;

CREATE INDEX CONCURRENTLY IF NOT EXISTS delete_comment_op_idx ON hive.operations USING btree 
(
    (body_binary::jsonb -> 'value' ->> 'author'),
    (body_binary::jsonb -> 'value' ->> 'permlink'),
    id desc
)
WHERE hive.operation_id_to_type_id(id) in (17, 61);

-- When you create expression indexes, you need to call ANALYZE to force postgresql to generate statistics on those expressions
ANALYZE VERBOSE hive.operations;
