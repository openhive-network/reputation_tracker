SET ROLE reptracker_owner;

-- Create a partial index on hafd.operations covering only the 3 operation types
-- used by reputation_tracker. This makes the index ~97% smaller than a full index
-- and dramatically speeds up block processing queries.
--
-- Requires HAF with hive.create_op_type_partial_index() (feature/op-type-id-column).
-- On older HAF versions, this gracefully does nothing.

DO $$
DECLARE
    _op_ids SMALLINT[];
BEGIN
    -- Check if the HAF function exists (graceful fallback for older HAF)
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'hive' AND p.proname = 'create_op_type_partial_index'
    ) THEN
        RAISE NOTICE 'hive.create_op_type_partial_index() not available — skipping partial index creation (older HAF?)';
        RETURN;
    END IF;

    -- Get op type IDs from the shared lookup function
    _op_ids := reptracker_backend.get_reptracker_op_type_ids();

    IF _op_ids IS NULL OR array_length(_op_ids, 1) != 3 THEN
        RAISE WARNING 'Expected 3 operation types, found: %. Index not created.', _op_ids;
        RETURN;
    END IF;

    RAISE NOTICE 'Creating partial index for reptracker op types: %', _op_ids;
    PERFORM hive.create_op_type_partial_index(_op_ids);
END
$$;

RESET ROLE;
