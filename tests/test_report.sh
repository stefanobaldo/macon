#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
MACON_CLI_SOURCED=1
export MACON_CLI_SOURCED
# Every rendered instant goes through `date -r`, which reads the local zone.
# Pinning it is what makes an assertion on a formatted timestamp -- and on the
# absence of a 1970 one -- mean the same thing on every machine.
TZ=UTC
export TZ
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=lib/records.sh
. "$MACON_LIB/records.sh"
# shellcheck source=lib/report.sh
. "$MACON_LIB/report.sh"
# shellcheck source=bin/macon
. "$REPO_DIR/bin/macon"

# --- an index that does not exist yet ----------------------------------------
#
# rec_sessions returns nothing at all when there is no index file. A report is
# still a document, and a document with an empty table body says nothing about
# whether the tool has never run or the filter matched nothing.

OUT=$(rep_html 0)
assert_contains "$OUT" "<!DOCTYPE html>" "an empty report is still a complete document"
assert_contains "$OUT" "</html>" "the empty document is closed"
assert_contains "$OUT" "No sessions recorded" "the empty report says why it is empty"

# --- the index -----------------------------------------------------------------

rec_append_session 20260815T000000Z-aaaa 1700000000 1700010000 'done' Nominal 1700000600 80 33
rec_append_session 20260816T000000Z-bbbb 1700100000 1700110000 hard-ceiling Serious 1700100600 62 33

OUT=$(rep_html 0)

assert_contains "$OUT" "<!DOCTYPE html>" "the report is a complete document"
assert_contains "$OUT" "</html>" "the document is closed"
assert_contains "$OUT" "20260815T000000Z-aaaa" "the first session appears"
assert_contains "$OUT" "20260816T000000Z-bbbb" "the second session appears"
assert_contains "$OUT" "hard-ceiling" "termination reasons are shown"
assert_contains "$OUT" "Serious" "worst thermal pressure is shown"
assert_contains "$OUT" "2023-11-14 22:13" "start times are formatted, not left as epochs"
assert_contains "$OUT" "2h46m" "the duration is derived from the two epochs"
assert_contains "$OUT" "80%" "the minimum battery level is shown"

# The instant the worst level was reached is a column of its own -- the spec
# lists it beside the level itself. Header and cell are asserted separately, and
# then counted against each other: a table whose body no longer lines up with
# its head is exactly what a column with no test ships, and neither assertion
# alone would catch half of it being removed.
assert_contains "$OUT" "<th>Worst at</th>" "the worst-at column has a header"
assert_contains "$OUT" '<td class="ok">Nominal</td><td>22:23</td><td>80%</td>' \
    "and a cell, between the level it belongs to and the battery"
ROW=$(printf '%s\n' "$OUT" | grep '20260815T000000Z-aaaa')
assert_eq "8" "$(printf '%s' "$ROW" | grep -o '<td' | wc -l | tr -d ' ')" \
    "an index row carries eight cells"
assert_eq "8" "$(printf '%s\n' "$OUT" | grep -o '<th>' | wc -l | tr -d ' ')" \
    "and the head carries eight columns to put them in"

# awk on macOS has no strftime -- it is a gawk extension, and calling it aborts
# the whole program. A row that still carries its raw epoch is what that failure
# looks like from here.
assert_fail "no row leaks a raw epoch" \
    sh -c "printf '%s' \"\$1\" | grep -q '1700000000'" _ "$OUT"

# Self-contained: a strict offline document must reference no remote host.
assert_fail "the report loads nothing from the network" \
    sh -c "printf '%s' \"\$1\" | grep -Eq 'https?://[^\"]*\\.(js|css)'" _ "$OUT"
assert_fail "the report pulls in no external script" \
    sh -c "printf '%s' \"\$1\" | grep -q '<script'" _ "$OUT"

# Filtering by start time drops older sessions.
OUT2=$(rep_html 1700050000)
assert_fail "the older session is filtered out" \
    sh -c "printf '%s' \"\$1\" | grep -q '20260815T000000Z-aaaa'" _ "$OUT2"
assert_contains "$OUT2" "20260816T000000Z-bbbb" "the newer session survives the filter"

# --- rec_aggregate's sentinels ------------------------------------------------
#
# "unknown", 0, -1 and 0 are not values. Rendered literally they become a
# thermal reading, a 1970 timestamp and a negative charge level -- a report that
# states things that never happened.

rec_append_session 20260817T000000Z-cccc 1700200000 1700210000 orphan unknown 0 -1 0
OUT=$(rep_html 1700150000)
assert_contains "$OUT" "20260817T000000Z-cccc" "a session that recorded nothing still gets a row"
assert_fail "the epoch-zero sentinel is not rendered as a date" \
    sh -c "printf '%s' \"\$1\" | grep -q '1970'" _ "$OUT"
