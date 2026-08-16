#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
MACON_FAILSAFE_SOURCED=1
export MACON_FAILSAFE_SOURCED
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=tests/fake-platform.sh
. "$TESTS_DIR/fake-platform.sh"
# shellcheck source=lib/session.sh
. "$MACON_LIB/session.sh"
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
# shellcheck source=lib/records.sh
. "$MACON_LIB/records.sh"
# shellcheck source=libexec/failsafe.sh
. "$REPO_DIR/libexec/failsafe.sh"

MACON_FAILSAFE_LOG="$MACON_STATE/failsafe.log"
export MACON_FAILSAFE_LOG
MACON_FAKE_NOW=1700000000
export MACON_FAKE_NOW

arm() {
    fake_set sleep 0
    fake_set disksleep 0
    fake_set powernap 0
    fake_set sleep_disabled yes
    fake_set fail_pmset_apply_ac 0
    fake_set fail_pmset_disablesleep 0
    printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$(snap_path)"
    fake_reset_calls
    : > "$MACON_FAILSAFE_LOG"
}

# --- real-boot detection ----------------------------------------------------
#
# RunAtLoad fires on `launchctl bootstrap` too, not only at boot. Without
# this guard, installing the failsafe during an active session would revert
# it and delete the snapshot -- the one piece of state nothing can rebuild.

fake_set boot_time 1699999970          # 30s of uptime
assert_ok "at a real boot the failsafe runs" failsafe_should_run

fake_set boot_time 1699913600          # ~24h of uptime
assert_fail "long after boot the failsafe does nothing" failsafe_should_run

# The window's edge, both sides, so the comparison cannot silently become
# the wrong operator.
fake_set boot_time 1699999400          # exactly 600s
assert_ok "the last second of the window still counts as a boot" failsafe_should_run
fake_set boot_time 1699999399          # 601s
assert_fail "one second past the window does not" failsafe_should_run

# The classic parsing trap: kern.boottime prints "{ sec = N, usec = M }", and a
# greedy pattern matches "usec" and returns MICROSECONDS. The resulting uptime
# is near 1.8 billion seconds, so the guard aborts at every real boot too.
# Asserted inline: `sh -c` would not carry the shell functions, and the
# assertion would pass on "command not found" instead of on the guard.
fake_set boot_time 242957
assert_fail "a microsecond-shaped boot time is not treated as a boot" \
    failsafe_should_run

# A live helper settles it before the clock is consulted at all. RunAtLoad
# fires on `launchctl bootstrap` as well as at boot, and inside the first ten
# minutes of uptime the window below cannot tell the two apart -- which is
# exactly when `macon failsafe install`, or re-running install.sh to upgrade,
# reaches it. The run directory is cleared at boot, so a helper polling from it
# is proof that this is not one.
mkdir -p "$(sess_run_dir)"
fake_set boot_time 1699999970          # 30s of uptime: the window says "boot"
printf '4242\n' > "$(sess_pid_path)"
fake_set proc_4242 '/usr/local/libexec/macon/macon-helper start /var/run/macon/session.conf'
assert_fail "a live session helper stops the failsafe even inside the window" \
    failsafe_should_run

arm
printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$(snap_path)"
failsafe_run
assert_eq "0" "$(fake_call_count 'pmset')" "it touches nothing while a session is live"
assert_ok "the live session's snapshot survives" snap_exists
assert_ok "and the machine is left exactly as the session left it" plat_sleep_disabled
assert_contains "$(cat "$MACON_FAILSAFE_LOG")" "not a boot" \
    "and the log says why it stood down"

rm -f "$(sess_pid_path)"
fake_set proc_4242 ""
assert_ok "with the session gone it is a boot again" failsafe_should_run

# A boot time in the future is a clock that cannot be reasoned from.
fake_set boot_time 1700000600
assert_fail "a boot time in the future is not treated as a boot" failsafe_should_run

# Unreadable, and leading zeros -- which `[` reads as decimal and $(( )) reads
# as octal, so the two halves of this function would disagree about the number.
fake_set boot_time ""
assert_fail "an unreadable boot time is not treated as a boot" failsafe_should_run
fake_set boot_time "0242957"
assert_fail "a zero-padded boot time is refused rather than read as octal" \
    failsafe_should_run

# Every refusal has to say why: this runs at boot with nobody watching, and the
# log is the only account of what it decided.
assert_ok "the failsafe logs why it stood down" test -s "$MACON_FAILSAFE_LOG"

# --- standing down ----------------------------------------------------------

arm
fake_set boot_time 1699913600
failsafe_run
assert_eq "0" "$(fake_call_count 'pmset')" "no pmset calls when it is not a boot"
assert_ok "the snapshot survives a non-boot invocation" snap_exists
assert_ok "the machine is left exactly as it was" plat_sleep_disabled

