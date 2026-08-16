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

teardown_state
