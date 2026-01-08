SET ROLE reptracker_owner;

/** openapi:paths
/accounts/{account-name}/reputation:
  get:
    tags:
      - Accounts
    summary: Account reputation
    description: |
      Returns calculated reputation with formula found in:
      https://hive.blog/steemit/@digitalnotvir/how-reputation-scores-are-calculated-the-details-explained-with-simple-math

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
$$
DECLARE
    _rep BIGINT;
    _result INT;
    _account_id INT := reptracker_backend.get_account_id("account-name", TRUE);
    -- Reputation display formula constants
    _log_base   INT := reptracker_backend.reputation_log_base();
    _log_offset INT := reptracker_backend.reputation_log_offset();
    _multiplier INT := reptracker_backend.reputation_multiplier();
    _base_score INT := reptracker_backend.reputation_base_score();
BEGIN
  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);

  SELECT ar.reputation INTO _rep
  FROM account_reputations ar
  WHERE ar.account_id = _account_id;

  IF _rep = 0 OR _rep IS NULL THEN
      RETURN 0;
  ELSE
      WITH log_account_rep AS MATERIALIZED
      (
          SELECT
              LOG(_log_base, ABS(_rep)) AS rep,
              (CASE WHEN _rep < 0 THEN -1 ELSE 1 END) AS is_neg
      ),
      calculate_rep AS MATERIALIZED
      (
          SELECT GREATEST(lar.rep - _log_offset, 0) * lar.is_neg AS rep
          FROM log_account_rep lar
      )
          SELECT ((cr.rep * _multiplier) + _base_score)::INT INTO _result
          FROM calculate_rep cr;

      RETURN _result;

  END IF;

END
$$;

RESET ROLE;
