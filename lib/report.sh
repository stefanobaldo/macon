#!/bin/sh
# Self-contained HTML report. No CDN, no external assets: the file must open
# by double-click on a machine with no network.
#
# This is the only component that answers the question a single night cannot:
# whether closed-lid operation is thermally sustainable on this machine, and
# whether a change to the physical setup helped.
#
# Read-only throughout. Nothing here mutates power settings, the run directory
# or the records; it renders what lib/records.sh already wrote.

_REP_TAB=$(printf '\t')

# What a cell shows when it has no value to show. rec_aggregate emits sentinels
# rather than empty fields -- "unknown", 0, -1, 0 -- and each of them renders as
# a plausible reading if it is printed as it stands: a thermal level, a 1970
# timestamp, a negative charge. Suppressing them is this module's job, and the
# records module says so in the comment above rec_aggregate.
_REP_NONE='&mdash;'

# Text becoming markup. Session ids and termination reasons are constrained
# upstream, but the worst-thermal field is the tail of a powermetrics line and
# lib/records.sh refuses only tabs and newlines in it -- so < and & arrive here
# intact. Applied to the whole tab-separated stream before it is split: none of
# the replacements can introduce a tab, so the column structure survives it.
_rep_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# A plain decimal integer, with no leading zeros and bounded in length. Neither
# clause is hygiene, and this guard is the only thing standing between a record
# field and `$(( ))`:
#
#   the LENGTH bound, because /bin/sh here is bash 3.2, whose arithmetic parses
#   its operands into intmax_t and exits 2 on anything larger rather than
#   returning false;
#
#   the LEADING ZERO, because $(( )) reads `08` as octal -- and `08` is not
#   valid octal at all, which is a fatal arithmetic error, not a wrong answer:
#   `value too great for base` kills the subshell computing the cell.
#
# cli_is_number in bin/macon and _sess_is_number in lib/session.sh carry the same
# two clauses for the same two reasons.
_rep_is_num() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
    esac
    [ "${#1}" -le 18 ]
}

# macOS awk has no strftime -- it is a gawk extension, and calling it aborts the
# whole program rather than the one field. Formatting happens out here instead,
# through BSD date's -r (seconds since the epoch), which is not GNU's -d @.
_rep_when() {
    date -r "$1" "+$2" 2>/dev/null
}

_rep_dur() {
    _dur=$(( $2 - $1 ))
    [ "$_dur" -lt 0 ] && _dur=0
    printf '%dh%02dm' "$((_dur / 3600))" "$(((_dur % 3600) / 60))"
}

_rep_cell() {
    printf '<td class="none">%s</td>' "$_REP_NONE"
}

# An instant, or nothing. Epoch zero is rec_aggregate's "never happened"
# sentinel for worst_at, so it is a non-value here rather than 1970.
_rep_time_cell() {
    if [ "$1" = "0" ] || ! _rep_is_num "$1"; then
        _rep_cell
    else
        printf '<td>%s</td>' "$(_rep_when "$1" "$2")"
    fi
}

# A charge level, or nothing. -1 is what both the helper and rec_aggregate write
# for a battery they could not read, and it is not a percentage.
_rep_batt_cell() {
    if _rep_is_num "$1"; then
        printf '<td>%s%%</td>' "$1"
    else
        _rep_cell
    fi
}

# A thermal level, or nothing. "unknown" is rec_aggregate's sentinel for a night
# where no sample carried a level it could rank, and it is reachable with a
# non-zero sample count.
_rep_thermal_cell() {
    case "$1" in
        unknown | '') _rep_cell ;;
        Nominal) printf '<td class="ok">%s</td>' "$1" ;;
        *) printf '<td class="warn">%s</td>' "$1" ;;
    esac
}

# One row per index row. rec_sessions already returns them newest first and
# already filtered on the start epoch, so neither is repeated here.
_rep_rows() {
    rec_sessions "$1" | _rep_escape |
        while IFS="$_REP_TAB" read -r _id _started _ended _reason _worst _wat _minb _count; do
            # count is zero exactly when the session ended before its first
            # poll: the row exists, but every sample-derived cell in it is a
            # sentinel. Said once at the row level, so the reader is not left to
            # infer it from four suppressed cells.
            if [ "$_count" = "0" ]; then
                printf '<tr class="empty">'
            else
                printf '<tr>'
            fi
            printf '<td class="id">%s</td>' "$_id"
            _rep_time_cell "$_started" '%Y-%m-%d %H:%M'
            if _rep_is_num "$_started" && _rep_is_num "$_ended"; then
                printf '<td>%s</td>' "$(_rep_dur "$_started" "$_ended")"
            else
                _rep_cell
            fi
            if [ "$_reason" = "done" ]; then
                printf '<td><span class="tag ok">%s</span></td>' "$_reason"
            else
                printf '<td><span class="tag warn">%s</span></td>' "$_reason"
            fi
            _rep_thermal_cell "$_worst"
            _rep_time_cell "$_wat" '%H:%M'
            _rep_batt_cell "$_minb"
            printf '<td>%s</td></tr>\n' "$_count"
        done
}

