#! /bin/bash

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
SRCPATH="${SCRIPTPATH}/../"

LOG_FILE=setup_db.log
source "$SCRIPTPATH/common.sh"

log_exec_params "$@"

# Script reponsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with hivemind.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to CLEAR a database containing already deployed reputation_tracker app at given HAF instance."
    echo "OPTIONS:"
    echo "  --host=VALUE         Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER        Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL   Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --drop-indexes       Allows to also drop indexes built by application on regular HAF tables (their rebuild can be timeconsuming). Indexes are preserved by default."
    echo "  --help               Display this help screen and exit"
    echo
}

POSTGRES_HOST="/var/run/postgresql"
POSTGRES_PORT=5432
POSTGRES_URL=""
DROP_ALL=0

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
    --drop-all*)
        DROP_ALL=1
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


psql $POSTGRES_ACCESS -v ON_ERROR_STOP=on -f - <<EOF

DO \$$
BEGIN
IF hive.app_context_exists('reptracker_app') THEN
    RAISE NOTICE 'Attempting to REMOVE a HAF application context for reputation_tracker app...';
    PERFORM hive.app_remove_context('reptracker_app');
END IF;
END
\$$;

DROP SCHEMA IF EXISTS reptracker_app CASCADE;

EOF

if [ ${DROP_ALL} -eq 1 ]; then
  echo "Attempting to drop roles & indexes built by application"

  psql -aw $POSTGRES_ACCESS -v ON_ERROR_STOP=on -c 'DROP OWNED BY reptracker_app_owner CASCADE;' || true
  psql -aw $POSTGRES_ACCESS -v ON_ERROR_STOP=on -c 'DROP ROLE IF EXISTS reptracker_app_owner, reputation_tracker_writer_group;'

  psql -aw $POSTGRES_ACCESS -v ON_ERROR_STOP=on -c 'DROP INDEX IF EXISTS hive.effective_comment_vote_idx;'
  psql -aw $POSTGRES_ACCESS -v ON_ERROR_STOP=on -c 'DROP INDEX IF EXISTS hive.delete_comment_op_idx;'
  psql -aw $POSTGRES_ACCESS -v ON_ERROR_STOP=on -c 'DROP INDEX IF EXISTS hive.stable_id_block_num_effective_vote_idx;'
else
  echo "Indexes & roles created by application have been preserved"
fi

