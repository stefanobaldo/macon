#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
MACON_CLI_SOURCED=1
export MACON_CLI_SOURCED
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=tests/fake-platform.sh
. "$TESTS_DIR/fake-platform.sh"
# shellcheck source=lib/decide.sh
. "$MACON_LIB/decide.sh"
# shellcheck source=lib/session.sh
. "$MACON_LIB/session.sh"
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
# shellcheck source=lib/records.sh
. "$MACON_LIB/records.sh"
# shellcheck source=bin/macon
. "$REPO_DIR/bin/macon"

# --- splitting the argument list at -- ---------------------------------------

cli_split_wrap_args --max 12 -- echo hello world
assert_eq "--max 12" "$WRAP_OPTS" "options before -- are macon's"
assert_eq "echo hello world" "$WRAP_CMD" "everything after -- is the wrapped command"

cli_split_wrap_args -- true
assert_eq "" "$WRAP_OPTS" "no options is valid"
assert_eq "true" "$WRAP_CMD" "a bare command is captured"

assert_fail "a missing -- separator is rejected" cli_split_wrap_args --max 12 echo hi
assert_fail "an empty command after -- is rejected" cli_split_wrap_args --max 12 --
assert_fail "no arguments at all are rejected" cli_split_wrap_args

# A second -- belongs to the command: it is the command's own separator, and
# macon has already consumed the one that was addressed to it.
cli_split_wrap_args -- git log -- path
assert_eq "git log -- path" "$WRAP_CMD" "a second -- stays with the wrapped command"

# run implies a completion source, so extend is accepted without --busy-check.
assert_ok "run satisfies the completion-source requirement for extend" \
    cli_parse_on --wrap --on-expire extend --max 12

# --- the option list is re-derived, never re-split ---------------------------
#
# WRAP_OPTS is a display string and cannot represent an option value that
# contains a space. Parsing it back would turn one argument into four, and the
# fourth would be reported as an unknown option -- so what is parsed is the
# original positional parameters, rotated into place.

assert_ok "an option value containing spaces survives parsing" \
    cli_run_parse --busy-check 'pgrep -qf my daemon' --max 12 -- true
assert_eq "pgrep -qf my daemon" "$OPT_BUSY_CHECK" \
    "the busy-check keeps its spaces"
assert_eq "12" "$OPT_MAX" "the ceiling is parsed from the same list"

assert_ok "no options before -- parses cleanly" cli_run_parse -- true
assert_eq "" "$OPT_MAX" "with no --max the ceiling is left for run to require"

assert_fail "an unknown option before -- is still refused" \
    cli_run_parse --nonsense -- true

# --- driving cli_cmd_run end to end ------------------------------------------

MACON_ARM_TRIES=3

MACON_FS_PLIST="$MACON_STATE/local.macon.failsafe.plist"
: > "$MACON_FS_PLIST"

TMPDIR="$MACON_STATE/tmp"
mkdir -p "$TMPDIR"
export TMPDIR

MACON_FAKE_NOW=1700000000
export MACON_FAKE_NOW

# The same stand-in for `macon-helper start DESCRIPTOR` the rollback tests use:
# it installs its own copy of the descriptor and declares a live process the
# real sess_helper_alive can match by name.
STUB="$MACON_STATE/stub-helper.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
cp "$1" "$MACON_RUN/session.conf"
sleep 30 &
_pid=$!
printf '%s\n' "$_pid" > "$MACON_RUN/helper.pid"
printf 'macon-helper start %s\n' "$1" > "$MACON_STATE/fake/proc_$_pid"
STUBEOF

# Reports every argument it was handed, one per line, and its own pid. Both are
# the assertions that matter: the pid is what macon must actually watch, and the
# argument list is what a second trip through `sh -c` would silently re-split.
ARGS="$MACON_STATE/args.sh"
cat > "$ARGS" <<'ARGSEOF'
#!/bin/sh
_out=$1
shift
printf '%s\n' "$$" > "$_out.pid"
: > "$_out"
for _a in "$@"; do printf '[%s]\n' "$_a" >> "$_out"; done
ARGSEOF

