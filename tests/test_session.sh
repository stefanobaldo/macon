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

# Every read and every write goes through these accessors, so a swapped pair
# would stay invisible: the heartbeat would simply be read back from wherever
# the PID was written. Pin the names.
assert_eq "$MACON_RUN" "$(sess_run_dir)" "the run dir honours MACON_RUN"
assert_eq "$MACON_RUN/session.conf" "$D" "the descriptor is session.conf"
assert_eq "$MACON_RUN/helper.pid" "$(sess_pid_path)" "the pid file is helper.pid"
assert_eq "$MACON_RUN/heartbeat" "$(sess_heartbeat_path)" "the heartbeat is heartbeat"

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

# Every field the helper compares arithmetically, not just the two above.
# strikes is macon_decide's rung-2 operand: the no-AC guard that stops the
# battery draining to zero behind a closed lid.
write_valid
sess_set "$D" strikes notanumber
assert_fail "a non-numeric strikes count is rejected" sess_validate "$D"

write_valid
sess_set "$D" started_at ""
assert_fail "an empty started_at is rejected" sess_validate "$D"

# Magnitude, not just character class. bash 3.2's `[` parses into intmax_t and
# EXITS 2 on anything larger, so an over-long value does not fail a comparison
# -- it makes the comparison fall through. Unrejected here, a 20-digit ceiling
# makes macon_decide skip its hard-ceiling rung and answer `extend`.
write_valid
sess_set "$D" hard_ceiling 99999999999999999999
assert_fail "an over-long ceiling is rejected" sess_validate "$D"

write_valid
sess_set "$D" strikes 99999999999999999999
assert_fail "an over-long strikes count is rejected" sess_validate "$D"

# Leading zeros are decimal to `[` but octal to $(( )), so 0300 would mean two
# different numbers in two places. 099 is not valid octal at all, and an
# arithmetic error is fatal to the whole shell rather than an error a caller
# can catch -- sess_orphaned runs on every command and would take it down.
write_valid
sess_set "$D" interval 0300
assert_fail "a leading-zero interval is rejected" sess_validate "$D"

write_valid
sess_set "$D" interval 099
assert_fail "an interval that is not even valid octal is rejected" sess_validate "$D"

write_valid
sess_set "$D" strikes 0
assert_ok "a plain zero is still a valid number" sess_validate "$D"

# session_id and user are data the helper trusts. `user` is what a later task
# interpolates into `sudo -u` to de-privilege a user-supplied command, so its
# character set is a privilege boundary rather than a format preference.
write_valid
sess_set "$D" user 'root; rm -rf /'
assert_fail "a user name with shell metacharacters is rejected" sess_validate "$D"

write_valid
sess_set "$D" user ""
assert_fail "an empty user is rejected" sess_validate "$D"

write_valid
sess_set "$D" session_id '../../etc/passwd'
assert_fail "a session id with path separators is rejected" sess_validate "$D"

# ...and the constraint must admit what the codebase actually produces. The
# fixture above is a hand-written stand-in; this pins the real generator.
write_valid
sess_set "$D" session_id "$(macon_new_session_id)"
assert_ok "a generated session id validates" sess_validate "$D"

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
write_valid
sess_set "$D" interval "$MACON_INTERVAL_FLOOR"
assert_ok "an interval exactly at the floor is accepted" sess_validate "$D"

# The ceiling is the other half of the same guarantee, and the half that is
# easy to miss: every rung of the poll order is evaluated ONLY at a poll, so
# the interval is the resolution of the hard ceiling and of the no-AC abort
# alike. An interval of a day is a perfectly valid number that defers the
# ceiling by a day -- the sleep between polls is what would be holding the
# machine awake, and no guard inside the loop can fire while it runs.
write_valid
sess_set "$D" interval "$MACON_INTERVAL_CEIL"
assert_ok "an interval exactly at the ceiling is accepted" sess_validate "$D"
write_valid
sess_set "$D" interval "$((MACON_INTERVAL_CEIL + 1))"
assert_fail "an interval above the ceiling is rejected" sess_validate "$D"
write_valid
sess_set "$D" interval 86400
assert_fail "an interval that would defer the hard ceiling by a day is rejected" \
    sess_validate "$D"

