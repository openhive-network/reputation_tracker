# Reputation Processing

## Overview

Reputation processing follows a multi-phase pipeline that extracts vote operations from the blockchain, transforms them into structured data, and calculates reputation changes. The key constraint is **sequential processing** - votes must be processed in blockchain order because each vote's effect depends on the voter's reputation at that moment.

## Processing Pipeline

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         BLOCK RANGE PROCESSING                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  Phase 1a: operations_in_range                                              │
│     Filter vote-related operations (types 72, 17, 61)                       │
│                              ↓                                              │
│  Phase 1b: vote_operations_raw                                              │
│     Parse JSON bodies → (author, voter, permlink, rshares)                  │
│                              ↓                                              │
│  Phase 2: account_ids                                                       │
│     Resolve account names → integer IDs (per-name index probe)              │
│                              ↓                                              │
│  Phase 3: permlink dictionary                                               │
│     Insert new permlinks, fetch IDs for all                                 │
│                              ↓                                              │
│  Phase 4: ranked_data                                                       │
│     Find previous votes (ROW_NUMBER + self-join)                            │
│                              ↓                                              │
│  Phase 5: check_if_prev_balances_canceled                                   │
│     Handle delete operations between votes                                  │
│                              ↓                                              │
│  Phase 6: active_votes updates                                              │
│     DELETE canceled votes, UPSERT new votes                                 │
│                              ↓                                              │
│  Phase 7: votes_to_process                                                  │
│     array_agg the batch's votes in source_op order                          │
│                              ↓                                              │
│  calculate_account_reputations(arrays)                                      │
│     Apply each vote in order in memory, one upsert for the batch            │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Operations That Affect Reputation

Three blockchain operations trigger reputation updates:

| Op Type ID | Operation Name | Effect |
|------------|----------------|--------|
| 72 | `effective_comment_vote_operation` | Vote cast or changed (contains rshares) |
| 17 | `delete_comment_operation` | Post deleted - all votes on it are removed from tracking |
| 61 | `comment_payout_update_operation` | Post paid out - votes are finalized and removed from tracking |

All operations are normalized to `effective_vote_return` type: `(author, voter, permlink, rshares)`.

## Vote Processing Rules

### Reputation Gate Rules

1. **Voter Reputation Gate**: Only votes from accounts with **non-negative** reputation affect the target
2. **Downvote Restrictions**:
   - Voter must have **explicit** reputation (not implicit/new account)
   - Voter's reputation must **exceed** target's reputation ("can't punch up")
   - Upvotes are always applied if voter has >= 0 reputation
3. **Implicit vs Explicit**: Accounts start with `is_implicit=TRUE` until they receive their first counted vote

### Vote Change Handling

When a vote is modified:
1. **Undo** the previous vote's reputation impact
2. **Apply** the new vote's impact

This is tracked via `prev_rshares` in the processing pipeline.

### Delete/Payout Handling

When a post is deleted or paid out:
1. All active votes on that post are removed from `active_votes` table
2. Reputation changes already applied are **preserved** (not reversed)
3. If a vote occurs after delete, it's treated as a fresh vote (no prev_rshares)

## Reputation Calculation Algorithm

Located in `db/calculate_account_reputations.sql`. One call per block range: it takes the
range's votes as four parallel arrays in `source_op` order (`author_ids`, `voter_ids`,
`rshares`, `prev_rshares`), reads the reputation of every account they touch from
`account_reputations` once into plpgsql arrays (accounts indexed densely, votes refer to
them by index), applies the rules below vote by vote against those arrays, then upserts
the accounts a vote changed in one statement (skipping rows whose final state equals the
stored one). The per-vote cost is plpgsql array reads and writes instead of a lookup and an
upsert per vote. It runs with `plan_cache_mode = force_custom_plan`: a generic plan
estimates `unnest()` of an array parameter at a few rows and nested-loops its joins over
the batch's tens of thousands of votes.

`reptracker_block_range_data()` also runs with `plan_cache_mode = force_custom_plan`. A
generic plan of its CTE chain, cached early in a sync while `active_votes` is small, is
never invalidated during the long `main()` session (no ANALYZE runs on its tables while it
holds them, and nothing else touches their definitions), so later batches ran on it at
10-20 s per 10,000 blocks instead of under 1 s. Phase 1b reads the parsed row's fields from
an `OFFSET 0` subquery column: `(CASE ... END).*` would call the parser once per field.

### Scaling Formula

```sql
reputation_change = rshares >> 6  -- equivalent to rshares / 64
```

The 6-bit right shift dampens vote weight to prevent reputation inflation.

### Phase 1: Undo Previous Vote (if vote changed)

