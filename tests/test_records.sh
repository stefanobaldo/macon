#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
# shellcheck source=lib/records.sh
. "$MACON_LIB/records.sh"

ID=20260815T000000Z-deadbeef
ID2=20260816T000000Z-cafebabe
ID3=20260817T000000Z-0badf00d

# Pin the file names. Every read and every write goes through these two
# accessors, so a renamed index or a dropped samples/ subdir would stay
# invisible: the records would simply be read back from wherever they were
# written.
assert_eq "$MACON_STATE/sessions.tsv" "$(rec_index_path)" \
    "the index is sessions.tsv under the state root"
assert_eq "$MACON_STATE/samples/$ID.tsv" "$(rec_samples_path "$ID")" \
    "samples live one file per session under samples/"

rec_append_sample "$ID" 1700000000 Nominal yes 80
rec_append_sample "$ID" 1700000300 Fair yes 80
rec_append_sample "$ID" 1700000600 Serious yes 74
rec_append_sample "$ID" 1700000900 Nominal yes 78

AGG=$(rec_aggregate "$ID")
assert_eq "Serious" "$(printf '%s' "$AGG" | cut -f1)" "aggregate finds the worst level"
assert_eq "1700000600" "$(printf '%s' "$AGG" | cut -f2)" "aggregate reports when it peaked"
assert_eq "74" "$(printf '%s' "$AGG" | cut -f3)" "aggregate finds the minimum battery"
assert_eq "4" "$(printf '%s' "$AGG" | cut -f4)" "aggregate counts every sample"

# The peak keeps the FIRST timestamp at which the worst level was reached. A
# later sample at the same level does not move it: "when it got that hot" is
# the useful answer, not "when it last was".
IDP=20260817T000000Z-01020304
rec_append_sample "$IDP" 1700200000 Serious yes 60
rec_append_sample "$IDP" 1700200300 Serious yes 60
assert_eq "1700200000" "$(rec_aggregate "$IDP" | cut -f2)" \
    "the peak keeps the first timestamp that reached it"

# unknown must never be treated as the worst level. It is what
# plat_thermal_pressure returns when powermetrics is unreadable, so it carries
# no severity at all; ranked as the worst it would make every unprivileged or
# failed sample look like a thermal emergency. It goes FIRST here on purpose --
# that is the order in which a wrong implementation actually keeps the slot.
IDU=20260816T000000Z-cafebab1
rec_append_sample "$IDU" 1700100000 unknown yes 90
rec_append_sample "$IDU" 1700100300 Nominal yes 90
assert_eq "Nominal" "$(rec_aggregate "$IDU" | cut -f1)" "unknown never wins the worst slot"

# The mandated scale is Nominal < Moderate/Fair < Serious/Heavy < Critical <
# Trapping < Sleeping. Sampling only its bottom third leaves the top free to
# rank BELOW Nominal with nothing noticing, so chain every adjacent pair.
worst_of() { # FIRST SECOND -> the level that wins
    _cid="pair-$1-$2"
    rec_append_sample "$_cid" 1700300000 "$1" yes 50
    rec_append_sample "$_cid" 1700300300 "$2" yes 50
    rec_aggregate "$_cid" | cut -f1
}

assert_eq "Moderate" "$(worst_of Nominal Moderate)"  "Moderate outranks Nominal"
assert_eq "Fair"     "$(worst_of Nominal Fair)"      "Fair outranks Nominal"
assert_eq "Serious"  "$(worst_of Fair Serious)"      "Serious outranks Fair"
assert_eq "Heavy"    "$(worst_of Moderate Heavy)"    "Heavy outranks Moderate"
assert_eq "Critical" "$(worst_of Heavy Critical)"    "Critical outranks Heavy"
assert_eq "Trapping" "$(worst_of Critical Trapping)" "Trapping outranks Critical"
assert_eq "Sleeping" "$(worst_of Trapping Sleeping)" "Sleeping outranks Trapping"

