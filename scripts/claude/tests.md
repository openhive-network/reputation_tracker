# Reptracker Tests Documentation

## Overview

Reptracker has five test suites validating different aspects:

| Suite | Purpose | Framework | Location |
|-------|---------|-----------|----------|
| **Tavern API** | REST endpoint validation | pytest + Tavern | `tests/tavern/` |
| **Performance** | Load testing & benchmarks | JMeter | `tests/performance/` |
| **Regression** | Compare against hived reference data | SQL + Python | `tests/regression/` |
| **Functional** | Shell script validation | Bash | `tests/functional/` |
| **Early block processing** | Processing while hived replays (keep-monotonic) | SQL | `tests/early_block_processing/` |

## Test Categories

### Tavern API Tests (`tests/tavern/`)

Pattern-based API tests using Tavern framework. Tests compare REST responses against expected JSON patterns.

**Structure:**
```
tests/tavern/
├── pytest.ini              # Test markers (patterntest, negative)
├── common.yaml             # Shared config (server address/port)
├── get_reputation/         # Reputation endpoint tests
│   ├── blocktrades.tavern.yaml   # Test definition
│   ├── blocktrades.pat.json      # Expected response pattern
│   ├── gtg.tavern.yaml
│   ├── gtg.pat.json
│   ├── negative_reputation.*     # wang: negative raw reputation
│   ├── no_reputation_row.*       # steem: existing account, no row -> 25
│   ├── zero_reputation.*         # inbamnn: row with raw reputation 0 -> 25
│   ├── non_existent_account.tavern.yaml
│   └── non_existent_account.pat.json
└── get_rep_last_synced_block/    # Sync status tests
    ├── block_hash.tavern.yaml
    └── block_hash.pat.json
```

**How tests work:**
1. `.tavern.yaml` files define test scenarios (HTTP requests)
2. `.pat.json` files contain expected response patterns
3. Tests use `validate_response:compare_rest_response_with_pattern` for comparison

**Environment variables:**
- `REPTRACKER_ADDRESS` - API server host (default: localhost)
- `REPTRACKER_PORT` - API server port (default: 3000)

### Performance Tests (`tests/performance/`)

JMeter load tests for API benchmarking.

**Files:**
- `test_scenarios.jmx` - JMeter test plan
- `run_performance_tests.sh` - Test runner script

**Configuration options:**
- `--backend-host` - Target host (default: localhost)
- `--backend-port` - Target port (default: 3000)
- `--test-thread-count` - Concurrent threads (default: 8)
- `--test-loop-count` - Iterations per thread (default: 60)
- `--test-result-path` - Output file path
- `--test-report-dir` - HTML report directory

### Regression Tests (`tests/regression/`)

Compares computed reputation values against reference data from hived.

**Files:**
- `run_test.sh` - Main test runner
- `accounts_dump.json.gz` - Reference data (5M blocks)
- `data_insertion_script.py` - Loads reference data into DB
- `install_test_schema.sh` - Creates test schema
- `sql/00_schema.sql` - Test tables and helper functions
- `sql/01_compare.sql` - Comparison function

**How it works:**
1. Creates `reptracker_account_dump` schema
2. Loads reference reputation data from `accounts_dump.json.gz`
3. Calls `compare_accounts()` to find differences
4. Reports any accounts with mismatched reputation

**Requirements:**
- Reptracker must be synced to 5M blocks
- PostgreSQL access as `reptracker_owner`

### Functional Tests (`tests/functional/`)

Validates shell scripts work correctly.

**File:** `test_scripts.sh`

**Tests performed:**
1. `generate_version_sql.sh` - Version generation
2. `install_app.sh` - Schema installation
3. `uninstall_app.sh` - Schema removal

### Early Block Processing Test (`tests/early_block_processing/`)

