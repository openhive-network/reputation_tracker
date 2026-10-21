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
    echo "hive.app_context_set_early_block_processing) and simulates a keep-monotonic massive"
    echo "sync of hived in it: the database is left modified, use a throwaway one."
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
"$script_dir/install_app.sh" --postgres-url="$POSTGRES_ACCESS"
psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -X -f "$SCRIPTDIR/early_block_processing.sql"
