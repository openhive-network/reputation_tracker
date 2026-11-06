#! /bin/bash
#
# Which loop scripts/process_blocks.sh starts (#12). haf_app_driver.py is on PATH in the
# app image, so the script must also check the HAF application registry: the driver exits
# before its first range when the app is not runnable from it, and as PID 1 under a
# restart policy that is a container that never processes a block.
#
# Installs reputation tracker into a HAF database that holds no blocks yet, puts stubs for
# haf_app_driver.py and run_with_reconnect.sh first on PATH, and checks the choice in each
# registry state. The database is left modified: use a throwaway one.

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

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
printf '#!/bin/bash\necho STUB-DRIVER "$@"\n' > "$stub_dir/haf_app_driver.py"
printf '#!/bin/bash\necho STUB-LEGACY "$@"\n' > "$stub_dir/run_with_reconnect.sh"
chmod +x "$stub_dir"/*

sql() { psql "$ADMIN_URL" -X -Atq -v ON_ERROR_STOP=on -c "$1"; }

failures=0
expect() {  # expect <case> <DRIVER|LEGACY|NONE> [postgres-url]
  local out chosen status=0
  # A script that dies must reach the report below, not stop the test
  out="$(PATH="$stub_dir:$PATH" REGISTRY_PROBE_ATTEMPTS=2 REGISTRY_PROBE_RETRY_SECONDS=0 \
         bash "$PROCESS_BLOCKS" --postgres-url="${3:-$OWNER_URL}" 2>&1)" || status=$?
  chosen="$(grep -oE 'STUB-(DRIVER|LEGACY)' <<<"$out" | head -1)" || true
  chosen="${chosen#STUB-}"
  # The driver must also be told which app to run
  if [ "$chosen" = "DRIVER" ] && ! grep -q -- "--app=reptracker_app " <<<"$out"; then
    chosen="DRIVER without --app=reptracker_app"
  fi
  # NONE: no loop started, and the service fails with an ERROR line
  if [ -z "$chosen" ] && [ "$status" -ne 0 ] && grep -q "^ERROR:" <<<"$out"; then
    chosen="NONE"
  fi
  if [ "$chosen" = "$2" ]; then
    echo "PASS  $1: $chosen"
  else
    echo "FAIL  $1: expected $2, got ${chosen:-nothing} (exit $status)"
    printf '      %s\n' "$out"
    failures=$((failures + 1))
  fi
}

[ "$(sql "SELECT to_regclass('hafd.applications') IS NOT NULL")" = "t" ] \
  || { echo "This HAF has no application registry; the test needs one"; exit 1; }
[ "$(sql "SELECT process_procedure FROM hafd.applications WHERE name = 'reptracker_app'")" = "reptracker_app.process_blocks" ] \
  || { echo "install did not register reptracker_app with its entry procedure"; exit 1; }

expect "registered with its entry procedure" DRIVER

sql "UPDATE hafd.applications SET process_procedure = NULL WHERE name = 'reptracker_app'"
expect "registered without an entry procedure" NONE
sql "UPDATE hafd.applications SET process_procedure = 'reptracker_app.process_blocks' WHERE name = 'reptracker_app'"
expect "entry procedure restored" DRIVER

sql "ALTER PROCEDURE reptracker_app.process_blocks(hive.blocks_range) RENAME TO process_blocks_hidden"
expect "entry procedure gone" NONE
sql "ALTER PROCEDURE reptracker_app.process_blocks_hidden(hive.blocks_range) RENAME TO process_blocks"

# Another application owns the context and drives it: no second loop
sql "DELETE FROM hafd.applications WHERE name = 'other_app'"  # left by an earlier run
sql "UPDATE hafd.applications SET name = 'other_app' WHERE name = 'reptracker_app'"
expect "context owned by an embedding application" NONE

# A runnable row under another name, for another context, does not count for this app
sql "UPDATE hafd.applications SET contexts = ARRAY['other_context'] WHERE name = 'other_app'"
expect "not in the registry, another application is" LEGACY

expect "database unreachable" NONE "postgresql://reptracker_owner@$POSTGRES_HOST:1/haf_block_log"

# The legacy loop itself must start, not only be chosen: it runs until stopped, so a
# timeout (124) with no error means it got past its startup (locks, context checks)
status=0
out="$(timeout 20 psql "$OWNER_URL" -X -v ON_ERROR_STOP=on \
       -c "SET SEARCH_PATH TO reptracker_app;" -c "CALL reptracker_app.main('reptracker_app', NULL);" 2>&1)" || status=$?
if [ "$status" -eq 124 ] && ! grep -q "ERROR" <<<"$out"; then
  echo "PASS  legacy main() runs"
else
  echo "FAIL  legacy main() runs: exit $status"
  printf '      %s\n' "$out"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "All cases passed"
