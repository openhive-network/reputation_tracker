-- Block processing while hived replays with psql-massive-index-policy=keep-monotonic.
--
-- Runs as a HAF superuser on a HAF database without blocks, right after
-- scripts/install_app.sh, and simulates what hived does: a massive dump under the
-- default drop-all policy (nothing may be delivered), the same dump under
-- keep-monotonic (reptracker must process it while the deferred core indexes are
-- missing, read no table whose indexes are all deferred, and finish its initial
-- sync only after HAF restores them), then the index restore and one more block.
\set ON_ERROR_STOP on
\set head 250

CREATE SCHEMA reptracker_early_test;
GRANT USAGE ON SCHEMA reptracker_early_test TO reptracker_owner;

CREATE TABLE reptracker_early_test.delivered( first_block INT, last_block INT, stage TEXT, deferred_table_scans BIGINT );
GRANT INSERT ON reptracker_early_test.delivered TO reptracker_owner;

-- Scans of the hafd tables whose indexes are all deferred, and of their indexes,
-- made so far by the current transaction.
CREATE FUNCTION reptracker_early_test.deferred_table_scans()
RETURNS BIGINT
LANGUAGE sql
AS $$
  SELECT COALESCE( sum( pg_stat_get_xact_numscans( r.oid ) ), 0 )::BIGINT
  FROM (
    SELECT c.oid FROM pg_class c
    WHERE c.oid IN ( 'hafd.account_operations'::regclass, 'hafd.transactions'::regclass, 'hafd.transactions_multisig'::regclass )
    UNION ALL
    SELECT i.indexrelid FROM pg_index i
    WHERE i.indrelid IN ( 'hafd.account_operations'::regclass, 'hafd.transactions'::regclass, 'hafd.transactions_multisig'::regclass )
  ) r( oid );
$$;

-- The haf_app_driver.py loop: one hive.app_next_iteration per range, the app's
-- registered process_blocks for each delivered one.
CREATE PROCEDURE reptracker_early_test.drive( _iterations INT )
LANGUAGE plpgsql
AS $$
DECLARE
  __range hive.blocks_range;
  __scans BIGINT;
BEGIN
  FOR __i IN 1 .. _iterations LOOP
    CALL hive.app_next_iteration( ARRAY['reptracker_app']::hive.contexts_group, __range, _wait => FALSE );
    IF __range IS NOT NULL THEN
      __scans := reptracker_early_test.deferred_table_scans();
      CALL reptracker_app.process_blocks( __range );
      INSERT INTO reptracker_early_test.delivered
      VALUES ( __range.first_block, __range.last_block, hive.get_current_stage_name('reptracker_app'),
               reptracker_early_test.deferred_table_scans() - __scans );
    END IF;
  END LOOP;
END
$$;

-- Blocks _from.._to, the last one produced now, with votes only in blocks 1..3:
-- alice upvotes bob, bob upvotes carol, carol downvotes alice.
CREATE FUNCTION reptracker_early_test.dump_blocks( _from INT, _to INT )
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO hafd.blocks
  SELECT b, ('\xBADD' || lpad( to_hex( b ), 6, '0' ))::bytea, '\xCAFE20', now() - ( _to - b ) * INTERVAL '3 seconds', 5, '\x4007', E'[]', '\x2157', 'STM65w', 1000, 1000, 1000000, 1000, 1000, 1000, 2000, 2000
  FROM generate_series( _from, _to ) b;

  INSERT INTO hafd.operations( id, trx_in_block, op_type_id, op_pos, body_value )
  SELECT hafd.operation_id( v.block, 0 ), 0, 72, 0, v.body
  FROM ( VALUES
      ( 1, '{"voter": "alice", "author": "bob", "permlink": "p1", "rshares": 6400}'::jsonb )
    , ( 2, '{"voter": "bob", "author": "carol", "permlink": "p2", "rshares": 640}'::jsonb )
    , ( 3, '{"voter": "carol", "author": "alice", "permlink": "p3", "rshares": -64000}'::jsonb )
  ) v( block, body )
  WHERE v.block BETWEEN _from AND _to;
END
$$;

SELECT hive.initialize_extension_data();

DO $$
BEGIN
  ASSERT ( SELECT early_block_processing FROM hafd.contexts WHERE name = 'reptracker_app' ),
    'reptracker_app did not opt in to early block processing at install';
END
$$;

INSERT INTO hafd.operation_types( id, name, is_virtual ) VALUES
    ( 17, 'hive::protocol::delete_comment_operation', FALSE )
  , ( 61, 'hive::protocol::comment_payout_update_operation', TRUE )
  , ( 72, 'hive::protocol::effective_comment_vote_operation', TRUE )
ON CONFLICT DO NOTHING;

\echo 'drop-all: no block is delivered before the index restore'
SELECT hive.disable_fk_of_irreversible();
SELECT hive.disable_indexes_of_irreversible( 'drop-all' );
SELECT hive.set_sync_state( 'REINDEX' );
SELECT reptracker_early_test.dump_blocks( 1, :head );
INSERT INTO hafd.accounts( id, name, block_num ) VALUES
    ( 5, 'initminer', 1 ), ( 6, 'alice', 1 ), ( 7, 'bob', 1 ), ( 8, 'carol', 1 );
