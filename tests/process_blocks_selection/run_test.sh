#! /bin/bash
#
# Which loop scripts/process_blocks.sh starts (#12). haf_app_driver.py is on PATH in the
# app image, so the script must also check the HAF application registry: the driver exits
# before its first range when the app is not runnable from it, and as PID 1 under a
# restart policy that is a container that never processes a block.
#
# Installs reputation tracker into a HAF database that holds no blocks yet, puts stubs for
# haf_app_driver.py and run_with_reconnect.sh first on PATH, and checks the choice in each
# registry state. Then runs the real legacy main() loop, with and without HAF's lock
# helper, and covers a HAF without the registry (1.28.7 and older) by hiding the
# registry table. The database is left modified: use a throwaway one.

set -euo pipefail

SCRIPTDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
script_dir="$SCRIPTDIR/../../scripts"
PROCESS_BLOCKS="${PROCESS_BLOCKS:-$script_dir/process_blocks.sh}"

POSTGRES_HOST="localhost"
POSTGRES_PORT=5432

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Checks which block-processing loop scripts/process_blocks.sh starts in each"
    echo "state of the HAF application registry. The database is left modified."
    echo "OPTIONS:"
    echo "  --host=VALUE             PostgreSQL host (defaults to localhost)"
    echo "  --port=NUMBER            PostgreSQL port (defaults to 5432)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host=*)
        POSTGRES_HOST="${1#*=}"
        ;;
    --port=*)
        POSTGRES_PORT="${1#*=}"
        ;;
    --help)
        print_help
        exit 0
        ;;
    *)
        echo "ERROR: '$1' is not a valid option or argument"
        echo
        print_help
        exit 1
        ;;
    esac
    shift
done

ADMIN_URL="postgresql://haf_admin@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log"
# The processor's own role and application name, as in production
OWNER_URL="postgresql://reptracker_owner@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=reptracker_block_processing"

if [ ! -f "$script_dir/set_version_in_sql.pgsql" ]; then
  "$script_dir/generate_version_sql.sh" "$script_dir/.."
fi
"$script_dir/install_app.sh" --postgres-url="$ADMIN_URL"

sql() { psql "$ADMIN_URL" -X -Atq -v ON_ERROR_STOP=on -c "$1"; }

# Undo whatever this test hid from HAF, whatever way it ends
restore_haf() {
  sql "DO \$\$ BEGIN
         IF to_regclass('hafd.applications_hidden_by_test') IS NOT NULL THEN
           ALTER TABLE hafd.applications_hidden_by_test RENAME TO applications;
         END IF;
         IF to_regprocedure('hive.acquire_app_block_processor_locks_hidden_by_test(text[])') IS NOT NULL THEN
           ALTER FUNCTION hive.acquire_app_block_processor_locks_hidden_by_test(text[]) RENAME TO acquire_app_block_processor_locks;
         END IF;
       END \$\$" || true
}

work_dir="$(mktemp -d)"
trap 'restore_haf; rm -rf "$work_dir"' EXIT
stubs="$work_dir/stubs"; mkdir -p "$stubs" "$work_dir/flaky" "$work_dir/failing"
printf '#!/bin/bash\necho STUB-DRIVER "$@"\n' > "$stubs/haf_app_driver.py"
printf '#!/bin/bash\necho STUB-LEGACY "$@"\n' > "$stubs/run_with_reconnect.sh"
# psql that cannot connect once, then works: the probe must retry
printf '#!/bin/bash\nif [ ! -e "%s/flaky/failed" ]; then touch "%s/flaky/failed"; echo "psql: error: connection refused (test)" >&2; exit 2; fi\nexec "%s" "$@"\n' \
  "$work_dir" "$work_dir" "$(command -v psql)" > "$work_dir/flaky/psql"
