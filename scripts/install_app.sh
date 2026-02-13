#! /bin/bash

set -e
set -o pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"
SRCPATH="${SCRIPTPATH}/../"

# Script responsible for execution of all actions required to finish configuration of the database holding a HAF database to work correctly with reputation_tracker.

print_help () {
    echo "Usage: $0 [OPTION[=VALUE]]..."
    echo
    echo "Allows to setup a database already filled by HAF instance, to work with reputation_tracker application."
    echo "OPTIONS:"
    echo "  --host=VALUE              Allows to specify a PostgreSQL host location (defaults to /var/run/postgresql)"
    echo "  --port=NUMBER             Allows to specify a PostgreSQL operating port (defaults to 5432)"
    echo "  --postgres-url=URL        Allows to specify a PostgreSQL URL (in opposite to separate --host and --port options)"
    echo "  --swagger-url=URL         Allows to specify a server URL"
    echo "  --is_forking=TRUE/FALSE   Allows to specify if app should be forking or not (defaults to true)"
    echo "  --help               Display this help screen and exit"
    echo
}

#reptracker_dir="$SCRIPTPATH/.."
POSTGRES_USER=${POSTGRES_USER:-"haf_admin"}
POSTGRES_HOST=${POSTGRES_HOST:-"localhost"}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_URL=${POSTGRES_URL:-""}
REPTRACKER_SCHEMA=${REPTRACKER_SCHEMA:-"reptracker_app"}
IS_FORKING=${IS_FORKING:-"true"}
SWAGGER_URL=${SWAGGER_URL:-"{reptracker-host}"}
POSTGRES_APP_NAME=reptracker_install
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
    --swagger-url=*)
        SWAGGER_URL="${1#*=}"
        ;;
    --schema=*)
        REPTRACKER_SCHEMA="${1#*=}"
        ;;
    --is_forking=*)
        IS_FORKING="${1#*=}"
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

POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$POSTGRES_USER@$POSTGRES_HOST:$POSTGRES_PORT/haf_block_log?application_name=${POSTGRES_APP_NAME}"}

install_schema() {
  echo "Installing schema..."
  # Core roles and schema setup
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -f "$SRCPATH/db/builtin_roles.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET ROLE reptracker_owner;CREATE SCHEMA IF NOT EXISTS ${REPTRACKER_SCHEMA} AUTHORIZATION reptracker_owner;"

  # Main application schema (HAF context, tables, control functions, processing procedures)
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET custom.is_forking = '$IS_FORKING'; SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/db/reptracker_app.sql"

  # Endpoints
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET custom.swagger_url = '$SWAGGER_URL'; SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/endpoints/endpoint_schema.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/endpoints/get_reputation.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/endpoints/get_rep_last_synced_block.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/endpoints/get_rep_version.sql"

  # Backend utilities (must be installed before operation parsers that depend on them)
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/backend/utilities/operation_types.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/backend/utilities/reputation_constants.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/backend/utilities/account.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/backend/utilities/validators.sql"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/backend/utilities/exceptions.sql"

  # Backend operation parsers
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/backend/operation_parsers/vote_operations.sql"

  # Reputation calculation (core algorithm)
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/db/calculate_account_reputations.sql"

  # Block processing logic
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/db/process_block_range.sql"

  # Version injection
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on -c "SET SEARCH_PATH TO ${REPTRACKER_SCHEMA};" -f "$SRCPATH/scripts/set_version_in_sql.pgsql"

  # Grant permissions to reptracker_user
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT USAGE ON SCHEMA ${REPTRACKER_SCHEMA} to reptracker_user;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT USAGE ON SCHEMA reptracker_endpoints to reptracker_user;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT USAGE ON SCHEMA reptracker_backend to reptracker_user;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT SELECT ON ALL TABLES IN SCHEMA ${REPTRACKER_SCHEMA} TO reptracker_user;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT SELECT ON ALL TABLES IN SCHEMA reptracker_endpoints TO reptracker_user;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT SELECT ON ALL TABLES IN SCHEMA reptracker_backend TO reptracker_user;"

  # Allow hived to fulfill vacuum full requests
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT MAINTAIN ON ALL TABLES IN SCHEMA ${REPTRACKER_SCHEMA} TO hived_group;"
  psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on  -c "SET ROLE reptracker_owner;GRANT ALL ON SCHEMA ${REPTRACKER_SCHEMA} TO hived_group;"
}

install_schema

