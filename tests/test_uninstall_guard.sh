#!/bin/sh
# Uninstalling is the one operation that can strand this Mac.
#
# Removing bin/macon, the helper and the LaunchDaemon while the machine is
# still modified takes away every way back at once: the CLI that would restore
# the power settings, and the boot failsafe that was the last line of defence
# if nobody did. So uninstall.sh refuses while anything says the machine is
# still holding a session, and this file is the proof of that refusal.
#
# uninstall.sh guards its side-effecting section behind MACON_UNINSTALL_SOURCED,
# so sourcing it defines the functions and removes nothing.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state

MACON_UNINSTALL_SOURCED=1
export MACON_UNINSTALL_SOURCED
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

# --- refusing to run as root ------------------------------------------------
#
# Not symmetry with install.sh: under sudo, HOME is root's, so the snapshot
# check above would look in a directory that never holds one and report the
# machine as safe to strand.

assert_ok "an unprivileged uninstall is allowed" uninstall_check_not_root 501
assert_fail "uninstalling as root is refused" uninstall_check_not_root 0
OUT=$(uninstall_check_not_root 0 2>&1) || :
assert_contains "$OUT" "sudo" "and says the script sudo's what it needs"

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
