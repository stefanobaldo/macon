#!/bin/sh
# Uninstalling is the one operation that can strand this Mac.
#
# Removing bin/macon, the helper and the LaunchDaemon while the machine is
# still modified takes away every way back at once: the CLI that would restore
# the power settings, and the boot failsafe that was the last line of defence
# if nobody did. So uninstall.sh refuses while anything says the machine is
# still holding a session, and this file is the proof of that refusal.
#
# uninstall.sh keeps its side-effecting section in a function that only an
# executed run calls, so sourcing it defines the functions and removes nothing.
# tests/test_source_inert.sh is the proof of that.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state

# shellcheck source=uninstall.sh
. "$REPO_DIR/uninstall.sh"

# --- a live helper ----------------------------------------------------------
#
# Deliberately conservative: ANY live process whose pid is in the run directory
# counts, without matching the command line. Refusing an uninstall that could
# have gone ahead costs a rerun; allowing one that should not have costs a Mac
# that cannot sleep and has no tool left to fix it.

assert_fail "an empty run directory holds no live helper" uninstall_helper_alive

printf 'not-a-pid\n' > "$MACON_RUN/helper.pid"
assert_fail "a garbage pid file is not a live helper" uninstall_helper_alive

printf '\n' > "$MACON_RUN/helper.pid"
assert_fail "an empty pid file is not a live helper" uninstall_helper_alive

printf '2147483647\n' > "$MACON_RUN/helper.pid"
assert_fail "a pid that no longer exists does not block forever" uninstall_helper_alive

# ps, not `kill -0`: the helper runs as root and the uninstaller does not, so
# `kill -0` would answer EPERM -- a false negative on exactly the case this
# check exists for.
printf '%s\n' "$$" > "$MACON_RUN/helper.pid"
assert_ok "a live pid in helper.pid is a live helper" uninstall_helper_alive
OUT=$(uninstall_blockers)
assert_contains "$OUT" "session" "and it blocks the uninstall"
rm -f "$MACON_RUN/helper.pid"

# --- a snapshot still on disk -----------------------------------------------
#
# A snapshot exists only between `macon on` and `macon off`. Its presence means
# the machine still holds values macon changed -- and the snapshot is the ONLY
# record of what they were before, since macOS exposes no power defaults.

assert_fail "with nothing saved there is no snapshot to worry about" \
    uninstall_snapshot_present
: > "$MACON_STATE/snapshot"
assert_ok "a snapshot on disk is detected" uninstall_snapshot_present

OUT=$(uninstall_blockers)
assert_contains "$OUT" "snapshot" "and blocks the uninstall"

OUT=$(uninstall_explain_blockers "$(uninstall_blockers)" 2>&1)
assert_contains "$OUT" "macon off" "the refusal points at the command that fixes it"
assert_contains "$OUT" "--force" "and names the override for someone who means it"
assert_contains "$OUT" "$MACON_STATE/snapshot" "and the file it found"
rm -f "$MACON_STATE/snapshot"

# --- sleep still disabled ---------------------------------------------------
#
# The only blocker that catches a machine still modified whose snapshot has
# already been removed -- the case where the guard matters most, and the one
# that cannot be set up with a file. uninstall.sh calls ioreg directly and by
# design (it must answer this with the installed tree already broken), so a
# PATH shim tests the real seam.

SHIM="$MACON_STATE/shim"
mkdir -p "$SHIM"
# The subshell is deliberate: the shimmed PATH must not outlive the call, or
# every later assertion in this file would be running against the fake ioreg.
# shellcheck disable=SC2030,SC2031
sleep_disabled_via_shim() ( PATH="$SHIM:$PATH"; export PATH; uninstall_sleep_disabled )
# shellcheck disable=SC2030,SC2031
blockers_via_shim() ( PATH="$SHIM:$PATH"; export PATH; uninstall_blockers )

fake_ioreg() {
    printf '#!/bin/sh\n%s\n' "$1" > "$SHIM/ioreg"
    chmod 755 "$SHIM/ioreg"
}

fake_ioreg 'printf "    | {\n    |   \"SleepDisabled\" = Yes\n    | }\n"'
assert_ok "SleepDisabled = Yes is detected" sleep_disabled_via_shim
assert_contains "$(blockers_via_shim)" "sleep-disabled" \
    "and blocks the uninstall on its own, with no snapshot and no session"
assert_contains "$(uninstall_explain_blockers "$(blockers_via_shim)" 2>&1)" \
    "DISABLED" "and the refusal says the lid is the problem"

