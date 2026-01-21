# Reptracker Tests Documentation

## Overview

Reptracker has four test suites validating different aspects:

| Suite | Purpose | Framework | Location |
|-------|---------|-----------|----------|
| **Tavern API** | REST endpoint validation | pytest + Tavern | `tests/tavern/` |
| **Performance** | Load testing & benchmarks | JMeter | `tests/performance/` |
| **Regression** | Compare against hived reference data | SQL + Python | `tests/regression/` |
| **Functional** | Shell script validation | Bash | `tests/functional/` |

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

## CI Pipeline Jobs

| Job | Stage | Test Suite | Description |
|-----|-------|------------|-------------|
| `pattern-test` | test | Tavern | API endpoint validation |
| `performance-test` | test | Performance | Load testing with JMeter |
| `regression-test` | test | Regression | Compare against hived data |
| `setup-scripts-test` | test | Functional | Validate install/uninstall scripts |
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
