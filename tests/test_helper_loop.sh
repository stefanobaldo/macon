#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
MACON_HELPER_SOURCED=1
export MACON_HELPER_SOURCED
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
# shellcheck source=libexec/macon-helper
. "$REPO_DIR/libexec/macon-helper"

mkdir -p "$(sess_run_dir)"
D=$(sess_desc_path)
ID=20260815T000000Z-deadbeef
fake_set sleep_disabled yes
fake_set power_source ac
fake_set battery_pct 80
fake_set thermal Nominal

setup_desc() {
    : > "$D"
    sess_set "$D" session_id "$ID"
    sess_set "$D" started_at 1700000000
    sess_set "$D" soft_deadline 1700003600
    sess_set "$D" hard_ceiling 1700007200
    sess_set "$D" policy restore
    sess_set "$D" interval 300
    sess_set "$D" strikes 2
    sess_set "$D" completion none
    sess_set "$D" user "$(id -un)"
    # Runtime state accumulates across polls on purpose; every phase below
    # starts from a clean slate so one phase's strikes cannot fund the next.
    rm -f "$(helper_offac_path)" "$(sess_heartbeat_path)" \
        "$(rec_samples_path "$ID")"
}

# --- the privilege boundary -------------------------------------------------
#
# The rule this pins is not "prefer sudo", it is "root NEVER executes a
# user-supplied command in its own context". Exhaustive because the failure is
# silent: a wrong answer here runs a hook as root and nothing observes it.

assert_ok "root must de-privilege even for its own name" \
    helper_needs_sudo 0 root root
assert_ok "root must de-privilege for another user" \
    helper_needs_sudo 0 root stefz
assert_ok "root must de-privilege when it is somehow named as the target" \
    helper_needs_sudo 0 stefz stefz
assert_fail "an unprivileged helper running as the target user needs no sudo" \
    helper_needs_sudo 501 stefz stefz
assert_ok "an unprivileged helper still de-privileges for another user" \
    helper_needs_sudo 501 stefz someone

# --- completion sources -----------------------------------------------------

setup_desc
assert_eq "unknown" "$(helper_probe_busy "$D")" "no completion source probes unknown"

setup_desc
sess_set "$D" completion sentinel
sess_set "$D" sentinel_path "$MACON_STATE/s.done"
assert_eq "yes" "$(helper_probe_busy "$D")" "an absent sentinel means still busy"
: > "$MACON_STATE/s.done"
assert_eq "no" "$(helper_probe_busy "$D")" "a present sentinel means finished"

setup_desc
sess_set "$D" completion process
sess_set "$D" watch_pid $$
assert_eq "yes" "$(helper_probe_busy "$D")" "a live wrapped PID means busy"
sess_set "$D" watch_pid 999999
assert_eq "no" "$(helper_probe_busy "$D")" "a dead wrapped PID means finished"
# kill -0 with a non-numeric operand is a usage error, not a false answer;
# without a guard the probe would report the session busy for ever.
sess_set "$D" watch_pid "not a pid"
assert_eq "no" "$(helper_probe_busy "$D")" "an unusable wrapped PID means finished"

# A busy-check that hangs must be treated as not busy, so a hung user
# command cannot block the loop and suppress the ceiling.
setup_desc
sess_set "$D" completion busy_check
sess_set "$D" busy_check "sleep 30"
sess_set "$D" busy_timeout 1
_start=$(date +%s)
_r=$(helper_probe_busy "$D")
_elapsed=$(( $(date +%s) - _start ))
assert_eq "no" "$_r" "a hung busy-check is treated as not busy"
assert_ok "a hung busy-check returns quickly" test "$_elapsed" -lt 5

setup_desc
sess_set "$D" completion busy_check
sess_set "$D" busy_check "true"
sess_set "$D" busy_timeout 5
assert_eq "yes" "$(helper_probe_busy "$D")" "busy-check exiting 0 means busy"
sess_set "$D" busy_check "false"
assert_eq "no" "$(helper_probe_busy "$D")" "busy-check exiting non-zero means finished"

