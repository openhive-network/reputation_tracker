# Reputation Tracker Architecture

## Overview

Reputation Tracker (reptracker) is a HAF application that calculates and tracks Hive account reputation scores. Reputation on Hive reflects community trust, built through content voting over time.

## How Reputation Works

### The Core Concept

When users vote on content (posts/comments), the vote affects the author's reputation score. Upvotes from reputable accounts increase reputation; downvotes from more reputable accounts can decrease it.

### Reputation Formula

```
reputation_change = rshares >> 6  (equivalent to rshares / 64)
```

Where `rshares` (reward shares) represents vote weight. The 6-bit right shift scales vote impact to prevent reputation inflation.

### Display Transformation

Raw reputation values are large integers. For API responses, they're converted to a human-readable score (typically 25-75 range):

```
score = (log10(abs(raw_rep)) - 9) * 9 + 25
if negative_rep: score = -score
```

See `backend/utilities/reputation_constants.sql` for the constants.

### Key Rules

1. **Voter Reputation Gate**: Only votes from accounts with **non-negative** reputation affect the target
2. **Downvote Restrictions**:
   - Voter must have explicit reputation (not implicit/new account)
   - Voter's reputation must **exceed** target's reputation (can't "punch up")
   - Upvotes are always applied if voter has >= 0 reputation
3. **Vote Changes**: When a vote is modified, the old contribution is undone before applying the new one
4. **Sequential Processing**: Votes must be processed in blockchain order because each vote's effect depends on the voter's reputation at that moment
5. **Implicit vs Explicit**: Accounts start with `is_implicit=TRUE` until they receive their first vote

## Operations Affecting Reputation

Three blockchain operations trigger reputation updates:

| Op Type ID | Operation Name | Effect |
|------------|----------------|--------|
| 72 | `effective_comment_vote_operation` | Vote cast or changed (has rshares) |
| 17 | `delete_comment_operation` | Post deleted, all votes on it are removed |
| 61 | `comment_payout_update_operation` | Post paid out, votes are finalized |

All operations are normalized to `effective_vote_return` type: `(author, voter, permlink, rshares)`

## Directory Structure

```
reptracker/
├── db/                              # Core SQL implementation
│   ├── reptracker_app.sql          # HAF context, tables, control functions
│   ├── process_block_range.sql     # Block processing (7-phase CTE chain)
│   ├── calculate_account_reputations.sql  # Reputation algorithm
│   └── builtin_roles.sql           # Database roles
├── backend/                         # Helper functions
│   ├── operation_parsers/
│   │   └── vote_operations.sql     # JSON parsing for vote operations
│   └── utilities/
│       ├── reputation_constants.sql # Scaling factors
│       ├── operation_types.sql     # Op type ID lookups
│       └── account.sql             # Account name→ID resolution
├── endpoints/                       # PostgREST API
│   ├── get_reputation.sql          # GET /accounts/{name}/reputation
│   ├── get_rep_last_synced_block.sql
│   └── endpoint_schema.sql         # OpenAPI definitions
├── scripts/                         # Shell scripts
│   ├── install_app.sh
│   ├── process_blocks.sh
│   └── uninstall_app.sh
└── tests/                           # Test suites
    ├── tavern/                      # API tests
    ├── regression/                  # Reference data tests
    └── performance/                 # JMeter benchmarks
```

## Key Files

| Purpose | File |
|---------|------|
| Reputation calculation algorithm | `db/calculate_account_reputations.sql` |
| Block processing logic | `db/process_block_range.sql` |
| HAF integration/tables | `db/reptracker_app.sql` |
| Vote operation parsing | `backend/operation_parsers/vote_operations.sql` |
| Main API endpoint | `endpoints/get_reputation.sql` |

## Database Schema

### Three Schemas

- `reptracker_app` - Core tables and processing functions
- `reptracker_endpoints` - PostgREST-exposed API functions
- `reptracker_backend` - Internal helper functions

### Core Tables

```sql
-- Accumulated reputation per account
account_reputations (
  account_id INT PRIMARY KEY,
  reputation BIGINT,
  is_implicit BOOLEAN  -- TRUE if never received a vote
)

-- Current vote state
active_votes (
  author_id INT,
  voter_id INT,
  permlink_serial_id INT,
  rshares BIGINT,
  PRIMARY KEY (author_id, permlink_serial_id, voter_id)
)

-- Permlink dictionary (saves storage)
permlinks (
  permlink_id SERIAL PRIMARY KEY,
  permlink TEXT UNIQUE
)
```

## HAF Integration

### Processing Modes

Reptracker uses HAF's context/fork handling with two stages:

- **MASSIVE_PROCESSING**: Bulk sync with batched commits (10K blocks per batch)
- **LIVE**: Single-block processing with immediate commits

### HAF Functions Used

- `hive.app_context_exists()`, `hive.app_create_context()` - Lifecycle
- `hive.app_next_iteration()` - Block fetching
- `hive.operations_view` - Access to blockchain operations
- `hive.accounts_view` - Account lookups
- `hive.app_register_table()` - Fork tracking registration

### Processing Entry Point

```
scripts/process_blocks.sh
  → reptracker_app.main()
    → hive.app_next_iteration() loop
      → reptracker_process_blocks()
        → reptracker_massive_processing() OR reptracker_single_processing()
          → reptracker_block_range_data()  (actual processing)
```

## HAFBE Integration

HAF Block Explorer (HAFBE) uses reptracker to display account reputation:

1. HAFBE includes reptracker as a git submodule
2. HAFBE installs reptracker schema alongside its own
3. HAFBE API calls `reptracker_endpoints.get_account_reputation()` to fetch reputation
4. Reputation data syncs alongside HAFBE's other data

## Database Roles

Two-role security model:

- **`reptracker_owner`**: Full access, owns all schemas, runs block processing
- **`reptracker_user`**: Read-only access, used by PostgREST for API

## Common Commands

### Installation
```bash
./scripts/install_app.sh --host=localhost --port=5432
./scripts/uninstall_app.sh --host=localhost --port=5432
```

### Block Processing
```bash
./scripts/process_blocks.sh                      # Process all blocks
./scripts/process_blocks.sh --stop-at-block=5000000  # Stop at specific block
```

### Docker Development
```bash
cd docker
curl https://gtg.openhive.network/get/blockchain/block_log.5M -o blockchain/block_log
docker compose up -d
docker compose down -v
```

## Expansion Rules

When modifying architecture:
1. Update this file with new concepts/components
2. Add new detailed docs to appropriate subdirectory
3. Keep this file as the overview, link to details
