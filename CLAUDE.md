# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Reputation Tracker is a HAF (Hive Application Framework) application that calculates reputation scores for Hive blockchain accounts. It processes blockchain data stored in a HAF database and exposes a REST API via PostgREST.

## Architecture

The application is SQL-based, running as stored procedures inside PostgreSQL:

- **db/** - Core SQL implementation
  - `reptracker_app.sql` - HAF context, tables, control functions, and processing procedures
  - `process_block_range.sql` - Core block processing logic for vote operations
  - `builtin_roles.sql` - Database role definitions
- **backend/** - Helper functions
  - `operation_parsers/vote_operations.sql` - Vote operation parsing and reputation calculation
  - `utilities/` - Account lookup, validators, exceptions
- **endpoints/** - PostgREST API endpoints
  - `get_reputation.sql` - Main API: `/accounts/{name}/reputation`
  - `get_rep_last_synced_block.sql` - Sync status endpoint
  - `get_rep_version.sql` - Version endpoint
  - `endpoint_schema.sql` - OpenAPI schema definitions
- **scripts/** - Shell scripts for installation and operation
- **tests/** - Test suites
  - `regression/` - Regression tests comparing against reference data
  - `functional/` - Functional tests
  - `tavern/` - API contract tests
  - `performance/` - Performance benchmarks

The app uses HAF's context/fork handling system with two processing modes:
- `MASSIVE_PROCESSING` - Bulk sync with batched commits
- `LIVE` - Single block processing with immediate commits

## Common Commands

### Installation
```bash
# Install app on HAF database
./scripts/install_app.sh --host=localhost --port=5432

# Uninstall app
./scripts/uninstall_app.sh --host=localhost --port=5432
```

### Block Processing
```bash
# Process all blocks (runs until stopped)
./scripts/process_blocks.sh

# Process up to specific block
./scripts/process_blocks.sh --stop-at-block=5000000
```

### Docker Development
```bash
cd docker

# Quick start with 5M blocks
curl https://gtg.openhive.network/get/blockchain/block_log.5M -o blockchain/block_log
docker compose up -d

# With override files
docker compose --file docker-compose.yml --file docker-compose.dev.yml up -d

# Stop
docker compose down -v
```

### Testing
```bash
# Regression test (compares against reference data)
cd tests/regression && ./run_test.sh --host=localhost

# Functional tests
cd tests/functional && ./test_scripts.sh --host=localhost

# Tavern API tests
cd tests/tavern && pytest -n 16 .

# Performance tests
./tests/performance/run_performance_tests.sh --backend-host=localhost
```

### Linting
```bash
# SQL linting
sqlfluff lint

# Shell script linting
shellcheck scripts/*.sh
```

## Database Schemas

- `reptracker_app` - Main application data (configurable via REPTRACKER_SCHEMA)
- `reptracker_endpoints` - PostgREST-exposed API functions
- `reptracker_backend` - Internal backend functions
- `reptracker_account_dump` - Test utilities for comparing reputation data

## Key Environment Variables

- `POSTGRES_HOST` / `POSTGRES_PORT` - Database connection
- `POSTGRES_USER` - Database user (default: `reptracker_owner`)
- `REPTRACKER_SCHEMA` - Application schema name (default: `reptracker_app`)
- `IS_FORKING` - Enable fork handling (default: `true`)

## CI Pipeline

The GitLab CI includes:
- `lint` - shellcheck for bash, sqlfluff for SQL
- `build` - Docker images, HAF data preparation, API client generation
- `sync` - Process 5M blocks and cache for tests
- `test` - Regression, functional, performance, and pattern (Tavern) tests
- `publish` - Docker images, npm packages, Python wheels

HAF submodule commit must match both `HAF_COMMIT` variable and `include: ref:` in `.gitlab-ci.yml`.

## HAF Submodule

The `haf/` directory is a git submodule pointing to the HAF framework. It provides:
- Database infrastructure and context management
- Block/operation views and helpers
- CI templates and cache management scripts

## Reputation Calculation

### How Reputation Works

Hive reputation is calculated from votes on content (posts/comments). The core formula:

```
reputation_change = rshares >> 6  (equivalent to rshares / 64)
```

Where `rshares` (reward shares) is the vote weight. The bit shift scales vote impact to prevent reputation inflation.

### Key Rules

1. **Voter reputation gate**: Only votes from accounts with non-negative reputation affect the target
2. **Vote changes**: When a vote is changed, the old contribution is undone before applying the new one
3. **Sequential processing**: Votes must be processed in blockchain order because each vote's effect depends on the voter's current reputation at that moment
4. **Implicit vs explicit**: Accounts start with implicit reputation (is_implicit=TRUE) until they receive their first vote

### Vote-Impacting Operations

Three operation types affect reputation:

| Op Type ID | Operation | Effect |
|------------|-----------|--------|
| 72 | `effective_comment_vote` | Vote cast or changed (has rshares) |
| 17 | `delete_comment` | Post deleted, all votes on it are removed |
| 61 | `comment_payout_update` | Post paid out, votes are finalized |

## Block Processing Flow

The main processing function `reptracker_block_range_data()` in `db/process_block_range.sql` executes in phases:

### Phase 1: Extract and Parse Operations
1. **operations_in_range** (MATERIALIZED): Filter vote-related operations from block range
2. **vote_operations_raw**: Parse JSON bodies using CROSS JOIN LATERAL with inline CASE dispatch

### Phase 2: Resolve Account Names
- Batch lookup of unique account names to IDs via `accounts_view`
- Uses JOIN pattern instead of correlated subqueries for efficiency

### Phase 3: Manage Permlink Dictionary
- Insert new permlinks to dictionary table (ON CONFLICT DO NOTHING)
- Join permlink IDs back to operations

### Phase 4: Rank and Find Previous Votes
- **ranked_data**: ROW_NUMBER partitions by (author, voter, permlink) to find most recent
- **add_prev_votes**: Self-join to find previous vote within the batch
- **find_prev_votes_in_table**: Fallback lookup in active_votes table for historical votes

### Phase 5: Handle Vote Cancellations
- Detect if delete/payout occurred between previous vote and current
- Reset prev_rshares to 0 if previous vote was already canceled

### Phase 6: Update Tables
- **delete_votes**: Remove votes for deleted/paid posts
- **upsert_votes**: Insert/update votes that should persist
- **materialize_votes**: Populate temp table for sequential processing

### Phase 7: Calculate Reputation
- Process votes sequentially (FOR LOOP) by blockchain order (source_op)
- Call `calculate_account_reputations()` for each vote

## Key Tables

| Table | Purpose |
|-------|---------|
| `account_reputations` | Accumulated reputation per account |
| `active_votes` | Current vote state (author, voter, permlink, rshares) |
| `permlinks` | Dictionary mapping permlink text to integer IDs |

## Performance Optimizations

- **MATERIALIZED CTEs**: Force materialization of expensive subqueries to prevent repeated execution
- **Batch JOINs**: Use JOIN instead of correlated subqueries for O(n) vs O(n²) lookups
- **LEFT ANTI-JOIN pattern**: `LEFT JOIN ... WHERE x IS NULL` instead of `NOT EXISTS` for batch filtering
- **Cached operation type IDs**: Store in DECLARE variables to avoid repeated function calls
- **Inline CASE dispatch**: Faster than wrapper function for JSON parsing

## Coding Conventions

- All functions use `SET ROLE reptracker_owner` / `RESET ROLE` wrapper
- JSDoc-style comments for function documentation
- Phase markers in CTE chains for readability
- STABLE/IMMUTABLE volatility hints where appropriate
