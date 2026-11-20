-- Right after scripts/install_app.sh into a HAF database whose hafd.operation_types
-- hived has not filled yet: the install registered no partial index on hafd.operations
-- and built none. Run by run_test.sh, which sets :haf_builds_index.
\set ON_ERROR_STOP on
-- do_rep_indexes_exist() calls its helpers unqualified, as main() does
SET search_path TO reptracker_app, public;

DO $$
BEGIN
  ASSERT reptracker_backend.get_reptracker_op_type_ids() IS NULL,
    'hafd.operation_types must not hold the reptracker operation types yet';
  ASSERT NOT EXISTS ( SELECT 1 FROM pg_indexes WHERE indexname LIKE 'hive_operations_op_types_%' ),
    'the install built a partial index on hafd.operations';
  ASSERT NOT EXISTS ( SELECT 1 FROM hafd.indexes_constraints
                      WHERE table_name = 'hafd.operations' AND index_constraint_name LIKE 'hive_operations_op_types_%' ),
    'the install registered a partial index on hafd.operations without the operation types';
  ASSERT NOT reptracker_app.do_rep_indexes_exist(),
    'do_rep_indexes_exist() reports the missing partial index as in place';
END
$$;

\echo 'install before hived filled hafd.operation_types: the partial index is not registered'
