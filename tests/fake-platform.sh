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

plat_macos_major() { _v=$(fake_get macos_major); printf '%s\n' "${_v:-26}"; }

plat_pmset_read() { fake_get "$1"; }

plat_pmset_apply_ac() {
    fake_record "pmset_apply_ac $*"
    while [ $# -ge 2 ]; do
        fake_set "$1" "$2"
        shift 2
    done
}

plat_pmset_disablesleep() {
    fake_record "pmset_disablesleep $1"
    if [ "$1" = "1" ]; then fake_set sleep_disabled yes; else fake_set sleep_disabled no; fi
}

plat_sleep_disabled() { [ "$(fake_get sleep_disabled)" = "yes" ]; }

plat_power_source() { _v=$(fake_get power_source); printf '%s\n' "${_v:-ac}"; }

plat_battery_pct() { _v=$(fake_get battery_pct); printf '%s\n' "${_v:-100}"; }

plat_thermal_pressure() { _v=$(fake_get thermal); printf '%s\n' "${_v:-Nominal}"; }

plat_boot_time() { _v=$(fake_get boot_time); printf '%s\n' "${_v:-1700000000}"; }

plat_launchctl() { fake_record "launchctl $*"; }

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
