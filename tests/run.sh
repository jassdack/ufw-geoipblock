#!/bin/bash
# Runs the test suite inside a disposable Ubuntu container.
#
# Requirements: Docker, and the host kernel modules ip_set, ip_set_hash_ip and xt_set
# (a container cannot load them itself; load them with
#  `sudo modprobe -a ip_set ip_set_hash_ip xt_set` if the ipset tests fail to create sets).
# The UFW tests enable ufw inside the container, which only touches the container's own
# network namespace; xt_geoip is deliberately not available there (see tests/ufw-test.sh).
#
# Usage: tests/run.sh            # default image ubuntu:24.04
#        TEST_IMAGE=debian:12 tests/run.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${TEST_IMAGE:-ubuntu:24.04}

echo "--- Running tests in $IMAGE ---"
docker run --rm \
    --cap-add NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    -v "$REPO_DIR":/src:ro \
    "$IMAGE" bash -c '
        set -e
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ipset iptables iproute2 ufw >/dev/null
        ipset --version
        ufw version | head -n 1
        rc=0
        bash /src/tests/dry-run-test.sh || rc=1
        bash /src/tests/inject-test.sh || rc=1
        bash /src/tests/ipset-test.sh || rc=1
        bash /src/tests/ufw-test.sh || rc=1
        exit $rc'
