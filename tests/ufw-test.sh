#!/bin/bash
# Runs install.sh's rule injection and `ufw reload` step (steps 3/5 and 4/5 plus the reload)
# against a real UFW: rules that iptables can load stay in place; rules it cannot load are
# removed again and UFW is left running and enabled. xt_geoip is not available inside the
# container, so any `-m geoip` rule reproduces the "kernel module missing" failure.
# Must run as root with CAP_NET_ADMIN and the ufw package installed (tests/run.sh does this);
# it enables UFW inside the container and rewrites /etc/ufw/before*.rules and before.init.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Build a harness from the real installer: configuration, argument parsing, port parsing,
# the ipset setup (the Phase 1 rules need the sets), the rule injection and the reload step.
# It skips the lockout prompt, package installation, GeoIP database download, systemd and
# the dead man's switch.
HARNESS="$WORK_DIR/install-rules.sh"
{
    sed -n '1,/^# 3\. Safety Check/p' "$REPO_DIR/install.sh"
    sed -n '/^# 5\. ipset initialization/,/^# 6\. Non-destructive/p' "$REPO_DIR/install.sh"
    sed -n '/^# 6\. Non-destructive/,/^# 7\. Enable Automation/p' "$REPO_DIR/install.sh"
    sed -n '/^# 8\. Reload UFW/,/^# --- DEAD MAN/p' "$REPO_DIR/install.sh"
} > "$HARNESS"
for needle in '^process_port_entry()' '^ensure_ipset()' '^inject_rules()' '^if ! ufw reload'; do
    if ! grep -q "$needle" "$HARNESS"; then
        echo "ERROR: could not extract '$needle' from install.sh; were the section comments renamed?"
        exit 1
    fi
done
# The installer looks the templates up next to itself.
cp -r "$REPO_DIR/ufw" "$WORK_DIR/ufw"

# run_harness COUNTRY PORTS: like `install.sh COUNTRY PORTS`, output in $WORK_DIR/out.
run_harness() {
    bash "$HARNESS" "$@" > "$WORK_DIR/out" 2>&1
}

has_block() {
    grep -q '# === BEGIN GEOIPBLOCK ===' "$1"
}

v4_rules() { iptables -S ufw-before-input | grep '^-A'; }
v6_rules() { ip6tables -S ufw6-before-input | grep '^-A'; }

PASS_CSV="$WORK_DIR/pass.csv"
printf '22,SSH,pass\n80,HTTP,pass\n' > "$PASS_CSV"

echo "== U0: preconditions"
check "xt_geoip match is NOT available in the container" \
    grep -q "Couldn't load match .geoip" <<< "$(iptables -m geoip -h 2>&1)"
ufw --force enable > "$WORK_DIR/out" 2>&1
check "ufw can be enabled in the container" [ $? -eq 0 ]
check_not "stock before.rules already has a GeoIP block" has_block /etc/ufw/before.rules
if [ "$FAIL" -ne 0 ]; then
    cat "$WORK_DIR/out"
    finish
    exit 1
fi

echo "== U1: rules UFW can load stay in place (all CSV rows 'pass': Phase 1-3 only)"
TRUSTED_SUBNETS="192.0.2.0/24 2001:db8::/32" run_harness JP "$PASS_CSV"
check "exit 0" [ $? -eq 0 ]
check "UFW reported a reload" grep -q "Firewall reloaded" "$WORK_DIR/out"
check "block kept in before.rules" has_block /etc/ufw/before.rules
check "block kept in before6.rules" has_block /etc/ufw/before6.rules
check_eq "IPv4 chain starts with Phase 1-3 (ipset, conntrack, loopback, trusted subnet)" \
    "-A ufw-before-input -m set --match-set persistent_offenders src -j DROP
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-input -i lo -j ACCEPT
-A ufw-before-input -s 192.0.2.0/24 -j ACCEPT" "$(v4_rules | head -n 4)"
check_eq "IPv6 chain starts with Phase 1-3 on the ufw6-before-input chain" \
    "-A ufw6-before-input -m set --match-set persistent_offenders6 src -j DROP
-A ufw6-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw6-before-input -i lo -j ACCEPT
-A ufw6-before-input -s fe80::/10 -j ACCEPT
-A ufw6-before-input -s fc00::/7 -j ACCEPT
-A ufw6-before-input -s 2001:db8::/32 -j ACCEPT" "$(v6_rules | head -n 6)"
check "UFW's own rules still follow" grep -q -- '-m conntrack --ctstate INVALID' <<< "$(v4_rules)"
check "UFW stays enabled" grep -q '^ENABLED=yes' /etc/ufw/ufw.conf

echo "== U2: rules UFW cannot load (xt_geoip missing) are removed again and UFW restarted"
run_harness JP 22
check "exit 1" [ $? -eq 1 ]
check "explains what happened" grep -q "UFW could not load the new rules" "$WORK_DIR/out"
check "tells how to investigate" grep -q 'lsmod | grep xt_geoip' "$WORK_DIR/out"
check_not "block left in before.rules" has_block /etc/ufw/before.rules
check_not "block left in before6.rules" has_block /etc/ufw/before6.rules
check "UFW enabled at boot again (ENABLED=yes)" grep -q '^ENABLED=yes' /etc/ufw/ufw.conf
check "UFW status active" grep -q '^Status: active' <<< "$(ufw status)"
check "UFW's stock before.rules loaded (loopback rule present)" \
    grep -qxF -- '-A ufw-before-input -i lo -j ACCEPT' <<< "$(v4_rules)"
check "UFW's stock before6.rules loaded" grep -q -- '-m rt --rt-type 0 -j DROP' <<< "$(v6_rules)"
check_not "no leftover GeoIP/ipset rules loaded" grep -q -- '-m set\|-m geoip' <<< "$(v4_rules; v6_rules)"
check "ipset setup in before.init kept" grep -q 'BEGIN GEOIPBLOCK-INIT' /etc/ufw/before.init
ufw reload > "$WORK_DIR/out" 2>&1
check "a plain 'ufw reload' works again afterwards" grep -q "Firewall reloaded" "$WORK_DIR/out"

echo "== U3: a loadable configuration installs again after the failure"
TRUSTED_SUBNETS="" run_harness JP "$PASS_CSV"
check "exit 0" [ $? -eq 0 ]
check "block back in before.rules" has_block /etc/ufw/before.rules
check_eq "Phase 1-3 loaded without subnet rules (TRUSTED_SUBNETS=\"\"), followed by UFW's own rules" \
    "-A ufw-before-input -m set --match-set persistent_offenders src -j DROP
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-input -i lo -j ACCEPT
-A ufw-before-input -i lo -j ACCEPT" "$(v4_rules | head -n 4)"

finish
