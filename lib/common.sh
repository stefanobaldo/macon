#!/bin/sh
# Shared primitives. Sourced by every other component.

macon_die() {
    printf 'macon: %s\n' "$*" >&2
    exit 1
}

macon_warn() {
    printf 'macon: %s\n' "$*" >&2
}

# Terminates a whole process group, falling back to the single process when the
# target never became a group leader.
#
# `kill -- -PID` cannot reach a group that is not ours to signal: a process
# group id IS its leader's pid, and a pid held by a live process cannot be
# recycled onto anything else. So either PID leads a group -- the one started
# under job control below -- or the group does not exist and the fallback
# signals the process alone.
macon_kill_group() {
    kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null || :
}

# macOS ships no timeout(1). Run a command with a bound: background it in its
# own process group, background a killer, and reap whichever finishes first.
#
# Without this, a hung --busy-check blocks the poll loop, and a blocked
# loop never evaluates the hard ceiling: a hung user command would
# silently disable the whole safety mechanism.
#
# The process group is what makes that bound real rather than nominal, and this
# codebase paid to learn it. Signalling only the direct child leaves its
# children running, and a surviving grandchild inherits whatever the child's
# stdout was -- so `_x=$(macon_run_timeout ...)` blocked for as long as the
# command hung, with the bound enforced on a process the caller was no longer
# waiting for. `set -m` puts the command in a group of its own so the kill
# reaches the tree; it is switched back off immediately, because it is needed
# only while the job is being created.
#
# stdin is /dev/null explicitly. A non-interactive shell does that for a
# background command by itself, but only while job control is OFF -- turning it
# on would otherwise hand the command this process's stdin, and with a
# controlling terminal a background read is a SIGTTIN and a job stopped for
# good. Restating it keeps the bound independent of that interaction.
macon_run_timeout() {
    _to=$1
    shift
    case $- in
        *m*) _mon=1 ;;
        *) _mon=0 ;;
    esac
    set -m
    "$@" < /dev/null &
    _cmd_pid=$!
    [ "$_mon" -eq 1 ] || set +m
    (
        sleep "$_to"
        macon_kill_group "$_cmd_pid"
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