```sql
IF NOT _author_is_implicit
   AND _voter_reputation >= 0
   AND (
     _prev_rshares >= 0  -- upvote
     OR (
       _prev_rshares < 0               -- downvote
       AND NOT _voter_is_implicit
       AND _voter_reputation > _author_reputation - _prev_rshares_scaled
     )
   ) THEN
  _author_reputation := _author_reputation - _prev_rshares_scaled;
END IF;
```

### Phase 2: Apply New Vote

```sql
IF _voter_reputation >= 0
   AND (
     _rshares >= 0  -- upvote
     OR (
       _rshares < 0                    -- downvote
       AND NOT _voter_is_implicit
       AND _voter_reputation > _author_reputation
     )
   ) THEN
  _author_reputation := _author_reputation + _rshares_scaled;
  _author_is_implicit := FALSE;  -- Account now has explicit reputation
END IF;
```

### Self-Vote Edge Case

When author votes on their own post, voter reputation state must be synchronized since they're the same account.

## Display Transformation

Raw reputation values are large integers. For API display:

```
score = (log10(abs(raw_rep)) - 9) * 9 + 25
if negative_rep: score = -score
```

This produces scores roughly in range 25-75 for typical accounts.

### Constants (from `reputation_constants.sql`)

| Function | Value | Purpose |
|----------|-------|---------|
| `reputation_scaling_bits()` | 6 | rshares >> 6 dampening |
| `reputation_log_base()` | 10 | Logarithm base |
| `reputation_log_offset()` | 9 | Subtracted from log result |
| `reputation_multiplier()` | 9 | Multiplier after offset |
| `reputation_base_score()` | 25 | Default display score |

## Processing Modes

### MASSIVE_PROCESSING (Initial Sync)

- Processes blocks in batches of 10,000
- Uses `synchronous_commit = OFF` for throughput
- During the initial sync only, requests VACUUM FULL of `account_reputations` and `active_votes` at most every 10 minutes
- Called via `reptracker_massive_processing()`
- HAF re-enters this stage for any catch-up of more than 101 blocks (e.g. after a restart). Those catch-ups request no vacuum: a VACUUM FULL holds an ACCESS EXCLUSIVE lock that stalls block processing and drops the table's visibility map
- `permlinks` is insert-only and is never requested a vacuum; it is created with reloptions (`autovacuum_vacuum_insert_scale_factor = 0`, insert threshold 100000, `autovacuum_freeze_min_age = 0`, analyze threshold 1000000) so autovacuum keeps its visibility map and statistics current

### Processing while hived replays

