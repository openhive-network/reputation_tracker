# The image AIDEV runs this project's checks in. AIDEV builds it on the base
# `environment.base` in .aidev/project.yaml follows (common-ci-configuration's
# haf-app-test-runner, CI's tavern runner), passed as BASE_IMAGE, and rebuilds it
# when that tag moves. Checks run with the caller's uid and, for the slots that
# reach the shared HAF, on the per-run network its relay is on; every tool is in
# the image, nothing is installed at run time.
#
# The base provides Python, bash, psql, shellcheck, postgrest, tavern, pytest,
# pytest-xdist and psycopg2 at common-ci-configuration's versions; this file pins
# no tool version. It adds only what the base lacks:
#
#   + hive/tests_api (validate_response, the tavern tests' comparator) at TESTS_API_COMMIT
#   + haf_app_driver.py, the generic HAF block-processing driver that
#     scripts/process_blocks.sh runs in production images, from hive/common-ci-configuration
#     at DRIVER_COMMIT (checksum-pinned)
#   + the rewriter step's tools (.aidev/reptracker_rewriter.py): the filesystem of
#     REWRITER_BASE, the image Dockerfile.rewriter builds on, at /opt/rewriter (its
#     OpenResty runs through its own musl loader: the checks have no docker daemon), and
#     process_openapi.py, which scripts/openapi_rewrite.sh fetches, from
#     hive/common-ci-configuration at PROCESS_OPENAPI_COMMIT (checksum-pinned), with
#     the deepmerge and jsonpointer it needs. Both refs must equal the candidate's
#     (Dockerfile.rewriter's FROM, openapi_rewrite.sh's COMMON_CI_REF); the step fails
#     when they do not
#
# See .aidev/README.md.
ARG BASE_IMAGE
ARG REWRITER_BASE=registry.gitlab.syncad.com/hive/common-ci-configuration/nginx:1d952fd19118762d0e66f91953e194ff08e69bb0
FROM ${REWRITER_BASE} AS rewriter

FROM ${BASE_IMAGE}

ARG TESTS_API_COMMIT=455898cc3462d4e5ee2274756e5e3d44688fe204
ARG DRIVER_COMMIT=3839feb0c30846aa3ae262143f216a3c1a0fa20b
ARG REWRITER_BASE
ARG PROCESS_OPENAPI_COMMIT=1d952fd19118762d0e66f91953e194ff08e69bb0

RUN pip install --no-cache-dir \
        "https://gitlab.syncad.com/hive/tests_api/-/archive/${TESTS_API_COMMIT}/tests_api-${TESTS_API_COMMIT}.tar.gz" \
        deepmerge jsonpointer

ADD --chmod=755 \
    --checksum=sha256:55f82b1c0d024a02149ba2d0157d3b7394773631514d5117ebaa3446555dc8d7 \
    https://gitlab.syncad.com/hive/common-ci-configuration/-/raw/${DRIVER_COMMIT}/haf-app-tools/scripts/haf_app_driver.py \
    /usr/local/bin/haf_app_driver.py

COPY --from=rewriter / /opt/rewriter/
ADD --chmod=644 \
    --checksum=sha256:8d0db49d368e21b663a905ac363eb22d54547b72200e483ae30246374233b3aa \
    https://gitlab.syncad.com/hive/common-ci-configuration/-/raw/${PROCESS_OPENAPI_COMMIT}/haf-app-tools/python/process_openapi.py \
    /usr/local/share/process_openapi.py
ENV REPTRACKER_REWRITER_ROOT=/opt/rewriter \
    REPTRACKER_REWRITER_BASE=${REWRITER_BASE} \
    REPTRACKER_PROCESS_OPENAPI=/usr/local/share/process_openapi.py \
    REPTRACKER_PROCESS_OPENAPI_COMMIT=${PROCESS_OPENAPI_COMMIT}
ENV HOME=/tmp
ENTRYPOINT []
CMD ["bash"]