Simulates in SQL what hived does during a massive sync, on a HAF database that holds no blocks (HAF with `hive.app_context_set_early_block_processing`, haf#379), after a fresh `install_app.sh`:

1. The context is opted in to early block processing at install.
2. `drop-all` policy: a dump of 250 blocks is not delivered before the index restore.
3. `keep-monotonic` policy (`hive.disable_indexes_of_irreversible('keep-monotonic')`, sync state `REINDEX`): reptracker processes the dump in `MASSIVE_PROCESSING`, then catches up with hived and processes 5 more blocks in the LIVE stage; its `process_blocks` transactions scan none of `hafd.transactions`, `hafd.transactions_multisig`, `hafd.account_operations` (all of their indexes are deferred), the reputations of the 3 synthetic votes are right, and the initial sync is **not** finished (no freeze requests, no partial index on `hafd.operations`).
4. HAF restores its indexes: the next LIVE block finishes the initial sync (3 freeze requests, partial index created).

**Files:** `run_test.sh` (installs, then runs the SQL), `early_block_processing.sql`. The database is left modified: use a throwaway one. Requires a superuser (`haf_admin`).

## Running Tests Locally

### Prerequisites

```bash
# Tavern tests
pip install tavern pytest pytest-xdist

# Performance tests
apt install jmeter  # or download from Apache

# Regression tests (Python deps)
pip install psycopg2-binary
```

### Tavern API Tests

```bash
export REPTRACKER_ADDRESS=localhost
export REPTRACKER_PORT=3000

cd tests/tavern

# Run all tests (parallel)
pytest -n 16 .

# Run specific endpoint
pytest get_reputation/ -v

# Run with verbose output
pytest -v --tb=short
```

### Performance Tests

```bash
# Requires running API server
./tests/performance/run_performance_tests.sh --backend-host=localhost

# With custom parameters
./tests/performance/run_performance_tests.sh \
  --backend-host=localhost \
  --backend-port=3000 \
  --test-thread-count=16 \
  --test-loop-count=100
```

### Regression Tests

```bash
# Requires synced database (5M blocks)
cd tests/regression
./run_test.sh --host=localhost --port=5432 --user=reptracker_owner
```

### Functional Tests

```bash
cd tests/functional
./test_scripts.sh --host=localhost
```

### Early Block Processing Test

```bash
# a HAF container without hived and without blocks
docker run -d --name haf-early -e PG_ACCESS='host haf_block_log haf_admin all trust\n' -p 5432:5432 registry.gitlab.syncad.com/hive/haf:<commit> --skip-hived
tests/early_block_processing/run_test.sh --host=localhost
```

## CI Pipeline Jobs

| Job | Stage | Test Suite | Description |
|-----|-------|------------|-------------|
| `pattern-test` | test | Tavern | API endpoint validation |
| `performance-test` | test | Performance | Load testing with JMeter |
| `regression-test` | test | Regression | Compare against hived data |
| `setup-scripts-test` | test | Functional | Validate install/uninstall scripts |
| `early-block-processing-test` | test | Early block processing | Processing while hived replays, on an empty HAF service (`--skip-hived`) |
| `python_api_client_test` | test | Python | Generated API client tests |

### CI Test Environment

Tests run in Docker-in-Docker (DinD) environment:
- HAF database synced to 5M blocks
- PostgREST API server running
- Tests connect to `docker` host inside containers

## Adding New Tests

### New Tavern Endpoint Test

1. Create test directory: `tests/tavern/{endpoint_name}/`
2. Add test file: `{test_name}.tavern.yaml`
3. Add pattern file: `{test_name}.pat.json`

**Example test file:**
```yaml
---
test_name: reptracker PostgREST

marks:
  - patterntest

includes:
  - !include ../common.yaml

stages:
  - name: test
    request:
      url: "{service.proto:s}://{service.server:s}:{service.port}/rpc/get_account_reputation"
      method: POST
      headers:
        content-type: application/json
        accept: application/json
      json:
        account-name: "username"
    response:
      status_code: 200
      verify_response_with:
        function: validate_response:compare_rest_response_with_pattern
```

### New Performance Scenario

Edit `tests/performance/test_scenarios.jmx` in JMeter GUI to add new test threads and samplers.

### New Regression Test Account

Add account to `accounts_dump.json.gz` (regenerate from hived if needed):
```bash
curl -s --data '{"jsonrpc":"2.0", "method":"reputation_api.get_account_reputations", "params": {"account_lower_bound": "", "limit": 10000000}, "id":1}' http://hived-node:8091 > accounts_dump.json
gzip accounts_dump.json
```

## Expansion Rules

When adding tests:
1. Add Tavern tests for new endpoints in `tests/tavern/{endpoint}/`
2. Update `test_scenarios.jmx` for performance-critical endpoints
3. Document test requirements in this file
4. Ensure CI jobs run new tests (check `.gitlab-ci.yml`)
