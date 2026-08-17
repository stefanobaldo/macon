#!/bin/sh
# Opt-in. Mutates real power settings and restores them.
# Run with: MACON_REAL_TESTS=1 sh tests/real/run.sh
#
# Everything else in tests/ runs against tests/fake-platform.sh and cannot
# touch the machine. This file is the one place where the real pmset, the real
# ioreg and the real root helper are exercised end to end -- which is the only
# way to check the claim the whole project rests on: that the original power
# configuration comes back.
set -u
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
# shellcheck source=tests/real/installed.sh
. "$TESTS_DIR/real/installed.sh"

[ "${MACON_REAL_TESTS:-0}" = "1" ] || { printf '  skipped (set MACON_REAL_TESTS=1)\n'; exit 0; }

# The same AC-block parse lib/platform.sh uses. Repeated rather than sourced on
# purpose: this suite exists to check the installed tool from the outside, and a
# reader that shares code with the thing under test cannot catch a defect in it.
real_ac_value() {
    pmset -g custom 2>/dev/null | awk -v k="$1" '
        /^AC Power/      { ac = 1; next }
        /^Battery Power/ { ac = 0 }
        ac && $1 == k    { print $2; exit }
    '
}

real_sleep_disabled() {
    ioreg -r -k SleepDisabled 2>/dev/null | grep -q '"SleepDisabled" = Yes'
}

BASE=$(mktemp -d)

# Captured before anything is asserted, because the safety net below restores
# from these and an assertion can fail on the very next line.
BASE_SLEEP=$(real_ac_value sleep)
BASE_DISKSLEEP=$(real_ac_value disksleep)
BASE_POWERNAP=$(real_ac_value powernap)

# A failing assertion in this file exits the shell mid-cycle, which on a real
# machine means exiting with sleep disabled. The project's own invariant --
# no failure path leaves the Mac unable to sleep -- applies to the test suite
# that verifies it, so the restore runs from an EXIT trap and not from the
# happy path. `macon off` first, because that is the supported route and
# exercising it is the point; a direct pmset second, because the case this net
# exists for is `macon off` being the thing that failed.
real_safety_net() {
    _rc=$?
    if real_sleep_disabled ||
        [ "$(real_ac_value sleep)" != "$BASE_SLEEP" ] ||
        [ "$(real_ac_value disksleep)" != "$BASE_DISKSLEEP" ] ||
        [ "$(real_ac_value powernap)" != "$BASE_POWERNAP" ]
    then
        printf '\n  SAFETY NET: the machine is not at its baseline; restoring it\n' >&2
        macon off >/dev/null 2>&1 || :
        if real_sleep_disabled || [ "$(real_ac_value sleep)" != "$BASE_SLEEP" ]; then
            printf '  SAFETY NET: macon off did not restore it; using pmset directly\n' >&2
            sudo pmset -a disablesleep 0 || :
            sudo pmset -c sleep "$BASE_SLEEP" \
                disksleep "$BASE_DISKSLEEP" \
                powernap "$BASE_POWERNAP" || :
        fi
        if real_sleep_disabled; then
            printf '  SAFETY NET FAILED: sleep is STILL disabled. Run: sudo pmset -a disablesleep 0\n' >&2
        else
            printf '  SAFETY NET: the machine is back at its baseline\n' >&2
        fi
    fi
    rm -rf "$BASE"
    exit "$_rc"
}
trap real_safety_net EXIT

# --- preconditions ------------------------------------------------------

assert_ok "macon is installed and on PATH" command -v macon

# This suite calls `macon`, which is the INSTALLED tool -- and an install is a
# copy taken at some earlier moment, not a view of this checkout. A branch that
# leaves bin/macon untouched installs nothing the suite invokes directly, so
# every assertion below passes against a prefix holding none of the code under
# review. That is not hypothetical: it is how a full green run came to be read
# as verifying a helper it had never loaded.
#
# The prefix is derived from the tool actually found rather than assumed to be
# /usr/local, so a MACON_PREFIX install is checked against the tree it came from.
REAL_PREFIX=$(cd "$(dirname "$(command -v macon)")/.." && pwd)
REAL_DRIFT=$(real_installed_drift "$REPO_DIR" "$REAL_PREFIX") && REAL_DRIFT_RC=0 ||
    REAL_DRIFT_RC=1
