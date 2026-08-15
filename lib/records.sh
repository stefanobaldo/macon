#!/bin/sh
# Tab-separated records. Not JSON: jq only ships from macOS 15 and the
# floor is 13, and hand-parsing JSON in shell is worse than every
# alternative. awk reads TSV natively.
#
# Two files with very different volumes: one index row per night (what
# `report` aggregates) and one sample file per session (~100 lines, read
# only when drilling into a single night). That split is why no database
# is needed.
#
# Deliberately dependency-free -- not even common.sh. The write path runs
# as root inside the watch loop at every poll, and the less it reaches for
# the better.

_REC_TAB=$(printf '\t')

_rec_warn() {
    printf 'macon: %s\n' "$*" >&2
}

# The id is a filename component on a path this module writes to AS ROOT, and
# `macon log ID` / `macon report --session ID` make the same path a READ for a
# user-supplied argument. lib/session.sh enforces this character class on the
# descriptor, but this module is deliberately independent of that one, so it
# cannot inherit the guarantee -- it has to state it again.
# Longest id accepted. This is the same bound MACON_NAME_MAX_CHARS puts on the
# same value at the other end of the descriptor. They are two numbers rather
# than one because this module is deliberately independent of lib/session.sh --
# so tests/test_records.sh asserts they have not drifted apart, which is the
# part that would otherwise rot in silence.
MACON_REC_ID_MAX_CHARS=64

_rec_is_id() {
    case "$1" in
        '' | *[!A-Za-z0-9._-]* | *..*)
            _rec_warn "refusing session id '$1': not a plain identifier"
            return 1
            ;;
    esac
    # Not hygiene: this becomes a path component, and the length limits that
    # apply to one are the filesystem's, which report themselves far too late
    # to be useful -- as a failed write, as root, at the end of a night.
    if [ "${#1}" -gt "$MACON_REC_ID_MAX_CHARS" ]; then
        _rec_warn "refusing session id: longer than $MACON_REC_ID_MAX_CHARS characters"
        return 1
    fi
    return 0
}

# A tab or a newline inside a value does not corrupt the value, it corrupts the
# FILE. A tab shifts every later column, so the sample silently drops out of
# both aggregates while still counting toward COUNT -- a night reads calmer
# than it was. A newline forges an entire extra row. plat_thermal_pressure
# returns the whole remainder of a powermetrics line, so this text is not ours.
# lib/session.sh refuses newlines in descriptor values for the same reason;
# this is that guard's counterpart on the other root-written file.
_rec_is_clean() {
    case "$1" in
        *"$_REC_TAB"* | *'
'*)
            _rec_warn "refusing to record a value containing a tab or newline"
            return 1
            ;;
    esac
}

rec_index_path() {
    printf '%s/sessions.tsv\n' "${MACON_STATE:-$HOME/.local/state/macon}"
}

rec_samples_path() {
    _rec_is_id "$1" || return 1
    printf '%s/samples/%s.tsv\n' "${MACON_STATE:-$HOME/.local/state/macon}" "$1"
}

# ID TS THERMAL AC BATT
rec_append_sample() {
    _p=$(rec_samples_path "$1") || return 1
    # Validate before creating anything: a refused sample leaves the file
    # exactly as it was, rather than half a row into it.
    for _v in "$2" "$3" "$4" "$5"; do
        _rec_is_clean "$_v" || return 1
    done
    mkdir -p "$(dirname "$_p")"
    printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$_p"
}

# ID STARTED ENDED REASON WORST WORST_AT MIN_BATT COUNT
#
# Column 1 is checked with the same guard as a samples path, because that is
# what it becomes: every id in the index is one `macon log ID` away from being
# a filename again. It also keeps the sort key where it belongs -- an id
# carrying a space costs the row a field under sort's blank splitting.
rec_append_session() {
    _rec_is_id "$1" || return 1
    for _v in "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; do
        _rec_is_clean "$_v" || return 1
    done
    _p=$(rec_index_path)
    mkdir -p "$(dirname "$_p")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$_p"
}

# Echoes WORST<TAB>WORST_AT<TAB>MIN_BATT<TAB>COUNT for one session.
#
# Two outcomes, and a caller must tell them apart by EXIT STATUS before reading
# any field:
#
#   rc 0 -- four populated fields, on every path that has an id to resolve. A
#           session that ends before its first poll has no sample file at all,
#           and returning nothing there would hand the caller three empty
#           columns to splice into an eight-column index row. The empty count is
#           the sharper edge: `[ "" -gt 0 ]` on bash 3.2 does not return false,
#           it EXITS 2 -- so a caller's guard falls through instead of failing.
#
#   rc 1 -- the id was refused and NOTHING is printed. `_agg=$(rec_aggregate
#           "$_id")` consumed without checking `$?` rebuilds precisely the empty
#           four columns the rc-0 path exists to prevent. Narrow but real, and an
#           asymmetry rather than a hypothetical: _sess_is_name admits `..` where
#           _rec_is_id above does not, so an id that passes sess_validate can
#           still be refused here.
rec_aggregate() {
    _p=$(rec_samples_path "$1") || return 1
    if [ ! -f "$_p" ]; then
        printf 'unknown\t0\t-1\t0\n'
        return 0
    fi
    awk -F'\t' '
        BEGIN {
            r["Nominal"] = 0; r["Moderate"] = 1; r["Fair"] = 1
            r["Serious"] = 2; r["Heavy"] = 2; r["Critical"] = 3
            r["Trapping"] = 4; r["Sleeping"] = 5
            n = 0
            worst_rank = -1; worst = "unknown"; worst_at = 0; min_b = 999
        }
        {
            n++
            lvl = $2
            # unknown carries no severity and must never win the slot.
            if (lvl in r && r[lvl] > worst_rank) {
                worst_rank = r[lvl]; worst = lvl; worst_at = $1
            }
            if ($4 ~ /^[0-9]+$/ && $4 + 0 < min_b) min_b = $4 + 0
        }
        END {
            if (min_b == 999) min_b = -1
            printf "%s\t%s\t%s\t%s\n", worst, worst_at, min_b, n
        }
    ' "$_p"
}

# Index rows, newest first. Optional SINCE filters on the start epoch.
rec_sessions() {
    _p=$(rec_index_path)
    [ -f "$_p" ] || return 0
    _since=${1:-0}
    # The filter reads field 2 as a number, so the sort has to agree with it on
    # both counts. Default sort splits on runs of BLANKS, and a tab is a blank:
    # an empty or space-bearing first field silently shifts the key onto
    # another column. And without -n the comparison is lexicographic, which
    # ranks a 9-digit epoch above a 10-digit one -- 2001 above 2023.
    awk -F'\t' -v since="$_since" '$2 + 0 >= since + 0' "$_p" |
        sort -t"$_REC_TAB" -k2,2nr
}
