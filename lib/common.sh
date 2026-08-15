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
