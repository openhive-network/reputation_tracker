# Reputation Tracker Endpoints

## Overview

Reptracker exposes reputation data in two ways:

1. **Direct PostgREST API** - Standalone REST endpoints served at `/reputation-api/`
2. **HAFBE Integration** - SQL functions called by HAFBE's unified account endpoint

Both access the same underlying `reptracker_endpoints` schema functions.

## API Endpoints

### Base URL

When running standalone: `http://localhost:3000/reputation-api`

### GET /accounts/{account-name}/reputation

Get the calculated reputation score for an account.

**Function**: `reptracker_endpoints.get_account_reputation(account-name TEXT)`

**Parameters**:
| Name | Type | Required | Description |
|------|------|----------|-------------|
| account-name | TEXT | Yes | Account name (e.g., "blocktrades") |

**Returns**: `INT` - Reputation score (typically 25-75 range)

**Response Headers**: `Cache-Control: public, max-age=2`

**Examples**:
```bash
# REST API
curl http://localhost:3000/reputation-api/accounts/blocktrades/reputation

# SQL
SELECT * FROM reptracker_endpoints.get_account_reputation('blocktrades');
```

**Return Values**:
- Positive integer: Calculated reputation score
- `0`: Account has no reputation (new or never voted on)
- `NULL`: Account doesn't exist

**Reputation Formula**:
```
score = (log10(abs(raw_rep)) - 9) * 9 + 25
if negative: score = -score
```

---

### GET /last-synced-block

Get the last block number processed by reputation tracker.

**Function**: `reptracker_endpoints.get_rep_last_synced_block()`

**Parameters**: None

**Returns**: `INT` - Block number

**Response Headers**: `Cache-Control: public, max-age=0`

**Examples**:
```bash
# REST API
curl http://localhost:3000/reputation-api/last-synced-block

# SQL
SELECT * FROM reptracker_endpoints.get_rep_last_synced_block();
```

---

### GET /version

Get the reputation tracker version (git commit hash).

**Function**: `reptracker_endpoints.get_reptracker_version()`

**Parameters**: None

**Returns**: `TEXT` - Git commit hash

**Response Headers**: `Cache-Control: public, max-age=100000`

**Examples**:
```bash
# REST API
curl http://localhost:3000/reputation-api/version

# SQL
SELECT * FROM reptracker_endpoints.get_reptracker_version();
```

---

### GET / (Root - OpenAPI Spec)

Returns the OpenAPI 3.1.0 specification for the API.

**Function**: `reptracker_endpoints.root()`

**Returns**: `JSON` - Full OpenAPI spec

```bash
curl http://localhost:3000/reputation-api/
```

## HAFBE Integration

When running as a submodule of HAF Block Explorer (HAFBE), reputation data is integrated into HAFBE's unified account endpoint.

### How It Works

HAFBE's `get_account` endpoint calls reptracker directly:

```sql
-- From hafbe/endpoints/accounts/get_account.sql
SELECT ...
FROM
  btracker_endpoints.get_account_balances("account-name")      _result_balance,
  reptracker_endpoints.get_account_reputation("account-name")  _result_reputation,
  hafbe_backend.get_json_metadata(_account_id)                 _result_json_metadata,
  ...
```

### HAFBE Endpoint

When using HAFBE, access reputation through:

```bash
# Full account data including reputation
curl http://localhost:3000/hafbe-api/accounts/blocktrades

# Response includes:
# {
#   "reputation": 69,
#   "balance": { ... },
#   ...
# }
```

### Standalone vs HAFBE Comparison

| Feature | Standalone | HAFBE |
|---------|------------|-------|
| API Path | `/reputation-api/accounts/{name}/reputation` | `/hafbe-api/accounts/{name}` |
| Returns | Single integer score | Full account object with reputation field |
| Use Case | Dedicated reputation service | Full block explorer |
| Data Sources | reptracker only | reptracker + btracker + hafbe |

## Implementation Details

### Source Files

| File | Purpose |
|------|---------|
| `endpoints/get_reputation.sql` | Main reputation endpoint |
| `endpoints/get_rep_last_synced_block.sql` | Sync status endpoint |
| `endpoints/get_rep_version.sql` | Version endpoint |
| `endpoints/endpoint_schema.sql` | OpenAPI spec and schema creation |

### Display Formula Constants

Located in `backend/utilities/reputation_constants.sql`:

| Constant | Value | Function |
|----------|-------|----------|
| Log base | 10 | `reputation_log_base()` |
| Log offset | 9 | `reputation_log_offset()` |
| Multiplier | 9 | `reputation_multiplier()` |
| Base score | 25 | `reputation_base_score()` |

### Database Roles

| Role | Access |
|------|--------|
| `reptracker_user` | PostgREST uses this role - read-only access to endpoint functions |
| `reptracker_owner` | Owns all schemas - used for processing |

## Adding New Endpoints

To add a new endpoint:

1. Create SQL file in `endpoints/` with OpenAPI comment block
2. Use `reptracker_endpoints` schema for the function
3. Run `scripts/generate_openapi.sh` to regenerate `endpoint_schema.sql`
4. Grant execute permission to `reptracker_user`

Example template:
```sql
SET ROLE reptracker_owner;

/** openapi:paths
/new-endpoint:
  get:
    tags:
      - Accounts
    summary: Description
    operationId: reptracker_endpoints.new_function
    responses:
      '200':
        description: Success
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS reptracker_endpoints.new_function;
CREATE OR REPLACE FUNCTION reptracker_endpoints.new_function()
RETURNS TEXT
-- openapi-generated-code-end
LANGUAGE 'plpgsql' STABLE
AS $$
BEGIN
  -- Implementation
END
$$;

RESET ROLE;
```

## Expansion Rules

When modifying endpoints:
1. Update this file with new endpoint documentation
2. Update the function inventory table
3. If changing HAFBE integration, update `scripts/claude/main.md`
4. Keep OpenAPI comments in sync with actual function signatures
