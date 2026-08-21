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

# The ladder waits for the helper to come up in tenth-of-a-second steps. That
# budget is right for a real sudo'd helper and is pure dead time here, where
# the stub is immediate and the failure cases never produce a PID at all.
MACON_ARM_TRIES=3

# Nothing in this file may touch the real LaunchDaemon path.
MACON_FS_PLIST="$MACON_STATE/local.macon.failsafe.plist"
# And the job itself scripted as loaded, the same way the helper daemon is
# below. cli_failsafe_loaded asks plat_launchd_loaded and nothing else, so an
# unscripted label is simply not loaded -- and every arm in this file would
# then refuse before touching anything, which is a correct refusal and the
# wrong test.
fake_set "launchd_$MACON_FS_LABEL" "not running"
: > "$MACON_FS_PLIST"

# The helper daemon, scripted as loaded. Without it every cli_arm below would
# refuse before touching anything, which is a correct refusal and the wrong
# test.
MACON_HELPER_LABEL=local.macon.helper
fake_set launchd_local.macon.helper "not running"
# And its plist, redirected and created. Arming RELOADS the job -- bootout then
# bootstrap -- so preflight refuses when the plist is gone, and a file left
# pointing at /Library/LaunchDaemons answers according to whether the machine
# running the suite happens to have macon installed. It passed here and failed
# on CI, which is the wrong way round for that to be discovered.
MACON_HELPER_PLIST="$MACON_STATE/local.macon.helper.plist"
: > "$MACON_HELPER_PLIST"

# The hand-over descriptor is built under TMPDIR; pointing that at the test's
# own directory keeps the assertion about cleaning it up from ever looking at
# another process's files.
TMPDIR="$MACON_STATE/tmp"
mkdir -p "$TMPDIR"
export TMPDIR

MACON_FAKE_NOW=1700000000
export MACON_FAKE_NOW

# A stand-in for `macon-helper arm DESCRIPTOR` followed by the daemon that
# launchd kickstarts. It installs its own copy of the descriptor exactly as the
# real `arm` does, records a PID, and declares that PID in the fake's process
# table so the real sess_helper_alive -- name match included -- is what decides
# whether arming succeeded.
#
# It does NOT background itself. That is the shape change: the old launcher was
# `nohup ... &` and its failure could only ever be "the fork failed", while
# `arm` runs to completion and its exit status is a real answer about the
# descriptor.
STUB="$MACON_STATE/stub-helper.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
cp "$1" "$MACON_RUN/session.conf" || exit 1
sleep 30 &
_pid=$!
printf '%s\n' "$_pid" > "$MACON_RUN/helper.pid"
printf 'macon-helper watch\n' > "$MACON_STATE/fake/proc_$_pid"
STUBEOF

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

kill_stub() {
    _p=$(cat "$(sess_pid_path)" 2>/dev/null)
    [ -n "$_p" ] && kill "$_p" 2>/dev/null
    return 0
}

mkdir -p "$(sess_run_dir)"
clean_machine

# The descriptor is handed over in a USER-WRITABLE file, which is the whole
# point of the hand-over: /var/run is root-owned, so a session built directly
# at sess_desc_path could not be written by the user who asked for it -- and a
# descriptor whose source and destination are the same path makes the helper's
# validate-then-copy a self-copy, which buys none of the tamper resistance it
# exists for.
D="$MACON_STATE/handover.conf"
write_desc() {
    : > "$D"
    sess_set "$D" session_id 20260815T000000Z-deadbeef
    sess_set "$D" started_at 1700000000
    sess_set "$D" soft_deadline 1700003600
    sess_set "$D" hard_ceiling 1700007200
    sess_set "$D" policy restore
    sess_set "$D" interval 300
    sess_set "$D" strikes 2
    sess_set "$D" completion none
    sess_set "$D" user "$(id -un)"
}
write_desc

# --- the helper cannot start ------------------------------------------------
#
# "Applied without a watcher" is the one state this ladder exists to make
# impossible. A warning and a hope that the user remembers to run `off` is not
# a rollback.