The install opts the context in with `hive.app_context_set_early_block_processing()` (skipped with a NOTICE on a HAF without it). With hived's `psql-massive-index-policy = keep-monotonic`, `hive.app_next_iteration` then delivers irreversible blocks while hived still replays, with HAF's deferred core indexes missing. Block processing needs none of them: `reptracker_block_range_data()` reads `operations_view` by block range (`hive_operations_block_num_id_idx`, kept) and `accounts_view` by name (`uq_hive_accounst_name`, kept once haf#381 lands), and nothing else from hafd. The stage comes from `app_next_iteration`, which measures the distance to `hive.get_estimated_hive_head_block()` (the chain head from the clock), so the context stays in MASSIVE_PROCESSING while hived replays old blocks. Near the end of HAF's massive sync it can still reach the LIVE stage before HAF restores its indexes, so the LIVE path calls `finish_initial_sync()` (and, on a HAF without the registered index path below, `create_rep_indexes()`) only once `hive.is_instance_ready()` holds: the freeze vacuums and the non-concurrent `CREATE INDEX` on `hafd.operations` (which blocks hived's inserts) wait for HAF. A 10,000-block massive transaction reads `hafd.accounts` for about 5 s on average (14 h over the mainnet chain), so it holds up HAF's constraint re-attach for seconds, not minutes.

### Partial op_type index on hafd.operations

`hive_operations_op_types_<ids>_idx` covers only reptracker's 3 operation types (`reptracker_backend.get_reptracker_op_type_ids()`), keyed on block number. It speeds up block processing; no query depends on it for correctness.

- **HAF with `hive.register_op_type_partial_index` (haf#510)** — `does_haf_build_rep_indexes()` is true. `scripts/install_app.sh` calls `register_rep_indexes(<schema>)` at every install and reinstall, after `operation_types.sql` and before the context processes any block. HAF builds the index: at its LIVE entry when registered during the massive sync, CONCURRENTLY by hived when registered later. Reptracker never builds it, and block processing never calls `create_rep_indexes()` or the deprecated `hive.create_op_type_partial_index()`: blocks are processed (slower, not wrongly) while the index is missing or still being built (`indisvalid` false). `do_rep_indexes_exist()` holds as soon as the index is registered in `hafd.indexes_constraints`. If hived has not filled `hafd.operation_types` yet, the install skips the registration with a NOTICE; `register_missing_rep_indexes(<schema>)` then registers it at the next start of block processing: at the start of `main()`, and in `scripts/process_blocks.sh` before it starts `haf_app_driver.py`, both as the processing role (`reptracker_owner` in the images). It does nothing while the index is registered or built. When it still cannot register (`hafd.operation_types` still empty, or `insufficient_privilege`: HAF requires a session user that can impersonate the context owner), it raises one WARNING per start naming the cause and the remedy (reinstall, or start as the context owner) and processing goes on without the index. Per-block processing never registers, as its role may lack the privilege. `hive.app_remove_context()` at uninstall releases the registration.
- **Older HAF** — `register_rep_indexes()` only raises a NOTICE naming the missing function, and the first LIVE block once `hive.is_instance_ready()` holds calls `create_rep_indexes()` while `do_rep_indexes_exist()` is false, which builds the index with `hive.create_op_type_partial_index()` (a blocking `CREATE INDEX`).

### Initial-sync marker

`reptracker_app_status.is_initial_sync_finished` (read by `is_initial_sync_finished()`) persists across restarts. The first LIVE iteration once `hive.is_instance_ready()` holds calls `finish_initial_sync()`, which sets it and requests one `VACUUM (FREEZE, ANALYZE)` (HAF request kind `'freeze'`, haf#360) of `permlinks`, `account_reputations` and `active_votes`. On a HAF whose `hive.app_request_table_vacuum()` has no `_kind` argument, the requests are skipped with a NOTICE. Reptracker never drops its indexes, so HAF's own post-`app_restore_indexes()` freeze does not cover it.

### LIVE (Real-time Sync)

- Processes blocks one at a time
- Uses `synchronous_commit = ON` for data safety
- Called via `reptracker_single_processing()`

## Function Inventory

### Core Processing

| Function | Location | Purpose |
|----------|----------|---------|
| `reptracker_block_range_data()` | `db/process_block_range.sql` | Main CTE chain - processes block range |
| `calculate_account_reputations()` | `db/calculate_account_reputations.sql` | Ordered reputation calculation over a batch of votes |

### Operation Parsers

| Function | Location | Purpose |
|----------|----------|---------|
| `process_effective_vote_operation()` | `backend/operation_parsers/vote_operations.sql` | Parse vote JSON |
| `process_deleted_comment_operation()` | `backend/operation_parsers/vote_operations.sql` | Parse delete/payout JSON |

### Operation Type Lookups

| Function | Location | Purpose |
|----------|----------|---------|
| `op_effective_comment_vote()` | `backend/utilities/operation_types.sql` | Returns op type 72 |
| `op_delete_comment()` | `backend/utilities/operation_types.sql` | Returns op type 17 |
| `op_comment_payout_update()` | `backend/utilities/operation_types.sql` | Returns op type 61 |

### Processing Control

| Function | Location | Purpose |
|----------|----------|---------|
| `main()` | `db/reptracker_app.sql` | Entry point - starts processing loop |
| `register_missing_rep_indexes()` | `db/reptracker_app.sql` | At each start of block processing: registers the partial index an install skipped, or WARNs |
| `reptracker_process_blocks()` | `db/reptracker_app.sql` | Dispatch to massive/single processing |
| `reptracker_massive_processing()` | `db/reptracker_app.sql` | Bulk sync mode |
| `reptracker_single_processing()` | `db/reptracker_app.sql` | Live sync mode |
| `is_initial_sync_finished()` | `db/reptracker_app.sql` | Whether the first LIVE iteration on a ready HAF has happened |
| `finish_initial_sync()` | `db/reptracker_app.sql` | Set the marker, request post-sync freeze vacuums |
| `continueProcessing()` | `db/reptracker_app.sql` | Check stop flag |
| `allowProcessing()` | `db/reptracker_app.sql` | Enable processing |
| `stopProcessing()` | `db/reptracker_app.sql` | Request graceful stop |

## Why Sequential Processing?

Votes **must** be processed in blockchain order (by `source_op`) because:

1. Each vote's effect depends on the voter's reputation **at that moment**
2. A vote can change the voter's own reputation (self-votes)
3. Earlier votes in a batch can affect whether later votes in the same batch count

**Example**: If Alice downvotes Bob, then Carol upvotes Alice:
- If Alice's downvote processed first: Alice has lower rep, downvote might be ignored
- If Carol's upvote processed first: Alice has higher rep, downvote may count

`reptracker_block_range_data()` aggregates the range's votes into arrays ordered by `source_op`, and `calculate_account_reputations()` applies them in that order against in-memory copies of the affected accounts' reputations.

## Expansion Rules

When modifying processing logic:
1. Update this file with new phases or algorithm changes
2. Update function inventory if adding new functions
3. If adding new operation types, update the "Operations That Affect Reputation" table
4. Consider creating `processing/` subdirectory for detailed algorithm documentation if this file grows too large