assert_fail "the -1 battery sentinel is not rendered as a charge level" \
    sh -c "printf '%s' \"\$1\" | grep -q '\\-1%'" _ "$OUT"
assert_fail "the unknown thermal sentinel is not rendered as a level" \
    sh -c "printf '%s' \"\$1\" | grep -q '>unknown<'" _ "$OUT"

# Two of the four sentinels are reachable with a non-zero count: a Mac whose
# battery cannot be read records -1 on every sample, and a night where no sample
# carried a rankable level leaves worst at "unknown".
rec_append_session 20260818T000000Z-dddd 1700300000 1700310000 'done' unknown 0 -1 42
OUT=$(rep_html 1700250000)
assert_contains "$OUT" "42" "the sample count is still shown"
assert_fail "a battery that could not be read is not a -1% reading" \
    sh -c "printf '%s' \"\$1\" | grep -q '\\-1%'" _ "$OUT"

# --- escaping -----------------------------------------------------------------
#
# The worst-thermal field is the tail of a powermetrics line. lib/records.sh
# refuses only tabs and newlines in it, so < and & arrive intact.

rec_append_session 20260819T000000Z-eeee 1700400000 1700410000 'done' 'Serious <b>&x' 1700400600 55 9
OUT=$(rep_html 1700350000)
assert_contains "$OUT" "Serious &lt;b&gt;&amp;x" "markup characters are escaped"
assert_fail "the raw markup does not reach the document" \
    sh -c "printf '%s' \"\$1\" | grep -q '<b>'" _ "$OUT"

# --- _rep_is_num --------------------------------------------------------------
#
# It is the only thing standing between a record field and `$(( ))`. A leading
# zero there is not a wrong answer, it is a FATAL arithmetic error -- $(( ))
# reads `08` as octal, and `08` is not valid octal at all.

assert_ok "a plain integer is a number" _rep_is_num 1700000000
assert_ok "zero is a number" _rep_is_num 0
assert_fail "an empty value is not" _rep_is_num ""
assert_fail "a negative value is not" _rep_is_num -1
assert_fail "a leading zero is refused: arithmetic would read it as octal" _rep_is_num 08
assert_fail "a value too long for intmax_t is refused" _rep_is_num 1234567890123456789

# End to end: a start epoch with a leading zero must cost that row its two
# derived cells, not put a shell diagnostic on stderr.
rec_append_session 20260820T000000Z-ffff 08 1700410000 'done' Nominal 1700400600 55 9
ERR=$(rep_html 0 2>&1 >/dev/null)
assert_eq "" "$ERR" "a leading-zero epoch does not blow up the arithmetic"
OUT=$(rep_html 0)
assert_contains "$OUT" "20260820T000000Z-ffff" "and the row is still rendered"
ROW=$(printf '%s\n' "$OUT" | grep '20260820T000000Z-ffff')
assert_eq "8" "$(printf '%s' "$ROW" | grep -o '<td' | wc -l | tr -d ' ')" \
    "with all eight of its cells"
assert_contains "$ROW" '<td class="none">&mdash;</td><td class="none">&mdash;</td>' \
    "the unreadable start costs it the start and the duration, and nothing else"

# --- rep_since_epoch ----------------------------------------------------------

assert_eq "1700000000" "$(rep_since_epoch 1700000000)" "a plain integer is an epoch"
assert_eq "0" "$(rep_since_epoch 0)" "zero is an epoch"
assert_eq "1699920000" "$(rep_since_epoch 2023-11-14)" "a calendar date is converted"
assert_fail "a date with no such day is refused" rep_since_epoch 2023-13-45
assert_fail "free text is refused" rep_since_epoch yesterday
assert_fail "an empty value is refused" rep_since_epoch ""

# --- one session's samples ----------------------------------------------------

SID=20260815T000000Z-aaaa
rec_append_sample "$SID" 1700000300 Nominal yes 80
rec_append_sample "$SID" 1700000600 'Serious <b>' no 74
rec_append_sample "$SID" 1700000900 unknown yes -1

OUT=$(rep_session_html "$SID")
assert_contains "$OUT" "<!DOCTYPE html>" "the drill-down is a complete document"
assert_contains "$OUT" "</html>" "the drill-down document is closed"
assert_contains "$OUT" "$SID" "the drill-down names its session"
assert_contains "$OUT" "2023-11-14 22:18:20" "sample timestamps are formatted"
assert_contains "$OUT" "Serious &lt;b&gt;" "sample values are escaped too"
assert_contains "$OUT" "74%" "battery readings are shown"
# Asserted as the rendered CELL, not as the bare word: "no" and "yes" are two
# and three characters of English that occur all over the inline stylesheet
# ("monospace" alone contains one), so a substring match on either would hold
# with the whole column deleted.
assert_contains "$OUT" '<th>On AC</th>' "the AC column has a header"
assert_contains "$OUT" '<td class="warn">no</td>' "a sample taken off AC is marked as such"
assert_contains "$OUT" '<td class="ok">yes</td>' "and a sample on AC is not"
ROW=$(printf '%s\n' "$OUT" | grep '22:18:20')
assert_eq "4" "$(printf '%s' "$ROW" | grep -o '<td' | wc -l | tr -d ' ')" \
    "a sample row carries four cells"