MACON_HELPER_CMD="false"
assert_fail "arming fails when the helper cannot start" cli_arm "$D"
assert_fail "disablesleep was rolled back" plat_sleep_disabled
assert_eq "1" "$(plat_pmset_read sleep)" "sleep was rolled back to its original value"
assert_eq "10" "$(plat_pmset_read disksleep)" "disksleep was rolled back"
assert_eq "1" "$(plat_pmset_read powernap)" "powernap was rolled back"
assert_ok "the snapshot survives a failed arming" snap_exists

# --- the helper starts but never appears ------------------------------------

clean_machine
MACON_HELPER_CMD="true"
assert_fail "arming fails when no live helper appears" cli_arm "$D"
assert_fail "disablesleep was rolled back again" plat_sleep_disabled
assert_eq "1" "$(plat_pmset_read sleep)" "the timers came back too"

# --- pmset refuses the timers -----------------------------------------------
#
# The first mutation has already landed at this point: the machine cannot
# sleep, and the ladder must not walk away from that state just because the
# second call failed.

clean_machine
fake_set fail_pmset_apply_ac 1
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
assert_fail "arming fails when the timers cannot be zeroed" cli_arm "$D"
assert_fail "a refused pmset still leaves the machine able to sleep" plat_sleep_disabled
assert_fail "the helper was never started" test -f "$(sess_pid_path)"

# --- disablesleep itself refuses --------------------------------------------

clean_machine
fake_set fail_pmset_disablesleep 1
assert_fail "arming fails when clamshell sleep cannot be disabled" cli_arm "$D"
assert_eq "0" "$(fake_call_count 'pmset_apply_ac')" \
    "nothing else is applied once the first mutation has failed"

# --- the happy path ---------------------------------------------------------

clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
assert_ok "arming succeeds when the helper comes up" cli_arm "$D"
assert_ok "disablesleep is applied" plat_sleep_disabled
assert_eq "0" "$(plat_pmset_read sleep)" "sleep is zeroed while armed"
assert_eq "0" "$(plat_pmset_read disksleep)" "disksleep is zeroed while armed"
assert_ok "the helper is alive by name, not merely by pid" sess_helper_alive
kill_stub

# Keys the machine does not have are not invented: pmset rejects a key it does
# not know, and one rejected key fails the whole invocation.
clean_machine
rm -f "$MACON_STATE/fake/powernap"
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
assert_ok "arming succeeds on a machine with no powernap" cli_arm "$D"
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 0 disksleep 0" \
    "the applied key set matches the machine"
case "$(fake_calls)" in
    *"powernap"*) assert_eq "absent" "present" "powernap is not applied when absent" ;;
    *) assert_eq "absent" "absent" "powernap is not applied when absent" ;;
esac
kill_stub

# --- on: the guards that run before anything is touched ---------------------
#
# cli_cmd_on exits on refusal, so each call is made in a subshell; a guard that
# fired must also have left the machine alone.

try_on() {
    ( cli_cmd_on "$@" )
}

clean_machine
fake_set power_source battery
assert_fail "on refuses to start on battery" try_on 8 --no-failsafe
assert_eq "0" "$(fake_call_count 'pmset')" "the battery refusal touched nothing"
assert_ok "on battery, --allow-battery starts anyway" try_on 8 --no-failsafe --allow-battery
kill_stub

clean_machine
rm -f "$MACON_FS_PLIST"
assert_fail "on refuses to start without the boot failsafe" try_on 8
assert_eq "0" "$(fake_call_count 'pmset')" "the failsafe refusal touched nothing"
: > "$MACON_FS_PLIST"

# The plist being on disk is not the same fact as launchd having the job, and
# arming on the weaker one is arming with no boot restore behind it. Refusing
# is the safe direction here: a false refusal costs a session that does not
# start, a false pass costs a Mac that reboots after a panic still unable to
# sleep.
clean_machine
fake_set "launchd_$MACON_FS_LABEL" ""
assert_fail "on refuses when launchd has not loaded the failsafe" try_on 8
assert_eq "0" "$(fake_call_count 'pmset')" "that refusal touched nothing either"
assert_ok "--no-failsafe still overrides it" try_on 8 --no-failsafe
kill_stub
fake_set "launchd_$MACON_FS_LABEL" "not running"