fake_ioreg 'printf "    | {\n    |   \"SleepDisabled\" = No\n    | }\n"'
assert_fail "SleepDisabled = No is not a blocker" sleep_disabled_via_shim

fake_ioreg 'exit 0'
assert_fail "a machine that reports nothing is not a blocker" sleep_disabled_via_shim

fake_ioreg 'printf "unrelated output\n"; exit 1'
assert_fail "and neither is an ioreg that fails" sleep_disabled_via_shim

rm -f "$SHIM/ioreg"

# --- refusing to run as root ------------------------------------------------
#
# Not symmetry with install.sh: under sudo, HOME is root's, so the snapshot
# check above would look in a directory that never holds one and report the
# machine as safe to strand.

assert_ok "an unprivileged uninstall is allowed" uninstall_check_not_root 501
assert_fail "uninstalling as root is refused" uninstall_check_not_root 0
OUT=$(uninstall_check_not_root 0 2>&1) || :
assert_contains "$OUT" "sudo" "and says the script sudo's what it needs"

# Fails closed: `[ "" -eq 0 ]` errors and exits 2 rather than returning false,
# so an unreadable uid used to be allowed straight through.
assert_fail "an empty uid is refused, not allowed" uninstall_check_not_root ""
assert_fail "a non-numeric uid is refused" uninstall_check_not_root wheel
assert_fail "an absurdly long uid is refused" uninstall_check_not_root 99999999999999999999

# --- the prefix -------------------------------------------------------------
#
# It reaches `sudo rm -rf`. A relative prefix deletes nothing under the prefix,
# but the LaunchDaemon removal that runs first is absolute -- so the script
# would take the real boot failsafe off the machine, leave the real
# installation in place, and print "macon is uninstalled".

assert_ok "an absolute prefix is accepted" uninstall_check_prefix /usr/local
assert_ok "including a non-default one" uninstall_check_prefix /opt/macon
assert_fail "a relative prefix is refused" uninstall_check_prefix usr/local
assert_fail "and so is an empty one" uninstall_check_prefix ""

# --- a failsafe that would not go -------------------------------------------
#
# `macon failsafe remove` exits 0 whether or not the plist went, and the CLI
# may not run at all: it dies sourcing its libraries if any are missing, which
# is exactly the half-broken installation someone reaches for the uninstaller
# to clean up. The plist is therefore rechecked after the attempt, and the
# components are NOT removed while it survives -- a RunAtLoad root job pointing
# at a deleted program is an error at every boot with no macon left to fix it.

MACON_FS_PLIST="$MACON_STATE/local.macon.failsafe.plist"
assert_fail "no plist, nothing to worry about" uninstall_failsafe_present
: > "$MACON_FS_PLIST"
assert_ok "a surviving plist is seen after the removal attempt" uninstall_failsafe_present

OUT=$(uninstall_explain_stuck_failsafe 2>&1)
assert_contains "$OUT" "$MACON_FS_PLIST" "the abort names the file that would not go"
assert_contains "$OUT" "nothing else was removed" "and says the components were kept"
assert_contains "$OUT" "launchctl bootout" "and gives the command to finish by hand"
rm -f "$MACON_FS_PLIST"

# --- handing --force on to the verb that does the removal -------------------
#
# `macon failsafe remove` refuses while this Mac still looks like it is holding
# a session -- the same three blockers this script checks. uninstall.sh --force
# reaches that verb with those blockers deliberately present, having already
# told the user it is going ahead, so the decision has to travel with the call:
# without the passthrough the --force path stops at the verb it invokes.

FS_PREFIX="$MACON_STATE/fs-prefix"
FS_ARGS="$MACON_STATE/fs-args"
mkdir -p "$FS_PREFIX/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$FS_ARGS" > "$FS_PREFIX/bin/macon"
chmod 755 "$FS_PREFIX/bin/macon"
_saved_prefix=$MACON_PREFIX
MACON_PREFIX=$FS_PREFIX

: > "$FS_ARGS"
assert_ok "the removal runs" uninstall_failsafe_remove 0
assert_eq "failsafe remove" "$(cat "$FS_ARGS")" \
    "an ordinary uninstall calls the verb plainly"

: > "$FS_ARGS"
assert_ok "and runs under --force too" uninstall_failsafe_remove 1
assert_eq "failsafe remove --force" "$(cat "$FS_ARGS")" \
    "--force is passed through to it"

