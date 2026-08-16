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
# shellcheck source=lib/session.sh
. "$MACON_LIB/session.sh"
# shellcheck source=bin/macon
. "$REPO_DIR/bin/macon"

# --- defaults ---------------------------------------------------------------

assert_ok "a bare duration parses" cli_parse_on 8
cli_parse_on 8
assert_eq "8" "$OPT_HOURS" "the duration is captured"
assert_eq "restore" "$OPT_POLICY" "policy defaults to restore"
assert_eq "300" "$OPT_INTERVAL" "interval defaults to 300"
assert_eq "8" "$OPT_MAX" "the ceiling defaults to the soft deadline"

assert_fail "a missing duration is rejected" cli_parse_on
assert_fail "a non-numeric duration is rejected" cli_parse_on abc
assert_fail "an unknown flag is rejected" cli_parse_on 8 --nope
assert_fail "an unknown policy is rejected" cli_parse_on 8 --on-expire destroy

# --- extend needs both a question and a bound -------------------------------
#
# extend is meaningless without something to ask, and dangerous without a
# ceiling, so both are refused at parse time rather than at 03:00.

assert_fail "extend without a completion source is rejected" \
    cli_parse_on 8 --on-expire extend --max 12
assert_fail "extend without an explicit --max is rejected" \
    cli_parse_on 8 --on-expire extend --busy-check 'true'
assert_ok "extend with both a source and a ceiling is accepted" \
    cli_parse_on 8 --on-expire extend --busy-check 'true' --max 12

# A ceiling below the soft deadline can never be satisfied.
assert_fail "a ceiling below the duration is rejected" cli_parse_on 8 --max 4

# --- the interval bounds ----------------------------------------------------
#
# The floor keeps powermetrics from being hammered as root at every poll. The
# ceiling is the safety half: every deadline is evaluated only at a poll, so
# the interval is the resolution of the hard ceiling itself.

assert_fail "an interval below 30s is rejected" cli_parse_on 8 --interval 5
assert_ok "an interval of exactly 30s is accepted" cli_parse_on 8 --interval 30
assert_ok "an interval at the ceiling is accepted" \
    cli_parse_on 8 --interval "$MACON_INTERVAL_CEIL"
assert_fail "an interval above the ceiling is rejected" \
    cli_parse_on 8 --interval "$((MACON_INTERVAL_CEIL + 1))"

# The two bounds are the descriptor's own, so the CLI can never accept an
# interval the helper would refuse after the ladder has started mutating. The
# values are pinned rather than merely read: the assertions above move with the
# constants, which is what makes them agree, and something has to notice if the
# constants themselves are widened. Both numbers bound how long a rung of the
# poll order can go unevaluated, so widening one is a decision, not a tweak.
assert_eq "30" "$MACON_INTERVAL_FLOOR" "the CLI enforces the descriptor's floor"
assert_eq "900" "$MACON_INTERVAL_CEIL" "the CLI enforces the descriptor's ceiling"

# --- capture ----------------------------------------------------------------

cli_parse_on 8 --sentinel
assert_eq "1" "$OPT_SENTINEL" "the sentinel flag is captured"

cli_parse_on 8 --busy-check 'pgrep -q myjob' --max 10 --on-expire extend --extend-by 45
assert_eq "pgrep -q myjob" "$OPT_BUSY_CHECK" "the busy-check command is captured verbatim"
assert_eq "45" "$OPT_EXTEND_BY" "the extension step is captured"

# --- numbers that are not numbers -------------------------------------------
#
# Every one of these values reaches `$(( ))` or `[ -lt ]` further down, and
# under /bin/sh -- bash 3.2 here -- neither construct fails politely:
#
#   A leading zero is decimal to `[` and OCTAL to `$(( ))`, so `030` would mean
#   30 to the guard and 24 to the deadline built from it. `08` is not valid
#   octal at all, and an arithmetic error is fatal to a non-interactive shell
#   rather than something the caller can catch -- `macon on 08` would abort
#   with a shell diagnostic instead of a usage message.
#
#   A value past intmax_t makes `[ -lt ]` EXIT 2, which makes the enclosing
#   `if` false: the guard stops guarding instead of firing. This is the same
#   idiom lib/session.sh bounds for the same reason.

assert_fail "a zero-padded duration is rejected" cli_parse_on 08
assert_fail "a zero-padded interval is rejected" cli_parse_on 8 --interval 030
assert_fail "a duration too large to compute a deadline from is rejected" \
    cli_parse_on 99999999999999999999
assert_fail "an absurd duration is rejected even when it is representable" \
    cli_parse_on 100000
assert_ok "a year is still accepted" cli_parse_on 8760
assert_fail "a zero-hour session is rejected" cli_parse_on 0

# --- options missing their values -------------------------------------------
#
# `--max` at the end of the line leaves $2 unset, and this script runs under
# `set -u`: reading it would kill the shell with a diagnostic naming a
# positional parameter, which is not a message anyone can act on.

assert_fail "an option missing its value is rejected" cli_parse_on 8 --max
assert_fail "a trailing --busy-check is rejected" cli_parse_on 8 --busy-check
assert_fail "a trailing --on-expire is rejected" cli_parse_on 8 --on-expire

# --- free-form values that would forge a descriptor line --------------------
#
# The descriptor is KEY=VALUE lines. A newline inside a value lands as its own
# line, and the forged key a caller would choose is hard_ceiling. sess_set
# refuses to write it, but a refusal at that depth is a field silently missing
# from an optional slot; refusing here names the flag that caused it.

assert_fail "a newline in the busy-check command is rejected" \
    cli_parse_on 8 --busy-check 'true
hard_ceiling=99'
assert_fail "a newline in the end hook is rejected" \
    cli_parse_on 8 --hook-end 'true
hard_ceiling=99'
assert_fail "a newline in the warn hook is rejected" \
    cli_parse_on 8 --hook-warn 'true
hard_ceiling=99'

# --- the copyright notice ---------------------------------------------------
#
# LICENSE is authoritative and the string in bin/macon is a courtesy copy, which
# means there are now two places for the same fact to live. Asserting they agree
# is cheaper than noticing the year drifted in one of them three releases later.
# The installed CLI ships without LICENSE beside it, so the copy cannot be read
# from disk at run time -- which is exactly why it can drift.
LICENSE_LINE=$(grep -i '^Copyright' "$REPO_DIR/LICENSE")
assert_contains "$MACON_COPYRIGHT" "Stefano Baldo" \
    "the notice names the copyright holder"
assert_contains "$LICENSE_LINE" "Stefano Baldo" \
    "and LICENSE names the same one"

# Compared as year plus holder rather than as whole strings: LICENSE carries the
# bare notice, the CLI's adds the licence name, so equality would fail on a
# difference that is intended.
assert_contains "$LICENSE_LINE" "$(printf '%s' "$MACON_COPYRIGHT" | sed 's/^Copyright (c) \([0-9]*\) \(.*\)\. MIT\.$/Copyright (c) \1 \2/')" \
    "the year and holder in bin/macon match LICENSE exactly"
assert_contains "$MACON_COPYRIGHT" "MIT" \
    "and the notice names the licence"

teardown_state