# --- the snapshot is taken fresh on every arm --------------------------------
#
# `macon off` and the boot failsafe consume the snapshot; a session that reaches
# its deadline, and the orphan heal, restore and leave it behind. So the
# ORDINARY endings leave a snapshot that the next arm would otherwise reuse, and
# a user who changed their power settings between two nights had those changes
# reverted when the second one ended -- restored to values that were correct for
# a night already over.
#
# The machine below is clean and holds disksleep 30; the snapshot on disk still
# says 10, exactly as a previous night left it.
clean_machine
fake_set disksleep 30
assert_ok "a clean machine whose values changed still arms" try_on 8
kill_stub
assert_eq "sleep 1 disksleep 30 powernap 1" "$(snap_restore_args)" \
    "arming re-snapshots the machine as it is now, not as a past night left it"

# The other half of the same change, and the reason re-reading is safe at all:
# snap_save REFUSES on a machine that already looks modified, so this cannot
# record zeros as though they were somebody's real configuration. Here that
# tightens a case that used to pass -- modified, but not an orphan, because the
# heartbeat is too fresh to declare one. It used to arm straight over the top.
clean_machine
fake_set sleep_disabled yes
printf '%s\n' "$MACON_FAKE_NOW" > "$(sess_heartbeat_path)"
assert_fail "on refuses to arm over a modified machine it cannot explain" try_on 8
assert_eq "0" "$(fake_call_count 'pmset')" "and that refusal touched nothing"
assert_eq "sleep 1 disksleep 10 powernap 1" "$(snap_restore_args)" \
    "the refusal left the existing snapshot untouched"

# A machine already modified with no snapshot to explain it: the original
# values are gone and macOS cannot reconstruct them, so guessing is worse than
# refusing.
clean_machine
rm -f "$(snap_path)"
fake_set sleep 0
fake_set disksleep 0
fake_set powernap 0
assert_fail "on refuses when the machine looks modified and no snapshot exists" \
    try_on 8
assert_eq "0" "$(fake_call_count 'pmset')" "the snapshot refusal touched nothing"

clean_machine
printf '4242\n' > "$(sess_pid_path)"
printf 'macon-helper start x\n' > "$MACON_STATE/fake/proc_4242"
assert_fail "on refuses while a session is already active" try_on 8
assert_eq "0" "$(fake_call_count 'pmset')" "the already-active refusal touched nothing"
rm -f "$(sess_pid_path)" "$MACON_STATE/fake/proc_4242"

# --- the plist backup line names a directory that is really there ------------
#
# snap_backup_plists creates the destination, fills it, then prunes to
# MACON_PMPREFS_KEEP -- so with a retention of zero, which is a real request to
# keep none, the backup just taken is itself in the excess. Printing the path it
# echoed named a directory deleted microseconds earlier, and said so with rc 0.
#
# The contract of snap_backup_plists is deliberately unchanged: it echoes the
# destination and reports whether a plist actually landed. Only the message is
# conditional, at the one call site that prints it.

clean_machine
rm -f "$(snap_path)"
# cli_preflight is called directly, so the option set cli_parse_on would have
# published has to be stated: under `set -u` an unread flag is fatal.
OPT_ALLOW_BATTERY=0
OPT_NO_FAILSAFE=0
KEEP_SAVED=$MACON_PMPREFS_KEEP
MACON_PMPREFS_KEEP=0
OUT=$( (cli_preflight) 2>&1 )
MACON_PMPREFS_KEEP=$KEEP_SAVED
assert_contains "$OUT" "saved original power state" \
    "preflight with no retention still snapshots and still arms"
assert_fail "and says nothing about a backup directory it pruned away" \
    sh -c "case \"$OUT\" in *'plist backup in'*) exit 0 ;; esac; exit 1"

