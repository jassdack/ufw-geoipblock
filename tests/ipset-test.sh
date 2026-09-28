#!/bin/bash
# Exercises install.sh's ipset setup (step 3/5) against real ipset/iptables.
# Must run as root with CAP_NET_ADMIN (e.g. inside the container started by tests/run.sh);
# it creates ipsets and iptables rules and overwrites /etc/ufw/before.init.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

INIT_FILE=/etc/ufw/before.init
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Build a harness from the real installer: configuration, argument parsing and validation,
# then step 3/5 only (skipping packages, GeoIP DB, UFW rules and systemd).
HARNESS="$WORK_DIR/step3.sh"
{
    sed -n '1,/^# 2\. Parse Ports/p' "$REPO_DIR/install.sh"
    sed -n '/^# 5\. ipset initialization/,/^# 6\. Non-destructive/p' "$REPO_DIR/install.sh"
} > "$HARNESS"
if ! grep -q '^ensure_ipset()' "$HARNESS" || ! grep -q 'DEFAULT_TIMEOUT=' "$HARNESS"; then
    echo "ERROR: could not extract step 3/5 from install.sh; were the section comments renamed?"
    exit 1
fi

run_step3() {
    bash "$HARNESS" > "$WORK_DIR/out" 2>&1
}

timeout_of() {
    ipset list -t "$1" | sed -n 's/^Header:.* timeout \([0-9]\+\).*/\1/p'
}

# ipset test prints "Warning: X is in set" to stderr even on success.
in_set() {
    ipset test "$1" "$2" 2>/dev/null
}

remaining_timeout() {
    ipset list "$1" | awk -v ip="$2" '$1 == ip { print $3 }'
}

# Simulate a stock Ubuntu before.init: present but not executable.
mkdir -p /etc/ufw
printf '#!/bin/sh\nset -e\n' > "$INIT_FILE"
chmod 640 "$INIT_FILE"

echo "== I1: fresh install with the default timeout"
run_step3
check "exit 0" [ $? -eq 0 ]
check_eq "IPv4 set timeout" 2147483 "$(timeout_of persistent_offenders)"
check_eq "IPv6 set timeout" 2147483 "$(timeout_of persistent_offenders6)"
check "before.init made executable" [ -x "$INIT_FILE" ]
check "before.init recreates the set with 2147483" grep -q 'timeout 2147483 -exist' "$INIT_FILE"

echo "== I2: re-running with the same value is a no-op"
run_step3
check "exit 0" [ $? -eq 0 ]
check_not "no migration message" grep -q Updating "$WORK_DIR/out"

echo "== I3: new timeout while the sets hold entries and are referenced by iptables"
iptables -A INPUT -m set --match-set persistent_offenders src -j DROP
ip6tables -A INPUT -m set --match-set persistent_offenders6 src -j DROP
ipset add persistent_offenders 1.2.3.4
ipset add persistent_offenders 5.6.7.8 timeout 600
ipset add persistent_offenders6 2001:db8::1
check_not "precondition: a referenced set cannot be destroyed" ipset -q destroy persistent_offenders
DEFAULT_TIMEOUT=1209600 run_step3
check "exit 0" [ $? -eq 0 ]
check_eq "IPv4 set timeout updated" 1209600 "$(timeout_of persistent_offenders)"
check_eq "IPv6 set timeout updated" 1209600 "$(timeout_of persistent_offenders6)"
check "1.2.3.4 kept" in_set persistent_offenders 1.2.3.4
check "2001:db8::1 kept" in_set persistent_offenders6 2001:db8::1
t=$(remaining_timeout persistent_offenders 5.6.7.8)
check "5.6.7.8 keeps its own remaining timeout (<= 600, got '$t')" [ "${t:-999999}" -le 600 ]
check_not "no temporary set left behind" grep -q _tmp <(ipset list -n)
check "iptables rule still references the set" \
    iptables -C INPUT -m set --match-set persistent_offenders src -j DROP
check "before.init updated to 1209600" grep -q 'timeout 1209600 -exist' "$INIT_FILE"
check_not "old value removed from before.init" grep -q 2147483 "$INIT_FILE"
check_eq "before.init block not duplicated" 1 "$(grep -c 'BEGIN GEOIPBLOCK-INIT' "$INIT_FILE")"

echo "== I4: invalid values abort before touching ipset"
for v in 0 2592000 abc; do
    DEFAULT_TIMEOUT=$v run_step3
    check "DEFAULT_TIMEOUT=$v rejected" [ $? -ne 0 ]
done
check_eq "set unchanged after invalid runs" 1209600 "$(timeout_of persistent_offenders)"

echo "== I5: an existing set created without a timeout is migrated"
iptables -F INPUT
ip6tables -F INPUT
ipset destroy persistent_offenders
ipset create persistent_offenders hash:ip
ipset add persistent_offenders 9.9.9.9
run_step3
check "exit 0" [ $? -eq 0 ]
check_eq "timeout added" 2147483 "$(timeout_of persistent_offenders)"
check "9.9.9.9 kept" in_set persistent_offenders 9.9.9.9

echo "== I6: generated before.init works at boot (sets absent) and when re-run"
ipset destroy persistent_offenders
ipset destroy persistent_offenders6
"$INIT_FILE" start
check "boot run exit 0" [ $? -eq 0 ]
check_eq "boot recreated the IPv4 set" 2147483 "$(timeout_of persistent_offenders)"
check_eq "boot recreated the IPv6 set" 2147483 "$(timeout_of persistent_offenders6)"
"$INIT_FILE" start
check "second run with existing sets exit 0" [ $? -eq 0 ]

finish
