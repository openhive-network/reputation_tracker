SET ROLE reptracker_owner;

/*
 * sync_status() — the last processed block as {last_block_num, last_block_time},
 * for the /sync-status endpoint (the HAF-wide uniform health/freshness API that
 * supersedes the bare-integer /last-synced-block). The timestamp lets consumers
 * compute staleness with a single call (age = now() - last_block_time) instead
 * of needing a second head-block reference.
 * The schema (and thus HAF context) name is injected via format() because the
 * app can be installed under a custom schema (--schema=...).
 *
 * The block's timestamp is read through the context's own blocks_view rather
 * than hafd.blocks: this is a forking context, so once caught up its current
 * block usually still sits in hafd.blocks_reversible for a few hundred ms
 * before OBI makes it irreversible. Joining hafd.blocks alone returned a null
 * time in that window, which health checks read as "no block processed yet"
 * and flapped the backend. The view covers both tables (and the pre-sync
 * case, block 0, still yields a null time).
 *
 * The lookup is deliberately parameterized on a plain variable: joining a
 * forking context's blocks_view on another relation's column defeats
 * predicate pushdown into the view's UNION ALL and plans as a hash join over
 * all of hafd.blocks (measured at 74 s on a mainnet node), whereas
 * `WHERE num = <param>` is an index lookup in both branches.
 */
DO $$
DECLARE
  __schema_name VARCHAR;
BEGIN
  SHOW SEARCH_PATH INTO __schema_name;
  EXECUTE format(
  $BODY$
    CREATE OR REPLACE FUNCTION reptracker_backend.sync_status()
    RETURNS JSON
    LANGUAGE 'plpgsql' STABLE
    AS
    $pb$
    DECLARE
      __block_num INT := (SELECT current_block_num FROM hafd.contexts WHERE name = %L);
    BEGIN
      -- Fail fast during HAF massive sync: hafd.blocks' PK is dropped for the
      -- duration (hive.disable_indexes_of_irreversible), so the lookup below
      -- would seq-scan the largest table in the database. Health-check agents
      -- gate on is_instance_ready() before calling APIs; this guard protects
      -- any caller that does not (e.g. a raw haproxy httpchk) by erroring in
      -- milliseconds instead of stalling.
      IF NOT hive.is_instance_ready() THEN
        RAISE EXCEPTION 'HAF instance is not ready (massive sync in progress)'
          USING ERRCODE = '55000';
      END IF;

      RETURN json_build_object(
        'last_block_num', __block_num,
        'last_block_time', to_char(
          (SELECT b.created_at FROM %I.blocks_view b WHERE b.num = __block_num),
          'YYYY-MM-DD"T"HH24:MI:SS')
      );
    END
    $pb$;
  $BODY$, __schema_name, __schema_name);
END
$$;

RESET ROLE;
