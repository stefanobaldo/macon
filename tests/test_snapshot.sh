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

# --- the plist backups are bounded ------------------------------------------
#
# One directory per arm, forensic only, and nothing used to remove them: 48 in
# three days on the verification machine. The retention keeps the newest, which
# is what a by-hand recovery reads; the older ones matter only if the newest was
# itself taken after something had already gone wrong.

count_pmprefs() {
    _n=0
    for _d in "$MACON_STATE"/pmprefs-*; do
        [ -d "$_d" ] || continue
        _n=$((_n + 1))
    done
    printf '%s\n' "$_n"
}

# The block above left the fake scripted to write no plist at all, and left its
# own backup directories behind. Both are reset here: this block counts the
# directories, and it asserts on the rc a landed plist produces.
fake_set pmprefs_files 1
rm -rf "$MACON_STATE"/pmprefs-*

MACON_PMPREFS_KEEP=3
: > "$MACON_STATE/snapshot"
for _s in 1 2 3 4 5; do
    mkdir -p "$MACON_STATE/pmprefs-20260101-00000$_s"
done

NEW=$(snap_backup_plists)
assert_eq "3" "$(count_pmprefs)" "the backups are pruned to the retention"
assert_ok "the directory just created survives" test -d "$NEW"
assert_ok "so does the newest of the older ones" \
    test -d "$MACON_STATE/pmprefs-20260101-000005"
assert_fail "the oldest is gone" \
    test -d "$MACON_STATE/pmprefs-20260101-000001"
assert_ok "the snapshot file is never a candidate" \
    test -f "$MACON_STATE/snapshot"

# Below the retention nothing is removed, and the backup still reports whether
# a plist landed -- pruning must not change that verdict.
rm -rf "$MACON_STATE"/pmprefs-*
MACON_PMPREFS_KEEP=10
backup_dir=$(snap_backup_plists)
backup_rc=$?
assert_eq "0" "$backup_rc" "a backup below the retention succeeds"
assert_eq "1" "$(count_pmprefs)" "and nothing was pruned"

# The retention arrives from the environment and is a count this module deletes
# by, so a value that is not a number must land on the default -- never on the
# zero that unvalidated arithmetic would make it, which would delete the whole
# forensic history. The guard runs where the constant is established, so the
# module is re-sourced here the way a real run reads its environment.
MACON_PMPREFS_KEEP=""
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
assert_eq "10" "$MACON_PMPREFS_KEEP" "an empty retention falls back to the default"

MACON_PMPREFS_KEEP=ten
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
assert_eq "10" "$MACON_PMPREFS_KEEP" "and so does one that is not a number"

rm -rf "$MACON_STATE"/pmprefs-*
for _s in 01 02 03 04 05 06 07 08 09 10 11 12; do
    mkdir -p "$MACON_STATE/pmprefs-20260101-0000$_s"
done
NEW=$(snap_backup_plists)
assert_eq "10" "$(count_pmprefs)" \
    "a non-numeric retention prunes to the default rather than deleting them all"
assert_ok "the directory just created survives it" test -d "$NEW"
assert_ok "so does the newest of the older ones" \
    test -d "$MACON_STATE/pmprefs-20260101-000012"

# All digits is not enough: /bin/sh here is bash 3.2, so 20 digits WRAP rather
# than fail, and the wrapped excess is larger than the directory -- keep-0 again,
# through a value the shape check accepts.
MACON_PMPREFS_KEEP=10000000000000000000
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
assert_eq "10" "$MACON_PMPREFS_KEEP" "an over-long retention falls back to the default too"

rm -rf "$MACON_STATE"/pmprefs-*
for _s in 01 02 03 04 05 06 07 08 09 10 11 12; do
    mkdir -p "$MACON_STATE/pmprefs-20260101-0000$_s"
done
NEW=$(snap_backup_plists)
assert_eq "10" "$(count_pmprefs)" \
    "an over-long retention prunes to the default rather than deleting them all"
assert_ok "and the directory just created survives that too" test -d "$NEW"

# The bound is a length, not a magnitude: the longest value it accepts is still
# accepted, and keeping more than exist prunes nothing.
MACON_PMPREFS_KEEP=999999999999999999
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
assert_eq "999999999999999999" "$MACON_PMPREFS_KEEP" \
    "a retention at the length bound is kept"

rm -rf "$MACON_STATE"/pmprefs-*
for _s in 01 02 03 04 05 06 07 08 09 10 11 12; do
    mkdir -p "$MACON_STATE/pmprefs-20260101-0000$_s"
done
NEW=$(snap_backup_plists)
assert_eq "13" "$(count_pmprefs)" "and prunes nothing, since none is in excess"
assert_ok "the oldest is still there" \
    test -d "$MACON_STATE/pmprefs-20260101-000001"
assert_ok "and so is the directory just created" test -d "$NEW"

teardown_state
