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

# The documented limit of macon_run_timeout, pinned rather than trusted: the
# kill reaches the process started here and NOT that process's children.
#
# This is a CHARACTERISATION test. It asserts a limitation, not a desirable
# property, and it is here because this exact shape already defeated a timeout
# in this codebase once -- the thermal sampler's, which was bounded and hung
# anyway. If someone teaches macon_run_timeout to kill a process group, the
# second assertion below SHOULD fail; update it deliberately rather than
# deleting it.
setup_state
_out="$MACON_STATE/timeout-out"

# Redirected to a file, the caller gets the bound it asked for. A grandchild
# that outlives the kill writes into a file nobody is waiting on.
_start=$(date +%s)
macon_run_timeout 1 sh -c 'sleep 4 & wait' > "$_out" 2>/dev/null
_elapsed=$(( $(date +%s) - _start ))
assert_ok "output to a file: the caller waits for the timeout, not the command" \
    test "$_elapsed" -lt 3

# Collected up a pipe, it does not. The surviving grandchild inherits the write
# end, so the substitution blocks until the GRANDCHILD exits and the bound is
# enforced on a process the caller is no longer waiting for.
_start=$(date +%s)
_ignored=$(macon_run_timeout 1 sh -c 'sleep 4 & wait' 2>/dev/null)
_elapsed=$(( $(date +%s) - _start ))
assert_ok "output up a pipe: the caller waits for the grandchild instead" \
    test "$_elapsed" -ge 3

teardown_state

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