assert_eq "4" "$(printf '%s\n' "$OUT" | grep -o '<th>' | wc -l | tr -d ' ')" \
    "and the head carries four columns to put them in"
assert_fail "an unreadable battery sample is not a -1% reading" \
    sh -c "printf '%s' \"\$1\" | grep -q '\\-1%'" _ "$OUT"

# A session with no sample file is a valid document, not an empty table.
OUT=$(rep_session_html 20260816T000000Z-bbbb)
assert_contains "$OUT" "No samples recorded" "a session with no samples says so"

# The id becomes a path and arrives on the command line. rec_samples_path
# refuses what it cannot use as a filename, and that refusal has to be honoured
# rather than turned into a document.
try_session_html() {
    ( rep_session_html "$1" 2>/dev/null )
}
assert_fail "a traversing id is refused outright" \
    try_session_html '../../etc/passwd'
assert_eq "" "$(try_session_html '../../etc/passwd')" \
    "and prints no half-document on the way out"

# --- the subcommand -----------------------------------------------------------

# cli_cmd_report refuses fatally, and macon_die exits rather than returning, so
# every call goes through a subshell of THIS shell -- `sh -c` would be a fresh
# shell in which none of these functions exist, and the assertion would hold for
# the wrong reason.
try_report() {
    ( cli_cmd_report "$@" )
}
try_report_quiet() {
    ( cli_cmd_report "$@" >/dev/null 2>&1 )
}

OUT=$(try_report)
assert_contains "$OUT" "20260816T000000Z-bbbb" "report with no options writes the index to stdout"

FILE="$MACON_STATE/report.html"
OUT=$(try_report --out "$FILE")
assert_contains "$OUT" "report written to $FILE" "--out names the file it wrote"
assert_contains "$(cat "$FILE")" "</html>" "and the file is a complete document"

OUT=$(try_report --since 2023-11-15)
assert_contains "$OUT" "20260816T000000Z-bbbb" "--since accepts a calendar date"
assert_fail "and the date is converted to the right instant" \
    sh -c "printf '%s' \"\$1\" | grep -q '20260815T000000Z-aaaa'" _ "$OUT"
OUT=$(try_report --since 1700050000)
assert_contains "$OUT" "20260816T000000Z-bbbb" "--since accepts an epoch"
assert_fail "and the epoch filters the same way" \
    sh -c "printf '%s' \"\$1\" | grep -q '20260815T000000Z-aaaa'" _ "$OUT"

OUT=$(try_report --session "$SID")
assert_contains "$OUT" "2023-11-14 22:18:20" "--session drills into that session's samples"

# Every option that takes a value has to be refused BY NAME when it is last on
# the line. Reading $2 there is an unset positional parameter, which under
# `set -u` aborts the shell instead of returning -- a diagnostic naming an
# internal variable rather than the flag the user typed.
OUT=$(try_report --out 2>&1)
assert_contains "$OUT" "--out requires a value" "a trailing --out is refused by name"
OUT=$(try_report --since 2>&1)
assert_contains "$OUT" "--since requires a value" "a trailing --since is refused by name"
OUT=$(try_report --session 2>&1)
assert_contains "$OUT" "--session requires a value" "a trailing --session is refused by name"

OUT=$(try_report --since nonsense 2>&1)
assert_contains "$OUT" "--since" "a --since it cannot read is refused, naming the flag"
assert_fail "and the command fails" try_report_quiet --since nonsense

assert_fail "an unusable --session id is refused" \
    try_report_quiet --session '../../etc/passwd'
assert_fail "an unknown option is refused" try_report_quiet --nope

# --since is meaningless once a single session has been named. A flag macon
# silently ignored is worse than one it refused.
OUT=$(try_report --session "$SID" --since 2023-11-15 2>&1 >/dev/null)
assert_contains "$OUT" "ignoring --since" "--since alongside --session is called out"

# A refused id must not leave a truncated file where a report used to be.
printf 'previous\n' > "$FILE"
( cli_cmd_report --session '../../etc/passwd' --out "$FILE" >/dev/null 2>&1 ) || :
assert_contains "$(cat "$FILE")" "previous" "a refused id does not clobber the output file"

teardown_state
