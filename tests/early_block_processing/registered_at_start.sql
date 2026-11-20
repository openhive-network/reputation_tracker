-- After hived has filled hafd.operation_types and main() has started once more as the
-- context owner, without a reinstall. On a HAF with hive.register_op_type_partial_index
-- (haf#510) that start registered the partial index the install skipped, without
-- building it; on an older HAF it neither registered nor built it (the LIVE stage
-- builds it there). Run by run_test.sh, which sets :haf_builds_index.
--
-- Then releases the registration, so that the reinstall that follows is what
-- registers it for early_block_processing.sql.
\set ON_ERROR_STOP on
-- do_rep_indexes_exist() calls its helpers unqualified, as main() does
SET search_path TO reptracker_app, public;
SELECT :'haf_builds_index'::BOOLEAN AS haf_builds_index \gset

\if :haf_builds_index
DO $$
BEGIN
  ASSERT EXISTS ( SELECT 1 FROM hafd.indexes_constraints ic
                  WHERE ic.table_name = 'hafd.operations' AND ic.index_constraint_name = 'hive_operations_op_types_17_61_72_idx'
                    AND ic.contexts @> ARRAY[( SELECT id FROM hafd.contexts WHERE name = 'reptracker_app' )] ),
    'the start of main() did not register the partial index on hafd.operations the install skipped';
  ASSERT NOT EXISTS ( SELECT 1 FROM pg_indexes WHERE indexname = 'hive_operations_op_types_17_61_72_idx' ),
    'the start of main() built the partial index on hafd.operations, which HAF builds';
  ASSERT reptracker_app.do_rep_indexes_exist(), 'do_rep_indexes_exist() does not see the registration';
END
$$;
DELETE FROM hafd.indexes_constraints
WHERE table_name = 'hafd.operations' AND index_constraint_name = 'hive_operations_op_types_17_61_72_idx';
\echo 'the start of main() registered the partial index the install skipped'
\else
DO $$
BEGIN
  ASSERT NOT EXISTS ( SELECT 1 FROM pg_indexes WHERE indexname = 'hive_operations_op_types_17_61_72_idx' ),
    'the start of main() built the partial index on hafd.operations';
END
$$;
\echo 'HAF without hive.register_op_type_partial_index: the start of main() leaves the partial index to the LIVE stage'
\endif
