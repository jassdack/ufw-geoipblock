#!/bin/bash
# Verifies which GeoIP rules install.sh generates from CSV files and manual port lists.
# Uses --dry-run, so it only needs root (for the installer's root check), not ipset or UFW.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Print "proto port [memo]" for each generated IPv4 DROP rule, in order.
summarize_v4_drops() {
    local line proto port memo
    while IFS= read -r line; do
        [[ $line =~ ^-A\ ufw-before-input\ -p\ ([a-z]+)\ --dport\ ([^ ]+)\ .*-j\ DROP$ ]] || continue
        proto=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
        memo=""
        [[ $line =~ --comment\ \"([^\"]*)\" ]] && memo=${BASH_REMATCH[1]}
        echo "$proto $port [$memo]"
    done
}

count_matching() {
    grep -cE -e "$1" <<< "$2" || true
}

echo "== D1: sample CSV plus edge cases"
CSV="$WORK_DIR/ports.csv"
cp "$REPO_DIR/ports.csv.sample" "$CSV"
# Make sure the appended rows start on their own line even if the sample lacks a trailing newline.
[ -n "$(tail -c1 "$CSV")" ] && echo >> "$CSV"
printf '%s\n' \
    '8443' \
    '9000,Only memo' \
    '# comment line' \
    '' \
    '7000,Memo, with comma,block' \
    '6000,Disabled,pass' >> "$CSV"
printf '5000,CRLF memo,block\r\n' >> "$CSV"

out=$(bash "$REPO_DIR/install.sh" --dry-run JP "$CSV" 2>&1)
check "dry-run exits 0" [ $? -eq 0 ]
expected="tcp 22 [SSH Access]
udp 22 [SSH Access]
tcp 80 [HTTP Web]
udp 80 [HTTP Web]
tcp 443 [HTTPS Secure]
udp 443 [HTTPS Secure]
tcp 8081 [File Browser UI]
udp 8081 [File Browser UI]
tcp 8443 []
udp 8443 []
tcp 9000 [Only memo]
udp 9000 [Only memo]
tcp 7000 [Memo, with comma]
udp 7000 [Memo, with comma]
tcp 5000 [CRLF memo]
udp 5000 [CRLF memo]"
check_eq "IPv4 DROP rules match the CSV (pass rows, comments and blank lines skipped)" \
    "$expected" "$(summarize_v4_drops <<< "$out")"
check_eq "one IPv4 LOG rule per DROP rule" "16" "$(count_matching '^-A ufw-before-input .*-j LOG' "$out")"
check_eq "IPv6 DROP rules mirror IPv4" "16" "$(count_matching '^-A ufw6-before-input .*-j DROP' "$out")"
check_eq "every DROP rule targets non-JP sources" "32" "$(count_matching '-m geoip ! --src-cc JP .*-j DROP' "$out")"

echo "== D2: manual port list"
out=$(bash "$REPO_DIR/install.sh" --dry-run JP 22,80,3000:3010 2>&1)
check "dry-run exits 0" [ $? -eq 0 ]
expected="tcp 22 []
udp 22 []
tcp 80 []
udp 80 []
tcp 3000:3010 []
udp 3000:3010 []"
check_eq "IPv4 DROP rules match the manual list" "$expected" "$(summarize_v4_drops <<< "$out")"
check_eq "IPv6 DROP rules mirror IPv4" "6" "$(count_matching '^-A ufw6-before-input .*-j DROP' "$out")"

echo "== D3: invalid DEFAULT_TIMEOUT is rejected"
for v in 0 2147484 2592000 abc -5; do
    out=$(DEFAULT_TIMEOUT=$v bash "$REPO_DIR/install.sh" --dry-run JP 22 2>&1)
    rc=$?
    check "DEFAULT_TIMEOUT=$v rejected" [ "$rc" -ne 0 ]
    check "DEFAULT_TIMEOUT=$v error message" grep -q "ERROR: DEFAULT_TIMEOUT must be" <<< "$out"
done

finish
