#! /bin/bash

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
SRCPATH="${SCRIPTPATH}/../"

LOG_FILE=install_app.log
source "$SCRIPTPATH/common.sh"

log_exec_params "$@"

# Script reponsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with hivemind.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to setup a database already filled by HAF instance, to work with reputation_tracker application."
    echo "OPTIONS:"
    echo "  --host=VALUE         Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER        Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL   Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --help               Display this help screen and exit"
    echo
}

POSTGRES_HOST="/var/run/postgresql"
POSTGRES_PORT=5432
POSTGRES_URL=""

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

if [ -z "$POSTGRES_URL" ]; then
  POSTGRES_ACCESS="postgresql://haf_admin@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log"
else
  POSTGRES_ACCESS=$POSTGRES_URL
fi

psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/db/builtin_roles.sql"
psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/db/database_schema.sql"
psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/db/rep_views.sql"
psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/db/rep_indexes.sql"
psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/db/process_block_range.sql"
psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/db/rep_helpers.sql"
psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/db/main_loop.sql"

psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/account_dump/account_rep_stats.sql"
psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f "${SRCPATH}/account_dump/compare_accounts.sql"
