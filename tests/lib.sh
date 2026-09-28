#!/bin/bash
# Shared helpers for the test scripts. Source this file; do not run it directly.

PASS=0
FAIL=0

# check DESCRIPTION COMMAND [ARGS...]: pass if the command succeeds.
check() {
    local desc=$1
    shift
    if "$@"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# check_not DESCRIPTION COMMAND [ARGS...]: pass if the command fails.
check_not() {
    local desc=$1
    shift
    if "$@"; then
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# check_eq DESCRIPTION EXPECTED ACTUAL: pass if both strings are equal; show a diff otherwise.
check_eq() {
    local desc=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        diff <(echo "$expected") <(echo "$actual") | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}

finish() {
    echo
    echo "RESULT ($(basename "$0")): $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}
