SET ROLE reptracker_owner;

/**
 * Vote Operation Parsers
 *
 * This file contains JSON parsing functions for vote-related blockchain operations.
 * These parsers extract structured data from JSONB operation bodies stored in HAF.
 *
 * Operations Processed:
 *   - effective_comment_vote (op_type 72): Vote cast or changed on a post/comment
 *   - delete_comment (op_type 17): Post deleted, all votes should be canceled
 *   - comment_payout_update (op_type 61): Post paid out, votes are finalized
 *
 * Architecture:
 *   The parsers return a common effective_vote_return type that normalizes
 *   all vote-impacting operations into a consistent format:
 *     (author, voter, permlink, rshares)
 *
 *   This allows the main processing CTE chain in process_block_range.sql to
 *   handle different operation types uniformly after parsing.
 *
 * Performance Note:
 *   These functions are called via CROSS JOIN LATERAL in process_block_range.sql.
 *   An inline CASE expression dispatches to the appropriate parser based on
 *   op_type_id. This is faster than a wrapper function due to reduced call overhead.
 *
 * Dependencies:
 *   - Called by: reptracker_block_range_data() in db/process_block_range.sql
 */

/**
 * Return type for vote operation parsing.
 *
 * All vote-impacting operations are normalized to this structure:
 *   - author: The account who created the content being voted on
 *   - voter: The account casting the vote (NULL for delete operations)
 *   - permlink: The content identifier (unique per author)
 *   - rshares: Vote weight in "reward shares" (NULL for delete operations)
 *
 * @note rshares can be negative for downvotes
 * @note (author, voter, permlink) uniquely identifies a vote
 */
DROP TYPE IF EXISTS reptracker_backend.effective_vote_return CASCADE;
CREATE TYPE reptracker_backend.effective_vote_return AS
(
    author TEXT,
    voter TEXT,
    permlink TEXT,
    rshares BIGINT
);

/**
 * Parses an effective_comment_vote_operation JSON body.
 *
 * This operation is emitted when a vote is cast or changed on a post/comment.
 * It contains the current vote weight (rshares) after the vote was applied.
 *
 * JSON Structure (body_value contains the inner value directly):
 *   {
 *     "author": "bob",
 *     "voter": "alice",
 *     "permlink": "my-first-post",
 *     "rshares": 1234567890,
 *     ...
 *   }
 *
 * @param _operation_body  The JSONB body_value from operations_view
 *
 * @returns effective_vote_return with (author, voter, permlink, rshares)
 *
 * @note rshares is always extracted as BIGINT. The ->> operator returns text
 *       regardless of the underlying JSON type, then we cast to BIGINT.
 *
 * @note STABLE because the function only reads its input and performs no DB writes
 */
CREATE OR REPLACE FUNCTION reptracker_backend.process_effective_vote_operation(IN _operation_body JSONB)
RETURNS reptracker_backend.effective_vote_return
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    ((_operation_body)->>'author')::TEXT,
    ((_operation_body)->>'voter')::TEXT,
    ((_operation_body)->>'permlink')::TEXT,
    -- The ->> operator extracts as TEXT regardless of JSON type, then we cast to BIGINT.
    -- This handles both numeric and string representations of rshares uniformly.
    (_operation_body ->> 'rshares')::BIGINT
  )::reptracker_backend.effective_vote_return;
END
$$;

/**
 * Parses delete_comment_operation and comment_payout_update_operation JSON bodies.
 *
 * Both operations signal that votes on a post should be finalized/removed:
 *   - delete_comment (op_type 17): Post was explicitly deleted by author
 *   - comment_payout_update (op_type 61): Post received payout, votes are finalized
 *
 * When these operations occur, all active votes on the post are removed from
 * the active_votes table and their reputation contributions are preserved
 * (not reversed). This prevents re-processing the same votes.
 *
 * JSON Structure (body_value contains the inner value directly):
 *   {
 *     "author": "bob",
 *     "permlink": "my-first-post"
 *   }
 *
 * @param _operation_body  The JSONB body_value from operations_view
 *
 * @returns effective_vote_return with (author, NULL, permlink, NULL)
 *          voter and rshares are NULL since delete/payout affects all votes
 *
 * @note The NULL voter indicates this is not a single vote but affects all votes
 *       on the specified (author, permlink) combination
 *
 * @note STABLE because the function only reads its input and performs no DB writes
 */
CREATE OR REPLACE FUNCTION reptracker_backend.process_deleted_comment_operation(IN _operation_body JSONB)
RETURNS reptracker_backend.effective_vote_return
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    ((_operation_body)->>'author')::TEXT,
    NULL,  -- voter: NULL because delete/payout affects ALL voters on this post
    ((_operation_body)->>'permlink')::TEXT,
    NULL   -- rshares: NULL because this is a delete signal, not a vote
  )::reptracker_backend.effective_vote_return;
END
$$;

RESET ROLE;
