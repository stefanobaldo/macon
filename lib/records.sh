#!/bin/sh
# Tab-separated records. Not JSON: jq only ships from macOS 15 and the
# floor is 13, and hand-parsing JSON in shell is worse than every
# alternative. awk reads TSV natively.
#
# Two files with very different volumes: one index row per night (what
# `report` aggregates) and one sample file per session (~100 lines, read
# only when drilling into a single night). That split is why no database
# is needed.

rec_index_path() {
    printf '%s/sessions.tsv\n' "${MACON_STATE:-$HOME/.local/state/macon}"
}

rec_samples_path() {
    printf '%s/samples/%s.tsv\n' "${MACON_STATE:-$HOME/.local/state/macon}" "$1"
}

# ID TS THERMAL AC BATT
rec_append_sample() {
    _p=$(rec_samples_path "$1")
    mkdir -p "$(dirname "$_p")"
    printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$_p"
}

# ID STARTED ENDED REASON WORST WORST_AT MIN_BATT COUNT
rec_append_session() {
    _p=$(rec_index_path)
    mkdir -p "$(dirname "$_p")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$_p"
}

# Echoes WORST<TAB>WORST_AT<TAB>MIN_BATT<TAB>COUNT for one session.
rec_aggregate() {
    _p=$(rec_samples_path "$1")
    [ -f "$_p" ] || return 0
    awk -F'\t' '
        BEGIN {
            r["Nominal"] = 0; r["Moderate"] = 1; r["Fair"] = 1
            r["Serious"] = 2; r["Heavy"] = 2; r["Critical"] = 3
            r["Trapping"] = 4; r["Sleeping"] = 5
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
    awk -F'\t' -v since="$_since" '$2 + 0 >= since + 0' "$_p" | sort -r -k2,2
}
