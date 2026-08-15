#!/bin/sh
# Proves the harness itself reports pass and failure correctly.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"

assert_eq "abc" "abc" "assert_eq accepts equal values"
assert_ok "true succeeds" true
assert_fail "false fails" false
assert_contains "hello world" "lo wo" "assert_contains finds a substring"
