#!/bin/bash
# Verifies the rule block that install.sh's inject_rules() writes into before.rules and
# before6.rules: the template contents (loopback, phase order), TRUSTED_SUBNETS handling
# and idempotency. It works on stand-in copies of the rules files, so it needs neither
# root nor UFW, only `ip` (iproute2) and perl like the installer itself.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Harness: the real inject_rules() under the installer's shell options (set -u matters for
# the TRUSTED_SUBNETS expansion). Usage: bash harness RULES_FILE RULES_BLOCK TEMPLATE
HARNESS="$WORK_DIR/inject.sh"
{
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    sed -n '/^inject_rules()/,/^}/p' "$REPO_DIR/install.sh"
    echo 'inject_rules "$@"'
} > "$HARNESS"
if ! grep -q '^inject_rules()' "$HARNESS"; then
    echo "ERROR: could not extract inject_rules() from install.sh; was the function renamed?"
    exit 1
fi

V4_TEMPLATE="$REPO_DIR/ufw/geoip-rules.template"
V6_TEMPLATE="$REPO_DIR/ufw/geoip-rules6.template"
V4_RULE='-A ufw-before-input -p tcp --dport 22 -m geoip ! --src-cc JP -j DROP'
V6_RULE='-A ufw6-before-input -p tcp --dport 22 -m geoip ! --src-cc JP -j DROP'
B4="$WORK_DIR/before.rules"
B6="$WORK_DIR/before6.rules"   # inject_rules picks the address family from the file name

# fresh_rules FILE [6]: a minimal stand-in for UFW's stock before.rules / before6.rules.
fresh_rules() {
    local file=$1 t=${2:-}
    cat > "$file" << EOF
*filter
:ufw${t}-before-input - [0:0]
:ufw${t}-before-output - [0:0]
:ufw${t}-before-forward - [0:0]
# End required lines
-A ufw${t}-before-input -i lo -j ACCEPT
COMMIT
EOF
}

inject_v4() { bash "$HARNESS" "$1" "$V4_RULE" "$V4_TEMPLATE"; }
inject_v6() { bash "$HARNESS" "$1" "$V6_RULE" "$V6_TEMPLATE"; }

# The injected block of FILE, markers included.
block_of() {
    sed -n '/# === BEGIN GEOIPBLOCK ===/,/# === END GEOIPBLOCK ===/p' "$1"
}

# The "-s SUBNET -j ACCEPT" rules of a block (Phase 3), in order.
subnet_rules() {
    grep -E -- '^-A ufw6?-before-input -s ' <<< "$1" || true
}

# Line number of the first line matching PATTERN in TEXT (0 if none).
line_of() {
    local n
    n=$(grep -nF -- "$1" <<< "$2" | head -n 1 | cut -d: -f1)
    echo "${n:-0}"
}

unset TRUSTED_SUBNETS
detected=$(ip -o -f inet addr show | awk '/scope global/ {print $4}')

echo "== J1: IPv4 block with TRUSTED_SUBNETS unset (auto-detected subnets)"
fresh_rules "$B4"
inject_v4 "$B4"
check "inject exits 0" [ $? -eq 0 ]
block=$(block_of "$B4")
check "block injected" [ -n "$block" ]
check "Phase 1: ipset blacklist" grep -qxF -- '-A ufw-before-input -m set --match-set persistent_offenders src -j DROP' <<< "$block"
check "Phase 2: conntrack" grep -qxF -- '-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' <<< "$block"
check "Phase 3: loopback accepted (127.0.0.1 belongs to no country)" grep -qxF -- '-A ufw-before-input -i lo -j ACCEPT' <<< "$block"
check "Phase 4: generated GeoIP rule" grep -qxF -- "$V4_RULE" <<< "$block"
check "loopback rule comes before the GeoIP rules" \
    [ "$(line_of '-i lo -j ACCEPT' "$block")" -lt "$(line_of '-m geoip' "$block")" ]
check "precondition: the container has a global IPv4 address to detect" [ -n "$detected" ]
for s in $detected; do
    check "detected subnet $s accepted" grep -qxF -- "-A ufw-before-input -s $s -j ACCEPT" <<< "$block"
done
check "subnet rules come before the GeoIP rules" \
    [ "$(line_of ' -s ' "$block")" -lt "$(line_of '-m geoip' "$block")" ]