# The command reaches a shell, not argv: a busy-check is a predicate the user
# writes, and pipelines are the normal shape of one.
sess_set "$D" busy_check "printf 'x\ny\n' | grep -q y"
assert_eq "yes" "$(helper_probe_busy "$D")" "a busy-check is evaluated by a shell"

# --- descriptor validation --------------------------------------------------
#
# sess_validate covers the nine fields it was written against. These are the
# other eight, and they are the ones that reach sudo, sleep, kill and [ -e ].

setup_desc
assert_ok "a minimal descriptor validates" helper_validate_desc "$D"

setup_desc
sess_set "$D" policy extend
assert_fail "policy=extend without an extension step is rejected" \
    helper_validate_desc "$D"
sess_set "$D" extend_by 1800
assert_ok "policy=extend with a numeric extension step validates" \
    helper_validate_desc "$D"

setup_desc
sess_set "$D" completion busy_check
sess_set "$D" busy_timeout 30
assert_fail "completion=busy_check with no command is rejected" \
    helper_validate_desc "$D"
sess_set "$D" busy_check "true"
sess_set "$D" busy_timeout "30s"
assert_fail "a non-numeric busy timeout is rejected" helper_validate_desc "$D"
sess_set "$D" busy_timeout 30
assert_ok "a complete busy_check descriptor validates" helper_validate_desc "$D"

setup_desc
sess_set "$D" completion sentinel
sess_set "$D" sentinel_path "relative/s.done"
assert_fail "a relative sentinel path is rejected" helper_validate_desc "$D"
sess_set "$D" sentinel_path "$MACON_STATE/s.done"
assert_ok "an absolute sentinel path validates" helper_validate_desc "$D"

setup_desc
sess_set "$D" completion process
sess_set "$D" watch_pid "1234; rm -rf /"
assert_fail "a non-numeric wrapped PID is rejected" helper_validate_desc "$D"
sess_set "$D" watch_pid 1234
assert_ok "a numeric wrapped PID validates" helper_validate_desc "$D"

setup_desc
sess_set "$D" hook_warn "say hello"
assert_fail "a warn hook without a numeric lead time is rejected" \
    helper_validate_desc "$D"
sess_set "$D" pre_warn 900
assert_ok "a warn hook with a numeric lead time validates" helper_validate_desc "$D"

# --- descriptor installation ------------------------------------------------
#
# Spec 6.1 rule 3: the helper works from its own copy, so the ceiling cannot be
# rewritten after the session starts.

setup_desc
_src="$MACON_STATE/handed-over.conf"
cp "$D" "$_src"
rm -f "$D"
assert_ok "a valid handed-over descriptor installs" helper_install_descriptor "$_src"
assert_ok "the installed copy is at the canonical path" test -f "$D"
assert_eq "$ID" "$(sess_get "$D" session_id)" "the installed copy carries the session"

# Rewriting the source after installation must not move the ceiling.
sess_set "$_src" hard_ceiling 1999999999
assert_eq "1700007200" "$(sess_get "$D" hard_ceiling)" \
    "the working copy is independent of the file the user handed over"

# An invalid descriptor must not land at the canonical path at all.
rm -f "$D"
sess_set "$_src" interval 5
assert_fail "an invalid handed-over descriptor is refused" \
    helper_install_descriptor "$_src"
assert_fail "a refused descriptor leaves nothing at the canonical path" test -f "$D"

# A new session must not inherit the last one's strike count. The run directory
# survives everything short of a reboot, so a helper killed while off AC leaves
# a count behind -- and the next session would spend it at its first poll,
# ending a night within one interval of starting it.
setup_desc
printf '5\n' > "$(helper_offac_path)"
helper_reset_counters
assert_fail "starting a session clears any inherited strike count" \
    test -f "$(helper_offac_path)"

