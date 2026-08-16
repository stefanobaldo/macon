#!/bin/sh
# Drop-in replacement for lib/platform.sh. Same function names and
# signatures, backed by scripted state under $MACON_STATE/fake.
# Records every mutating call so tests can assert on call shape.

FAKE_DIR="$MACON_STATE/fake"
mkdir -p "$FAKE_DIR"
: > "$FAKE_DIR/calls"

fake_set() {
    printf '%s\n' "$2" > "$FAKE_DIR/$1"
}

fake_get() {
    if [ -f "$FAKE_DIR/$1" ]; then cat "$FAKE_DIR/$1"; fi
}

fake_record() {
    printf '%s\n' "$*" >> "$FAKE_DIR/calls"
}

fake_calls() {
    cat "$FAKE_DIR/calls"
}

# Tests assert on the calls made by one action at a time, so they need to clear
# the log between phases. Going through this helper keeps the fake's internal
# layout an implementation detail instead of pinning it in every test file.
fake_reset_calls() {
    : > "$FAKE_DIR/calls"
}

# grep -c prints "0" and exits NON-ZERO when nothing matches. The count must
# therefore be taken from stdout and the status discarded: a `|| printf '0\n'`
# fallback would append a second zero to the one grep already printed, and
# every "this call was never made" assertion would compare against "0\n0".
fake_call_count() {
    if [ -f "$FAKE_DIR/calls" ]; then
        grep -c "$1" "$FAKE_DIR/calls" || :
    else
        printf '0\n'
    fi
}

# Returns a scripted value exactly as scripted, EMPTY INCLUDED, and falls back
# to the default only for a key no test has touched. `${_v:-default}` cannot do
# that, and "this reader returned nothing" is a real state for several of them:
# a Mac with no battery, a sysctl that failed, a sw_vers that did not answer.
# A fake that cannot express it leaves every caller's guard against it untested.
fake_get_or() {
    if [ -f "$FAKE_DIR/$1" ]; then
        fake_get "$1"
    else
        printf '%s\n' "$2"
    fi
}

plat_macos_major() { fake_get_or macos_major 26; }

plat_pmset_read() { fake_get "$1"; }

# Scripted failure: `fake_set fail_<call> 1` makes that call record itself and
# return non-zero WITHOUT changing state, which is what a rejected pmset
# invocation does. Rollback and keep-the-snapshot paths are unreachable
# otherwise, and they are the paths that only run when something has gone
# wrong -- exactly the ones worth having under test.
_fake_should_fail() {
    [ "$(fake_get "fail_$1")" = "1" ]
}

plat_pmset_apply_ac() {
    fake_record "pmset_apply_ac $*"
    _fake_should_fail pmset_apply_ac && return 1
    while [ $# -ge 2 ]; do
        fake_set "$1" "$2"
        shift 2
    done
}

plat_pmset_disablesleep() {
    fake_record "pmset_disablesleep $1"
    _fake_should_fail pmset_disablesleep && return 1
    if [ "$1" = "1" ]; then fake_set sleep_disabled yes; else fake_set sleep_disabled no; fi
}

plat_sleep_disabled() { [ "$(fake_get sleep_disabled)" = "yes" ]; }

plat_clamshell_closed() { [ "$(fake_get clamshell)" = "closed" ]; }

plat_display_lit() { [ "$(fake_get display)" = "lit" ]; }

# Recorded like the pmset writers, because "was the display blanked, and how
# many times" is exactly what the watch has to be pinned on: firing twice for
# one lid close is as wrong as not firing at all.
plat_display_sleep_now() {
    fake_record "display_sleep_now"
    _fake_should_fail display_sleep_now && return 1
    fake_set display dark
}

plat_power_source() { fake_get_or power_source ac; }

plat_battery_pct() { fake_get_or battery_pct 100; }

plat_thermal_pressure() { fake_get_or thermal Nominal; }

plat_boot_time() { fake_get_or boot_time 1700000000; }

plat_launchctl() { fake_record "launchctl $*"; }

# Scripted process table: `fake_set proc_<pid> "<command line>"` makes that PID
# live with that command, and an unscripted PID is simply not running. Matching
# goes through grep exactly as the real implementation does, so a test cannot
# pass here on pattern semantics the real ps|grep would not honour.
plat_process_matches() {
    _cmd=$(fake_get "proc_$1")
    [ -n "$_cmd" ] || return 1
    printf '%s\n' "$_cmd" | grep -q "$2"
}

# Writes N stub plists into DEST, where N is scripted by `fake_set pmprefs_files N`
# (default 1), and fails when N is zero — mirroring the real unmatched-glob case.
plat_backup_pmprefs() {
    fake_record "backup_pmprefs $1"
    _n=$(fake_get pmprefs_files)
    _n=${_n:-1}
    _i=0
    while [ "$_i" -lt "$_n" ]; do
        _i=$((_i + 1))
        printf 'stub\n' > "$1/com.apple.PowerManagement.$_i.plist"
    done
    [ "$_n" -gt 0 ]
}
