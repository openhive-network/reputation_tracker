#! /bin/bash


set -euo pipefail

SCRIPTDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"


POSTGRES_HOST="localhost"
POSTGRES_PORT=5432
POSTGRES_USER="reptracker_owner"
REPTRACKER_SCHEMA=${REPTRACKER_SCHEMA:-"reptracker_app"}

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to start a reputation tracker test (5m blocks)."
    echo "reputation tracker must be stopped on 5m blocks (add flag to ./process_blocks.sh --stop-at-block=5000000)"
    echo "OPTIONS:"
    echo "  --host=VALUE             Allows to specify a PostgreSQL host location (defaults to localhost)"
    echo "  --port=NUMBER            Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --user=VALUE             Allows to specify a PostgreSQL user (defaults to hafbe_owner)"
}

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

POSTGRES_ACCESS_ADMIN="postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log"

echo "Clearing tables..."
psql "$POSTGRES_ACCESS_ADMIN" -v "ON_ERROR_STOP=on" -c "TRUNCATE reptracker_account_dump.account_reputation;"
psql "$POSTGRES_ACCESS_ADMIN" -v "ON_ERROR_STOP=on" -c "TRUNCATE reptracker_account_dump.differing_accounts;"

# CI comes with psycopg2 preinstalled
if [[ -z "${CI:-}" ]]; then
    echo "Installing dependecies..."
    pip install psycopg2-binary
fi

# The line below is somewhat problematic. Gunzip by default deletes gz file after decompression,
# but the '-k' parameter, which prevents that from happening is not supported on some of its versions.
# 
# Thus, depending on the OS, the line below may need to be replaced with one of the following:
# gunzip -c "${SCRIPTDIR}/accounts_dump.json.gz" > "${SCRIPTDIR}/accounts_dump.json"
# gzcat "${SCRIPTDIR}/accounts_dump.json.gz" > "${SCRIPTDIR}/accounts_dump.json"
# zcat "${SCRIPTDIR}/accounts_dump.json.gz" > "${SCRIPTDIR}/accounts_dump.json"

gunzip -k "${SCRIPTDIR}/accounts_dump.json.gz"

# curl -s --data '{"jsonrpc":"2.0", "method":"reputation_api.get_account_reputations", "params": {"account_lower_bound": "", "limit": 10000000}, "id":1}' http://172.17.0.2:8091 > accounts_dump.json 

echo "Starting data_insertion_script.py..."
python3 "$SCRIPTDIR/data_insertion_script.py" "$SCRIPTDIR" --host "$POSTGRES_HOST" --port "$POSTGRES_PORT" --user "$POSTGRES_USER" #--debug

echo "Looking for diffrences between hived node and hafbe stats..."

if command -v ts > /dev/null 2>&1; then
    timestamper="ts '%Y-%m-%d %H:%M:%.S'"
elif command -v tai64nlocal > /dev/null 2>&1; then
    timestamper="tai64n | tai64nlocal"
else
    timestamper="cat"
fi

psql "$POSTGRES_ACCESS_ADMIN" -v "ON_ERROR_STOP=on" -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -c "SELECT reptracker_account_dump.compare_accounts();" 2>&1 | tee -i >(eval "$timestamper" > "account_dump_test.log")

DIFFERING_ACCOUNTS=$(psql "$POSTGRES_ACCESS_ADMIN" -v "ON_ERROR_STOP=on" -t -A  -c "SELECT * FROM reptracker_account_dump.differing_accounts;")

if [ -z "$DIFFERING_ACCOUNTS" ]; then
    echo "Account balances are correct!"
    rm -f "${SCRIPTDIR}/accounts_dump.json"
    exit 0
else
    echo "Account balances are incorrect..."
    psql "$POSTGRES_ACCESS_ADMIN" -v "ON_ERROR_STOP=on" -c "SELECT * FROM reptracker_account_dump.differing_accounts;"
    rm -f "${SCRIPTDIR}/accounts_dump.json"
    exit 3
fi
