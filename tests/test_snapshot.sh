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
fake_reset_calls
plat_pmset_disablesleep 1
plat_pmset_apply_ac sleep 0 disksleep 0 powernap 0
fake_reset_calls
assert_ok "restore succeeds with a complete snapshot" snap_restore
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

# Restoring without a snapshot must still free the machine, and must say so.
# Clearing disablesleep is the call that actually restores the ability to
# sleep; the non-zero rc is how a caller learns nothing was reapplied.
fake_reset_calls
assert_fail "restore reports failure when no snapshot exists" snap_restore
assert_contains "$(fake_calls)" "pmset_disablesleep 0" \
    "restore still clears disablesleep without a snapshot"
assert_eq "0" "$(fake_call_count 'pmset_apply_ac')" \
    "restore issues no apply call without a snapshot"
assert_fail "the machine can sleep again afterwards" plat_sleep_disabled

# An unreadable pmset prints nothing at rc 0. Recording that would yield a
# snapshot that passes snap_exists and restores nothing, so snap_save must
# fail closed — and must not destroy the snapshot it already had.
fake_set sleep_disabled no
fake_set sleep 1
fake_set disksleep 10
fake_set powernap 1
assert_ok "a good snapshot is saved first" snap_save

fake_set powernap ""
assert_fail "snap_save refuses an empty reading" snap_save
assert_eq "sleep 1 disksleep 10 powernap 1" "$(snap_restore_args)" \
    "the previous snapshot survived the refused save"

fake_set powernap "0; rm -rf /"
assert_fail "snap_save refuses a non-numeric reading" snap_save
assert_eq "sleep 1 disksleep 10 powernap 1" "$(snap_restore_args)" \
    "the previous snapshot survived the second refused save"

# Values read back off disk become pmset arguments, so a malformed field is
# dropped rather than passed through.
printf 'sleep=1\ndisksleep=oops\npowernap=1\n' > "$(snap_path)"
assert_eq "sleep 1 powernap 1" "$(snap_restore_args)" \
    "a malformed field is dropped from the restore args"
fake_reset_calls
assert_ok "restore succeeds on the surviving fields" snap_restore
assert_contains "$(fake_calls)" "pmset_apply_ac sleep 1 powernap 1" \
    "only validated fields reach pmset"

# The forensic plist copy goes through the platform layer, and an empty
# directory does not count as a backup having happened.
fake_reset_calls
fake_set pmprefs_files 2
backup_dir=$(snap_backup_plists)
backup_rc=$?
assert_eq "0" "$backup_rc" "backing up plists succeeds when files land"
assert_contains "$(fake_calls)" "backup_pmprefs $backup_dir" \
    "the backup goes through the platform layer"
assert_ok "a plist landed in the backup directory" \
    test -f "$backup_dir/com.apple.PowerManagement.1.plist"

fake_set pmprefs_files 0
backup_dir=$(snap_backup_plists)
backup_rc=$?
assert_eq "1" "$backup_rc" "backup reports failure when no plist landed"
assert_ok "the destination is still echoed on failure" test -n "$backup_dir"

teardown_state
