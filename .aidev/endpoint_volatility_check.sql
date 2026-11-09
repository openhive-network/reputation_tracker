-- Every function in reptracker_endpoints is STABLE or IMMUTABLE, so PostgREST
-- runs its POST calls (the rewriter forwards REST GETs as POSTs) in a READ ONLY
-- transaction, as it does for VOLATILE functions only on GET. Then the
-- endpoints whose volatility was once missing are called as reptracker_user
-- inside a READ ONLY transaction.
-- Runs as haf_shared_consumer in the run's clone (.aidev/run-checks.sh install
-- and reinstall) and writes nothing.
\set ON_ERROR_STOP on

DO $$
DECLARE
  _volatile TEXT;
BEGIN
  SELECT string_agg(p.oid::regprocedure::TEXT, ', ' ORDER BY p.proname)
  INTO _volatile
  FROM pg_proc p
  WHERE p.pronamespace = 'reptracker_endpoints'::regnamespace
    AND p.provolatile = 'v';

  IF _volatile IS NOT NULL THEN
    RAISE EXCEPTION 'endpoint functions declared VOLATILE: %', _volatile;
  END IF;

  RAISE NOTICE 'every function in reptracker_endpoints is STABLE or IMMUTABLE';
END
$$;

BEGIN READ ONLY;
SET LOCAL ROLE reptracker_user;

DO $$
BEGIN
  IF current_setting('transaction_read_only') <> 'on' THEN
    RAISE EXCEPTION 'the endpoint calls are not running in a READ ONLY transaction';
  END IF;

  PERFORM reptracker_endpoints.get_rep_last_synced_block();
  PERFORM reptracker_endpoints.root();

  RAISE NOTICE 'the endpoints run in a READ ONLY transaction';
END
$$;

ROLLBACK;
