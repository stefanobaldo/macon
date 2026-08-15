#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
# shellcheck source=lib/records.sh
. "$MACON_LIB/records.sh"

ID=20260815T000000Z-deadbeef

rec_append_sample "$ID" 1700000000 Nominal yes 80
rec_append_sample "$ID" 1700000300 Fair yes 80
rec_append_sample "$ID" 1700000600 Serious yes 74
rec_append_sample "$ID" 1700000900 Nominal yes 78

AGG=$(rec_aggregate "$ID")
assert_eq "Serious" "$(printf '%s' "$AGG" | cut -f1)" "aggregate finds the worst level"
assert_eq "1700000600" "$(printf '%s' "$AGG" | cut -f2)" "aggregate reports when it peaked"
assert_eq "74" "$(printf '%s' "$AGG" | cut -f3)" "aggregate finds the minimum battery"
assert_eq "4" "$(printf '%s' "$AGG" | cut -f4)" "aggregate counts every sample"

# unknown must never be treated as the worst level.
ID2=20260816T000000Z-cafebabe
rec_append_sample "$ID2" 1700100000 unknown yes 90
rec_append_sample "$ID2" 1700100300 Nominal yes 90
assert_eq "Nominal" "$(rec_aggregate "$ID2" | cut -f1)" "unknown never wins the worst slot"

rec_append_session "$ID" 1700000000 1700001000 "done" Serious 1700000600 74 4
rec_append_session "$ID2" 1700100000 1700101000 hard-ceiling Nominal 1700100300 90 2

assert_eq "2" "$(rec_sessions | wc -l | tr -d ' ')" "the index holds both sessions"
assert_eq "$ID2" "$(rec_sessions | head -1 | cut -f1)" "sessions are listed newest first"
assert_eq "1" "$(rec_sessions 1700050000 | wc -l | tr -d ' ')" "--since filters by start time"
assert_eq "done" "$(rec_sessions | tail -1 | cut -f4)" "the termination reason round-trips"

teardown_state
