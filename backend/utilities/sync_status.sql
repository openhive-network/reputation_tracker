SET ROLE reptracker_owner;

/*
 * sync_status() — the last processed block as {last_block_num, last_block_time},
 * for the /sync-status endpoint (the HAF-wide uniform health/freshness API that
 * supersedes the bare-integer /last-synced-block). The timestamp lets consumers
 * compute staleness with a single call (age = now() - last_block_time) instead
 * of needing a second head-block reference.
 * The schema (and thus HAF context) name is injected via format() because the
 * app can be installed under a custom schema (--schema=...); LEFT JOIN so the
 * pre-sync case (no processed block yet) still yields an object with null time.
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
    BEGIN
      RETURN (
        SELECT json_build_object(
          'last_block_num', c.current_block_num,
          'last_block_time', to_char(b.created_at, 'YYYY-MM-DD"T"HH24:MI:SS')
        )
        FROM hafd.contexts c
        LEFT JOIN hafd.blocks b ON b.num = c.current_block_num
        WHERE c.name = '%s'
      );
    END
    $pb$;
  $BODY$, __schema_name);
END
$$;

RESET ROLE;
