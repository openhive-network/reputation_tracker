# Reputation Tracker

A HAF (Hive Application Framework) application that calculates reputation scores for Hive blockchain accounts.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start with Docker](#quick-start-with-docker)
- [Local Installation](#local-installation)
- [Running Tests](#running-tests)

## Overview

Reputation Tracker calculates and maintains reputation scores for all Hive blockchain accounts. Reputation is derived from votes on content (posts and comments).

Key features:
- **Reputation Scores** - Current reputation for any account
- **Vote-based Calculation** - Processes upvotes and downvotes from the blockchain
- **Sequential Processing** - Maintains correct order-dependent reputation calculations
- **Fork Handling** - Properly handles blockchain reorganizations via HAF

### How Reputation Works

Hive reputation is calculated from votes using the formula:

```
reputation_change = rshares >> 6  (equivalent to rshares / 64)
```

Where `rshares` (reward shares) is the vote weight. Key rules:
- Only votes from accounts with non-negative reputation affect the target
- When a vote is changed, the old contribution is undone before applying the new one
- Votes must be processed in blockchain order (each vote's effect depends on voter's current reputation)

## Architecture

Reputation Tracker uses a two-tier architecture:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   REST Client   │────▶│    PostgREST    │────▶│   PostgreSQL    │
│                 │     │   (API Layer)   │     │   (HAF + App)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

- **Database Layer**: PostgreSQL with HAF extensions. All business logic lives in SQL stored procedures.
- **API Layer**: PostgREST exposes SQL functions as REST endpoints with zero application code.

### Directory Structure

| Directory | Purpose |
|-----------|---------|
| `db/` | Core SQL: table definitions, block processing functions |
| `backend/` | SQL backend helpers: operation parsers, utilities |
| `endpoints/` | PostgREST API definitions and type definitions |
| `scripts/` | Shell scripts for installation, processing, CI |
| `docker/` | Docker Compose setup and configuration |
| `tests/` | All test suites (see [Running Tests](#running-tests)) |

### Database Schemas

| Schema | Role | Purpose |
|--------|------|---------|
| `reptracker_app` | `reptracker_owner` | Core tables and processing functions |
| `reptracker_backend` | `reptracker_owner` | Backend helper functions (parsers, utilities) |
| `reptracker_endpoints` | `reptracker_user` | PostgREST-exposed API functions |

## Reputation Processing

### How Reputation is Calculated

Reputation changes are derived from vote weight (rshares) using a dampening formula:

```
reputation_change = rshares >> 6  (equivalent to rshares / 64)
```

The 6-bit right shift prevents high-stake votes from dominating reputation. Raw reputation values are then transformed for display:

```
display_score = (log10(abs(raw_reputation)) - 9) * 9 + 25
if negative: display_score = -display_score
```

This produces scores roughly in the 25-75 range for typical accounts.

### Vote Processing

Votes are processed in blockchain order (critical requirement). Each vote's effect depends on the voter's reputation at that moment. When a vote is changed:
1. The previous vote's impact is undone
2. The new vote's impact is applied

### Operations That Affect Reputation

| Operation | Op Type | Effect |
|-----------|---------|--------|
| `effective_comment_vote` | 72 | Vote cast or changed - applies reputation change based on rshares |
| `delete_comment` | 17 | Post deleted - votes are removed from tracking (reputation preserved) |
| `comment_payout_update` | 61 | Post paid out - votes are finalized and removed from tracking |

### Reputation Gate Rules

| Rule | Description |
|------|-------------|
| Voter reputation gate | Only votes from accounts with non-negative reputation count |
| Downvote restriction | Voter must have explicit reputation AND higher rep than target |
| Upvote freedom | Always applied if voter has >= 0 reputation |
| Implicit accounts | New accounts start with `is_implicit=TRUE` until first counted vote |

### Key Functions

| Function | File | Purpose |
|----------|------|---------|
| `reptracker_block_range_data()` | `db/process_block_range.sql` | Main processing CTE chain |
| `calculate_account_reputations()` | `db/calculate_account_reputations.sql` | Per-vote reputation calculation |
| `process_effective_vote_operation()` | `backend/operation_parsers/vote_operations.sql` | Parse vote JSON |
| `main()` | `db/reptracker_app.sql` | Processing entry point |

## Quick Start with Docker

The fastest way to run Reputation Tracker with a demo dataset (5M blocks):

```bash
# Clone repository
git clone https://gitlab.syncad.com/hive/reputation_tracker.git
cd reputation_tracker

# Download demo blockchain data
curl https://gtg.openhive.network/get/blockchain/block_log.5M -o docker/blockchain/block_log

# Start all services
cd docker
docker compose up -d
```

The API will be available at `http://localhost:3000`.

### Docker Commands

```bash
# Stop services (preserves data)
docker compose stop

# Stop and remove containers
docker compose down

# Stop and remove ALL data (clean slate)
docker compose down -v

# Include Swagger UI (port 8080)
docker compose --profile swagger up -d

# View logs
docker compose logs -f
```

### Custom Configuration

Create a `.env.local` file to override defaults:

```bash
cd docker

cat <<EOF > .env.local
HAF_REGISTRY=hiveio/haf
HAF_VERSION=v1.27.5.0
HAF_COMMAND=--shared-file-size=2G --plugin database_api --replay --stop-at-block=10000000
EOF

docker compose --env-file .env.local up -d
```

See [docker/README.md](docker/README.md) for advanced configuration options.

## Local Installation

For development or connecting to an existing HAF instance.

### Prerequisites

- HAF instance running with PostgreSQL accessible
- Ubuntu 20.04+ (tested)

### Install Dependencies

```bash
sudo apt-get update
sudo apt-get install -y apache2-utils curl postgresql-client wget xz-utils
```

### Install PostgREST

```bash
wget https://github.com/PostgREST/postgrest/releases/download/v12.2.3/postgrest-v12.2.3-linux-static-x64.tar.xz -O postgrest.tar.xz
tar -xJf postgrest.tar.xz
sudo mv postgrest /usr/local/bin/
rm postgrest.tar.xz
```

### Setup Database

```bash
# Clone repository
git clone https://gitlab.syncad.com/hive/reputation_tracker.git
cd reputation_tracker

# Install schema (connects to localhost:5432 by default)
./scripts/install_app.sh

# Or specify custom connection
./scripts/install_app.sh --host=192.168.1.100 --port=5432
```

Use `./scripts/install_app.sh --help` to see all available options.

### Process Blocks

```bash
# Process all available blocks and wait for new ones (live sync)
./scripts/process_blocks.sh

# Process up to specific block
./scripts/process_blocks.sh --stop-at-block=5000000
```

Use `./scripts/process_blocks.sh --help` to see all available options.

### Start API Server

```bash
PGRST_DB_URI="postgres://reptracker_user@localhost/haf_block_log" \
PGRST_DB_SCHEMA="reptracker_endpoints" \
PGRST_DB_ANON_ROLE="reptracker_user" \
PGRST_DB_EXTRA_SEARCH_PATH="reptracker_app" \
postgrest
```

The API is now available at `http://localhost:3000`.

### Uninstall

```bash
./scripts/uninstall_app.sh
```

Use `./scripts/uninstall_app.sh --help` to see available options.

## Running Tests

Reputation Tracker includes multiple test suites:

| Test Suite | Purpose | Requirements |
|------------|---------|--------------|
| **Tavern API** | REST endpoint validation | Running API server |
| **Performance** | Load testing | Running API server |
| **Regression** | Compare against reference data | Database access |
| **Functional** | Shell script validation | None |

### Tavern API Tests

Pattern-based API tests using the Tavern framework.

```bash
# Install dependencies
pip install tavern pytest

# Set target server
export REPTRACKER_ADDRESS=localhost
export REPTRACKER_PORT=3000

# Run tests
cd tests/tavern
pytest -n 16 .

# Run specific endpoint test
pytest get_reputation/ -v
```

### Performance Tests

Load tests for the PostgREST API.

```bash
# Run tests (API must be running)
./tests/performance/run_performance_tests.sh --backend-host=localhost
```

### Regression Tests

Compare computed reputation against expected reference data.

```bash
cd tests/regression
./run_test.sh --host=localhost --port=5432
```

### Functional Tests

Validate shell scripts and utilities.

```bash
cd tests/functional
./test_scripts.sh --host=localhost
```

### Running All Tests in CI

The GitLab CI pipeline runs all test suites automatically. Key jobs:

- `pattern-test` - Tavern tests against synced mainnet data
- `performance-test` - Load tests
- `regression-test` - Reputation comparison tests

## API / Functions

### Overview

Reptracker exposes reputation data in two ways:
- **Standalone API**: Direct REST endpoints at `/reputation-api/`
- **HAFBE Integration**: SQL functions called by HAF Block Explorer's unified account endpoint

### Available Endpoints

| Endpoint | Method | Function | Returns |
|----------|--------|----------|---------|
| `/accounts/{account-name}/reputation` | GET | `get_account_reputation(TEXT)` | Reputation score (INT) |
| `/last-synced-block` | GET | `get_rep_last_synced_block()` | Last processed block (INT) |
| `/version` | GET | `get_reptracker_version()` | Git commit hash (TEXT) |

### Available Functions

| Function | Schema | Parameters | Returns | Description |
|----------|--------|------------|---------|-------------|
| `get_account_reputation` | `reptracker_endpoints` | account_name TEXT | INT | Calculate and return reputation score |
| `get_rep_last_synced_block` | `reptracker_endpoints` | (none) | INT | Get last processed block number |
| `get_reptracker_version` | `reptracker_endpoints` | (none) | TEXT | Get application version |

### Usage Examples

#### REST API Calls

```bash
# Get account reputation (standalone)
curl http://localhost:3000/reputation-api/accounts/blocktrades/reputation

# Get sync status
curl http://localhost:3000/reputation-api/last-synced-block

# Get version
curl http://localhost:3000/reputation-api/version

# Get OpenAPI spec
curl http://localhost:3000/reputation-api/
```

#### SQL Function Calls

```sql
-- Get reputation for an account
SELECT * FROM reptracker_endpoints.get_account_reputation('blocktrades');
-- Returns: 69

-- Get last synced block
SELECT * FROM reptracker_endpoints.get_rep_last_synced_block();
-- Returns: 5000000

-- Get version
SELECT * FROM reptracker_endpoints.get_reptracker_version();
-- Returns: 'c2fed8958584511ef1a66dab3dbac8c40f3518f0'
```

### Reputation Score Interpretation

| Score Range | Meaning |
|-------------|---------|
| 0 | New account or never received votes |
| 25 | Starting reputation (after first vote) |
| 25-40 | New/growing account |
| 40-60 | Established account |
| 60-75+ | Highly reputable account |
| Negative | Account has been heavily downvoted |

### HAFBE Integration

When running as part of HAF Block Explorer, reputation is included in account queries:

```bash
# Via HAFBE unified endpoint
curl http://localhost:3000/hafbe-api/accounts/blocktrades
# Returns full account object including reputation field
```

## Integration with HAF Block Explorer

Reputation Tracker is a submodule of [HAF Block Explorer (HAFBE)](https://gitlab.syncad.com/hive/haf_block_explorer). HAFBE provides comprehensive blockchain data access, including account reputation via reptracker.

### How HAFBE Uses reptracker

1. HAFBE includes reptracker as a git submodule
2. During installation, HAFBE installs the reptracker schema alongside its own
3. HAFBE API calls `reptracker_endpoints.get_account_reputation()` to fetch reputation
4. Reputation syncs automatically alongside HAFBE's other data

### Standalone vs HAFBE Usage

| Mode | Use Case |
|------|----------|
| **Standalone** | Direct reputation queries, dedicated reputation service |
| **With HAFBE** | Full block explorer with reputation integrated into account data |

When running standalone, reptracker provides a focused API for reputation queries. When integrated with HAFBE, reputation data is available through HAFBE's unified account endpoints.

## Contributing

See the project's GitLab page for contribution guidelines and issue tracking.

## License

See [LICENSE](LICENSE) file.