# The two shared rungs are shared, not ordered: neither member outranks the
# other, so the earlier sample keeps the slot. Both directions, or "equal" is
# indistinguishable from "the second one is lower".
assert_eq "Moderate" "$(worst_of Moderate Fair)"  "Moderate and Fair share one rung"
assert_eq "Fair"     "$(worst_of Fair Moderate)"  "...in either order"
assert_eq "Serious"  "$(worst_of Serious Heavy)"  "Serious and Heavy share one rung"
assert_eq "Heavy"    "$(worst_of Heavy Serious)"  "...in either order too"

# A level nobody has heard of is not evidence of heat.
assert_eq "Nominal" "$(worst_of Nominal Apocalyptic)" \
    "an unrecognised level never wins the worst slot"

# One output shape on every path, four populated fields always. A session that
# ends before its first poll has no sample file at all; three fields spliced
# into an eight-column index row would shift every later column of it.
IDN=20260818T000000Z-00000000
assert_eq "unknown|0|-1|0" "$(rec_aggregate "$IDN" | tr '\t' '|')" \
    "a session with no sample file still yields four fields"

IDE=20260818T000000Z-11111111
mkdir -p "$MACON_STATE/samples"
: > "$MACON_STATE/samples/$IDE.tsv"
assert_eq "unknown|0|-1|0" "$(rec_aggregate "$IDE" | tr '\t' '|')" \
    "an empty sample file yields the same four fields"

# ...and COUNT must be a number, not an empty string. On bash 3.2 `[ "" -gt 0 ]`
# does not return false, it EXITS 2 -- so an empty field does not make a
# caller's guard fail, it makes the guard fall through.
assert_ok "the count of an empty session is still an integer" \
    test "$(rec_aggregate "$IDE" | cut -f4)" -eq 0

# --- the index -------------------------------------------------------------
#
# Three sessions whose id order, start order and end order all DISAGREE. With
# any two of them the fixture proves nothing: sorting by id, by end time or by
# whole line would land on the same answer as sorting by start time, and every
# one of those is a different function from the one this claims to be.
#
#   id order (desc):    ID3  > ID2  > ID
#   start order (desc): ID2  > ID   > ID3   <- the only correct one
#   end order (desc):   ID3  > ID2  > ID
#
# ID3's start epoch has nine digits on purpose: lexicographically "999999999"
# outranks "1700100000", so a string sort puts 2001 above 2023.
rec_append_session "$ID" 1700000000 1700001000 "done" Serious 1700000600 74 4
rec_append_session "$ID2" 1700100000 1700101000 hard-ceiling Nominal 1700100300 90 2
rec_append_session "$ID3" 999999999 1700900000 orphan Nominal 999999500 61 9

assert_eq "3" "$(rec_sessions | wc -l | tr -d ' ')" "the index holds every session"
assert_eq "$ID2" "$(rec_sessions | head -1 | cut -f1)" \
    "sessions are listed newest first by START time, not by id or end time"
assert_eq "$ID" "$(rec_sessions | sed -n 2p | cut -f1)" \
    "the middle row is the middle start time"
assert_eq "$ID3" "$(rec_sessions | tail -1 | cut -f1)" \
    "a shorter start epoch is older, not newer"

# Every column of the row, not just the two the ordering happens to expose.
# This row is the interface `macon report` renders, and a pair of swapped
# columns in the writer is invisible to a reader that only checks two of them.
row_for() { rec_sessions | awk -F'\t' -v id="$1" '$1 == id'; }
ROW=$(row_for "$ID")
assert_eq "1700000000" "$(printf '%s' "$ROW" | cut -f2)" "the start epoch is column 2"
assert_eq "1700001000" "$(printf '%s' "$ROW" | cut -f3)" "the end epoch is column 3"
assert_eq "done" "$(printf '%s' "$ROW" | cut -f4)" "the termination reason is column 4"
assert_eq "Serious" "$(printf '%s' "$ROW" | cut -f5)" "the worst level is column 5"
assert_eq "1700000600" "$(printf '%s' "$ROW" | cut -f6)" "the peak timestamp is column 6"
assert_eq "74" "$(printf '%s' "$ROW" | cut -f7)" "the minimum battery is column 7"
assert_eq "4" "$(printf '%s' "$ROW" | cut -f8)" "the sample count is column 8"

