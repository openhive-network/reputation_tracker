SET ROLE reptracker_owner;

/**
 * Exception Handlers
 *
 * Provides standardized error messages for REST API responses.
 * PostgREST converts PostgreSQL RAISE EXCEPTION into HTTP error responses.
 *
 * Error Format:
 *   PostgREST returns exceptions as JSON: {"message": "Account 'foo' does not exist"}
 *   HTTP status code is typically 400 (Bad Request) for user errors.
 */

/**
 * Raises a standardized exception for missing accounts.
 *
 * Called by validate_account() when an account cannot be found in the database.
 * The exception message is formatted for end-user display via the REST API.
 *
 * @param _account_name  The account name that was not found
 *
 * @raises EXCEPTION with message "Account '<name>' does not exist"
 *
 * @note IMMUTABLE because the function has no side effects and always raises.
 *       This allows the query planner to optimize calls away in dead code paths.
 */
CREATE OR REPLACE FUNCTION reptracker_backend.rest_raise_missing_account(_account_name TEXT)
RETURNS VOID
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  RAISE EXCEPTION 'Account ''%'' does not exist', _account_name;
END
$$;

RESET ROLE;
