# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Reputation Tracker is a HAF (Hive Application Framework) application that calculates reputation scores for Hive blockchain accounts. It processes blockchain data stored in a HAF database and exposes a REST API via PostgREST.

## Architecture

The application is SQL-based, running as stored procedures inside PostgreSQL:

- **db/** - Core SQL implementation
  - `database_schema.sql` - Creates tables: `account_reputations`, `active_votes`, `permlinks`
  - `main_loop.sql` - Application entry point (`main()` procedure) and block processing logic
  - `process_block_range.sql` - Processes vote operations to update reputations
  - `backend.sql` - Backend schema functions
- **endpoints/** - PostgREST API endpoints
  - `get_reputation.sql` - Main API: `/accounts/{name}/reputation`
  - `endpoint_schema.sql` - OpenAPI schema definitions
- **scripts/** - Shell scripts for installation and operation

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
cd tests && ./account_dump_test.sh --host=localhost

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