# The ordinary retention keeps the backup, so the line is printed -- and the
# path in it is a directory that exists.
clean_machine
rm -f "$(snap_path)"
OPT_ALLOW_BATTERY=0
OPT_NO_FAILSAFE=0
OUT=$( (cli_preflight) 2>&1 )
assert_contains "$OUT" "plist backup in " "the kept backup is announced"
BACKUP_DIR=$(printf '%s\n' "$OUT" | sed -n 's/^plist backup in //p')
assert_ok "and the directory the message names is on disk" test -d "$BACKUP_DIR"

# --- on: the descriptor it builds -------------------------------------------

clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
assert_ok "on arms a session" try_on 8 --max 12 --interval 60 --sentinel \
    --on-expire extend --extend-by 45 --pre-warn 20 --hook-end 'true'
I="$(sess_desc_path)"
assert_ok "the helper installed its own copy of the descriptor" test -f "$I"
assert_eq "1700028800" "$(sess_get "$I" soft_deadline)" "the soft deadline is now + 8h"
assert_eq "1700043200" "$(sess_get "$I" hard_ceiling)" "the ceiling is now + 12h"
assert_eq "2700" "$(sess_get "$I" extend_by)" "the extension step is stored in seconds"
assert_eq "1200" "$(sess_get "$I" pre_warn)" "the warning lead time is stored in seconds"
assert_eq "60" "$(sess_get "$I" interval)" "the interval is stored as given"
assert_eq "extend" "$(sess_get "$I" policy)" "the policy is stored"
assert_eq "sentinel" "$(sess_get "$I" completion)" "the completion source is stored"
assert_eq "$MACON_STATE/$(sess_get "$I" session_id).done" \
    "$(sess_get "$I" sentinel_path)" "the sentinel path is absolute and per-session"
assert_eq "$(id -un)" "$(sess_get "$I" user)" "the invoking user is recorded"
assert_ok "the descriptor the helper installed is valid" sess_validate "$I"
kill_stub

# The hand-over file is temporary and must not survive the session that used
# it: it is world-readable-adjacent by nature and holds the same fields the
# helper deliberately re-owns.
assert_eq "" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'macon-session.*' 2>/dev/null)" \
    "the hand-over descriptor is cleaned up"

# --- on: a descriptor that does not validate --------------------------------
#
# The helper validates its own copy on arrival, so this check is not what makes
# the descriptor trustworthy -- it is what makes a bad one fail BEFORE the
# first pmset call rather than after it, as a rollback. Nothing the parser
# admits today can build an invalid descriptor, which is exactly why the
# failure is driven through the seam: the value of the check is that it holds
# when a future flag opens a gap the parser does not cover.

clean_machine
# shellcheck disable=SC2317,SC2329
sess_validate() { return 1; }
assert_fail "on refuses to arm a descriptor that does not validate" try_on 8
assert_eq "0" "$(fake_call_count 'pmset')" \
    "an invalid descriptor is refused before anything is mutated"

# --- on: a field that cannot be written -------------------------------------
#
# sess_set returns non-zero when it refuses a value, and most descriptor fields
# are OPTIONAL -- so an unchecked write is a field that is silently not there,
# which sess_validate cannot notice by design. Parsing already refuses the one
# value known to trip it today, which is why this drives the failure through
# the seam instead: the guard has to hold for whatever trips it next.

clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
# shellcheck disable=SC2317,SC2329
sess_set() {
    [ "$2" = "hook_end" ] && return 1
    _f=$1
    printf '%s=%s\n' "$2" "$3" >> "$_f"
}
assert_fail "on refuses to arm when a descriptor field cannot be written" \
    try_on 8 --hook-end 'true'
assert_eq "0" "$(fake_call_count 'pmset')" \
    "the write that failed stopped the ladder before it began"

# --- the daemon is not loaded -----------------------------------------------
#
# The twin of the failsafe gate, and with no escape hatch: --no-failsafe exists
# because the failsafe has a defensible degraded mode, and this has none. A
# nohup fallback would be a second arming path that nothing exercises until the
# day it is the only one left.

