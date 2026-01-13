#! /bin/bash

set -e

print_help () {
    cat <<-EOF
Usage: $0 <source directory> [OPTION[=VALUE]]...

Build any Docker image defined as a target in docker-bake.hcl
OPTIONS:
  --registry=URL        Docker registry to assign the image to (default: 'registry.gitlab.syncad.com/hive/reputation_tracker')
  --tag=TAG             Docker tag to be build (defaults set in docker-bake.hcl)
  --target=TARGET       Target defined in docker-bake.hcl (default: 'default' - builds full image)
  --progress=TYPE       Determines how to display build progress (default: 'auto')
  --help|-h|-?          Display this help screen and exit
EOF
}

export CI_REGISTRY_IMAGE=${CI_REGISTRY_IMAGE:-"registry.gitlab.syncad.com/hive/reputation_tracker"}
PROGRESS_DISPLAY=${PROGRESS_DISPLAY:-"auto"}
TARGET=${TARGET:-"default"}

while [ $# -gt 0 ]; do
  case "$1" in
    --registry=*)
        arg="${1#*=}"
        CI_REGISTRY_IMAGE="$arg"
        ;;
    --tag=*)
        arg="${1#*=}"
        BASE_TAG="$arg"
        ;;
    --progress=*)
        arg="${1#*=}"
        PROGRESS_DISPLAY="$arg"
        ;;
    --target=*)
        arg="${1#*=}"
        TARGET="$arg"
        ;;
    --help|-h|-?)
        print_help
        exit 0
        ;;
    *)
        if [ -z "$SRCROOTDIR" ];
        then
          SRCROOTDIR="${1}"
        else
          echo "ERROR: '$1' is not a valid option/positional argument"
          echo
          print_help
          exit 2
        fi
        ;;
    esac
    shift
done

# Different targets use different tag variables
if [[ -n $BASE_TAG ]]; then
  case ${TARGET:-} in
    psql-client|psql-client-ci)
      export PSQL_CLIENT_VERSION=$BASE_TAG
      ;;
    default|full|full-ci)
      export TAG=$BASE_TAG
      ;;
    ci-runner|ci-runner-ci)
      export TAG_CI=$BASE_TAG
      ;;
  esac
fi

pushd "$SRCROOTDIR"

# All the variables below must be declared and assigned separately
# for 'set -e' to work correctly. See https://www.shellcheck.net/wiki/SC2155
# for an explanation

BUILD_TIME="$(date -uIseconds)"
export BUILD_TIME

GIT_COMMIT_SHA="$(git rev-parse HEAD || true)"
if [ -z "$GIT_COMMIT_SHA" ]; then
  GIT_COMMIT_SHA="[unknown]"
fi
export GIT_COMMIT_SHA

GIT_CURRENT_BRANCH="$(git branch --show-current || true)"
if [ -z "$GIT_CURRENT_BRANCH" ]; then
  GIT_CURRENT_BRANCH="$(git describe --abbrev=0 --all --exclude 'pipelines/*' | sed 's/^.*\///' || true)"
  if [ -z "$GIT_CURRENT_BRANCH" ]; then
    GIT_CURRENT_BRANCH="[unknown]"
  fi
fi
export GIT_CURRENT_BRANCH

GIT_LAST_LOG_MESSAGE="$(git log -1 --pretty=%B || true)"
if [ -z "$GIT_LAST_LOG_MESSAGE" ]; then
  GIT_LAST_LOG_MESSAGE="[unknown]"
fi
export GIT_LAST_LOG_MESSAGE

GIT_LAST_COMMITTER="$(git log -1 --pretty="%an <%ae>" || true)"
if [ -z "$GIT_LAST_COMMITTER" ]; then
  GIT_LAST_COMMITTER="[unknown]"
fi
export GIT_LAST_COMMITTER

GIT_LAST_COMMIT_DATE="$(git log -1 --pretty="%aI" || true)"
if [ -z "$GIT_LAST_COMMIT_DATE" ]; then
  GIT_LAST_COMMIT_DATE="[unknown]"
fi
export GIT_LAST_COMMIT_DATE

docker buildx bake --provenance=false --progress="$PROGRESS_DISPLAY" "$TARGET"

# Build postgrest-rewriter with standardized tagging
# Same tagging convention as main image: short SHA + latest (develop) + version (tags)
REWRITER_TARGET=without_tag
TAG_BUILD_ARGS=""
REWRITER_TAGS=""

# Always tag with short SHA
if [ -n "${CI_COMMIT_SHORT_SHA:-}" ]; then
  REWRITER_TAGS="--tag $CI_REGISTRY_IMAGE/postgrest-rewriter:$CI_COMMIT_SHORT_SHA"
fi

# Tag with 'latest' on develop branch
if [ "${CI_COMMIT_BRANCH:-}" = "${CI_DEFAULT_BRANCH:-develop}" ]; then
  REWRITER_TAGS="$REWRITER_TAGS --tag $CI_REGISTRY_IMAGE/postgrest-rewriter:latest"
fi

# Tag with version on protected tags
if [ -n "${CI_COMMIT_TAG:-}" ]; then
  REWRITER_TARGET=with_tag
  TAG_BUILD_ARGS="--build-arg GIT_COMMIT_TAG=$CI_COMMIT_TAG"
  REWRITER_TAGS="$REWRITER_TAGS --tag $CI_REGISTRY_IMAGE/postgrest-rewriter:$CI_COMMIT_TAG"
fi

# Fallback for local builds (use BASE_TAG if no CI variables)
if [ -z "$REWRITER_TAGS" ] && [ -n "$BASE_TAG" ]; then
  REWRITER_TAGS="--tag $CI_REGISTRY_IMAGE/postgrest-rewriter:$BASE_TAG"
fi

echo "Building postgrest-rewriter with tags: $REWRITER_TAGS"

# shellcheck disable=SC2086
docker buildx build \
    --build-arg BUILD_TIME="$BUILD_TIME" \
    --build-arg GIT_COMMIT_SHA="$GIT_COMMIT_SHA" \
    --build-arg GIT_CURRENT_BRANCH="$GIT_CURRENT_BRANCH" \
    --build-arg GIT_LAST_LOG_MESSAGE="$GIT_LAST_LOG_MESSAGE" \
    --build-arg GIT_LAST_COMMITTER="$GIT_LAST_COMMITTER" \
    --build-arg GIT_LAST_COMMIT_DATE="$GIT_LAST_COMMIT_DATE" \
    --target=$REWRITER_TARGET \
    $TAG_BUILD_ARGS \
    $REWRITER_TAGS \
    --push \
    --file Dockerfile.rewriter .

popd
