#!/bin/sh
# Shared primitives. Sourced by every other component.

macon_die() {
    printf 'macon: %s\n' "$*" >&2
    exit 1
}

macon_warn() {
    printf 'macon: %s\n' "$*" >&2
}

# macOS ships no timeout(1). Run a command with a bound: background it,
# background a killer, and reap whichever finishes first.
#
# Without this, a hung --busy-check blocks the poll loop, and a blocked
# loop never evaluates the hard ceiling: a hung user command would
# silently disable the whole safety mechanism.
#
# KNOWN LIMIT, and it has already cost this project once: the kill reaches the
# process started here and NOT that process's children. Two consequences.
#
#   1. Do NOT collect this function's output through a command substitution
#      when the command can spawn children. A surviving grandchild inherits the
#      pipe and holds it open, so `_x=$(macon_run_timeout ...)` blocks for as
#      long as the command hangs -- the bound is still enforced on the child and
#      still useless to the caller. Redirect to a file and read the file;
#      _helper_sample_thermal in libexec/macon-helper is the worked example.
#   2. A user command that spawns children leaves them running after the
#      timeout fires. That is a leak, not a hang, as long as (1) is respected.
macon_run_timeout() {
    _to=$1
    shift
    "$@" &
    _cmd_pid=$!
    (
        sleep "$_to"
        kill -TERM "$_cmd_pid" 2>/dev/null
    ) &
    _killer_pid=$!
    wait "$_cmd_pid" 2>/dev/null
    _rc=$?
    kill -TERM "$_killer_pid" 2>/dev/null
    wait "$_killer_pid" 2>/dev/null
    return "$_rc"
}

# Injectable clock. Poll-order tests must not wait for real time to pass.
macon_now() {
    if [ -n "${MACON_FAKE_NOW:-}" ]; then
        printf '%s\n' "$MACON_FAKE_NOW"
    else
        date +%s
    fi
}

macon_new_session_id() {
    printf '%s-%s\n' \
        "$(date -u +%Y%m%dT%H%M%SZ)" \
        "$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}
