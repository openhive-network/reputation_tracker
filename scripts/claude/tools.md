# Utility Scripts

These scripts help with common development and debugging tasks. **Use them automatically when the task matches their purpose.**

## Available Tools

### check-reptracker-pipeline.sh

**Location**: `scripts/claude/tools/check-reptracker-pipeline.sh`

**Use when**: User asks to analyze failed CI/CD pipelines, check pipeline status, or debug test failures in Reputation Tracker.

**Usage**:
```bash
# Check latest pipeline for a branch
./scripts/claude/tools/check-reptracker-pipeline.sh develop

# Check specific pipeline by ID
./scripts/claude/tools/check-reptracker-pipeline.sh 141690
```

**What it does**:
- Fetches pipeline status from GitLab API (project ID 331)
- Shows summary of job statuses (success/failed/running)
- Lists key jobs: prepare_haf_image, prepare_haf_data, sync, regression-test, performance-test, pattern-test
- For failed jobs: extracts relevant error lines from logs with job-specific filtering
- Shows running and canceled jobs

**Output sections**:
- Pipeline summary (branch, SHA, status, URL)
- Job status counts
- Key jobs status (OK/FAIL/RUN)
- Failed jobs with extracted error context
- Running jobs with runner info

---

### run_sync_test.sh

**Location**: `scripts/claude/tools/run_sync_test.sh`

**Use when**: User wants to test sync performance, benchmark block processing, or measure optimization impact.

**Usage**:
```bash
# Default: sync to 5M blocks
./scripts/claude/tools/run_sync_test.sh

# Custom target block
./scripts/claude/tools/run_sync_test.sh 1000000

# Custom target and host
./scripts/claude/tools/run_sync_test.sh 5000000 172.17.0.2

# Full: target, host, log file
./scripts/claude/tools/run_sync_test.sh 5000000 172.17.0.2 my_test.log
```

**What it does**:
- Starts `process_blocks.sh` with specified target block
- Monitors progress in real-time
- Automatically stops when target block reached
- Calculates total processing time, blocks processed, average time per 10K blocks

**Output includes**:
- Total processing time in seconds and minutes
- Block ranges processed count
- Average time per block range

---

### job_failure_analysis.md

**Location**: `scripts/claude/tools/job_failure_analysis.md`

**Use when**: Investigating CI/CD failures, understanding cache-manager issues, or debugging NFS/tablespace problems.

**What it contains**:
- Common pipeline failure patterns for reptracker
- Root cause explanations for timeout, missing block_log, permission, and tablespace issues
- Evidence patterns to look for in logs
- Quick diagnosis steps
- NFS performance analysis

**Key topics covered**:
- sync job timeout (cache-manager redundant copy)
- regression-test failures (reputation calculation issues)
- pattern-test failures (API response mismatches)
- PostgreSQL tablespace caching issues
- Missing block_log configuration

---

## When to Use These Tools

| Task | Script to Use |
|------|---------------|
| Analyze failed CI/CD pipeline | `check-reptracker-pipeline.sh` |
| Check pipeline job status | `check-reptracker-pipeline.sh` |
| Debug test failures | `check-reptracker-pipeline.sh` |
| Test sync performance | `run_sync_test.sh` |
| Benchmark optimizations | `run_sync_test.sh` |
| Understand CI failure patterns | `job_failure_analysis.md` |
| Debug cache/NFS issues | `job_failure_analysis.md` |

## Expansion Rules

When adding new utility scripts:
1. Add script to `scripts/claude/tools/`
2. Document it here with: Location, Use when, Usage, What it does
3. Add to the "When to Use" table
4. Include example commands with common use cases

## Note for Other Apps

These scripts are adapted from Balance Tracker (btracker) templates. When setting up documentation for other HAF apps:
1. Copy relevant scripts
2. Update PROJECT_ID in pipeline checker (331 → target project ID)
3. Update key job names to match target project's CI configuration
4. Adjust baseline performance numbers for benchmarks