# psql whose query fails on a live connection: the probe must not guess
printf '#!/bin/bash\necho "ERROR:  permission denied for table applications (test)" >&2\nexit 3\n' > "$work_dir/failing/psql"
chmod +x "$stubs"/* "$work_dir/flaky/psql" "$work_dir/failing/psql"

failures=0
fail() { echo "FAIL  $1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; failures=$((failures + 1)); }

# expect <case> <DRIVER|LEGACY|NONE> [grep pattern the output must hold] [-- process_blocks.sh args]
# EXTRA_PATH: a directory to put before the stubs (a psql stand-in)
expect() {
  local name="$1" want="$2" must="${3:-}" out chosen status=0
  shift 3 || shift $#
  [ "${1:-}" = "--" ] && shift
  [ $# -eq 0 ] && set -- --postgres-url="$OWNER_URL"
  # A script that dies must reach the report below, not stop the test
  out="$(PATH="${EXTRA_PATH:+$EXTRA_PATH:}$stubs:$PATH" REGISTRY_PROBE_ATTEMPTS=2 REGISTRY_PROBE_RETRY_SECONDS=0 \
         timeout 60 bash "$PROCESS_BLOCKS" "$@" 2>&1)" || status=$?
  chosen="$(grep -oE 'STUB-(DRIVER|LEGACY)' <<<"$out" | head -1)" || true
  chosen="${chosen#STUB-}"
  # The driver must be told which app to run and which install lock to share
  if [ "$chosen" = "DRIVER" ] && ! grep -q -- "--app=reptracker_app --postgres-url=.* --lock=reputation_tracker" <<<"$out"; then
    chosen="DRIVER without --app=reptracker_app or --lock=reputation_tracker"
  fi
  # NONE: no loop started, and the service fails with an ERROR line
  if [ -z "$chosen" ] && [ "$status" -ne 0 ] && grep -q "^ERROR:" <<<"$out"; then
    chosen="NONE"
  fi
  if [ "$chosen" != "$want" ]; then
    fail "$name: expected $want, got ${chosen:-nothing} (exit $status)" "$out"
  elif [ -n "$must" ] && ! grep -qE -- "$must" <<<"$out"; then
    fail "$name: $chosen, but the output lacks /$must/" "$out"
  else
    echo "PASS  $name: $chosen"
  fi
}

# run_main <case> <must-match pattern...>: the real legacy loop runs until stopped, so
# a timeout (124) with no error, after it entered its loop, means it started
run_main() {
  local name="$1" out status=0 pattern
  shift
  # -s INT: psql cancels the CALL on the server before it exits
  out="$(timeout -s INT 10 psql "$OWNER_URL" -X -v ON_ERROR_STOP=on \
         -c "SET SEARCH_PATH TO reptracker_app;" -c "CALL reptracker_app.main('reptracker_app', NULL);" 2>&1)" || status=$?
  if [ "$status" -ne 124 ] || grep -v "canceling statement due to user request" <<<"$out" | grep -q "ERROR"; then
    fail "$name: exit $status" "$out"; return
  fi
  for pattern in "Entering application main loop" "$@"; do
    grep -q -- "$pattern" <<<"$out" || { fail "$name: output lacks '$pattern'" "$out"; return; }
  done
  echo "PASS  $name"
}

[ "$(sql "SELECT to_regclass('hafd.applications') IS NOT NULL")" = "t" ] \
  || { echo "This HAF has no application registry; the test needs one"; exit 1; }
[ "$(sql "SELECT process_procedure FROM hafd.applications WHERE name = 'reptracker_app'")" = "reptracker_app.process_blocks" ] \
  || { echo "install did not register reptracker_app with its entry procedure"; exit 1; }

expect "registered with its entry procedure" DRIVER
expect "--stop-at-block reaches the driver" DRIVER "--stop-at-block=5" -- --postgres-url="$OWNER_URL" --stop-at-block=5
EXTRA_PATH="$work_dir/flaky" expect "database down at the first attempt" DRIVER "attempt 1\): psql: error: connection refused \(test\); retrying"
EXTRA_PATH="$work_dir/failing" expect "registry query fails" NONE "ERROR: could not read the HAF application registry: ERROR:  permission denied"
expect "database unreachable" NONE "ERROR: could not connect" -- --postgres-url="postgresql://reptracker_owner@$POSTGRES_HOST:1/haf_block_log"

# The driver cannot run an app without its entry procedure; the legacy loop can
sql "UPDATE hafd.applications SET process_procedure = NULL WHERE name = 'reptracker_app'"
expect "registered without an entry procedure" LEGACY "entry procedure"
sql "UPDATE hafd.applications SET process_procedure = 'reptracker_app.process_blocks' WHERE name = 'reptracker_app'"
sql "ALTER PROCEDURE reptracker_app.process_blocks(hive.blocks_range) RENAME TO process_blocks_hidden"
expect "entry procedure gone" LEGACY "entry procedure"
run_main "legacy main() runs with the entry procedure gone"
sql "ALTER PROCEDURE reptracker_app.process_blocks_hidden(hive.blocks_range) RENAME TO process_blocks"
expect "entry procedure restored" DRIVER

# Another application owns the context and drives it: no second loop
sql "DELETE FROM hafd.applications WHERE name = 'other_app'"  # left by an earlier run
sql "UPDATE hafd.applications SET name = 'other_app' WHERE name = 'reptracker_app'"
expect "context owned by an embedding application" NONE "belongs to another application"

# A runnable row under another name, for another context, does not count for this app
sql "UPDATE hafd.applications SET contexts = ARRAY['other_context'] WHERE name = 'other_app'"
expect "not in the registry, another application is" LEGACY
expect "--stop-at-block reaches the legacy loop" LEGACY "main\('reptracker_app', 5\)" -- --postgres-url="$OWNER_URL" --stop-at-block=5
sql "DELETE FROM hafd.applications WHERE name = 'other_app'"
"$script_dir/install_app.sh" --postgres-url="$ADMIN_URL" > /dev/null 2>&1

# The real legacy loop, holding the reputation_tracker application lock
run_main "legacy main() runs"

# A HAF without the lock helpers (1.28.7 and older)
sql "ALTER FUNCTION hive.acquire_app_block_processor_locks(text[]) RENAME TO acquire_app_block_processor_locks_hidden_by_test"
run_main "legacy main() runs without HAF's lock helper" "without the reputation_tracker application lock"
restore_haf

# A HAF without the registry (1.28.7 and older): the install skips registration, and
# the script takes the legacy loop
sql "ALTER TABLE hafd.applications RENAME TO applications_hidden_by_test"
status=0
out="$("$script_dir/install_app.sh" --postgres-url="$ADMIN_URL" 2>&1)" || status=$?
if [ "$status" -eq 0 ] && grep -q "This HAF has no application registry" <<<"$out"; then
  echo "PASS  install on a HAF without the registry"
else
  fail "install on a HAF without the registry: exit $status" "$(grep -E 'ERROR|WARNING' <<<"$out" || true)"
fi
expect "HAF without the registry" LEGACY "falling back to the legacy CALL main\(\) loop"
restore_haf

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "All cases passed"
