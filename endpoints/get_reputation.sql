SET ROLE reptracker_owner;

/** openapi:paths
/reputation/{account-name}:
  get:
    tags:
      - Account-reputation
    summary: Account reputation
    description: |
      Returns calculated reputation with formula found in:
      https://hive.blog/steemit/@digitalnotvir/how-reputation-scores-are-calculated-the-details-explained-with-simple-math

      SQL example
      * `SELECT * FROM reptracker_endpoints.get_account_reputation('blocktrades');`

      * `SELECT * FROM reptracker_endpoints.get_account_reputation('initminer');`

      REST call example
      * `GET https://{reptracker-host}/%1$s/reputation/blocktrades`
      
      * `GET https://{reptracker-host}/%1$s/reputation/initminer`
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
            example: 35
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
    _account_id INT = (SELECT av.id FROM hive.accounts_view av WHERE av.name = "account-name");
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
            LOG(10, ABS(_rep)) AS rep,
            (CASE WHEN _rep < 0 THEN -1 ELSE 1 END) AS is_neg 
    ),
    calculate_rep AS MATERIALIZED
    (
        SELECT GREATEST(lar.rep - 9, 0) * lar.is_neg AS rep
        FROM log_account_rep lar
    )
        SELECT ((cr.rep * 9) + 25)::INT INTO _result
        FROM calculate_rep cr;

    RETURN _result;

END IF;

END
$$;

RESET ROLE;
