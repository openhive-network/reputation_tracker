SET ROLE reptracker_owner;

-- Operation type lookup functions for Reputation Tracker
-- These provide semantic names and avoid magic numbers scattered throughout the code
-- Each function returns the operation type ID by looking up the name in hafd.operation_types
--
-- Operation IDs used by reptracker:
--   - 72: effective_comment_vote_operation (vote cast or changed)
--   - 17: delete_comment_operation (post/comment deleted)
--   - 61: comment_payout_update_operation (alternative delete detection)

-- Vote operations
CREATE OR REPLACE FUNCTION reptracker_backend.op_effective_comment_vote()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::effective_comment_vote_operation');
END;
$$;

-- Delete operations (votes should be canceled when content is deleted)
CREATE OR REPLACE FUNCTION reptracker_backend.op_delete_comment()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::delete_comment_operation');
END;
$$;

CREATE OR REPLACE FUNCTION reptracker_backend.op_comment_payout_update()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_payout_update_operation');
END;
$$;

-- All reptracker op type IDs as a sorted array (used by index creation and validation)
CREATE OR REPLACE FUNCTION reptracker_backend.get_reptracker_op_type_ids()
RETURNS SMALLINT[] LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (
    SELECT array_agg(id ORDER BY id)
    FROM hafd.operation_types
    WHERE name IN (
      'hive::protocol::effective_comment_vote_operation',
      'hive::protocol::delete_comment_operation',
      'hive::protocol::comment_payout_update_operation'
    )
  );
END;
$$;

RESET ROLE;