# The CLI may not be there at all: it dies sourcing its libraries if any are
# missing, which is the half-broken installation someone reaches for the
# uninstaller to clean up. The direct removal below it is what covers that.
MACON_PREFIX="$MACON_STATE/no-such-prefix"
: > "$FS_ARGS"
assert_ok "a missing CLI is not a failure" uninstall_failsafe_remove 1
assert_eq "" "$(cat "$FS_ARGS")" "and nothing is invoked"
MACON_PREFIX=$_saved_prefix

# --- what it leaves behind --------------------------------------------------

OUT=$(uninstall_state_note)
assert_contains "$OUT" "$MACON_STATE" "the state directory is named, not removed"
assert_ok "and it is still there" test -d "$MACON_STATE"

# --- the clean case ---------------------------------------------------------
#
# Asserted per predicate rather than on uninstall_blockers as a whole: this
# suite runs on a real Mac, and `ioreg` there answers for that machine. A test
# demanding an empty blocker list would fail on a laptop that genuinely has a
# session running -- which is the state where refusing is correct.

assert_fail "no pid file, no session blocker" uninstall_helper_alive
assert_fail "no snapshot, no snapshot blocker" uninstall_snapshot_present

# --- the helper daemon has to be booted out, not deleted --------------------
#
# Verified on the real machine: a loaded job is independent of its plist file.
# Delete the file and the job stays loaded and keeps respawning -- so an
# uninstall that only removes the file leaves a root job alive on a machine its
# owner believes is clean, and the `rm` looks like it worked.

U=$(cat "$REPO_DIR/uninstall.sh")

assert_contains "$U" "local.macon.helper" \
    "uninstall.sh knows the helper daemon's label"
# Single-quoted on purpose, here and in the grep below: this is source text
# being searched for, and the quote between `bootout ` and `system/` is part of
# it -- dropping it from uninstall.sh instead would trip SC2086.
# shellcheck disable=SC2016
assert_contains "$U" 'bootout "system/$MACON_HELPER_LABEL"' \
    "and boots the job out rather than only deleting its plist"

# Order: booting out after deleting the plist would still work, but the removal
# has to happen at all, and it has to precede removing the helper binary the
# job points at -- a respawn between the two would run a program that is gone.
# shellcheck disable=SC2016
BOOTOUT_AT=$(printf '%s\n' "$U" | grep -nF 'bootout "system/$MACON_HELPER_LABEL"' | head -1 | cut -d: -f1)
RM_AT=$(printf '%s\n' "$U" | grep -n 'rm -rf.*libexec/macon' | head -1 | cut -d: -f1)
assert_ok "the daemon is stopped before its program is removed" \
    test "$BOOTOUT_AT" -lt "$RM_AT"

# --- the label and plist path uninstall.sh restates -------------------------
#
# uninstall.sh defines its own constants rather than sourcing bin/macon, so it
# keeps working with the installed tree half-removed -- the state someone
# reaches for the uninstaller to clean up. The price is drift, and drift here is
# silent: a rename in the CLI would leave the uninstaller booting out a label
# launchd does not have, and rc 3 for "no such process" is indistinguishable
# from a job that was never loaded.

helper_default() {
    sed -n "s/^$2=\${$2:-\(.*\)}$/\1/p" "$1" | head -1
}
# Read before compared: two defaults that both failed to parse would be equal.
CLI_LABEL=$(helper_default "$REPO_DIR/bin/macon" MACON_HELPER_LABEL)
CLI_PLIST=$(helper_default "$REPO_DIR/bin/macon" MACON_HELPER_PLIST)
assert_eq "local.macon.helper" "$CLI_LABEL" "the CLI's default label parses"
assert_contains "$CLI_PLIST" "/Library/LaunchDaemons/" \
    "and so does its default plist path"
assert_eq "$CLI_LABEL" "$(helper_default "$REPO_DIR/uninstall.sh" MACON_HELPER_LABEL)" \
    "uninstall.sh boots out the label the CLI registers"
assert_eq "$CLI_PLIST" "$(helper_default "$REPO_DIR/uninstall.sh" MACON_HELPER_PLIST)" \
    "and deletes the plist the CLI expects"

# --- what the uninstall actually runs, and in what order --------------------
#
# Everything above is a claim about source text, and source text is a weak
# proxy: `local.macon.helper` would satisfy the first assertion from inside a
# comment, and the line numbers measure where lines sit rather than what runs.
# So the removal is run for real behind a PATH shim and the order is read back
# off the recording.
#
# Nothing real is touched. Every step that changes this machine goes through
# sudo, and sudo here is a stub that records its arguments and returns 0 without
# executing them -- so no launchctl, rm or pmset reaches the Mac. The stubs
# SUCCEED, unlike the refusing ones in tests/test_source_inert.sh: a stub that
# refused would stop uninstall_main at its first privileged call, long before
# the ordering that is the point of this section.

