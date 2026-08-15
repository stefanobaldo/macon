#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=tests/fake-platform.sh
. "$TESTS_DIR/fake-platform.sh"
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"

fake_set sleep 1
fake_set disksleep 10
fake_set powernap 1
fake_set sleep_disabled no

assert_fail "no snapshot exists initially" snap_exists
assert_fail "a clean machine does not look active" snap_looks_active
assert_ok "snap_save succeeds on a clean machine" snap_save
assert_ok "snapshot exists after saving" snap_exists
assert_eq "sleep 1 disksleep 10 powernap 1" "$(snap_restore_args)" \
    "restore args carry every saved key"

# Restoring must be one pmset call, not one per key.
: > "$MACON_STATE/fake/calls"
plat_pmset_disablesleep 1
plat_pmset_apply_ac sleep 0 disksleep 0 powernap 0
: > "$MACON_STATE/fake/calls"
snap_restore
assert_eq "1" "$(fake_call_count 'pmset_apply_ac')" "restore applies keys in one call"
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 1 disksleep 10 powernap 1" \
    "restore applies the saved values"
assert_contains "$(fake_calls)" "pmset_disablesleep 0" "restore clears disablesleep"
assert_eq "1" "$(plat_pmset_read sleep)" "sleep is back to its original value"

# The poisoning guard: no snapshot plus an already-modified machine.
rm -f "$(snap_path)"
fake_set sleep 0
fake_set disksleep 0
fake_set powernap 0
assert_ok "an all-zero machine looks active" snap_looks_active
assert_fail "snap_save refuses to snapshot a modified machine" snap_save
assert_fail "no snapshot was written" snap_exists

# disablesleep alone is enough to consider the machine active.
fake_set sleep 1
fake_set disksleep 10
fake_set powernap 1
fake_set sleep_disabled yes
assert_ok "disablesleep=yes alone means active" snap_looks_active
assert_fail "snap_save still refuses" snap_save

teardown_state