clean_machine
rm -f "$(snap_path)"
rm -f "$MACON_STATE/fake/launchd_local.macon.helper"
# cli_preflight is called directly here rather than through cli_cmd_on, so the
# option set cli_parse_on would have published has to be stated: under `set -u`
# an unread flag is a fatal error, not a default.
OPT_ALLOW_BATTERY=0
OPT_NO_FAILSAFE=0
OUT=$( (cli_preflight) 2>&1 )
assert_contains "$OUT" "helper daemon is not loaded" \
    "preflight refuses when launchd does not have the job"
# Both repairs, and the cheap one first. `macon off` re-registers the job
# (cli_restore_helper_daemon), which covers every way of reaching this message
# that leaves the plist on disk -- a job unloaded by hand, or an `off` that died
# between its bootout and its bootstrap.
assert_contains "$OUT" "macon off" \
    "and names the one command that puts it back"
assert_contains "$OUT" "install.sh" \
    "as well as the installer, for a daemon that is really gone"
assert_fail "and nothing was applied" plat_sleep_disabled
assert_fail "and no snapshot was taken" snap_exists
fake_set launchd_local.macon.helper "not running"

# --- the daemon is loaded but its plist is gone -----------------------------
#
# A SECOND fact, and one that only became load-bearing when arming started
# reloading the job instead of kickstarting it. A loaded job outlives its plist
# file -- verified -- so a half-uninstalled machine answers "loaded" to the gate
# above and has nothing to bootstrap from. Kickstart did not care; a reload does.
#
# Refused in preflight rather than discovered in cli_arm, because by then the
# power settings are applied and the answer is a rollback the user reads as a
# failure to start rather than as a macon that is half gone.

clean_machine
rm -f "$(snap_path)"
rm -f "$MACON_HELPER_PLIST"
OPT_ALLOW_BATTERY=0
OPT_NO_FAILSAFE=0
OUT=$( (cli_preflight) 2>&1 )
assert_contains "$OUT" "$MACON_HELPER_PLIST" \
    "preflight refuses a loaded daemon whose plist is gone, and names the file"
assert_contains "$OUT" "install.sh" \
    "and points at the installer, which is what puts the file back"
assert_fail "and nothing was applied" plat_sleep_disabled
assert_fail "and no snapshot was taken" snap_exists
: > "$MACON_HELPER_PLIST"

# --- arming as root is refused ----------------------------------------------
#
# macon escalates per operation and is documented to be run as yourself. Run
# under sudo anyway, arming was not refused: it recorded root as the session
# owner, so the helper ran the user's own --busy-check and hooks as root -- the
# one thing the privilege split exists to prevent -- and it left the power
# snapshot in the user's state directory owned by root, where the next
# unprivileged arm could not replace it without asking.
#
# The uid is read through cli_uid so the branch that matters is reachable by a
# suite that is not root. A shell function and not an environment variable:
# a variable would be an override anyone could set under sudo to defeat exactly
# this.

assert_ok "an unprivileged uid may arm" \
    cli_check_not_root 501 'macon on' 'because reasons'
assert_fail "uid 0 may not" cli_check_not_root 0 'macon on' 'because reasons'

# Fails CLOSED on a uid it could not read: `[ "" -eq 0 ]` does not answer false,
# it errors -- so an unreadable uid must be refused rather than allowed through.
# An empty $(id -u) is not hypothetical: a sanitised PATH with no id on it
# produces one. Ten digits is the whole range of a 32-bit uid_t.
assert_fail "an empty uid is refused, not allowed" \
    cli_check_not_root '' 'macon on' 'because reasons'
assert_fail "a non-numeric uid is refused" \
    cli_check_not_root root 'macon on' 'because reasons'
assert_fail "an absurdly long uid is refused" \
    cli_check_not_root 99999999999999999999 'macon on' 'because reasons'

OUT=$(cli_check_not_root 0 'macon on' 'the reason it cannot' 2>&1) || :
assert_contains "$OUT" "macon on" "the refusal names the command it refused"
assert_contains "$OUT" "the reason it cannot" "and the reason that command has"
OUT=$(cli_check_not_root '' 'macon on' 'the reason it cannot' 2>&1) || :
assert_contains "$OUT" "user id" "an unreadable uid says so rather than blaming sudo"

