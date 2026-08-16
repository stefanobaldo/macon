#!/bin/sh
# Sourcing install.sh or uninstall.sh must not touch this machine.
#
# This is the assertion whose absence let a green suite hide a real install.
# Both scripts are written to be sourced -- it is how tests/test_install_checks.sh
# and tests/test_uninstall_guard.sh reach the pure functions without writing to
# /usr/local -- and both used to protect their privileged half by WRAPPING it in
# an `if ...; then ... fi`. A wrapper is a guard only while its two halves stay
# paired. One unbalanced `fi` closed the installer's early, the privileged half
# became top-level code, and the next `. install.sh` in the test suite installed
# macon into /usr/local and bootstrapped a root LaunchDaemon. Every test file
# still passed, because nothing asserted that sourcing does nothing.
#
# So this file asserts it directly, at the seam where it matters: with a PATH
# shim standing in front of every command either script uses to change the
# machine. The shim records the call and refuses it, which makes this test safe
# to run against the real default prefix -- and running it against the real
# default prefix is what keeps it honest, see the note on MACON_PREFIX below.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state

W="$MACON_STATE/inert"
SHIM="$W/shim"
CALLS="$W/calls"
mkdir -p "$SHIM" "$W/run" "$W/state"
: > "$CALLS"

# Everything either script reaches for when it changes this machine. sudo alone
# would very nearly do -- every removal and every copy goes through it -- but
# the point of the shim is that it does not depend on knowing that, so the whole
# mutating vocabulary is in front of the real binaries.
#
# They exit non-zero: a script that got past its guard should stop at the first
# refused call rather than run on and find something else to do.
for _c in sudo launchctl chown chmod cp install mkdir mv ln rm pmset; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 97\n' \
        "$_c" "$CALLS" > "$SHIM/$_c"
    chmod 755 "$SHIM/$_c"
done

# The recorder is proved to record before it is trusted to stay empty. Without
# this, a shim directory that was never reached -- a typo in PATH, a chmod that
# did not take -- would make every assertion below pass by doing nothing.
#
# The subshell is deliberate, here and below: the shimmed PATH must not outlive
# the call, or the rest of this file -- and teardown_state -- would be running
# against fakes.
# shellcheck disable=SC2030,SC2031
run_shimmed() ( PATH="$SHIM:$PATH"; export PATH; "$@" )
assert_fail "the shim refuses a privileged command" run_shimmed sudo -n true
assert_contains "$(cat "$CALLS")" "sudo -n true" "and records it"
: > "$CALLS"

# Sourced the way the incident sourced it: from a shell with NO positional
# parameters, which is what a test file is. `sh -c` with no operands after the
# command string leaves $# at 0 and $0 at "sh", exactly as tests/test_*.sh do.
#
# MACON_RUN and MACON_STATE point at empty temporary directories on purpose, and
# MACON_PREFIX is deliberately NOT set. A run that reached the privileged half
# has to get all the way to a privileged call for this test to mean anything: a
# real snapshot on this machine, or a prefix under a user-owned temporary
# directory, would make it refuse for an unrelated reason and this file would
# pass on a tree that was installing itself. Empty state directories clear the
# session blockers; the default prefix, /usr/local, is root-owned on a Mac and
# clears the unsafe-prefix refusal. The shim is what makes that safe.
# shellcheck disable=SC2030,SC2031
source_file() (
    PATH="$SHIM:$PATH"
    export PATH
    MACON_SOURCE_FILE="$1" MACON_SOURCE_PROBE="$2" \
        SRC_DIR="$REPO_DIR" MACON_RUN="$W/run" MACON_STATE="$W/state" \
        sh -c 'set -u
. "$MACON_SOURCE_FILE"
command -v "$MACON_SOURCE_PROBE" >/dev/null || exit 3
printf "sourced-and-defined\n"' 2>&1
)

# --- install.sh -------------------------------------------------------------

# The privileged assertion goes first, so that a tree which has lost its guard
# fails on the sentence that describes what went wrong. The tail of install.sh
# ends in `sudo sh install.sh --install-files`, a `chown -R root:wheel` and a
# `macon failsafe install` that bootstraps a root LaunchDaemon.
OUT=$(source_file "$REPO_DIR/install.sh" install_files) || :
assert_eq "" "$(cat "$CALLS")" \
    "sourcing install.sh runs no privileged command -- no sudo, cp, chown or launchctl"
assert_contains "$OUT" "sourced-and-defined" \
    "and still defines its functions, which is what it is sourced for"
: > "$CALLS"

# --- uninstall.sh -----------------------------------------------------------
#
# Equally capable of harm and sourced by its own test file: its tail is
# `sudo launchctl bootout`, `sudo rm -f` and `sudo rm -rf` against a prefix that
# defaults to /usr/local.

OUT=$(source_file "$REPO_DIR/uninstall.sh" uninstall_blockers) || :
assert_eq "" "$(cat "$CALLS")" \
    "sourcing uninstall.sh runs no privileged command -- no sudo rm, no launchctl bootout"
assert_contains "$OUT" "sourced-and-defined" \
    "and still defines its functions, which is what it is sourced for"

teardown_state
