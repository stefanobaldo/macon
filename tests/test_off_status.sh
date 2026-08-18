#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
MACON_CLI_SOURCED=1
export MACON_CLI_SOURCED
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=tests/fake-platform.sh
. "$TESTS_DIR/fake-platform.sh"
# shellcheck source=lib/decide.sh
. "$MACON_LIB/decide.sh"
# shellcheck source=lib/session.sh
. "$MACON_LIB/session.sh"
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
# shellcheck source=lib/records.sh
. "$MACON_LIB/records.sh"
# shellcheck source=bin/macon
. "$REPO_DIR/bin/macon"

MACON_FS_PLIST="$MACON_STATE/local.macon.failsafe.plist"
# Paired with the line above: without it cli_failsafe_loaded asks the real
# launchd about the real daemon, and these assertions would then depend on
# whether this machine happens to have macon installed.
MACON_FS_LOADED=yes
: > "$MACON_FS_PLIST"

# The session helper's daemon, redirected for the same reason: `off`
# re-registers it, and a test must never name the real path when it does.
MACON_HELPER_LABEL=local.macon.helper
MACON_HELPER_PLIST="$MACON_STATE/local.macon.helper.plist"
: > "$MACON_HELPER_PLIST"
MACON_ARM_TRIES=3
MACON_FAKE_NOW=1700000000
export MACON_FAKE_NOW

mkdir -p "$(sess_run_dir)"
ID=20260815T000000Z-deadbeef

