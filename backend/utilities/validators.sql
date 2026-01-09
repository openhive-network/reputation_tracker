SET ROLE reptracker_owner;

/**
 * Input Validators
 *
 * Provides validation logic for API input parameters.
 * These functions enforce business rules and provide user-friendly error messages.
 *
 * Dependencies:
 *   - reptracker_backend.rest_raise_missing_account: Exception handler
 */

/**
 * Validates an account lookup result based on requirement rules.
 *
 * This function implements the validation logic for account lookups:
 *   - If _required=TRUE and account not found → raise exception
 *   - If _required=FALSE but name was provided and not found → raise exception
 *   - If _required=FALSE and no name provided → allow NULL (optional parameter)
 *
 * The second case handles the scenario where an API caller explicitly provides
 * an account name (indicating intent), but the account doesn't exist.
 *
 * @param _account_id    The resolved account ID (NULL if account not found)
 * @param _account_name  The original account name that was looked up
 * @param _required      Whether the account is required (TRUE) or optional (FALSE)
 *
 * @raises EXCEPTION via rest_raise_missing_account() if validation fails
 *
 * @example
 *   -- Required account: raises if NULL
 *   PERFORM reptracker_backend.validate_account(NULL, 'badname', TRUE);
 *   -- ERROR: Account 'badname' does not exist
 *
 *   -- Optional but provided: raises if NULL
 *   PERFORM reptracker_backend.validate_account(NULL, 'badname', FALSE);
 *   -- ERROR: Account 'badname' does not exist
 *
 *   -- Optional and not provided: allows NULL
 *   PERFORM reptracker_backend.validate_account(NULL, NULL, FALSE);
 *   -- OK (no error)
 *
 * @note IMMUTABLE because the function's output depends only on its inputs
 *       and it has no side effects (the exception is deterministic).
 */
CREATE OR REPLACE FUNCTION reptracker_backend.validate_account(_account_id INT, _account_name TEXT, _required BOOLEAN)
RETURNS VOID
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  -- Raise exception if:
  -- 1. Account is required but not found, OR
  -- 2. Account name was provided (indicating intent) but not found
  IF (_required AND _account_id IS NULL) OR (NOT _required AND _account_name IS NOT NULL AND _account_id IS NULL) THEN
    PERFORM reptracker_backend.rest_raise_missing_account(_account_name);
  END IF;
END
$$;

RESET ROLE;