check_eq "block starts right after the chain definitions" ":ufw-before-forward - [0:0]" \
    "$(grep -B2 -F '# === BEGIN GEOIPBLOCK ===' "$B4" | head -n 1)"
check_eq "block comes before UFW's own rules" "-A ufw-before-input -m set --match-set persistent_offenders src -j DROP" \
    "$(grep -m1 '^-A ' "$B4")"
check "file still ends with COMMIT" [ "$(tail -n 1 "$B4")" = "COMMIT" ]

echo "== J2: TRUSTED_SUBNETS=\"\" disables the subnet trust rules but keeps the rest"
fresh_rules "$B4"
fresh_rules "$B6" 6
TRUSTED_SUBNETS="" inject_v4 "$B4"
check "IPv4 inject exits 0 under set -u" [ $? -eq 0 ]
TRUSTED_SUBNETS="" inject_v6 "$B6"
check "IPv6 inject exits 0 under set -u" [ $? -eq 0 ]
block=$(block_of "$B4")
check_eq "no subnet rules in the IPv4 block" "" "$(subnet_rules "$block")"
check "IPv4 loopback rule kept" grep -qxF -- '-A ufw-before-input -i lo -j ACCEPT' <<< "$block"
check "IPv4 GeoIP rule kept" grep -qxF -- "$V4_RULE" <<< "$block"
block=$(block_of "$B6")
check_eq "IPv6 block keeps only the fixed link-local/ULA rules" \
    "-A ufw6-before-input -s fe80::/10 -j ACCEPT
-A ufw6-before-input -s fc00::/7 -j ACCEPT" "$(subnet_rules "$block")"
check "IPv6 loopback rule kept" grep -qxF -- '-A ufw6-before-input -i lo -j ACCEPT' <<< "$block"
check "IPv6 GeoIP rule kept" grep -qxF -- "$V6_RULE" <<< "$block"

echo "== J3: explicit TRUSTED_SUBNETS is split by address family and replaces auto-detection"
fresh_rules "$B4"
fresh_rules "$B6" 6
TRUSTED_SUBNETS="10.0.0.0/8 2001:db8::/32 192.168.1.0/24" inject_v4 "$B4"
check "IPv4 inject exits 0" [ $? -eq 0 ]
TRUSTED_SUBNETS="10.0.0.0/8 2001:db8::/32 192.168.1.0/24" inject_v6 "$B6"
check "IPv6 inject exits 0" [ $? -eq 0 ]
check_eq "IPv4 block: the IPv4 subnets only, in order" \
    "-A ufw-before-input -s 10.0.0.0/8 -j ACCEPT
-A ufw-before-input -s 192.168.1.0/24 -j ACCEPT" "$(subnet_rules "$(block_of "$B4")")"
check_eq "IPv6 block: fixed rules plus the IPv6 subnet, on the ufw6-before-input chain" \
    "-A ufw6-before-input -s fe80::/10 -j ACCEPT
-A ufw6-before-input -s fc00::/7 -j ACCEPT
-A ufw6-before-input -s 2001:db8::/32 -j ACCEPT" "$(subnet_rules "$(block_of "$B6")")"
for s in $detected; do
    check_not "detected subnet $s not added when TRUSTED_SUBNETS is set" grep -qF -- "-s $s " "$B4"
done

echo "== J4: re-running replaces the block instead of adding a second one"
inject_v4 "$B4"
check "inject exits 0" [ $? -eq 0 ]
check_eq "one BEGIN marker" 1 "$(grep -c '# === BEGIN GEOIPBLOCK ===' "$B4")"
check_eq "one END marker" 1 "$(grep -c '# === END GEOIPBLOCK ===' "$B4")"
check_not "old explicit subnet gone" grep -qF -- '-s 10.0.0.0/8 ' "$B4"
for s in $detected; do
    check "detected subnet $s back" grep -qxF -- "-A ufw-before-input -s $s -j ACCEPT" "$B4"
done
check_eq "UFW's own rules untouched" "1" "$(grep -c -- '^-A ufw-before-input -i lo -j ACCEPT' <<< "$(sed '/# === BEGIN GEOIPBLOCK ===/,/# === END GEOIPBLOCK ===/d' "$B4")")"

finish
