SET ROLE reptracker_owner;

/**
 * Account Lookup Utility
 *
 * Provides account name-to-ID resolution with validation.
 * Used by API endpoints to convert user-provided account names to internal IDs.
 *
 * Dependencies:
 *   - hive.accounts_view: HAF view containing all Hive accounts
 *   - reptracker_backend.validate_account: Validation function
 */

/**
 * Resolves a Hive account name to its internal account ID.
 *
 * @param _account_name  The Hive account name to look up (e.g., 'gtg', 'blocktrades')
 * @param _required      If TRUE, raises an exception when account doesn't exist.
 *                       If FALSE, returns NULL for non-existent accounts (unless name was provided).
 *
 * @returns The account's integer ID from hive.accounts_view, or NULL if not found and not required.
 *
 * @raises EXCEPTION 'Account ''%'' does not exist' when _required=TRUE and account not found.
 *
 * @example
 *   -- Required account (raises if not found)
 *   SELECT reptracker_backend.get_account_id('gtg', TRUE);
 *
 *   -- Optional account (returns NULL if not found)
 *   SELECT reptracker_backend.get_account_id('nonexistent', FALSE);
 */
CREATE OR REPLACE FUNCTION reptracker_backend.get_account_id(_account_name TEXT, _required BOOLEAN)
RETURNS INT STABLE
LANGUAGE 'plpgsql'
AS
$$
DECLARE
  -- Look up account ID from HAF's accounts view
  _account_id INT := (SELECT av.id FROM hive.accounts_view av WHERE av.name = _account_name);
BEGIN
  -- Validate based on required flag (may raise exception)
  PERFORM reptracker_backend.validate_account(_account_id, _account_name, _required);

  RETURN _account_id;
END
$$;

RESET ROLE;