clean_machine() {
    fake_set sleep 1
    fake_set disksleep 10
    fake_set powernap 1
    fake_set sleep_disabled no
    fake_set power_source ac
    fake_set battery_pct 80
    fake_set fail_pmset_apply_ac 0
    fake_set fail_pmset_disablesleep 0
    rm -f "$MACON_RUN"/* 2>/dev/null || :
    rm -f "$(snap_path)"
    snap_save
    fake_reset_calls
}

# Puts the machine in the state an armed session leaves it in, with a
# descriptor the CLI can read back.
arm() {
    clean_machine
    _d=$(sess_desc_path)
    : > "$_d"
    sess_set "$_d" session_id "$ID"
    sess_set "$_d" started_at 1699996400
    sess_set "$_d" soft_deadline 1700005400
    sess_set "$_d" hard_ceiling 1700010000
    sess_set "$_d" policy restore
    sess_set "$_d" interval 300
    sess_set "$_d" strikes 2
    sess_set "$_d" completion sentinel
    sess_set "$_d" user "$(id -un)"
    plat_pmset_disablesleep 1
    plat_pmset_apply_ac sleep 0 disksleep 0 powernap 0
    fake_reset_calls
}

# `off` no longer signals anything. It boots the daemon out, and the kill stub
# this file used to carry -- along with the zombie-reaping care that made it
# deterministic -- went with the signal it stood in for. What replaced both is
# the recorded call list, which is where the order now gets asserted.
STUB_PID=4242
start_stub_helper() {
    printf '%s\n' "$STUB_PID" > "$(sess_pid_path)"
    printf 'macon-helper start x\n' > "$MACON_STATE/fake/proc_$STUB_PID"
}

# The fake's process table is scripted, so a process that was never really
# running has to be retired by hand.
retire_stub_helper() {
    rm -f "$MACON_STATE/fake/proc_$STUB_PID"
}

# --- off --------------------------------------------------------------------

arm
cli_cmd_off >/dev/null
assert_eq "1" "$(fake_call_count 'pmset_apply_ac')" "off restores in a single call"
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 1 disksleep 10 powernap 1" \
    "off restores the saved values"
assert_fail "off leaves disablesleep clear" plat_sleep_disabled
assert_fail "off clears the snapshot" snap_exists
assert_fail "off clears the descriptor" test -f "$(sess_desc_path)"

# A session ended by hand is still a session. Without a row here, the night is
# missing from the index entirely -- and the index is what `report` reads.
_row=$(rec_sessions 0 | head -1)
assert_eq "$ID" "$(printf '%s' "$_row" | cut -f1)" "off records the session it ended"
assert_eq "manual" "$(printf '%s' "$_row" | cut -f4)" "and records how it ended"
assert_eq "1699996400" "$(printf '%s' "$_row" | cut -f2)" "with the start time the descriptor carried"

# Nothing to end: `off` on an idle machine is a no-op that must not invent a row.
_before=$(rec_sessions 0 | wc -l | tr -d ' ')
clean_machine
cli_cmd_off >/dev/null
assert_eq "$_before" "$(rec_sessions 0 | wc -l | tr -d ' ')" \
    "off with no session records nothing"

# The helper must be gone BEFORE the restore: a helper still polling against a
# descriptor that has been deleted is a loop reasoning from empty values.
#
# Under launchd that means booting the DAEMON out. Signalling the pid is what
# this used to do and what KeepAlive now undoes -- verified on the real machine,
# the helper is back within a tenth of a second -- so the signal is gone from
# here entirely and the order is asserted further down, on the recorded calls.

arm
start_stub_helper
fake_set launchd_local.macon.helper running
fake_reset_calls
OUT=$(cli_cmd_off 2>&1)
assert_contains "$(fake_calls)" "launchd_bootout local.macon.helper" \
    "off stops the helper by booting its daemon out"
assert_fail "off clears the pid file" test -f "$(sess_pid_path)"
assert_fail "off leaves no live helper behind" sess_helper_alive

# The stub outlives the bootout, because the fake's process table is scripted
# and launchd is not there to reap it. That models the case worth pinning: a
# bootout that did not take must not stop the restore.
assert_contains "$OUT" "still running after the bootout" \
    "a helper that survived the bootout is reported"
assert_fail "and the machine was restored anyway" plat_sleep_disabled
retire_stub_helper

# A restore that failed has not consumed the snapshot, and deleting it there
# destroys the only record of the original values -- while the machine is still
# holding the wrong ones.
arm
fake_set fail_pmset_apply_ac 1
OUT=$(cli_cmd_off 2>&1)
assert_ok "a failed restore keeps the snapshot" snap_exists
assert_contains "$OUT" "did not fully succeed" "and says so"
assert_eq "sleep 1 disksleep 10 powernap 1" "$(snap_restore_args)" \
    "the kept snapshot is intact"

# No snapshot: disablesleep can still be cleared, and that is the half that
# matters. What cannot be guessed is not guessed.
clean_machine
plat_pmset_disablesleep 1
rm -f "$(snap_path)"
fake_reset_calls
OUT=$(cli_cmd_off 2>&1)
assert_contains "$OUT" "no snapshot" "off without a snapshot says so"
assert_fail "off without a snapshot still lets the machine sleep" plat_sleep_disabled
assert_eq "0" "$(fake_call_count 'pmset_apply_ac')" \
    "and applies nothing it would have to invent"

# The run files are cleared AFTER the restore, not before it. cli_stop_helper
# gives up after MACON_ARM_TRIES and warns "did not stop; restoring anyway", so
# a helper can still be polling here -- and deleting the descriptor out from
# under it leaves it reading every field as empty, which is what `[ -ge ]` exits
# 2 on. Asserted as an order rather than a state, through the same call log the
# restore is already recorded in.
#
# Behaviourally the real cli_remove_run_files, minus the sudo escalation this
# suite must never reach: every file it is given here is owned by the user
# running the tests, so the first rm always succeeds.
# shellcheck disable=SC2317,SC2329
cli_remove_run_files() {
    fake_record "remove_run_files"
    rm -f "$@" 2>/dev/null || :
}

arm
start_stub_helper
fake_reset_calls
cli_cmd_off >/dev/null
assert_eq "pmset_disablesleep 0" \
    "$(fake_calls | grep -e 'pmset_disablesleep' -e 'remove_run_files' | head -1)" \
    "off restores before it deletes the descriptor the helper polls from"
assert_contains "$(fake_calls)" "remove_run_files" "and it does delete them"
assert_fail "off clears the descriptor" test -f "$(sess_desc_path)"

# --- healing an orphan ------------------------------------------------------
#
# Settings applied, no live helper, stale heartbeat: nothing will end this
# session on its own, because the boot failsafe only fires at a boot.

# An older session id than the one `off` recorded above, so the row this
# section asserts on is found by id rather than by being the newest.
OID=20260814T000000Z-cafebabe
arm
sess_set "$(sess_desc_path)" session_id "$OID"
sess_set "$(sess_desc_path)" started_at 1699996000
printf '1000\n' > "$(sess_heartbeat_path)"
assert_ok "the fixture is an orphan" sess_orphaned
cli_heal_orphan
assert_fail "healing lets the machine sleep again" plat_sleep_disabled
assert_eq "1" "$(plat_pmset_read sleep)" "healing restores the saved values"
assert_fail "healing clears the descriptor" test -f "$(sess_desc_path)"
assert_fail "healing clears the heartbeat" test -f "$(sess_heartbeat_path)"
_row=$(rec_sessions 0 | awk -F'\t' -v id="$OID" '$1 == id')
assert_eq "$OID" "$(printf '%s' "$_row" | cut -f1)" "healing records the session it ended"
assert_eq "orphan" "$(printf '%s' "$_row" | cut -f4)" "and records why the row exists"
assert_eq "1699996000" "$(printf '%s' "$_row" | cut -f2)" \
    "with the start time the abandoned descriptor still carried"

# --- status -----------------------------------------------------------------
#
# It is a read command and must stay one: an orphan is REPORTED, never healed.
# A status that quietly restored would make the state it describes disappear as
# it described it.

arm
printf '999999\n' > "$(sess_pid_path)"
printf '1000\n' > "$(sess_heartbeat_path)"
fake_reset_calls
OUT=$(cli_cmd_status)
assert_contains "$OUT" "ORPHANED" "status reports an orphaned session"
assert_eq "0" "$(fake_call_count 'pmset')" "status makes no pmset calls"
assert_ok "status leaves the machine still applied" plat_sleep_disabled
assert_ok "status leaves the descriptor in place" test -f "$(sess_desc_path)"

arm
start_stub_helper
OUT=$(cli_cmd_status)
assert_contains "$OUT" "DISABLED" "status reports that the lid is safe to close"
assert_contains "$OUT" "active" "status reports a live session"
assert_contains "$OUT" "1h30m" "status reports the time left to the soft deadline"
assert_contains "$OUT" "sentinel" "status names the completion source"
assert_contains "$OUT" "80%" "status reports the battery level"
assert_contains "$OUT" "installed" "status reports the boot failsafe"
retire_stub_helper

# Past the soft deadline the remaining time is clamped, not negative: the
# session is still running, on the ceiling's clock.
arm
start_stub_helper
sess_set "$(sess_desc_path)" soft_deadline 1699999000
OUT=$(cli_cmd_status)
assert_contains "$OUT" "0h0m" "a passed soft deadline reads as no time left"
retire_stub_helper

clean_machine
rm -f "$MACON_FS_PLIST"
OUT=$(cli_cmd_status)
assert_contains "$OUT" "none" "status reports an idle machine"
assert_contains "$OUT" "absent" "status reports a missing boot failsafe"
assert_contains "$OUT" "manual" "status reports how the last session ended"

# The bug report template asks a user to paste this output, so it has to say
# which macon produced it. Asserted against MACON_VERSION rather than a literal,
# so bumping the version does not require editing a test to match.
assert_contains "$OUT" "$MACON_VERSION" "status reports the version it is running"
assert_contains "$OUT" "version:" "and labels it"
: > "$MACON_FS_PLIST"

# --- saved ------------------------------------------------------------------

clean_machine
OUT=$(cli_cmd_saved)
assert_contains "$OUT" "sleep 1 disksleep 10 powernap 1" "saved shows the restore arguments"
assert_contains "$OUT" "$(snap_path)" "saved names the file it read"
rm -f "$(snap_path)"
OUT=$(cli_cmd_saved)
assert_contains "$OUT" "no snapshot" "saved says so when there is nothing stored"

# --- log --------------------------------------------------------------------

clean_machine
rec_append_sample "$ID" 1700000300 Nominal yes 80
rec_append_sample "$ID" 1700000600 Serious yes 74
rec_close_session "$ID" 1699996400 1700000900 "done"
OUT=$(cli_cmd_log)
assert_contains "$OUT" "Serious" "log defaults to the most recent session"
OUT=$(cli_cmd_log --session "$ID")
assert_contains "$OUT" "Nominal" "log accepts an explicit session"
OUT=$(cli_cmd_log "$ID")
assert_contains "$OUT" "Nominal" "log accepts a bare session id too"

# The id becomes a path, and this one comes from the command line. cli_cmd_log
# exits on refusal, so it is called in a subshell -- asserted through the
# command itself rather than through the guard it delegates to, or the
# assertion would hold even if log never consulted the guard.
try_log() {
    ( cli_cmd_log "$@" )
}
assert_fail "log refuses an id that is not a plain identifier" \
    try_log '../../etc/passwd'
assert_fail "log refuses an id with no samples" try_log 20260101T000000Z-00000000

# --- off stops the daemon before it restores --------------------------------
#
# The order is the test. Restoring first would leave a live helper polling
# against the restore, and killing the pid instead of booting the job out does
# not stop anything: KeepAlive brings the helper straight back. Verified on the
# real machine -- `launchctl kill TERM` kills the process and launchd respawns
# it within a tenth of a second; only `bootout` stops it.

MACON_HELPER_LABEL=local.macon.helper
MACON_HELPER_PLIST="$MACON_STATE/local.macon.helper.plist"
: > "$MACON_HELPER_PLIST"

fake_set launchd_local.macon.helper running
fake_set sleep_disabled yes
fake_reset_calls
cli_cmd_off >/dev/null 2>&1

CALLS=$(fake_calls)
assert_contains "$CALLS" "launchd_bootout local.macon.helper" \
    "off boots the daemon out"

# The ORDER, asserted by line number rather than by presence: both calls being
# there is not the claim.
BOOTOUT_AT=$(printf '%s\n' "$CALLS" | grep -n 'launchd_bootout' | head -1 | cut -d: -f1)
RESTORE_AT=$(printf '%s\n' "$CALLS" | grep -n 'pmset_disablesleep 0' | head -1 | cut -d: -f1)
assert_ok "the bootout precedes the restore" test "$BOOTOUT_AT" -lt "$RESTORE_AT"

assert_contains "$CALLS" "launchd_bootstrap local.macon.helper" \
    "and the daemon is put back for the next session"
BOOTSTRAP_AT=$(printf '%s\n' "$CALLS" | grep -n 'launchd_bootstrap' | head -1 | cut -d: -f1)
assert_ok "the re-registration follows the restore" \
    test "$BOOTSTRAP_AT" -gt "$RESTORE_AT"

# --- off with the daemon already gone ---------------------------------------
#
# A machine whose daemon someone unloaded by hand: off must still restore, and
# it quietly re-registers on the way out.

rm -f "$MACON_STATE/fake/launchd_local.macon.helper"
fake_set sleep_disabled yes
fake_reset_calls
cli_cmd_off >/dev/null 2>&1
assert_fail "off does not boot out a job that is not loaded" \
    test "$(fake_call_count 'launchd_bootout')" -gt 0
assert_fail "and the machine can sleep again" plat_sleep_disabled

# --- off when the plist itself is gone --------------------------------------
#
# macon half-uninstalled. off restores, warns, and does not pretend to have
# re-registered anything.

rm -f "$MACON_HELPER_PLIST"
fake_set sleep_disabled yes
fake_reset_calls
OUT=$(cli_cmd_off 2>&1)
assert_fail "the machine can sleep again" plat_sleep_disabled
assert_contains "$OUT" "helper daemon plist is missing" \
    "and the missing plist is reported rather than silently skipped"
assert_eq "0" "$(fake_call_count 'launchd_bootstrap')" \
    "nothing was bootstrapped from a file that is not there"
: > "$MACON_HELPER_PLIST"

# --- status reports the daemon ----------------------------------------------
#
# `runs` is launchd's own start counter and the entire respawn diagnostic: macon
# keeps none of its own, so a night in which the helper died forty times is
# otherwise indistinguishable from a clean one.
#
# The row reports the number and does NOT interpret it. Measured on the real
# machine, across the exact sequence macon produces: install.sh bootstraps and
# the job runs once and exits 0 (runs=1); `macon on` kickstarts it (runs=2);
# each crash adds one; `macon off` boots out and re-bootstraps, resetting it to
# 1. A healthy session therefore sits at TWO, and any "greater than 1 means
# trouble" threshold would fire every single night.

fake_set launchd_local.macon.helper running
fake_set launchd_runs_local.macon.helper 2
assert_contains "$(cli_cmd_status)" "loaded, running (runs: 2)" \
    "a healthy session reports launchd's count as it stands"

fake_set launchd_runs_local.macon.helper 7
assert_contains "$(cli_cmd_status)" "loaded, running (runs: 7)" \
    "and a night with crashes reports the higher count, uninterpreted"

fake_set launchd_local.macon.helper "not running"
assert_contains "$(cli_cmd_status)" "loaded, idle" \
    "a loaded job with no process reads as idle"

# An unreadable count is simply absent -- the row must not invent a number, and
# must not lose the half that IS load-bearing.
rm -f "$MACON_STATE/fake/launchd_runs_local.macon.helper"
fake_set launchd_local.macon.helper running
OUT=$(cli_cmd_status)
assert_contains "$OUT" "loaded, running" "an unreadable count still reports the state"
case "$OUT" in
    *"runs:"*) assert_eq "absent" "present" "no count is invented when none can be read" ;;
    *) assert_eq "absent" "absent" "no count is invented when none can be read" ;;
esac

rm -f "$MACON_STATE/fake/launchd_local.macon.helper"
assert_contains "$(cli_cmd_status)" "NOT LOADED" \
    "an unloaded daemon is reported prominently"
assert_contains "$(cli_cmd_status)" "'macon on' will refuse" \
    "and the consequence is named, not left to be discovered"

# An unparseable state degrades to the fact that IS load-bearing. The output of
# `launchctl print` changes shape between macOS releases, so the row must not
# depend on parsing it.
fake_set launchd_local.macon.helper "some future wording"
OUT=$(cli_cmd_status)
assert_contains "$OUT" "helper daemon:" "an unknown state still produces a row"
case "$OUT" in
    *"NOT LOADED"*) assert_eq "loaded" "not loaded" \
        "an unparseable state must not read as unloaded" ;;
    *) assert_eq "loaded" "loaded" "an unparseable state still reads as loaded" ;;
esac

unset MACON_FAKE_NOW
teardown_state