# A newline in a value would land as its own KEY=VALUE line, forging a field
# indistinguishable from a written one. The write is refused outright, and the
# field it tried to overwrite keeps its previous value.
write_valid
assert_fail "a value containing a newline is refused" \
    sess_set "$D" user "stefz
strikes=99999999999999999999"
assert_eq "2" "$(sess_get "$D" strikes)" "the forged key never reached the file"
assert_eq "stefz" "$(sess_get "$D" user)" "the refused write left the old value"

# A write that cannot produce its temporary file must be REPORTED, not
# swallowed. sess_set rewrites the descriptor rather than editing it, and the
# root helper re-reads that file at every poll: a rewrite that half succeeded
# and was installed anyway is a poll order whose operands are empty, and empty
# operands make `[ -ge ]` exit 2 on bash 3.2 -- every rung falls through and the
# hard ceiling stops being evaluated at all. Simulated by making the temporary
# path impossible to create, which is what a full or read-only volume produces.
write_valid
mkdir -p "$D.tmp"
assert_fail "a rewrite that cannot be written is refused" \
    sess_set "$D" soft_deadline 1700009999
assert_eq "1700003600" "$(sess_get "$D" soft_deadline)" \
    "and the descriptor still holds the value it had"
assert_ok "the descriptor is still a valid one" sess_validate "$D"
rmdir "$D.tmp"
assert_ok "and the same write succeeds once the path is writable again" \
    sess_set "$D" soft_deadline 1700009999
assert_eq "1700009999" "$(sess_get "$D" soft_deadline)" "with the new value in place"

# Liveness needs both halves proved. A `return 1` stub and a liveness-only
# check that drops the name match are both wrong in opposite directions: the
# first reports every healthy session as an orphan, the second hands a
# recycled PID our identity.
printf '4242\n' > "$(sess_pid_path)"
fake_set proc_4242 '/usr/local/libexec/macon/macon-helper --session 20260815T000000Z-deadbeef'
assert_ok "a live macon-helper is recognised" sess_helper_alive

fake_set proc_4242 '/usr/sbin/cupsd -l'
assert_fail "a live PID that is not the helper is not ours" sess_helper_alive

# Orphan detection: applied, no live helper, stale heartbeat.
write_valid
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

# The tolerance is MACON_HEARTBEAT_GRACE missed polls, so with a 300s interval
# the window is 900s. Straddle it, or the constant is free to be anything.
printf '%s\n' "$((MACON_FAKE_NOW - 900))" > "$(sess_heartbeat_path)"
assert_fail "a heartbeat exactly 3 intervals old is not yet an orphan" sess_orphaned
printf '%s\n' "$((MACON_FAKE_NOW - 901))" > "$(sess_heartbeat_path)"
assert_ok "a heartbeat past 3 intervals is an orphan" sess_orphaned

# Fail closed: a heartbeat that cannot be read is not evidence of health.
rm -f "$(sess_heartbeat_path)"
assert_ok "a missing heartbeat is an orphan" sess_orphaned
printf 'corrupt\n' > "$(sess_heartbeat_path)"
assert_ok "an unreadable heartbeat is an orphan" sess_orphaned

# Detection must never mutate: macon status reports an orphan, it does not
# heal one, and a read command has to stay a read command.
printf '1000\n' > "$(sess_heartbeat_path)"
fake_reset_calls
before=$(find "$MACON_RUN" -type f -exec cksum {} \; | sort)
assert_ok "the orphan is still detected" sess_orphaned
assert_eq "$before" "$(find "$MACON_RUN" -type f -exec cksum {} \; | sort)" \
    "sess_orphaned changed no file under the run dir"
assert_eq "" "$(fake_calls)" "sess_orphaned issued no mutating platform call"

# Nothing applied means nothing to heal.
fake_set sleep_disabled no
printf '1000\n' > "$(sess_heartbeat_path)"
assert_fail "an unmodified machine is never an orphan" sess_orphaned

unset MACON_FAKE_NOW
teardown_state
