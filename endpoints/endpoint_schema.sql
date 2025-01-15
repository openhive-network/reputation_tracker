SET ROLE reptracker_owner;

/** openapi
openapi: 3.1.0
info:
  title: Reputation tracker
  description: >-
    Reputation tracker is an API calculating current
    account reputation that is result of voting.
  license:
    name: MIT License
    url: https://opensource.org/license/mit
  version: 1.27.8
externalDocs:
  description: Reputation tracker gitlab repository
  url: https://gitlab.syncad.com/hive/reputation_tracker
tags:
  - name: Accounts
    description: Informations about account reputation
  - name: Other
    description: General API information
servers:
  - url: /reputation-api
 */

DO $__$
DECLARE 
  __schema_name VARCHAR;
  __swagger_url TEXT;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;
  __swagger_url := current_setting('custom.swagger_url')::TEXT;

CREATE SCHEMA IF NOT EXISTS reptracker_endpoints AUTHORIZATION reptracker_owner;

EXECUTE FORMAT(
'create or replace function reptracker_endpoints.root() returns json as $_$
declare
-- openapi-spec
-- openapi-generated-code-begin
  openapi json = $$
{
  "openapi": "3.1.0",
  "info": {
    "title": "Reputation tracker",
    "description": "Reputation tracker is an API calculating current account reputation that is result of voting.",
    "license": {
      "name": "MIT License",
      "url": "https://opensource.org/license/mit"
    },
    "version": "1.27.8"
  },
  "externalDocs": {
    "description": "Reputation tracker gitlab repository",
    "url": "https://gitlab.syncad.com/hive/reputation_tracker"
  },
  "tags": [
    {
      "name": "Accounts",
      "description": "Informations about account reputation"
    },
    {
      "name": "Other",
      "description": "General API information"
    }
  ],
  "servers": [
    {
      "url": "/reputation-api"
    }
  ],
  "paths": {
    "/accounts/{account-name}/reputation": {
      "get": {
        "tags": [
          "Accounts"
        ],
        "summary": "Account reputation",
        "description": "Returns calculated reputation with formula found in:\nhttps://hive.blog/steemit/@digitalnotvir/how-reputation-scores-are-calculated-the-details-explained-with-simple-math\n\nSQL example\n* `SELECT * FROM reptracker_endpoints.get_account_reputation(''blocktrades'');`\n\nREST call example\n* `GET ''https://%1$s/reputation-api/accounts/blocktrades/reputation''`\n",
        "operationId": "reptracker_endpoints.get_account_reputation",
        "parameters": [
          {
            "in": "path",
            "name": "account-name",
            "required": true,
            "schema": {
              "type": "string"
            },
            "description": "Name of the account"
          }
        ],
        "responses": {
          "200": {
            "description": "No such account in the database",
            "content": {
              "application/json": {
                "schema": {
                  "type": "integer"
                },
                "example": 69
              }
            }
          }
        }
      }
    },
    "/last-synced-block": {
      "get": {
        "tags": [
          "Other"
        ],
        "summary": "Get last block number synced by reputation tracker",
        "description": "Get the block number of the last block synced by reputation tracker.\n\nSQL example\n* `SELECT * FROM reptracker_endpoints.get_rep_last_synced_block();`\n\nREST call example\n* `GET ''https://%1$s/reputation-api/last-synced-block''`\n",
        "operationId": "reptracker_endpoints.get_rep_last_synced_block",
        "responses": {
          "200": {
            "description": "Last synced block by reputation tracker\n\n* Returns `INT`\n",
            "content": {
              "application/json": {
                "schema": {
                  "type": "integer"
                },
                "example": 5000000
              }
            }
          },
          "404": {
            "description": "No blocks synced"
          }
        }
      }
    }
  }
}
$$;
-- openapi-generated-code-end
begin
  return openapi;
end
$_$ language plpgsql;'
, __swagger_url);

END
$__$;

RESET ROLE;
