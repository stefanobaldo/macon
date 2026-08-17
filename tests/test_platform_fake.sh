#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=tests/fake-platform.sh
. "$TESTS_DIR/fake-platform.sh"

fake_set sleep 1
fake_set disksleep 10
fake_set powernap 1
fake_set sleep_disabled no
fake_set power_source ac
fake_set battery_pct 80
fake_set thermal Nominal
fake_set boot_time 1700000000

assert_eq "1" "$(plat_pmset_read sleep)" "fake returns the scripted sleep value"
assert_eq "10" "$(plat_pmset_read disksleep)" "fake returns the scripted disksleep value"
assert_eq "" "$(plat_pmset_read nosuchkey)" "unknown key reads empty"
assert_fail "sleep_disabled is false when scripted no" plat_sleep_disabled
assert_eq "ac" "$(plat_power_source)" "fake reports the scripted power source"
assert_eq "80" "$(plat_battery_pct)" "fake reports the scripted battery level"
assert_eq "Nominal" "$(plat_thermal_pressure)" "fake reports the scripted thermal level"
assert_eq "1700000000" "$(plat_boot_time)" "fake reports the scripted boot time"

fake_set sleep_disabled yes
assert_ok "sleep_disabled is true when scripted yes" plat_sleep_disabled

# A pattern that never matched must report zero, not an empty string and not a
# doubled count. Later tasks assert "this call was never made", so the miss case
# carries as much weight as the hit case.
assert_eq "0" "$(fake_call_count 'never_called_anything')" \
    "an unmatched pattern counts zero"

# Applying keys must be observable as a single call, because pmset validates
# the whole key set per invocation.
plat_pmset_apply_ac sleep 0 disksleep 0 powernap 0
assert_eq "1" "$(fake_call_count 'pmset_apply_ac')" "apply is recorded as one call"
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 0 disksleep 0 powernap 0" \
    "apply records every key in one call"
assert_eq "0" "$(plat_pmset_read sleep)" "apply updates the fake's state"

fake_reset_calls
plat_say_as_user someone "Mac on activated, 2 hours remaining."
assert_eq "1" "$(fake_call_count 'say_as_user')" \
    "the announcement is recorded rather than spoken"
assert_contains "$(fake_calls)" "say_as_user someone Mac on activated" \
    "and records who it would be spoken as, and what was said"

# --- fake/real parity -------------------------------------------------------
#
# This file REPLACES lib/platform.sh in every test that loads it; it is not an
# overlay. So a plat_ function the real file defines and this one does not is a
# "command not found" at best -- and for anything that touches hardware, a test
# reaching the real machine instead of the fake.
#
# plat_say_as_user is what made this worth pinning. A suite that can speak is a
# suite that speaks out loud on whoever runs it, and on a CI runner too: GitHub's
# macOS images ship `say` like any other Mac. Keeping that from happening is a
# property of where the function lives, and this is the assertion that keeps it
# living there.
#
# plat_needs_sudo is the only one allowed to be absent, and deliberately so:
# there is no machine behind a pure predicate, and it is tested by calling the
# real one because the branch that matters -- uid 0 running direct -- cannot be
# reached by a suite that does not run as root.
PURE_PREDICATES='plat_needs_sudo'

_real_list="$MACON_STATE/plat-real"
_fake_list="$MACON_STATE/plat-fake"
grep -oE '^plat_[a-z_0-9]+\(\)' "$MACON_LIB/platform.sh" | tr -d '()' | sort > "$_real_list"
grep -oE '^plat_[a-z_0-9]+\(\)' "$TESTS_DIR/fake-platform.sh" | tr -d '()' | sort > "$_fake_list"

# A regex that stopped matching would make every assertion below vacuously
# true, which is the failure mode of comparing two empty lists.
assert_ok "the parity check found functions to compare" \
    [ "$(wc -l < "$_real_list")" -gt 10 ]

_unfaked=$(comm -23 "$_real_list" "$_fake_list" | grep -vxF "$PURE_PREDICATES" || :)
assert_eq "" "$_unfaked" \
    "every machine-touching plat_ function has a fake, so no test reaches the real Mac"

teardown_state