_rep_sample_rows() {
    _rep_escape < "$1" |
        while IFS="$_REP_TAB" read -r _ts _thermal _ac _batt; do
            printf '<tr>'
            _rep_time_cell "$_ts" '%Y-%m-%d %H:%M:%S'
            # Not suppressed the way the aggregate is: down here "unknown" is
            # the reading itself -- the sample really did carry no level -- and
            # hiding it would hide how much of the night went unmeasured.
            _rep_thermal_cell "$_thermal"
            if [ "$_ac" = "yes" ]; then
                printf '<td class="ok">%s</td>' "$_ac"
            else
                printf '<td class="warn">%s</td>' "$_ac"
            fi
            _rep_batt_cell "$_batt"
            printf '</tr>\n'
        done
}

# Everything from the doctype to the opening of the table. The stylesheet is
# inline and there is no script at all: the document has to render with the
# network unreachable, which is the state the machine is in when someone opens
# it to find out what happened last night.
_rep_open() {
    cat <<'HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
HEAD
    printf '<title>macon &mdash; %s</title>\n' "$1"
    cat <<'STYLE'
<style>
:root { color-scheme: light dark; --bg:#fff; --fg:#111; --muted:#666; --line:#e3e3e3; --warn:#b45309; --ok:#15803d; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#111; --fg:#eee; --muted:#999; --line:#333; --warn:#fbbf24; --ok:#4ade80; }
}
body { background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; margin:0; padding:2rem; }
h1 { font-size:1.4rem; margin:0 0 .25rem; }
p.sub { color:var(--muted); margin:0 0 2rem; }
.wrap { overflow-x:auto; }
table { border-collapse:collapse; width:100%; min-width:640px; }
th, td { text-align:left; padding:.5rem .75rem; border-bottom:1px solid var(--line); }
th { font-weight:600; color:var(--muted); font-size:.8rem; text-transform:uppercase; letter-spacing:.04em; }
td.id { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.8rem; color:var(--muted); }
.tag { padding:.1rem .45rem; border-radius:.25rem; font-size:.8rem; }
.tag.ok { color:var(--ok); } .tag.warn { color:var(--warn); }
td.warn { color:var(--warn); font-weight:600; } td.ok { color:var(--ok); }
td.none, tr.empty td, td.nothing { color:var(--muted); }
td.nothing { text-align:center; padding:2rem .75rem; }
</style>
</head>
<body>
STYLE
    printf '<h1>macon &mdash; %s</h1>\n' "$1"
    printf '<p class="sub">%s</p>\n' "$2"
    printf '<div class="wrap">\n<table>\n<thead><tr>'
}

_rep_close() {
    cat <<'FOOT'
</tbody>
</table>
</div>
</body>
</html>
FOOT
}

# Rows, or a visible statement that there are none. rec_sessions returns nothing
# at all when no index file exists, and an empty <tbody> cannot tell a reader
# whether the tool has never run or the filter matched nothing.
_rep_body() {
    printf '</tr></thead>\n<tbody>\n'
    if [ -n "$1" ]; then
        printf '%s\n' "$1"
    else
        printf '<tr><td class="nothing" colspan="%s">%s</td></tr>\n' "$2" "$3"
    fi
}

# The index: one row per night, newest first. SINCE is an epoch.
rep_html() {
    _rep_open "session report" \
        "One row per night. Worst thermal pressure is the peak reached at any point during the session."
    for _h in Session Started Duration "Ended by" "Worst thermal" "Worst at" "Min battery" Samples; do
        printf '<th>%s</th>' "$_h"
    done
    _rep_body "$(_rep_rows "${1:-0}")" 8 "No sessions recorded yet."
    _rep_close
}

# One night's raw samples. Returns non-zero, having printed nothing, for an id
# rec_samples_path refuses -- the id arrives on the command line, and this is
# the guard that keeps it from becoming an arbitrary path.
rep_session_html() {
    _sp=$(rec_samples_path "$1") || return 1
    _rep_open "session $(printf '%s' "$1" | _rep_escape)" \
        "Every sample recorded during this session, oldest first."
    for _h in Time "Thermal pressure" "On AC" Battery; do
        printf '<th>%s</th>' "$_h"
    done
    if [ -f "$_sp" ]; then
        _rep_body "$(_rep_sample_rows "$_sp")" 4 "No samples recorded for this session."
    else
        _rep_body "" 4 "No samples recorded for this session."
    fi
    _rep_close
}

# --since takes either spelling. A plain integer is an epoch; YYYY-MM-DD is a
# calendar date, converted at local midnight -- BSD date -j -f fills the fields
# the format does not mention from the CURRENT time, so a bare date would
# otherwise exclude everything earlier in the day than the moment of the run.
# Anything else returns non-zero and prints nothing; the message naming the flag
# belongs to the caller, which knows what the user typed it as.
rep_since_epoch() {
    if _rep_is_num "$1"; then
        printf '%s\n' "$1"
        return 0
    fi
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    _se=$(date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null) || return 1
    [ -n "$_se" ] || return 1
    printf '%s\n' "$_se"
}
