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

# The bound has to hold for the command's CHILDREN too, and this pair is what
# says so. It used to be a characterisation test asserting the opposite -- the
# kill reached the direct child only -- because that exact shape had already
# defeated a timeout in this codebase once: the thermal sampler's, which was
# bounded and hung anyway. macon_run_timeout now starts the command in its own
# process group, so both halves below are the same claim from two directions,
# and the second is the one that used to fail.
setup_state
_out="$MACON_STATE/timeout-out"

_start=$(date +%s)
macon_run_timeout 1 sh -c 'sleep 4 & wait' > "$_out" 2>/dev/null
_elapsed=$(( $(date +%s) - _start ))
assert_ok "output to a file: the caller waits for the timeout, not the command" \
    test "$_elapsed" -lt 3

# The half that costs a caller its timeout when only the direct child is
# signalled: a surviving grandchild inherits the write end of the substitution's
# pipe and holds it open, so the caller blocks for as long as the command hangs.
_start=$(date +%s)
_ignored=$(macon_run_timeout 1 sh -c 'sleep 4 & wait' 2>/dev/null)
_elapsed=$(( $(date +%s) - _start ))
assert_ok "output up a pipe: the caller still gets the bound it asked for" \
    test "$_elapsed" -lt 3

# The grandchild is gone rather than merely no longer holding the pipe. A leaked
# child of a --busy-check is a process the poll loop spawns once per interval and
# never reaps.
_pidf="$MACON_STATE/timeout-grandchild.pid"
macon_run_timeout 1 sh -c "sleep 4 & printf '%s\n' \"\$!\" > $_pidf; wait" \
    >/dev/null 2>&1
assert_fail "the command's own child was killed with it" \
    sh -c "kill -0 $(cat "$_pidf") 2>/dev/null"

# stdin is /dev/null, not this process's.
#
# Read as a property, not as a mutation test: removing the explicit redirect in
# macon_run_timeout does NOT make this fail, because a non-interactive shell
# already nulls a background command's input -- but only while job control is
# off, and turning job control on is exactly what this function now does. Which
# of the two rules wins turned out to depend on whether the call is inside a
# subshell, so the redirect is there to make the answer not depend on that, and
# the assertion is here to notice if the answer ever changes.
_seen=$(printf 'SECRET\n' | { macon_run_timeout 5 sh -c 'cat'; } 2>/dev/null)
assert_eq "" "$_seen" "the bounded command does not inherit the caller's stdin"

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