# --- one poll ---------------------------------------------------------------

setup_desc
MACON_FAKE_NOW=1700000600
export MACON_FAKE_NOW
assert_eq "continue" "$(helper_iterate "$D")" "mid-session the loop continues"
assert_eq "1" "$(wc -l < "$(rec_samples_path "$ID")" | tr -d ' ')" \
    "one iteration writes one sample"
assert_eq "Nominal" "$(cut -f2 < "$(rec_samples_path "$ID")")" \
    "the sample carries the thermal reading"
assert_eq "80" "$(cut -f4 < "$(rec_samples_path "$ID")")" \
    "the sample carries the battery reading"
assert_eq "$MACON_FAKE_NOW" "$(cat "$(sess_heartbeat_path)")" \
    "the heartbeat is refreshed with the poll time"

# A machine with no battery reads empty. An empty column is indistinguishable
# from a shifted one, so it is recorded as the aggregate's own sentinel.
setup_desc
fake_set battery_pct ""
helper_iterate "$D" >/dev/null
assert_eq "-1" "$(cut -f4 < "$(rec_samples_path "$ID")")" \
    "an unreadable battery is recorded as -1"
fake_set battery_pct 80

# powermetrics is the one sampler that can hang, and it runs as root at every
# poll. A hung sampler must cost the reading, not the poll.
setup_desc
# Overrides of the fake, for the two states it cannot script. Invoked by the
# helper, so shellcheck cannot see the call sites from here.
# shellcheck disable=SC2317,SC2329
plat_thermal_pressure() { sleep 30; }
# shellcheck disable=SC2034
MACON_THERMAL_TIMEOUT=1
_start=$(date +%s)
helper_iterate "$D" >/dev/null
_elapsed=$(( $(date +%s) - _start ))
assert_eq "unknown" "$(cut -f2 < "$(rec_samples_path "$ID")")" \
    "a hung thermal sampler is recorded as unknown"
assert_ok "a hung thermal sampler does not block the poll" test "$_elapsed" -lt 5

# A level carrying a tab would shift every later column, so the sample would be
# refused outright and the poll would lose its battery reading and its count.
# shellcheck disable=SC2317,SC2329
plat_thermal_pressure() { printf 'Serious\tand then some\n'; }
# shellcheck disable=SC2034
MACON_THERMAL_TIMEOUT=20
setup_desc
helper_iterate "$D" >/dev/null
assert_eq "unknown" "$(cut -f2 < "$(rec_samples_path "$ID")")" \
    "a thermal level containing a tab degrades to unknown"
assert_eq "80" "$(cut -f4 < "$(rec_samples_path "$ID")")" \
    "the rest of the sample survives a malformed thermal level"
# shellcheck source=lib/platform.sh
plat_thermal_pressure() { _v=$(fake_get thermal); printf '%s\n' "${_v:-Nominal}"; }

# --- a descriptor that stops being readable mid-session ---------------------
#
# The descriptor is validated once on arrival and then re-read at every poll,
# and it is not a constant: a failed sess_set can truncate it, and `macon off`
# deletes it -- including after giving up on a helper that would not die. Every
# field then reads EMPTY, because sess_get answers a missing file with success
# and no output, and an empty operand makes `[ -ge ]` exit 2 on bash 3.2 rather
# than return false. Without re-validation every rung of macon_decide falls
# through and the poll answers `continue` for ever, while the helper is alive,
# sess_orphaned is false and `macon status` reports a healthy session.

setup_desc
MACON_FAKE_NOW=1700000600
assert_eq "continue" "$(helper_iterate "$D")" "an intact descriptor is evaluated normally"

setup_desc
rm -f "$D"
assert_eq "end:invalid-descriptor" "$(helper_iterate "$D" 2>/dev/null)" \
    "a descriptor that has been deleted ends the session"

