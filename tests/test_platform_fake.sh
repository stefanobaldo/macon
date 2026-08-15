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

teardown_state
