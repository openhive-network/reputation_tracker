SET ROLE reptracker_owner;

/** openapi:paths
/last-synced-block:
  get:
    tags:
      - Other
    summary: Get last block number synced by reputation tracker
    description: |
      Get the block number of the last block synced by reputation tracker.

      SQL example
      * `SELECT * FROM reptracker_endpoints.get_rep_last_synced_block();`
      
      REST call example
      * `GET ''https://%1$s/reputation-api/last-synced-block''`
    operationId: reptracker_endpoints.get_rep_last_synced_block
    responses:
      '200':
        description: |
          Last synced block by reputation tracker
          
          * Returns `INT`
        content:
          application/json:
            schema:
              type: integer
            example: 5000000
      '404':
        description: No blocks synced
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS reptracker_endpoints.get_rep_last_synced_block;
CREATE OR REPLACE FUNCTION reptracker_endpoints.get_rep_last_synced_block()
RETURNS INT 
-- openapi-generated-code-end
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN

  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);
  RETURN current_block_num FROM hive.contexts WHERE name = 'reptracker_app';
END
$$;

RESET ROLE;