setup_desc
: > "$D"
assert_eq "end:invalid-descriptor" "$(helper_iterate "$D" 2>/dev/null)" \
    "an empty descriptor ends the session"

# Truncated rather than gone: the file is still there and still parses, but the
# ceiling is no longer in it. This is the shape a partial rewrite leaves behind.
setup_desc
grep -v '^hard_ceiling=' "$D" > "$D.cut" && mv "$D.cut" "$D"
assert_eq "end:invalid-descriptor" "$(helper_iterate "$D" 2>/dev/null)" \
    "a descriptor that lost its ceiling ends the session"

# A field that is present but unusable is the same class: an over-long value is
# not rejected by a comparison, it makes the comparison exit 2.
setup_desc
sess_set "$D" strikes 99999999999999999999
assert_eq "end:invalid-descriptor" "$(helper_iterate "$D" 2>/dev/null)" \
    "a descriptor whose strike count cannot be compared ends the session"

# Ending is only the answer if it really ends: the loop has to reach
# helper_finish and the restore, from a descriptor it can no longer read.
setup_desc
fake_set sleep_disabled yes
printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$(snap_path)"
fake_reset_calls
rm -f "$D"
helper_finish "$D" invalid-descriptor 2>/dev/null
assert_fail "an unreadable descriptor does not cost the restore" plat_sleep_disabled
assert_eq "1" "$(fake_call_count 'pmset_apply_ac')" \
    "and the restore is still the single call it has to be"
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 1 disksleep 10 powernap 1" \
    "with the saved values"

# --- the poll order, through the loop ---------------------------------------

setup_desc
sess_set "$D" completion sentinel
sess_set "$D" sentinel_path "$MACON_STATE/never.done"
MACON_FAKE_NOW=1700007200
assert_eq "end:hard-ceiling" "$(helper_iterate "$D")" \
    "the ceiling ends the session even with an unfired sentinel"

# Losing AC accumulates strikes and aborts. The counter has to survive the
# command substitution the loop reads the decision through -- a strike count
# held in a shell variable is discarded at the end of every poll, and the
# no-ac abort then never fires at all.
setup_desc
fake_set power_source battery
MACON_FAKE_NOW=1700000600
assert_eq "continue" "$(helper_iterate "$D")" "one strike is not enough"
assert_eq "end:no-ac" "$(helper_iterate "$D")" "the second strike aborts"

# Strikes are consecutive. A single blip must not fund an abort an hour later.
setup_desc
fake_set power_source battery
assert_eq "continue" "$(helper_iterate "$D")" "the blip is one strike"
fake_set power_source ac
assert_eq "continue" "$(helper_iterate "$D")" "AC returning clears the strikes"
fake_set power_source battery
assert_eq "continue" "$(helper_iterate "$D")" "the count restarts from zero"
fake_set power_source ac

# --- ending the session -----------------------------------------------------

setup_desc
sess_set "$D" hook_end "cp '$MACON_STATE/fake/sleep_disabled' '$MACON_STATE/hook_saw'; printf '%s\n' \"\$MACON_REASON\" > '$MACON_STATE/hook_reason'"
rec_append_sample "$ID" 1700000300 Nominal yes 80
rec_append_sample "$ID" 1700000600 Serious yes 74
fake_set sleep_disabled yes
fake_set sleep 0
fake_set disksleep 0
fake_set powernap 0
printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$(snap_path)"
printf '99999\n' > "$(sess_pid_path)"
printf '1\n' > "$(helper_offac_path)"
fake_reset_calls
MACON_FAKE_NOW=1700001000
helper_finish "$D" "done"

assert_eq "1" "$(fake_call_count 'pmset_apply_ac')" "finishing restores in one call"
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 1 disksleep 10 powernap 1" \
    "finishing restores the saved values"
assert_fail "finishing leaves the machine able to sleep" plat_sleep_disabled

