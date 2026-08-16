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
# Paired with the line above: without it cli_failsafe_loaded asks the real
# launchd about the real daemon, and these assertions would then depend on
# whether this machine happens to have macon installed.
MACON_FS_LOADED=yes
: > "$MACON_FS_PLIST"

# The hand-over descriptor is built under TMPDIR; pointing that at the test's
# own directory keeps the assertion about cleaning it up from ever looking at
# another process's files.
TMPDIR="$MACON_STATE/tmp"
mkdir -p "$TMPDIR"
export TMPDIR

MACON_FAKE_NOW=1700000000
export MACON_FAKE_NOW

# A stand-in for `macon-helper start DESCRIPTOR`: it installs its own copy of
# the descriptor exactly as the real one does, records a PID, and declares that
# PID in the fake's process table so the real sess_helper_alive -- name match
# included -- is what decides whether arming succeeded.
STUB="$MACON_STATE/stub-helper.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
cp "$1" "$MACON_RUN/session.conf"
sleep 30 &
_pid=$!
printf '%s\n' "$_pid" > "$MACON_RUN/helper.pid"
printf 'macon-helper start %s\n' "$1" > "$MACON_STATE/fake/proc_$_pid"
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
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\" &"
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
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\" &"
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
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\" &"
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
assert_ok "on battery, --force starts anyway" try_on 8 --no-failsafe --force
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
MACON_FS_LOADED=no
assert_fail "on refuses when launchd has not loaded the failsafe" try_on 8
assert_eq "0" "$(fake_call_count 'pmset')" "that refusal touched nothing either"
assert_ok "--no-failsafe still overrides it" try_on 8 --no-failsafe
kill_stub
MACON_FS_LOADED=yes

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

# --- on: the descriptor it builds -------------------------------------------

clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\" &"
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
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\" &"
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

unset MACON_FAKE_NOW
teardown_state