SELECT hive.end_massive_sync( :head );

SET ROLE reptracker_owner;
CALL reptracker_early_test.drive( 3 );
RESET ROLE;
DO $$
BEGIN
  ASSERT NOT hive.is_instance_ready_for_block_processing(), 'drop-all drops the kept indexes too';
  ASSERT NOT EXISTS ( SELECT 1 FROM reptracker_early_test.delivered ), 'drop-all delivered blocks before the index restore';
  ASSERT hive.app_get_current_block_num( 'reptracker_app' ) = 0, 'drop-all: reptracker processed blocks before the index restore';
END
$$;

\echo 'keep-monotonic: blocks are processed while hived replays'
SELECT hive.enable_indexes_of_irreversible();
SELECT hive.disable_indexes_of_irreversible( 'keep-monotonic' );
DO $$
BEGIN
  ASSERT NOT hive.is_instance_ready(), 'the deferred indexes must be missing';
  ASSERT hive.is_instance_ready_for_block_processing(), 'the kept indexes must exist';
  ASSERT NOT hive.are_core_indexes_created( 'hafd.account_operations' ), 'account_operations indexes must be deferred';
END
$$;

SET ROLE reptracker_owner;
CALL reptracker_early_test.drive( 10 );
RESET ROLE;

-- having caught up with hived, the context is within the LIVE stage's distance of
-- the chain head estimated from the newest dumped block
SELECT reptracker_early_test.dump_blocks( :head + 1, :head + 5 );
SELECT hive.end_massive_sync( :head + 5 );

SET ROLE reptracker_owner;
CALL reptracker_early_test.drive( 10 );
RESET ROLE;

SELECT * FROM reptracker_early_test.delivered ORDER BY first_block;

DO $$
DECLARE
  __head INT := ( SELECT consistent_block FROM hafd.hive_state );
BEGIN
  ASSERT hive.get_sync_state() = 'REINDEX', 'the processing must run while hived replays';
  ASSERT hive.app_get_current_block_num( 'reptracker_app' ) = __head,
    format( 'reptracker reached block %s, not the dumped head %s', hive.app_get_current_block_num( 'reptracker_app' ), __head );
  ASSERT EXISTS ( SELECT 1 FROM reptracker_early_test.delivered WHERE stage = 'MASSIVE_PROCESSING' ), 'no range was processed in MASSIVE_PROCESSING';
  ASSERT NOT EXISTS ( SELECT 1 FROM reptracker_early_test.delivered WHERE deferred_table_scans != 0 ),
    'block processing read hafd.transactions, hafd.transactions_multisig or hafd.account_operations, whose indexes are deferred';
  ASSERT EXISTS ( SELECT 1 FROM reptracker_early_test.delivered WHERE stage = 'live' ),
    'the context never reached the LIVE stage, so the finalization gate was not exercised';
  ASSERT NOT ( SELECT is_initial_sync_finished FROM reptracker_app.reptracker_app_status ), 'the initial sync was finished before HAF restored its indexes';
  ASSERT NOT EXISTS ( SELECT 1 FROM hafd.vacuum_requests WHERE schema_name = 'reptracker_app' AND kind = 'freeze' ),
    'freeze vacuums were requested before HAF restored its indexes';
  ASSERT NOT EXISTS ( SELECT 1 FROM pg_indexes WHERE indexname = 'hive_operations_op_types_17_61_72_idx' ),
    'the partial index on hafd.operations was created during the massive sync';
  ASSERT ( SELECT string_agg( format( '%s:%s:%s', a.name, r.reputation, r.is_implicit ), ',' ORDER BY a.name )
           FROM reptracker_app.account_reputations r JOIN hafd.accounts a ON a.id = r.account_id )
         = 'alice:-1000:f,bob:100:f,carol:10:f',
    'unexpected reputations after processing during the replay';
END
$$;

\echo 'HAF restores its indexes: the next LIVE block finishes the initial sync'
SELECT hive.enable_indexes_of_irreversible();
SELECT hive.enable_fk_of_irreversible();
SELECT reptracker_early_test.dump_blocks( :head + 6, :head + 6 );
SELECT hive.end_massive_sync( :head + 6 );

SET ROLE reptracker_owner;
CALL reptracker_early_test.drive( 3 );
RESET ROLE;

DO $$
BEGIN
  ASSERT hive.is_instance_ready(), 'the restored instance must be ready';
  ASSERT hive.app_get_current_block_num( 'reptracker_app' ) = ( SELECT consistent_block FROM hafd.hive_state ), 'the block after the restore was not processed';
  ASSERT ( SELECT is_initial_sync_finished FROM reptracker_app.reptracker_app_status ), 'the initial sync did not finish once HAF was ready';
  ASSERT ( SELECT count(*) FROM hafd.vacuum_requests WHERE schema_name = 'reptracker_app' AND kind = 'freeze' ) = 3,
    'finish_initial_sync did not request one freeze vacuum per table';
  ASSERT EXISTS ( SELECT 1 FROM pg_indexes WHERE indexname = 'hive_operations_op_types_17_61_72_idx' ),
    'the partial index on hafd.operations was not created once HAF was ready';
END
$$;

\echo 'early block processing test passed'
