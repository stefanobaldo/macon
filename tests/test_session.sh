#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=tests/fake-platform.sh
. "$TESTS_DIR/fake-platform.sh"
# shellcheck source=lib/session.sh
. "$MACON_LIB/session.sh"

mkdir -p "$(sess_run_dir)"
D=$(sess_desc_path)

write_valid() {
    : > "$D"
    sess_set "$D" session_id 20260815T000000Z-deadbeef
    sess_set "$D" started_at 1700000000
    sess_set "$D" soft_deadline 1700003600
    sess_set "$D" hard_ceiling 1700007200
    sess_set "$D" policy restore
    sess_set "$D" interval 300
    sess_set "$D" strikes 2
    sess_set "$D" completion none
    sess_set "$D" user stefz
}

write_valid
assert_eq "restore" "$(sess_get "$D" policy)" "sess_get reads a field back"
assert_ok "a well-formed descriptor validates" sess_validate "$D"

# Numbers must be numbers: these values become command arguments and
# deadline comparisons.
write_valid
sess_set "$D" interval "300; rm -rf /"
assert_fail "a non-numeric interval is rejected" sess_validate "$D"

write_valid
sess_set "$D" hard_ceiling notanumber
assert_fail "a non-numeric ceiling is rejected" sess_validate "$D"

# Enumerations must be in range.
write_valid
sess_set "$D" policy destroy
assert_fail "an unknown policy is rejected" sess_validate "$D"

write_valid
sess_set "$D" completion telepathy
assert_fail "an unknown completion source is rejected" sess_validate "$D"

# The ceiling can never precede the soft deadline.
write_valid
sess_set "$D" hard_ceiling 1700001000
assert_fail "a ceiling before the soft deadline is rejected" sess_validate "$D"

# The interval floor protects against hammering powermetrics as root.
write_valid
sess_set "$D" interval 5
assert_fail "an interval below the 30s floor is rejected" sess_validate "$D"

# Orphan detection: applied, no live helper, stale heartbeat.
fake_set sleep_disabled yes
printf '999999\n' > "$(sess_pid_path)"
printf '1000\n' > "$(sess_heartbeat_path)"
MACON_FAKE_NOW=1700000000
export MACON_FAKE_NOW
assert_fail "a dead PID is not a live helper" sess_helper_alive
assert_ok "applied + no helper + stale heartbeat is an orphan" sess_orphaned

# A fresh heartbeat is not an orphan, even without a live PID: the helper
# may simply be between polls.
printf '%s\n' "$MACON_FAKE_NOW" > "$(sess_heartbeat_path)"
assert_fail "a fresh heartbeat is not an orphan" sess_orphaned

# Nothing applied means nothing to heal.
fake_set sleep_disabled no
printf '1000\n' > "$(sess_heartbeat_path)"
assert_fail "an unmodified machine is never an orphan" sess_orphaned

unset MACON_FAKE_NOW
teardown_state