UW="$MACON_STATE/uninstall-run"
USHIM="$UW/shim"
UCALLS="$UW/calls"
mkdir -p "$USHIM" "$UW/prefix"
: > "$UCALLS"
for _c in sudo rm pmset cp chown chmod ln mv; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' \
        "$_c" "$UCALLS" > "$USHIM/$_c"
    chmod 755 "$USHIM/$_c"
done

# launchctl is recorded like the rest, but `print` answers 3 -- launchd's reply
# for a label it does not have, which is what a bootout that worked leaves
# behind. That selects the branch which has to stay silent.
# shellcheck disable=SC2016  # "$*" and "$1" are written into the stub, not expanded here
printf '#!/bin/sh\nprintf "launchctl %%s\\n" "$*" >> "%s"\ncase "${1:-}" in print) exit 3 ;; esac\nexit 0\n' \
    "$UCALLS" > "$USHIM/launchctl"
chmod 755 "$USHIM/launchctl"

# uninstall.sh reads the IORegistry directly and by design. A machine that
# reports nothing is not a blocker (asserted above), which is what lets
# uninstall_main reach its removals on a Mac that genuinely has sleep disabled.
printf '#!/bin/sh\nexit 0\n' > "$USHIM/ioreg"
chmod 755 "$USHIM/ioreg"

# The subshell is deliberate, here and below: the shimmed PATH must not outlive
# the call, or the rest of this file -- and teardown_state -- would run against
# fakes.
# shellcheck disable=SC2030,SC2031
run_shimmed() ( PATH="$USHIM:$PATH"; export PATH; "$@" )

# shellcheck disable=SC2030,SC2031
run_uninstall_main() (
    PATH="$USHIM:$PATH"
    export PATH
    MACON_PREFIX="$UW/prefix"
    MACON_FS_PLIST="$UW/local.macon.failsafe.plist"
    MACON_HELPER_PLIST="$UW/local.macon.helper.plist"
    MACON_HELPER_LABEL=local.macon.test
    uninstall_main > "$UW/out" 2>&1
)

# The recorder is proved to record before it is read: a shim directory that was
# never reached would otherwise make every grep below fail, or pass, for a
# reason that has nothing to do with the uninstaller.
assert_ok "the shim accepts a privileged command" run_shimmed sudo -n true
assert_contains "$(cat "$UCALLS")" "sudo -n true" "and records it"
: > "$UCALLS"

assert_ok "the uninstall runs to the end behind the shim" run_uninstall_main
assert_contains "$(cat "$UW/out")" "macon is uninstalled" \
    "and reaches the line that says so"

CALLED=$(cat "$UCALLS")
assert_contains "$CALLED" "bootout system/local.macon.test" \
    "it boots the helper daemon out by label"
assert_contains "$CALLED" "rm -f $UW/local.macon.helper.plist" \
    "and deletes the plist as well -- tidying up after the bootout, not instead"

# The order is the assertion, not the presence. A bootout that ran after the
# components were removed would leave a window in which launchd respawns a
# program that is no longer on disk; one that ran after the plist was deleted
# would still work, but only because bootout does not read the file.
BOOTOUT_RUN=$(printf '%s\n' "$CALLED" | grep -n 'bootout system/local.macon.test' | head -1 | cut -d: -f1)
PLIST_RM_RUN=$(printf '%s\n' "$CALLED" | grep -nF "rm -f $UW/local.macon.helper.plist" | head -1 | cut -d: -f1)
COMP_RM_RUN=$(printf '%s\n' "$CALLED" | grep -n 'rm -rf .*libexec/macon' | head -1 | cut -d: -f1)
assert_ok "the daemon is stopped before the program it runs is removed" \
    test "$BOOTOUT_RUN" -lt "$COMP_RM_RUN"
assert_ok "and before its plist goes" \
    test "$BOOTOUT_RUN" -lt "$PLIST_RM_RUN"

# launchd was asked whether the job really went, and said no such label. The
# by-hand instructions are for the case where it is still there.
assert_contains "$CALLED" "launchctl print system/local.macon.test" \
    "the uninstall checks the bootout actually took"
assert_fail "and stays quiet when launchd no longer has the job" \
    grep -q "still loaded" "$UW/out"

teardown_state