# SINCE is a START-time filter. Filtering on the end time instead would keep
# ID3 as well, since it ran long past this boundary.
assert_eq "1" "$(rec_sessions 1700050000 | wc -l | tr -d ' ')" \
    "--since filters by start time, not by end time"
assert_eq "$ID2" "$(rec_sessions 1700050000 | cut -f1)" \
    "and it keeps the session that started after the boundary"

# The boundary itself is inclusive; straddle it, or >= and > are the same test.
assert_eq "1" "$(rec_sessions 1700100000 | wc -l | tr -d ' ')" \
    "--since keeps a session that started exactly on the boundary"
assert_eq "0" "$(rec_sessions 1700100001 | wc -l | tr -d ' ')" \
    "--since drops a session that started one second before it"

# --- refusals --------------------------------------------------------------
#
# The id is a filename component on a path this module writes to AS ROOT, and
# `macon log ID` makes that same path a read for an argument the user typed.
assert_fail "a session id with path separators is refused" \
    rec_samples_path '../../pwned'
assert_fail "a sample under a traversing id is refused" \
    rec_append_sample '../../pwned' 1700000000 Nominal yes 50
assert_eq "" "$(find "$MACON_STATE/.." -maxdepth 1 -name 'pwned.tsv' 2>/dev/null)" \
    "the refused write landed nowhere outside the state root"
assert_fail "an aggregate over a traversing id is refused" rec_aggregate '../../pwned'
assert_fail "an empty session id is refused" rec_samples_path ''
assert_fail "a bare .. is refused" rec_samples_path '..'

# A tab or newline in a value corrupts the file, not the value: a tab shifts
# every later column, so the sample drops out of both aggregates while still
# counting, and a newline forges a whole row.
IDG=20260819T000000Z-11223344
rec_append_sample "$IDG" 1700400000 Nominal yes 50
assert_fail "a thermal value containing a tab is refused" \
    rec_append_sample "$IDG" 1700400300 "Nom$(printf '\t')inal" yes 50
# Spaces, not tabs, in the forged row: a payload carrying both is refused by the
# tab branch before the newline branch is ever consulted, so it would assert the
# tab guard twice and the newline guard never.
assert_fail "a thermal value containing a newline is refused" \
    rec_append_sample "$IDG" 1700400600 "Nominal
1700409999 Sleeping yes 1" yes 50
assert_eq "1" "$(rec_aggregate "$IDG" | cut -f4)" "neither refused sample reached the file"
assert_eq "Nominal" "$(rec_aggregate "$IDG" | cut -f1)" "the forged row never became a sample"

assert_fail "an index value containing a tab is refused" \
    rec_append_session "$IDG" 1700400000 1700401000 "do$(printf '\t')ne" Nominal 1700400000 50 1
assert_fail "an index row under a malformed id is refused" \
    rec_append_session 'id with spaces' 1700400000 1700401000 "done" Nominal 1700400000 50 1
assert_eq "3" "$(rec_sessions | wc -l | tr -d ' ')" "no refused index row landed"

# A row whose first field is empty -- what a crash between the append opening
# the file and printf finishing the row leaves behind -- must not reorder the
# rows around it. sort splits on runs of BLANKS by default and a tab is one, so
# without an explicit -t the leading tab costs the row a field and the sort key
# lands on a different column entirely. Isolated state: this row cannot be
# written through the API, which is the point.
SAVED_STATE=$MACON_STATE
MACON_STATE=$(mktemp -d)
printf '\t1700100000\t1\tdone\tNominal\t1\t90\t1\n' > "$MACON_STATE/sessions.tsv"
printf 'zz\t1700000000\t9\tdone\tNominal\t1\t90\t1\n' >> "$MACON_STATE/sessions.tsv"
assert_eq "1700100000" "$(rec_sessions | head -1 | cut -f2)" \
    "a truncated row does not shift the sort key onto another column"