# Spec 9.3: a hung or broken hook must never be able to delay the restore, so
# the restore is already visible by the time the hook runs.
assert_eq "no" "$(cat "$MACON_STATE/hook_saw")" \
    "the end hook observes a machine that is already restored"
assert_eq "done" "$(cat "$MACON_STATE/hook_reason")" \
    "the end hook is told why the session ended"

_row=$(rec_sessions 0 | head -1)
assert_eq "$ID" "$(printf '%s' "$_row" | cut -f1)" "the session lands in the index"
assert_eq "done" "$(printf '%s' "$_row" | cut -f4)" "the index records the reason"
assert_eq "Serious" "$(printf '%s' "$_row" | cut -f5)" "the index carries the worst level"
assert_eq "74" "$(printf '%s' "$_row" | cut -f7)" "the index carries the minimum battery"
assert_eq "2" "$(printf '%s' "$_row" | cut -f8)" "the index carries the sample count"

assert_fail "finishing clears the descriptor" test -f "$D"
assert_fail "finishing clears the pid file" test -f "$(sess_pid_path)"
assert_fail "finishing clears the heartbeat" test -f "$(sess_heartbeat_path)"
assert_fail "finishing clears the strike count" test -f "$(helper_offac_path)"

# rec_aggregate refuses an id it cannot use as a filename and prints NOTHING.
# _sess_is_name admits `..` where _rec_is_id does not, so this is reachable
# from a descriptor that passed validation. Splicing that empty output into an
# eight-column row is exactly what the aggregate's sentinel exists to prevent.
setup_desc
sess_set "$D" session_id ".."
fake_set sleep_disabled yes
printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$(snap_path)"
_before=$(rec_sessions 0 | wc -l | tr -d ' ')
fake_reset_calls
helper_finish "$D" "hard-ceiling"
assert_fail "an unusable session id does not cost the restore" plat_sleep_disabled
assert_eq "1" "$(fake_call_count 'pmset_apply_ac')" \
    "an unusable session id still restores in one call"
assert_eq "$_before" "$(rec_sessions 0 | wc -l | tr -d ' ')" \
    "an unusable session id writes no half-empty index row"

# --- the loop itself --------------------------------------------------------
#
# helper_wait is the loop's only pause, and stubbing it is what lets a night
# run in milliseconds. Everything below drives the real loop.

arm_snapshot() {
    fake_set sleep_disabled yes
    printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$(snap_path)"
}

setup_desc
sess_set "$D" policy extend
sess_set "$D" extend_by 600
sess_set "$D" completion sentinel
sess_set "$D" sentinel_path "$MACON_STATE/loop-a.done"
rm -f "$MACON_STATE/loop-a.done" "$MACON_STATE/loop-a.deadlines"
arm_snapshot
MACON_FAKE_NOW=1700003600
_polls=0
# shellcheck disable=SC2317,SC2329  # the loop under test calls this
helper_wait() {
    _polls=$((_polls + 1))
    sess_get "$D" soft_deadline >> "$MACON_STATE/loop-a.deadlines"
    [ "$_polls" -lt 3 ] || : > "$MACON_STATE/loop-a.done"
}
helper_loop "$D"

assert_eq "1700004200" "$(head -1 "$MACON_STATE/loop-a.deadlines")" \
    "a busy extend session at its deadline pushes the deadline once"
assert_eq "1700004200" "$(sed -n '3p' "$MACON_STATE/loop-a.deadlines")" \
    "it does not push again while inside the new deadline"
assert_eq "done" "$(rec_sessions 0 | head -1 | cut -f4)" \
    "the completion source ends the extended session"
assert_fail "the loop returns having cleared the descriptor" test -f "$D"

