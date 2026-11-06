#! /bin/bash
set -e
set -o pipefail
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

# Asks the HAF application registry who should process ${REPTRACKER_SCHEMA}'s blocks.
# Prints one of:
#   driver    registered under its own name with an entry procedure that exists
#   broken    registered under its own name, but with no entry procedure or one that is
#             gone (e.g. after an uninstall whose context removal failed). The legacy
#             loop would fail too: HAF's lock helper refuses such an app ("reinstall")
#   embedded  another application owns the context and drives it
#   legacy    not in the registry at all, mostly a HAF older than the registry (haf#341),
#             where db/reptracker_app.sql skips registration
#
# Checking that haf_app_driver.py is on PATH is not enough: the psql base image has
# shipped it since 14-3, and the driver exits before its first range when the app is
# not runnable from the registry. As PID 1 under a restart policy, that is a container
# that never processes a block (#12).
#
# Two statements, not one: PostgreSQL resolves relations at plan time, so a query naming
# hafd.applications fails on a HAF without it whatever to_regclass() says. The SQL goes
# through stdin because psql does not substitute :'app' in -c strings. -w: never wait
# for a password on stdin, which holds the SQL.
registry_probe() {
    PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
    psql "$POSTGRES_ACCESS" -X -w -Atq -v ON_ERROR_STOP=on -v app="${REPTRACKER_SCHEMA}" <<'EOF'
SELECT to_regclass('hafd.applications') IS NOT NULL AS has_registry \gset
\if :has_registry
SELECT CASE
  WHEN EXISTS (
    SELECT 1 FROM hafd.applications
    WHERE name = :'app'
      AND process_procedure IS NOT NULL
      AND to_regprocedure(process_procedure || '(hive.blocks_range)') IS NOT NULL)
  THEN 'driver'
  WHEN EXISTS (SELECT 1 FROM hafd.applications WHERE name = :'app')
  THEN 'broken'
  WHEN EXISTS (
    SELECT 1 FROM hafd.applications
    WHERE name <> :'app' AND contexts @> ARRAY[ :'app' ]::TEXT[])
  THEN 'embedded'
  ELSE 'legacy'
END;
\else
SELECT 'legacy';
\endif
EOF
}

# A database that is briefly unreachable at start must not decide the loop for the
# container's whole life: retry while psql cannot connect (exit status 2), then give up
# and leave the retry to the restart policy.
choose_loop() {
    local attempt answer status
    for attempt in $(seq 1 "${REGISTRY_PROBE_ATTEMPTS:-12}"); do
        status=0
        answer="$(registry_probe 2>/dev/null)" || status=$?
        if [ "$status" -ne 2 ]; then
            # 0: the registry's answer. Anything else is a query that failed on a live
            # connection (e.g. a privilege missing), which a retry would not change.
            [ "$status" -eq 0 ] && echo "$answer" || echo "legacy"
            return 0
        fi
        echo "Cannot connect to the database to check the HAF application registry (attempt $attempt); retrying" >&2
        sleep "${REGISTRY_PROBE_RETRY_SECONDS:-5}"
    done
    echo "unreachable"
}

process_blocks() {
    local n_blocks="${1:-null}"
    log_file="reptracker_sync.log"

    # The generic HAF block-processing driver (haf#341) runs the registered
    # ${REPTRACKER_SCHEMA}.process_blocks procedure per delivered range and idles
    # on its own connection between blocks. It ships with the psql base image.
    # exec it directly (no tee pipeline): as PID 1 it must receive SIGTERM itself
    # to stop cleanly; a bash parent would swallow the signal until docker's kill.
    if ! command -v haf_app_driver.py >/dev/null 2>&1; then
        echo "WARNING: haf_app_driver.py not found, falling back to the legacy CALL main() loop"
    else
        case "$(choose_loop)" in
            driver)
                echo "${REPTRACKER_SCHEMA} is registered in the HAF application registry; running haf_app_driver.py"
                local limit_arg=()
                [ "$n_blocks" != "null" ] && limit_arg=(--stop-at-block="$n_blocks")
                exec haf_app_driver.py --app="${REPTRACKER_SCHEMA}" --postgres-url="$POSTGRES_ACCESS" --lock=reputation_tracker "${limit_arg[@]}"
                ;;
            broken)
                echo "ERROR: ${REPTRACKER_SCHEMA} is in the HAF application registry, but its entry procedure"
                echo "       is missing. Reinstall reputation tracker (scripts/install_app.sh)."
                exit 1
                ;;
            embedded)
                # Its loop already processes this context; a second one must not.
                echo "ERROR: the ${REPTRACKER_SCHEMA} context belongs to another application in the HAF"
                echo "       application registry, whose block processing drives it. Not starting a second"
                echo "       loop: stop this block processing service."
                exit 1
                ;;
            unreachable)
                echo "ERROR: could not connect to the database to check the HAF application registry"
                exit 1
                ;;
            *)
                echo "WARNING: haf_app_driver.py is on PATH, but the HAF application registry does not list"
                echo "         ${REPTRACKER_SCHEMA} (HAF older than haf#341, or the registry could not be"
                echo "         read); falling back to the legacy CALL main() loop"
                ;;
        esac
    fi

    # record the startup time for use in health checks
    date -uIseconds > /tmp/block_processing_startup_time.txt

    exec run_with_reconnect.sh -- psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=on" -v REPTRACKER_SCHEMA="${REPTRACKER_SCHEMA}" -c "\timing" -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -c "CALL ${REPTRACKER_SCHEMA}.main('${REPTRACKER_SCHEMA}', $n_blocks);"
}

process_blocks "$PROCESS_BLOCK_LIMIT"