rm -rf "$MACON_STATE"
MACON_STATE=$SAVED_STATE

# --- closing out a session --------------------------------------------------
#
# The one call both writers make -- the helper when its loop ends, the CLI when
# `off` or an orphan heal ends a session the helper is not around to close. It
# exists so the rule that is easy to get wrong lives in one place: rec_aggregate
# tells its two outcomes apart by exit status, and splicing four fields out of
# the silent one rebuilds the half-empty row its sentinels exist to prevent.

IDC=20260820T000000Z-c105ec10
rec_append_sample "$IDC" 1700500000 Nominal yes 88
rec_append_sample "$IDC" 1700500300 Serious no 66
assert_ok "closing a session writes its row" \
    rec_close_session "$IDC" 1700500000 1700500600 manual
CROW=$(row_for "$IDC")
assert_eq "manual" "$(printf '%s' "$CROW" | cut -f4)" "the reason reaches column 4"
assert_eq "Serious" "$(printf '%s' "$CROW" | cut -f5)" "the aggregate's worst level is spliced in"
assert_eq "1700500300" "$(printf '%s' "$CROW" | cut -f6)" "and its peak timestamp"
assert_eq "66" "$(printf '%s' "$CROW" | cut -f7)" "and its minimum battery"
assert_eq "2" "$(printf '%s' "$CROW" | cut -f8)" "and its sample count"

# A session that ended before its first poll still gets a row, carrying the
# sentinels rather than four empty columns.
IDCE=20260820T010000Z-c105ec11
assert_ok "a session with no samples still closes" \
    rec_close_session "$IDCE" 1700500000 1700500010 manual
assert_eq "0" "$(row_for "$IDCE" | cut -f8)" "an unsampled session records a zero count"

# An id the module refuses is the outcome a caller must not paper over: no row
# at all is right, and a partial row is what this function exists to prevent.
_before=$(rec_sessions 0 | wc -l | tr -d ' ')
assert_fail "an unusable id fails the close-out" \
    rec_close_session '..' 1700500000 1700500600 manual
assert_eq "$_before" "$(rec_sessions 0 | wc -l | tr -d ' ')" \
    "and writes no row rather than a half-empty one"

# ...and the guard must admit what the codebase actually produces. common.sh is
# sourced HERE, deliberately last: records.sh depends on nothing but
# MACON_STATE, and sourcing it at the top would hide a records.sh that reached
# for macon_warn.
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
GEN=$(macon_new_session_id)
assert_eq "$MACON_STATE/samples/$GEN.tsv" "$(rec_samples_path "$GEN")" \
    "a generated session id is admitted"

# The id is length-bounded because it becomes a path component, and a limit
# discovered by the filesystem reports itself as a failed write, as root, at the
# end of a night.
_long=$(printf '%065d' 0)
assert_fail "an id longer than the cap is refused" rec_samples_path "$_long"
_at_cap=$(printf '%064d' 0)
assert_eq "$MACON_STATE/samples/$_at_cap.tsv" "$(rec_samples_path "$_at_cap")" \
    "an id exactly at the cap is admitted"

# This module and lib/session.sh bound the same value at opposite ends of the
# descriptor, and are deliberately independent of each other -- which means the
# two numbers can drift apart with nothing to notice. This is what notices.
# session.sh is sourced last for the same reason common.sh was.
# shellcheck source=lib/session.sh
. "$MACON_LIB/session.sh"
assert_eq "$MACON_NAME_MAX_CHARS" "$MACON_REC_ID_MAX_CHARS" \
    "the two id length caps are still the same number"

teardown_state