# And the guard is wired into the path that arms, ahead of everything that
# mutates -- the orphan heal included, which runs inside preflight and restores.
clean_machine
rm -f "$(snap_path)"
OPT_ALLOW_BATTERY=0
OPT_NO_FAILSAFE=0
# shellcheck disable=SC2317,SC2329
cli_uid() { printf '0\n'; }
OUT=$( (cli_preflight) 2>&1 )
assert_contains "$OUT" "macon on" "preflight refuses to arm as root"
assert_contains "$OUT" "sudo" "and says how the command was reached"
assert_fail "nothing was applied" plat_sleep_disabled
assert_fail "and no snapshot was taken" snap_exists

# `macon run` arms too, and the refusal names the verb the user typed rather
# than the one that happens to share the guard.
OUT=$( (cli_preflight 'macon run') 2>&1 )
assert_contains "$OUT" "macon run" "and names 'macon run' when that is what arms"

# shellcheck disable=SC2317,SC2329
cli_uid() { id -u; }
OUT=$( (cli_preflight) 2>&1 )
assert_contains "$OUT" "saved original power state" \
    "and an unprivileged uid still arms"

# --- the descriptor is refused ----------------------------------------------
#
# `arm` is synchronous and checked, so a descriptor this machine cannot use is
# refused HERE rather than inside a launchd job whose stderr goes nowhere. The
# machine has already been mutated by then, so it must roll back.

clean_machine
MACON_HELPER_CMD="false"
assert_fail "arming fails when the descriptor is refused" cli_arm "$D"
assert_fail "disablesleep was rolled back" plat_sleep_disabled
assert_eq "1" "$(plat_pmset_read sleep)" "the timers came back"
assert_fail "and the descriptor was not left behind for a kickstart to obey" \
    test -f "$(sess_desc_path)"

# --- launchd refuses to start the job ---------------------------------------

clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
fake_set fail_launchd_bootstrap 1
assert_fail "arming fails when the daemon cannot be started" cli_arm "$D"
assert_fail "disablesleep was rolled back" plat_sleep_disabled
assert_fail "and the descriptor is gone" test -f "$(sess_desc_path)"
# The pid file too, like every rollback below this point. The real `arm` writes
# none, so on a real machine there is usually nothing here to clear -- but a
# start whose outcome is not known is one `watch` may still be reaching, and
# `watch` writes the pid before it does anything else.
assert_fail "and the pid file with it" test -f "$(sess_pid_path)"
assert_fail "so nothing reports a live helper over a machine just restored" \
    sess_helper_alive
fake_set fail_launchd_bootstrap 0

# A bootout that fails must NOT fail the arm. The job may already be unloaded --
# 3/ESRCH is an ordinary answer, not a fault -- and the bootstrap that follows
# is what actually has to work. Refusing here would turn a machine whose daemon
# someone had already unloaded into one that cannot arm at all.
clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
fake_set fail_launchd_bootout 1
assert_ok "a bootout that fails does not fail the arm" cli_arm "$D"
assert_ok "the helper is alive all the same" sess_helper_alive
fake_set fail_launchd_bootout 0
kill_stub

# --- the happy path goes through launchd ------------------------------------
#
# A RELOAD, not a kickstart, and the order is the assertion. `launchctl
# kickstart` on a loaded-but-idle job blocks until ThrottleInterval has elapsed
# since that job last started -- measured at ten seconds minus the time since
# the last start -- and every `macon off` re-registers the daemon, so `off`
# then `on` sat silently for the remainder of the window. The throttle clock is
# per-load, so booting out and bootstrapping again resets it: 10.04s against
# 30ms from the same position.
#
# Pinned by ORDER rather than by presence, the same way `off`'s stop sequence
# is: a bootstrap that ran before the bootout would unload the job it had just
# started, leaving nothing running and the ladder rolling back.

clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""
fake_reset_calls
assert_ok "arming succeeds" cli_arm "$D"
CALLS=$(fake_calls)
assert_contains "$CALLS" "launchd_bootout local.macon.helper" \
    "the helper is started by reloading the daemon, not by forking"
