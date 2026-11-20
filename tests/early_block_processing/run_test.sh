#! /bin/bash

set -euo pipefail

SCRIPTDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
script_dir="$SCRIPTDIR/../../scripts"

POSTGRES_HOST="localhost"
POSTGRES_PORT=5432
POSTGRES_URL=""

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Installs reputation tracker into a HAF database that holds no blocks yet (HAF with"
    echo "hive.app_context_set_early_block_processing) before hived fills hafd.operation_types,"
    echo "checks that the start of block processing registers the partial index the install"
    echo "skipped, reinstalls, and simulates a keep-monotonic massive sync of hived in it: the"
    echo "database is left modified, use a throwaway one."
    echo "OPTIONS:"
    echo "  --host=VALUE             Allows to specify a PostgreSQL host location (defaults to localhost)"
    echo "  --port=NUMBER            Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL       Allows to specify a PostgreSQL URL of a superuser (defaults to haf_admin)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host=*)
        POSTGRES_HOST="${1#*=}"
        ;;
    --port=*)
        POSTGRES_PORT="${1#*=}"
        ;;
    --postgres-url=*)
        POSTGRES_URL="${1#*=}"
        ;;
    --help)
        print_help
        exit 0
        ;;
    -*)
        echo "ERROR: '$1' is not a valid option"
        echo
        print_help
        exit 1
        ;;
    *)
        echo "ERROR: '$1' is not a valid argument"
        echo
        print_help
        exit 2
        ;;
    esac
    shift
done

POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://haf_admin@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log"}

if [ ! -f "$script_dir/set_version_in_sql.pgsql" ]; then
  "$script_dir/generate_version_sql.sh" "$script_dir/.."
fi
sql() { psql "$POSTGRES_ACCESS" -X -Atq -v ON_ERROR_STOP=on "$@"; }

# Starts the legacy main() loop as the context owner, as scripts/process_blocks.sh
# does, with a block limit it has already reached: it returns after its start. Prints
# how many WARNINGs about the unregistered partial index it raised.
main_index_warnings() {
  local out
  out="$(sql -c "SET ROLE reptracker_owner;" -c "SET SEARCH_PATH TO reptracker_app;" \
    -c "CALL reptracker_app.main('reptracker_app', 0);" 2>&1)"
  grep -c "WARNING:.*partial index on hafd.operations .* is not registered with HAF" <<<"$out" || true
}

expect_main_index_warnings() {
  local got
  got="$(main_index_warnings)"
  if [ "$got" != "$1" ]; then
    echo "FAIL: main() raised $got WARNINGs about the unregistered partial index, expected $1 ($2)"
    exit 1
  fi
}

if [ "$(sql -c "SELECT count(*) FROM hafd.operation_types")" != 0 ]; then
  echo "ERROR: hafd.operation_types is not empty: this test needs a HAF database hived has never started on"
  exit 1
fi
haf_builds_index="$(sql -c "SELECT to_regproc('hive.register_op_type_partial_index') IS NOT NULL")"

# An install before hived has started: the registration is skipped
"$script_dir/install_app.sh" --postgres-url="$POSTGRES_ACCESS"
sql -v haf_builds_index="$haf_builds_index" -f "$SCRIPTDIR/skipped_registration.sql"
if [ "$haf_builds_index" = t ]; then
  expect_main_index_warnings 1 "hafd.operation_types still empty"
else
  expect_main_index_warnings 0 "a HAF without hive.register_op_type_partial_index builds the index at LIVE"
fi

# hived fills hafd.operation_types when it starts
sql -c "
INSERT INTO hafd.operation_types( id, name, is_virtual ) VALUES
    ( 17, 'hive::protocol::delete_comment_operation', FALSE )
  , ( 61, 'hive::protocol::comment_payout_update_operation', TRUE )
  , ( 72, 'hive::protocol::effective_comment_vote_operation', TRUE );"
expect_main_index_warnings 0 "the next start registers the index"
sql -v haf_builds_index="$haf_builds_index" -f "$SCRIPTDIR/registered_at_start.sql"

# The install with hafd.operation_types filled registers the index itself
"$script_dir/install_app.sh" --postgres-url="$POSTGRES_ACCESS"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -X -f "$SCRIPTDIR/early_block_processing.sql"