if [ "$REAL_DRIFT_RC" -ne 0 ]; then
    printf '  the installed tree under %s is not this checkout:\n' "$REAL_PREFIX" >&2
    printf '%s\n' "$REAL_DRIFT" | sed 's/^/    | /' >&2
    printf '  run: sh install.sh -- then try again.\n' >&2
fi
assert_eq "0" "$REAL_DRIFT_RC" "the installed tree is the code in this checkout"

assert_ok "the machine is on AC power" \
    sh -c "pmset -g batt | grep -q \"'AC Power'\""
assert_fail "the machine starts with sleep enabled" real_sleep_disabled
assert_ok "the baseline AC values are readable" \
    sh -c "[ -n '$BASE_SLEEP' ] && [ -n '$BASE_DISKSLEEP' ] && [ -n '$BASE_POWERNAP' ]"

pmset -g custom > "$BASE/before.txt"
ioreg -r -k SleepDisabled | grep '"SleepDisabled"' > "$BASE/before-sd.txt"

# Matched against the `session:` line and nothing else. `macon status` prints
# "clamshell sleep: active" on a perfectly idle machine, so a bare grep for
# "active" is an assertion that passes with no session at all -- the shape this
# project has caught four times already.
real_status_session() {
    macon status | awk -F': *' '/^session:/ { print $2; exit }'
}

assert_eq "none" "$(real_status_session)" "status reports no session before arming"

# --- the cycle ----------------------------------------------------------

# --no-failsafe so the assertion below is about the cycle and not about
# whatever the machine's LaunchDaemon happens to be; tests/real/test_failsafe.sh
# is where the boot failsafe is checked.
assert_ok "on arms a session" macon on 1 --no-failsafe

assert_ok "on applies disablesleep" real_sleep_disabled
assert_eq "0" "$(real_ac_value sleep)" "sleep is zeroed while armed"
assert_eq "0" "$(real_ac_value disksleep)" "disksleep is zeroed while armed"
assert_eq "0" "$(real_ac_value powernap)" "powernap is zeroed while armed"

assert_fail "status no longer reports 'none' once armed" \
    test "$(real_status_session)" = "none"

assert_ok "off restores" macon off

assert_eq "none" "$(real_status_session)" "status reports no session after off"

# --- the comparison this suite exists for -------------------------------

ioreg -r -k SleepDisabled | grep '"SleepDisabled"' > "$BASE/after-sd.txt"
diff -u "$BASE/before-sd.txt" "$BASE/after-sd.txt" > "$BASE/diff-sd.txt" 2>&1 || :
printf '  SleepDisabled diff:\n'
sed 's/^/    | /' "$BASE/diff-sd.txt"
assert_ok "SleepDisabled returns to its original value" \
    test ! -s "$BASE/diff-sd.txt"

# SleepServices is a derived key that materialises once powernap is written
# explicitly; its value tracks powernap, so it is excluded from the diff.
pmset -g custom | grep -v SleepServices > "$BASE/after.txt"
grep -v SleepServices "$BASE/before.txt" > "$BASE/before-filtered.txt"

# Printed rather than merely asserted. This diff IS the result of the suite,
# and a reviewer reading a session log should see it -- empty or not -- instead
# of a bare "ok" standing in for it.
diff -u "$BASE/before-filtered.txt" "$BASE/after.txt" > "$BASE/diff.txt" 2>&1 || :
printf '  pmset -g custom diff (SleepServices excluded):\n'
sed 's/^/    | /' "$BASE/diff.txt"
assert_ok "power configuration returns to the baseline" \
    test ! -s "$BASE/diff.txt"

# --- what the cycle left behind -----------------------------------------

assert_fail "no session descriptor survives the session" \
    test -f /var/run/macon/session.conf

# The index row is written by the same code path a real night ends through, so
# a cycle that restored correctly but recorded nothing is still a defect.
assert_ok "the session index has a row for this cycle" \
    macon report --since 0 --out "$BASE/report.html"
assert_ok "the report renders something" test -s "$BASE/report.html"
assert_ok "the report names the reason the session ended" \
    grep -q 'manual' "$BASE/report.html"
