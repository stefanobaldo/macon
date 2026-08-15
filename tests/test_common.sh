#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"

# A fast command returns its own status.
macon_run_timeout 5 true
assert_eq "0" "$?" "run_timeout returns 0 for a fast successful command"

macon_run_timeout 5 false
assert_eq "1" "$?" "run_timeout returns 1 for a fast failing command"

# A hung command is killed rather than blocking the caller.
_start=$(date +%s)
macon_run_timeout 1 sleep 30
_rc=$?
_elapsed=$(( $(date +%s) - _start ))
assert_eq "143" "$_rc" "run_timeout reports 143 when it kills the command"
assert_ok "run_timeout returns in under 5s for a 30s command" test "$_elapsed" -lt 5

# The clock is injectable so poll-order tests are deterministic.
MACON_FAKE_NOW=1700000000
export MACON_FAKE_NOW
assert_eq "1700000000" "$(macon_now)" "macon_now honours MACON_FAKE_NOW"
unset MACON_FAKE_NOW
assert_ok "macon_now returns a plausible epoch without the override" \
    test "$(macon_now)" -gt 1700000000

# Session ids are unique and shaped for sorting.
_a=$(macon_new_session_id)
_b=$(macon_new_session_id)
assert_fail "two session ids differ" test "$_a" = "$_b"
assert_ok "session id matches the expected shape" \
    sh -c "printf '%s' \"$_a\" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'"