clean_machine() {
    fake_set sleep 1
    fake_set disksleep 10
    fake_set powernap 1
    fake_set sleep_disabled no
    fake_set power_source ac
    fake_set battery_pct 80
    fake_set fail_pmset_apply_ac 0
    fake_set fail_pmset_disablesleep 0
    rm -f "$MACON_RUN"/* 2>/dev/null || :
    rm -f "$(snap_path)"
    snap_save
    fake_reset_calls
}

kill_stub() {
    _p=$(cat "$(sess_pid_path)" 2>/dev/null)
    [ -n "$_p" ] && kill "$_p" 2>/dev/null
    return 0
}

mkdir -p "$(sess_run_dir)"

# `run` has no positional duration, so the ceiling is the only bound it can
# have -- and a session with no bound is the one thing that must not start.
clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\" &"
( cli_cmd_run -- true ) 2>/dev/null
assert_fail "run refuses to start without --max" test "$?" -eq 0
assert_eq "0" "$(fake_call_count 'pmset')" "the missing ceiling touched nothing"

# --- the happy path ----------------------------------------------------------

clean_machine
OUT="$MACON_STATE/argv.out"
rm -f "$OUT" "$OUT.pid"
( cli_cmd_run --max 12 -- sh "$ARGS" "$OUT" "one two" three ) >/dev/null
assert_eq "0" "$?" "run exits with the wrapped command's status"

assert_eq "[one two]
[three]" "$(cat "$OUT")" "the wrapped command keeps the arguments it was given"

I="$(sess_desc_path)"
assert_ok "the helper installed its own copy of the descriptor" test -f "$I"
assert_eq "process" "$(sess_get "$I" completion)" \
    "the wrapped process is the completion source"
assert_eq "$(cat "$OUT.pid")" "$(sess_get "$I" watch_pid)" \
    "the watched pid is the process macon actually started"
assert_eq "1700043200" "$(sess_get "$I" hard_ceiling)" "the ceiling is now + 12h"
assert_eq "1700043200" "$(sess_get "$I" soft_deadline)" \
    "with no separate duration the soft deadline is the ceiling"
assert_ok "the descriptor the helper installed is valid" sess_validate "$I"
kill_stub

# The wrapped command's exit status is the command's answer, not macon's.
clean_machine
( cli_cmd_run --max 12 -- sh -c 'exit 7' ) >/dev/null
assert_eq "7" "$?" "a failing wrapped command fails macon run"
kill_stub

assert_eq "" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'macon-session.*' 2>/dev/null)" \
    "the hand-over descriptor is cleaned up"

# --- refusals happen before the command starts -------------------------------
#
# Every guard that can refuse a session runs first. A refusal that arrived after
# the wrapped command had started would leave it running with nothing keeping
# the Mac awake for it -- and macon_die exits, so there is no return path on
# which it could be cleaned up.

clean_machine
MARK="$MACON_STATE/never.out"
rm -f "$MARK" "$MARK.pid"
fake_set power_source battery
( cli_cmd_run --max 12 -- sh "$ARGS" "$MARK" x ) >/dev/null 2>&1
assert_fail "run on battery is refused" test "$?" -eq 0
assert_fail "the wrapped command was never started" test -f "$MARK.pid"
assert_eq "0" "$(fake_call_count 'pmset')" "the battery refusal touched nothing"

clean_machine
rm -f "$MACON_FS_PLIST"
rm -f "$MARK" "$MARK.pid"
( cli_cmd_run --max 12 -- sh "$ARGS" "$MARK" x ) >/dev/null 2>&1
assert_fail "run without the boot failsafe is refused" test "$?" -eq 0
assert_fail "the wrapped command was not started for that refusal either" \
    test -f "$MARK.pid"
: > "$MACON_FS_PLIST"

# --- arming fails after the command has started ------------------------------
#
# This is the one window that cannot be closed by ordering: the wrapped process
# has to exist before the descriptor can name it. If the session then fails to
# arm, the command it started must not be left running -- together with whatever
# it spawned, which is why it is started in its own process group.

clean_machine
TREE="$MACON_STATE/tree.sh"
cat > "$TREE" <<'TREEEOF'
#!/bin/sh
sleep 30 &
printf '%s\n' "$!" > "$1.child"
printf '%s\n' "$$" > "$1"
wait
TREEEOF
PIDF="$MACON_STATE/tree.pid"
rm -f "$PIDF" "$PIDF.child"

MACON_HELPER_CMD="false"
( cli_cmd_run --max 12 -- sh "$TREE" "$PIDF" ) >/dev/null 2>&1
assert_fail "run fails when the session cannot be armed" test "$?" -eq 0

# The child writes both pids before it blocks; give it the moment it needs.
_t=0
while [ "$_t" -lt 30 ] && [ ! -f "$PIDF.child" ]; do
    sleep 0.1 2>/dev/null || sleep 1
    _t=$((_t + 1))
done
assert_ok "the wrapped command did start" test -f "$PIDF.child"

_t=0
while [ "$_t" -lt 30 ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; do
    sleep 0.1 2>/dev/null || sleep 1
    _t=$((_t + 1))
done
assert_fail "the wrapped command was stopped when arming failed" \
    sh -c "kill -0 $(cat "$PIDF") 2>/dev/null"
assert_fail "so was the child it had already spawned" \
    sh -c "kill -0 $(cat "$PIDF.child") 2>/dev/null"
assert_fail "and the machine was left able to sleep" plat_sleep_disabled

# --- run alongside an explicit completion flag -------------------------------
#
# Only one completion source fits in a descriptor. The wrapped process is the
# one `run` exists for, so it wins -- loudly, because silently discarding a flag
# the user typed is how a session ends at a time nobody asked for.

clean_machine
MACON_HELPER_CMD="sh '$STUB' \"\$MACON_DESC\" &"
_warn=$( ( cli_cmd_run --max 12 --busy-check 'true' -- true ) 2>&1 >/dev/null )
assert_contains "$_warn" "--busy-check" "the discarded flag is named"
assert_eq "process" "$(sess_get "$(sess_desc_path)" completion)" \
    "the wrapped process is still the completion source"
kill_stub

unset MACON_FAKE_NOW
teardown_state