assert_contains "$CALLS" "launchd_bootstrap local.macon.helper" \
    "and the bootstrap names the label it registers"
case "$CALLS" in
    *launchd_kickstart*)
        assert_eq "reload" "kickstart" \
            "arming must not kickstart -- that is the call that waits out the throttle" ;;
    *)
        assert_eq "reload" "reload" \
            "and it is not a kickstart, which would wait out the throttle" ;;
esac
OUT_AT=$(printf '%s\n' "$CALLS" | grep -n 'launchd_bootout' | head -1 | cut -d: -f1)
IN_AT=$(printf '%s\n' "$CALLS" | grep -n 'launchd_bootstrap' | head -1 | cut -d: -f1)
assert_ok "the bootout comes first, which is what resets the throttle" \
    test "$OUT_AT" -lt "$IN_AT"
assert_ok "the helper is alive by name" sess_helper_alive
kill_stub

# --- the default invocation names a verb the helper accepts -----------------
#
# Every case above substitutes MACON_HELPER_CMD, so the one command string that
# ever runs in production is the one string the suite never executes. That blind
# spot let this branch sit green while `bin/macon` still invoked a verb the
# helper had stopped accepting -- `macon on` could not have started a session at
# all, and nothing here would have said so.
#
# `sudo` is shadowed by a function, which a POSIX shell resolves ahead of PATH,
# so the real command string is really evaluated and nothing is really elevated.
# The verb is then read back out of the argument list and put to the real
# helper: two files, one assertion, and neither one trusted to describe itself.

clean_machine
unset MACON_HELPER_CMD
SUDO_ARGV="$MACON_STATE/sudo-argv"
# shellcheck disable=SC2317,SC2329
sudo() {
    printf '%s\n' "$*" > "$SUDO_ARGV"
    return 1
}
assert_fail "the default invocation runs when nothing overrides it" cli_arm "$D"
unset -f sudo
ARGV=$(cat "$SUDO_ARGV")
assert_contains "$ARGV" "/macon-helper" "and it invokes the installed helper"

HELPER_VERB=$(printf '%s\n' "$ARGV" | sed 's|.*/macon-helper ||' | cut -d' ' -f1)
assert_eq "arm" "$HELPER_VERB" "with the arm verb"

# The helper's own answer, not a second copy of the same assumption. An
# unknown verb reaches the entry point's catch-all, whose usage line lists the
# whole verb set; a verb it accepts never prints that.
#
# It runs against the fake platform layer, like everything else in this file.
# Left alone, this subprocess inherits MACON_LIB=$REPO_DIR/lib from
# tests/run.sh and sources the REAL lib/platform.sh -- safe today only because
# the verb that comes out happens to be `arm`, which dies at the entry point
# for want of a descriptor. Nothing here guarantees that: the verb is read out
# of an argument list on purpose, and the day it reads `watch` this line would
# put `sudo pmset` on the maintainer's own machine. The state and run roots are
# redirected with it so the probe cannot write into this test's own.
PROBE_LIB="$MACON_STATE/probe-lib"
mkdir -p "$PROBE_LIB"
for _lib in "$REPO_DIR"/lib/*.sh; do
    ln -sf "$_lib" "$PROBE_LIB/$(basename "$_lib")"
done
ln -sf "$TESTS_DIR/fake-platform.sh" "$PROBE_LIB/platform.sh"
PROBE_STATE="$MACON_STATE/probe-state"
PROBE_RUN="$MACON_STATE/probe-run"
OUT=$(MACON_LIB="$PROBE_LIB" MACON_STATE="$PROBE_STATE" MACON_RUN="$PROBE_RUN" \
    sh "$REPO_DIR/libexec/macon-helper" "$HELPER_VERB" 2>&1 || :)
case "$OUT" in
    *'usage: macon-helper {'*)
        assert_eq "accepted" "rejected" "and the helper accepts that verb" ;;
    *) assert_eq "accepted" "accepted" "and the helper accepts that verb" ;;
esac

MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\""

unset MACON_FAKE_NOW
teardown_state
