# Pipeline Job Failure Analysis - Reputation Tracker

This document contains analysis of common pipeline failure patterns for Reputation Tracker and related HAF applications.

---

## Common Failure Patterns

### 1. sync Job Timeout

**Symptoms**: sync job exceeds time limit (usually 2 hours)

**Root Causes**:
- **Redundant local cache copy**: cache-manager.sh doing `cp -a` to local cache BEFORE NFS push
- **Slow NFS file operations**: Many files cause metadata overhead
- **Large sync data**: Reputation data grows with blockchain size

**Evidence to look for**:
```
[cache-manager] Caching locally: /cache/haf_sync_...
Warning: Failed to push to NFS cache
ERROR: Job failed: execution took longer than Xh0m0s seconds
```

**Fix**: cache-manager.sh should skip local copy when NFS available, use tar archives

---

### 2. regression-test Failures

**Symptoms**: Reputation dump comparison fails

**Root Causes**:
- Reputation calculation algorithm changed
- Vote processing order issue
- Reference data outdated

**Evidence to look for**:
```
FAILED
mismatch
differ
AssertionError
```

**Investigation**:
1. Check `tests/regression/account_dump_test.log`
2. Compare expected vs actual reputation values
3. Review recent changes to `db/calculate_account_reputations.sql`

---

### 3. pattern-test (Tavern) Failures

**Symptoms**: API endpoint tests fail

**Root Causes**:
- API response format changed
- Endpoint not available
- Schema mismatch

**Evidence to look for**:
```
FAILED
tavern
AssertionError
passed.*failed
```

**Investigation**:
1. Check which specific test file failed
2. Compare expected vs actual response in test output
3. Verify endpoint_schema.sql matches test expectations

---

### 4. PostgreSQL Tablespace Issues

**Symptoms**: Database doesn't start, missing subdirectory errors

**Root Causes**:
- Tablespace symlinks not preserved in cache
- Absolute symlink paths invalid on different runner

**Evidence**:
```
FATAL: database "haf_block_log" does not exist
DETAIL: The database subdirectory "pg_tblspc/..." is missing
```

**Fix**: Ensure cache-manager preserves symlinks, convert absolute to relative paths

---

### 5. Missing block_log

**Symptoms**: HAF container fails to start

**Root Causes**:
- Block log not mounted
- Path configuration mismatch

**Evidence**:
```
test -e /blockchain/block_log_5m/block_log
container must have /blockchain directory mounted
```

**Fix**: Verify `BLOCK_LOG_SOURCE_DIR_5M` variable and runner block_log location

---

## NFS Performance Notes

### File Metadata Overhead

NFS operations are slow for many small files:

| Operation | Speed |
|-----------|-------|
| Single large file write | 969 MB/s |
| cp -a (many files) | 257 MB/s |
| tar archive (single file) | 760 MB/s |

**Solution**: Store caches as tar archives on NFS

### Performance Comparison

- PUT (tar archive): ~25s vs 74s with cp (3x faster)
- GET (tar extract): ~13s vs 74s with cp (5.7x faster)

---

## Quick Diagnosis Steps

1. **Check job logs** for error patterns above
2. **Look at timing** - did it timeout or fail immediately?
3. **Check cache operations** - look for "Caching locally" messages
4. **Verify HAF image** - is the correct image being used?
5. **Check runner** - is the data-cache-storage runner available?

---

## Related Documentation

- HAF cache-manager: See HAF repo's `scripts/ci-helpers/cache-manager.sh`
- CI templates: `common-ci-configuration` project
- btracker similar issues: `../../../btracker/scripts/claude/tools/job_failure_analysis.md`
