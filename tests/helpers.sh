#!/bin/sh
# Test assertions. Any failure prints to stderr and exits non-zero,
# which tests/run.sh records as a failed file.

_assert_fail() {
    printf '  FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || _assert_fail "$3 (expected '$1', got '$2')"
    printf '  ok: %s\n' "$3"
}

assert_ok() {
    _msg=$1
    shift
    if "$@"; then printf '  ok: %s\n' "$_msg"; else _assert_fail "$_msg (command failed)"; fi
}

assert_fail() {
    _msg=$1
    shift
    if "$@"; then _assert_fail "$_msg (command unexpectedly succeeded)"; else printf '  ok: %s\n' "$_msg"; fi
}

assert_contains() {
    case "$1" in
        *"$2"*) printf '  ok: %s\n' "$3" ;;
        *) _assert_fail "$3 (expected '$2' within '$1')" ;;
    esac
}

# Every test gets isolated state roots so nothing touches the real machine.
setup_state() {
    MACON_STATE=$(mktemp -d)
    MACON_RUN=$(mktemp -d)
    export MACON_STATE MACON_RUN
}

teardown_state() {
    [ -n "$MACON_STATE" ] && rm -rf "$MACON_STATE"
    [ -n "$MACON_RUN" ] && rm -rf "$MACON_RUN"
}
