#! /bin/bash
set -e
set -o pipefail
trap 'kill 0' TERM INT
# Script responsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with reputation_tracker.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to start a data collection for reputation_tracker application."
    echo "OPTIONS:"
    echo "  --host=VALUE         Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER        Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL   Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --stop-at-block=num  Allows to stop processing (sync) at given block"
    echo "  --help               Display this help screen and exit"
    echo
}

POSTGRES_USER=${POSTGRES_USER:-"reptracker_owner"}
POSTGRES_HOST=${POSTGRES_HOST:-"localhost"}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_URL=${POSTGRES_URL:-""}
PROCESS_BLOCK_LIMIT=${PROCESS_BLOCK_LIMIT:-null}
REPTRACKER_SCHEMA=${REPTRACKER_SCHEMA:-"reptracker_app"}

while [ $# -gt 0 ]; do
  case "$1" in
    --host=*)
        POSTGRES_HOST="${1#*=}"
        ;;
    --port=*)
        POSTGRES_PORT="${1#*=}"
        ;;
    --user=*)
        POSTGRES_USER="${1#*=}"
        ;;
    --postgres-url=*)
        POSTGRES_URL="${1#*=}"
        ;;
    --stop-at-block=*)
        PROCESS_BLOCK_LIMIT="${1#*=}"
        ;;
    --schema=*)
        REPTRACKER_SCHEMA="${1#*=}"
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

POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=reptracker_block_processing"}

process_blocks() {
    local n_blocks="${1:-null}"
    log_file="reptracker_sync.log"
    # record the startup time for use in health checks
    date -uIseconds > /tmp/block_processing_startup_time.txt

    run_with_reconnect.sh -- psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=on" -v REPTRACKER_SCHEMA="${REPTRACKER_SCHEMA}" -c "\timing" -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -c "CALL ${REPTRACKER_SCHEMA}.main('${REPTRACKER_SCHEMA}', $n_blocks);" 2>&1 | tee -i $log_file
}

process_blocks "$PROCESS_BLOCK_LIMIT"
