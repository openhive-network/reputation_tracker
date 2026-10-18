SET ROLE reptracker_owner;

DO $$
DECLARE
  __schema_name VARCHAR;
BEGIN
SHOW SEARCH_PATH INTO __schema_name;
EXECUTE format(
$BODY$

/** openapi:paths
/accounts/{account-name}/reputation:
  get:
    tags:
      - Accounts
    summary: Account reputation
    description: |
      Returns calculated reputation with formula found in:
      https://hive.blog/steemit/@digitalnotvir/how-reputation-scores-are-calculated-the-details-explained-with-simple-math

      An existing account that has no reputation yet (never received a counted
      vote) or whose raw reputation is 0 gets the base score 25, as in hivemind
      and the wallets.

      SQL example
      * `SELECT * FROM reptracker_endpoints.get_account_reputation(''blocktrades'');`

      REST call example
      * `GET ''https://%1$s/reputation-api/accounts/blocktrades/reputation''`
    operationId: reptracker_endpoints.get_account_reputation
    parameters:
      - in: path
        name: account-name
        required: true
        schema:
          type: string
        description: Name of the account
    responses:
      '200':
        description: |
          Account reputation

          * Returns `INT`
        content:
          application/json:
            schema:
              type: integer
            example: 69
      '404':
        description: No such account in the database
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS reptracker_endpoints.get_account_reputation;
CREATE OR REPLACE FUNCTION reptracker_endpoints.get_account_reputation(
    "account-name" TEXT
)
RETURNS INT 
-- openapi-generated-code-end
LANGUAGE 'plpgsql' STABLE
AS
$pb$
DECLARE
    _rep BIGINT;
    _adjusted NUMERIC;
BEGIN
  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);

  -- Single query: resolve account name and fetch reputation in one step
  SELECT ar.reputation INTO _rep
  FROM hive.accounts_view av
  LEFT JOIN %1$I.account_reputations ar ON ar.account_id = av.id
  WHERE av.name = "account-name";

  -- Account not found in HAF
  IF NOT FOUND THEN
    PERFORM reptracker_backend.rest_raise_missing_account("account-name");
  END IF;

  -- No reputation data or zero reputation: base score, matching hivemind's rep_log10()
  IF _rep IS NULL OR _rep = 0 THEN
    RETURN 25;
  END IF;

  -- Display formula: score = (log10(abs(rep)) - 9) * 9 + 25
  -- Constants from reptracker_backend.reputation_constants: base=10, offset=9, multiplier=9, base_score=25
  _adjusted := GREATEST(LOG(10, ABS(_rep)) - 9, 0);
  IF _rep < 0 THEN
    _adjusted := -_adjusted;
  END IF;

  RETURN (_adjusted * 9 + 25)::INT;
END
$pb$;

$BODY$,
__schema_name);
END
$$;

RESET ROLE;
