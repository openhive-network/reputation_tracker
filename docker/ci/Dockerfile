# syntax=registry.gitlab.syncad.com/hive/common-ci-configuration/dockerfile:1.5
FROM registry.gitlab.syncad.com/hive/common-ci-configuration/docker-builder:latest

COPY --from=registry.gitlab.syncad.com/hive/common-ci-configuration/benchmark-test-runner:latest \
  --link /opt/tools/jmeter /opt/tools/jmeter
COPY --from=registry.gitlab.syncad.com/hive/common-ci-configuration/benchmark-test-runner:latest \
  --link /opt/tools/m2u /opt/tools/m2u

USER root
RUN <<EOF
  # Install system dependencies
  # Alpine v3.20 has Python 3.12, which is compatible with tests_api
  # util-linux provides flock with NFS support (BusyBox flock fails on NFS)
  apk add --no-cache bash ca-certificates openjdk11-jre postgresql-client python3 py3-pip py3-psycopg2 util-linux

  # Create symlinks in bin directory
  ln -s /opt/tools/jmeter/bin/jmeter.sh /usr/bin/jmeter
  ln -s /opt/tools/m2u/m2u /usr/bin/m2u
EOF

USER hived
CMD ["/bin/bash"]