# --- restoring at a real boot -----------------------------------------------

arm
fake_set boot_time 1699999970
failsafe_run
assert_contains "$(fake_calls)" "pmset_disablesleep 0" "the failsafe clears disablesleep"
assert_eq "1" "$(fake_call_count 'pmset_apply_ac')" "the failsafe restores in one call"
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 1 disksleep 10 powernap 1" \
    "the failsafe restores the saved values"
assert_eq "1" "$(plat_pmset_read sleep)" "the machine is back to its saved values"
assert_fail "the snapshot is cleared after a boot restore" snap_exists

# Clearing disablesleep is the call that gives the machine its ability to sleep
# back, so it cannot be conditional on having something to restore.
arm
rm -f "$(snap_path)"
fake_set boot_time 1699999970
failsafe_run
assert_contains "$(fake_calls)" "pmset_disablesleep 0" \
    "the failsafe clears disablesleep even with no snapshot"
assert_fail "the machine can sleep again" plat_sleep_disabled
assert_eq "0" "$(fake_call_count 'pmset_apply_ac')" "with no snapshot there is nothing to apply"
# "there was nothing to restore" and "what there was could not be used" are
# different mornings, and the log is where that distinction has to survive.
assert_contains "$(cat "$MACON_FAILSAFE_LOG")" "no snapshot to restore" \
    "the log distinguishes an absent snapshot"

arm
printf 'sleep=x\ndisksleep=y\npowernap=z\n' > "$(snap_path)"
fake_set boot_time 1699999970
failsafe_run
assert_eq "0" "$(fake_call_count 'pmset_apply_ac')" \
    "a snapshot with no usable values reaches pmset with nothing"
assert_ok "an unusable snapshot is kept rather than discarded" snap_exists
assert_contains "$(cat "$MACON_FAILSAFE_LOG")" "no usable values" \
    "the log distinguishes an unusable snapshot from an absent one"

# The snapshot is deleted because it has been consumed. If applying it FAILED
# it has not been consumed, and deleting it there destroys the only record of
# the values while the machine is still holding the wrong ones.
arm
fake_set boot_time 1699999970
fake_set fail_pmset_apply_ac 1
failsafe_run
assert_ok "a failed restore keeps the snapshot" snap_exists
assert_eq "sleep 1 disksleep 10 powernap 1" "$(snap_restore_args)" \
    "the kept snapshot is still intact"

arm
fake_set boot_time 1699999970
fake_set fail_pmset_disablesleep 1
failsafe_run
assert_ok "a failed disablesleep clear keeps the snapshot" snap_exists

# --- finding the snapshot ---------------------------------------------------
#
# The snapshot lives under the USER's state directory. launchd starts a system
# daemon with no user context, so `$HOME/.local/state/macon` resolves to a path
# that does not exist and the failsafe would find nothing to restore -- and
# would restore nothing, silently, at exactly the moment it is the only thing
# left holding the invariant.

ALICE="$MACON_STATE/Users/alice/.local/state/macon"
BOB="$MACON_STATE/Users/bob/.local/state/macon"
mkdir -p "$ALICE" "$BOB"
printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$ALICE/snapshot"
printf 'sleep=2\ndisksleep=20\npowernap=1\n' > "$BOB/snapshot"
touch -t 202601010000 "$ALICE/snapshot"
touch -t 202602010000 "$BOB/snapshot"

assert_fail "no candidate holding a snapshot is a failure to report" \
    failsafe_find_state "$MACON_STATE/nowhere"
assert_eq "$ALICE" "$(failsafe_find_state "$MACON_STATE/nowhere" "$ALICE")" \
    "a candidate that does not exist is skipped"
# Only one machine-wide power configuration exists, so when two users each hold
# a snapshot the one written last is the one describing the machine.
assert_eq "$BOB" "$(failsafe_find_state "$ALICE" "$BOB")" \
    "the most recently written snapshot wins"
assert_eq "$BOB" "$(failsafe_find_state "$BOB" "$ALICE")" \
    "and wins regardless of the order the candidates are offered in"

# Wired in, not merely present: with no MACON_STATE -- which is how launchd
# starts a system daemon -- the restore has to find the snapshot on its own.
_saved_state=$MACON_STATE
printf 'sleep=3\ndisksleep=30\npowernap=1\n' > "$BOB/snapshot"
MACON_STATE_ROOTS="$ALICE $BOB"
unset MACON_STATE
fake_set boot_time 1699999970
fake_set sleep_disabled yes
fake_set fail_pmset_apply_ac 0
fake_set fail_pmset_disablesleep 0
fake_reset_calls
failsafe_run
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 3 disksleep 30 powernap 1" \
    "with no state directory given, the failsafe finds the snapshot and restores it"
