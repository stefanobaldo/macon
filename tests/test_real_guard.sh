#!/bin/sh
# The opt-in suite in tests/real/ exercises whatever `macon` is on PATH -- the
# installed tree, never this checkout. That is deliberate: it exists to check
# the installed artifact from the outside. What it lacked was any assertion that
# the installed artifact is the code under review.
#
# A branch whose bin/macon is unchanged installs nothing new into the one file
# the suite calls, so a stale /usr/local passes all fifteen assertions while the
# change being reviewed never executes. That happened: a full green run was read
# as verifying a helper it had not loaded.
#
# So the drift check lives in a sourceable file and is tested here, against
# temporary directories, rather than being a line in test_cycle.sh that only
# runs on a machine with sudo and AC power.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
# shellcheck source=tests/real/installed.sh
. "$REPO_DIR/tests/real/installed.sh"
setup_state

W="$MACON_STATE/guard"

# Builds a checkout and the prefix `install.sh` would produce from it, and
# prints the root holding both. The copies are made exactly as install.sh:310-313
# makes them -- three named files and lib/*.sh by glob -- so a fixture that
# drifts from the installer is a fixture that fails here first.
new_pair() {
    _r="$W/$1"
    mkdir -p "$_r/repo/bin" "$_r/repo/libexec" "$_r/repo/lib" \
        "$_r/prefix/bin" "$_r/prefix/libexec/macon/lib"
    printf 'cli\n' > "$_r/repo/bin/macon"
    printf 'helper\n' > "$_r/repo/libexec/macon-helper"
    printf 'failsafe\n' > "$_r/repo/libexec/failsafe.sh"
    printf 'common\n' > "$_r/repo/lib/common.sh"
    printf 'platform\n' > "$_r/repo/lib/platform.sh"

    cp "$_r/repo/bin/macon" "$_r/prefix/bin/macon"
    cp "$_r/repo/libexec/macon-helper" "$_r/prefix/libexec/macon/macon-helper"
    cp "$_r/repo/libexec/failsafe.sh" "$_r/prefix/libexec/macon/failsafe.sh"
    cp "$_r"/repo/lib/*.sh "$_r/prefix/libexec/macon/lib/"

    printf '%s\n' "$_r"
}

# --- the case the check exists for --------------------------------------

R=$(new_pair helper-differs)
printf 'helper v2\n' > "$R/prefix/libexec/macon/macon-helper"

out=$(real_installed_drift "$R/repo" "$R/prefix") && rc=0 || rc=1
assert_eq "1" "$rc" "an installed helper that differs from the checkout is drift"
assert_contains "$out" "libexec/macon/macon-helper" \
    "and the drifting path is named"

# The file that actually drifted on the maintainer's machine was lib/platform.sh,
# reached by glob rather than by name. A check written from the three named
# copies alone passes this fixture and misses the real incident.
R=$(new_pair lib-differs)
printf 'platform v2\n' > "$R/prefix/libexec/macon/lib/platform.sh"

out=$(real_installed_drift "$R/repo" "$R/prefix") && rc=0 || rc=1
assert_eq "1" "$rc" "an installed lib that differs from the checkout is drift"
assert_contains "$out" "libexec/macon/lib/platform.sh" \
    "and the drifting lib is named"

# install.sh copies; it never deletes. A lib this checkout no longer carries
# stays in the prefix, and bin/macon sources every lib/*.sh it finds there -- so
# the installed tool keeps running code the branch deleted. Walking the checkout
# alone cannot see it: nothing in the repo points at the file.
R=$(new_pair stale-leftover)
printf 'removed\n' > "$R/prefix/libexec/macon/lib/legacy.sh"

out=$(real_installed_drift "$R/repo" "$R/prefix") && rc=0 || rc=1
assert_eq "1" "$rc" "an installed lib the checkout no longer carries is drift"
assert_contains "$out" "libexec/macon/lib/legacy.sh" \
    "and the leftover is named"

# --- and the other direction ---------------------------------------------

# Without this, a check that reported drift unconditionally would satisfy every
# assertion above while making the real suite impossible to run.
R=$(new_pair matching)

out=$(real_installed_drift "$R/repo" "$R/prefix") && rc=0 || rc=1
assert_eq "0" "$rc" "a prefix installed from this checkout is not drift"
assert_eq "" "$out" "and nothing is named"

# A prefix with nothing in it is the case of a tool that was never installed.
# The real suite has its own assertion for that, but this one must not be
# silent about it either.
R=$(new_pair not-installed)
rm -f "$R/prefix/libexec/macon/macon-helper"

out=$(real_installed_drift "$R/repo" "$R/prefix") && rc=0 || rc=1
assert_eq "1" "$rc" "an installed file that is missing entirely is drift"
assert_contains "$out" "libexec/macon/macon-helper" "and the missing path is named"

teardown_state
