#!/bin/bash

set -e

function print_help () {
cat <<-EOF
Usage: $0 [OPTION[=VALUE]]...

Script that waits for Reputation Tracker to process 5'000'000 blocks.
To be used in CI.
OPTIONS:
    --postgres-access=URL    PostgreSQL URL
    --help|-h|-?              Display this help screen and exit
EOF
}

function wait-for-rt-startup() {
    if command -v psql &> /dev/null
    then
        until psql "$POSTGRES_ACCESS" --quiet --tuples-only --command="$COMMAND" | grep 1 &>/dev/null
        do 
            echo "$MESSAGE"
            sleep 20
        done
    else
        echo "Please install psql before running this script."
        exit 1
    fi
}

#shellcheck disable=SC2089
COMMAND="SELECT hive.is_app_in_sync('reptracker_app')::INT;"
MESSAGE="Waiting for Reputation Tracker to finish processing blocks..."

while [ $# -gt 0 ]; do
  case "$1" in
    --postgres-access=*)
        arg="${1#*=}"
        POSTGRES_ACCESS="$arg"
        ;;
    --help|-h|-\?)
        print_help
        exit 0
        ;;
    *)
        echo "ERROR: '$1' is not a valid option/positional argument"
        echo
        print_help
        exit 2
        ;;
  esac
  shift
done

POSTGRES_ACCESS=${POSTGRES_ACCESS:-postgresql://haf_admin@localhost:5432/haf_block_log}

export -f wait-for-rt-startup
export POSTGRES_ACCESS
#shellcheck disable=SC2090
export COMMAND
export MESSAGE

timeout -k 1m 55m bash -c wait-for-rt-startup
      
echo "Block processing is finished."