assert_fail "the discovered snapshot is consumed like any other" test -f "$BOB/snapshot"
MACON_STATE=$_saved_state
export MACON_STATE

# --- no user context --------------------------------------------------------
#
# launchd starts a system daemon with no user context. Every state path here
# defaults to $HOME/..., and under `set -u` an unset HOME is fatal rather than
# absent. Sourced rather than run: running it would drive the REAL platform
# layer against this machine.
#
# This began as defence against a behaviour nobody had confirmed. It is now
# measured: on a real install, `launchctl print system/local.macon.failsafe`
# reports the daemon's environment as MACON_LIB, MACON_LIBEXEC, MACON_STATE,
# OSLogRateLimit and XPC_SERVICE_NAME -- and no HOME. The default is
# load-bearing, not belt-and-braces.
#
# The failure it prevents is also worse than "the shell exits": removing this
# line and starting the script the way launchd does logs
# "boot detected: disablesleep cleared" and then "no snapshot to restore",
# with `snapshot.sh: HOME: unbound variable` on stderr where nobody reads it.
# snap_path() dies inside a command substitution, so snap_exists() merely reads
# false -- the daemon reports a clean run while a snapshot sits on disk and the
# machine keeps its zeroed sleep timers. A default install masks it, because the
# plist names MACON_STATE and the $HOME branch is never taken; what this
# protects is the safety net underneath that.
# The single quotes are the point: $HOME must be expanded by the child shell,
# after it has sourced the file, not by this one before it starts.
# shellcheck disable=SC2016
assert_eq "/var/root" \
    "$(env -u HOME sh -c '. "$1"; printf "%s\n" "$HOME"' _ "$REPO_DIR/libexec/failsafe.sh")" \
    "the failsafe defines a home rather than inheriting none"

# --- the night that ended in a panic ----------------------------------------
#
# A session that died with the machine leaves a samples file and NO index row:
# the row is written when a session ends, and the reboot clears only /var/run,
# while both of these files live in the user's state directory. That asymmetry
# is the detector, and it survives exactly what the crash destroyed.

CID=20260901T000000Z-0badc0de
DONE_ID=20260901T010000Z-0000beef

arm
rec_append_sample "$CID" 1700100000 Nominal yes 90
rec_append_sample "$CID" 1700100300 Serious yes 71
# A session that ended properly already has its row, and must not get a second
# one describing the same night as a reboot.
rec_append_sample "$DONE_ID" 1700200000 Nominal yes 95
rec_close_session "$DONE_ID" 1700200000 1700200600 "done"
fake_set boot_time 1699999970
failsafe_run

CROW=$(rec_sessions 0 | awk -F'\t' -v id="$CID" '$1 == id')
assert_eq "reboot" "$(printf '%s' "$CROW" | cut -f4)" \
    "a session with no index row is recorded as ended by reboot"
assert_eq "1700100000" "$(printf '%s' "$CROW" | cut -f2)" \
    "its start is the first sample it managed to write"
assert_eq "1700100300" "$(printf '%s' "$CROW" | cut -f3)" \
    "and its end is the last -- the final moment macon saw it alive"
assert_eq "Serious" "$(printf '%s' "$CROW" | cut -f5)" "the aggregates are the session's own"
assert_eq "2" "$(printf '%s' "$CROW" | cut -f8)" "including how many samples it left"
assert_eq "1" "$(rec_sessions 0 | awk -F'\t' -v id="$DONE_ID" '$1 == id' | wc -l | tr -d ' ')" \
    "a session that ended properly is not recorded twice"

# Idempotent across boots: the row it just wrote is the row that makes it skip
# the same session next time.
arm
fake_set boot_time 1699999970
failsafe_run
assert_eq "1" "$(rec_sessions 0 | awk -F'\t' -v id="$CID" '$1 == id' | wc -l | tr -d ' ')" \
    "the next boot does not record the same session again"

# Not a boot, nothing to reconstruct: the scan is part of the restore and is
# gated by the same guard.
NID=20260901T020000Z-0000face
arm
rec_append_sample "$NID" 1700300000 Nominal yes 90
fake_set boot_time 1699913600
failsafe_run
assert_eq "" "$(rec_sessions 0 | awk -F'\t' -v id="$NID" '$1 == id')" \
    "no row is written when this is not a boot"

# The index is written by the user; the failsafe runs as root. Appending to an
# existing file preserves its ownership, but CREATING it here would leave a
# root-owned index in a user-owned directory and break the user's next write.
arm
rm -f "$(rec_index_path)"
fake_set boot_time 1699999970
failsafe_run
assert_fail "the failsafe does not create the index as root" test -f "$(rec_index_path)"

unset MACON_FAKE_NOW
teardown_state