# An extension may never buy time past the ceiling. Without the cap the
# soft deadline walks past the one value the whole tool guarantees.
setup_desc
sess_set "$D" policy extend
sess_set "$D" extend_by 999999
sess_set "$D" completion sentinel
sess_set "$D" sentinel_path "$MACON_STATE/loop-b.done"
rm -f "$MACON_STATE/loop-b.done"
arm_snapshot
MACON_FAKE_NOW=1700003600
# shellcheck disable=SC2317,SC2329  # the loop under test calls this
helper_wait() {
    sess_get "$D" soft_deadline > "$MACON_STATE/loop-b.deadline"
    : > "$MACON_STATE/loop-b.done"
}
helper_loop "$D"
assert_eq "1700007200" "$(cat "$MACON_STATE/loop-b.deadline")" \
    "an extension is clamped to the hard ceiling"

# The warning is a courtesy, and a courtesy repeated at every poll for the
# last hour of a session is a defect.
setup_desc
sess_set "$D" completion sentinel
sess_set "$D" sentinel_path "$MACON_STATE/loop-c.done"
sess_set "$D" hook_warn "printf 'x\n' >> '$MACON_STATE/loop-c.warned'"
sess_set "$D" pre_warn 900
rm -f "$MACON_STATE/loop-c.done" "$MACON_STATE/loop-c.warned"
arm_snapshot
MACON_FAKE_NOW=1700002800
_polls=0
# shellcheck disable=SC2317,SC2329  # the loop under test calls this
helper_wait() {
    _polls=$((_polls + 1))
    [ "$_polls" -lt 3 ] || : > "$MACON_STATE/loop-c.done"
}
helper_loop "$D"
assert_eq "1" "$(wc -l < "$MACON_STATE/loop-c.warned" | tr -d ' ')" \
    "the warn hook fires once, not at every poll inside the window"

# An extension the descriptor could not be updated with. Granting it again at
# every poll for the rest of the night is the alternative, from a file the loop
# has just been told it cannot write; ending is the direction the invariant
# points, and the restore is what proves it ended.
setup_desc
sess_set "$D" policy extend
sess_set "$D" extend_by 600
sess_set "$D" completion sentinel
sess_set "$D" sentinel_path "$MACON_STATE/loop-d.done"
rm -f "$MACON_STATE/loop-d.done"
arm_snapshot
MACON_FAKE_NOW=1700003600
mkdir -p "$D.tmp"
_polls=0
# shellcheck disable=SC2317,SC2329  # the loop under test calls this
helper_wait() {
    _polls=$((_polls + 1))
    # Only reached if the failed write did NOT end the session. Ending the
    # session here too keeps a regression a failed assertion rather than a
    # suite that never returns.
    : > "$MACON_STATE/loop-d.done"
}
helper_loop "$D"
rmdir "$D.tmp" 2>/dev/null || :
assert_eq "0" "$_polls" "a failed extension ends the session rather than polling on"
assert_fail "and the machine is left able to sleep" plat_sleep_disabled
assert_fail "and the descriptor is cleared on the way out" test -f "$D"

# The descriptor disappearing mid-session, driven through the real loop. This is
# `macon off` against a helper that would not die, and the state it used to
# leave behind: a root helper polling for ever on `sleep ""` (~2ms an
# iteration), recreating the heartbeat, keeping sess_helper_alive true and
# refusing every later `macon on`. The loop must end instead, and the restore
# must happen on the way out.
setup_desc
arm_snapshot
MACON_FAKE_NOW=1700000600
_polls=0
# shellcheck disable=SC2317,SC2329  # the loop under test calls this
helper_wait() {
    _polls=$((_polls + 1))
    rm -f "$D"
    # A loop that did not end would come back here for ever, so the tenth visit
    # gives up: this file has to fail rather than hang.
    [ "$_polls" -lt 10 ] || _assert_fail "the loop kept polling with no descriptor"
}
helper_loop "$D"
assert_eq "1" "$_polls" "the loop ends at the first poll after its descriptor is gone"
assert_fail "and the machine is left able to sleep" plat_sleep_disabled
assert_fail "with the run files cleared" test -f "$(sess_heartbeat_path)"

unset MACON_FAKE_NOW
teardown_state
