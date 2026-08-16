#!/bin/sh
# Session descriptor: data only, never shell fragments. The root helper
# reads this file and must be able to trust every field, so validation
# happens before anything acts on it.

# Deliberately NOT overridable. Every other root here honours an environment
# variable, but a floor its own consumer can lower is not a floor: it exists
# because the helper runs powermetrics as root at every poll.
MACON_INTERVAL_FLOOR=30

# And a ceiling, for the opposite reason. Every rung of the poll order is
# evaluated only AT a poll, so the interval is the resolution of the hard
# ceiling and of the no-AC abort: a session overshoots its ceiling by up to one
# interval, and drains on battery with the lid closed for up to `strikes` of
# them. An interval of a day is a perfectly ordinary number that would defer
# the ceiling by a day, and the sleep between polls is not something any guard
# inside the loop can interrupt.
MACON_INTERVAL_CEIL=900

MACON_HEARTBEAT_GRACE=3   # missed polls tolerated before declaring an orphan

# Longest value accepted for a numeric field. See _sess_is_number.
MACON_NUMBER_MAX_DIGITS=18

# Longest value accepted for a name field. macOS user names are far shorter,
# and macon_new_session_id emits 25 characters.
MACON_NAME_MAX_CHARS=64

sess_run_dir() {
    printf '%s\n' "${MACON_RUN:-/var/run/macon}"
}

sess_desc_path()      { printf '%s/session.conf\n' "$(sess_run_dir)"; }
sess_pid_path()       { printf '%s/helper.pid\n' "$(sess_run_dir)"; }
sess_heartbeat_path() { printf '%s/heartbeat\n' "$(sess_run_dir)"; }

sess_set() {
    _f=$1
    _k=$2
    _v=$3
    # A newline inside a value would land as its own KEY=VALUE line, forging a
    # field sess_get cannot tell apart from one that was really written. Today
    # no field carries free-form text, so nothing exploits it; the guard is here
    # because the moment one does, the forged key is a hard_ceiling.
    case "$_v" in
        *'
'*)
            macon_warn "refusing to write '$_k': the value contains a newline"
            return 1
            ;;
    esac
    if [ -f "$_f" ]; then
        # The rewrite is checked, and its result is installed only if it
        # succeeded. `|| :` here used to swallow a PARTIAL write -- a full disk
        # on the volume /var/run lives on -- and the mv then put that truncation
        # over the good descriptor. The root helper re-reads this file at every
        # poll, so a truncated descriptor is a poll order with no operands: the
        # hard ceiling stops being evaluated while the helper is still alive.
        #
        # grep exits 1 for "no lines selected", which is the ordinary result of
        # rewriting a file that holds only this key. Anything above that is an
        # error -- and so is a redirection that never produced the temporary at
        # all, which the status alone does not distinguish: a shell reports a
        # redirection it could not open as status 1, the same value grep uses
        # for a successful run that matched nothing. Braced so that message
        # goes to /dev/null with grep's own.
        { grep -v "^$_k=" "$_f" > "$_f.tmp"; } 2>/dev/null
        _sess_rc=$?
        if [ "$_sess_rc" -gt 1 ] || [ ! -f "$_f.tmp" ]; then
            rm -f "$_f.tmp" 2>/dev/null || :
            macon_warn "could not rewrite '$_f' to set '$_k'"
            return 1
        fi
        if ! mv "$_f.tmp" "$_f"; then
            rm -f "$_f.tmp"
            macon_warn "could not replace '$_f' while setting '$_k'"
            return 1
        fi
    fi
    printf '%s=%s\n' "$_k" "$_v" >> "$_f"
}

sess_get() {
    [ -f "$1" ] || return 0
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

# A plain decimal integer, bounded at BOTH ends. Neither bound is hygiene:
#
#   Magnitude -- /bin/sh here is bash 3.2, whose `[ -lt ]` parses into
#   intmax_t and EXITS 2 rather than returning false on anything larger. An
#   over-long value therefore does not fail a comparison, it makes the
#   comparison fall through: sess_validate's own guards below stop enforcing,
#   and macon_decide skips its hard-ceiling rung entirely -- the one guarantee
#   this tool exists to provide.
#
#   Leading zeros -- `[ ]` reads them as decimal but $(( )) reads them as
#   octal, so `0300` would mean 300 to validation and 192 to sess_orphaned.
#   Worse, `099` is not valid octal at all, and an arithmetic-evaluation
#   error is fatal to a non-interactive shell even inside an `if` condition,
#   so it terminates the process rather than returning an error to it.
_sess_is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
    esac
    [ "${#1}" -le "$MACON_NUMBER_MAX_DIGITS" ]
}

# An identifier the helper may hold but must never let become syntax. `user`
# is interpolated into `sudo -u` when the helper de-privileges a user-supplied
# command, so its character set is a privilege boundary, not a format check.
_sess_is_name() {
    case "$1" in
        '' | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "${#1}" -le "$MACON_NAME_MAX_CHARS" ]
}

sess_validate() {
    _f=$1
    _ok=0

    for _k in started_at soft_deadline hard_ceiling interval strikes; do
        _v=$(sess_get "$_f" "$_k")
        if ! _sess_is_number "$_v"; then
            macon_warn "descriptor field '$_k' is not a plain integer: '$_v'"
            _ok=1
        fi
    done

    for _k in session_id user; do
        _v=$(sess_get "$_f" "$_k")
        if ! _sess_is_name "$_v"; then
            macon_warn "descriptor field '$_k' is not a plain identifier: '$_v'"
            _ok=1
        fi
    done

    case "$(sess_get "$_f" policy)" in
        restore | extend) ;;
        *) macon_warn "descriptor field 'policy' is not restore or extend"; _ok=1 ;;
    esac

    case "$(sess_get "$_f" completion)" in
        none | busy_check | process | sentinel) ;;
        *) macon_warn "descriptor field 'completion' is not a known source"; _ok=1 ;;
    esac

    [ "$_ok" -eq 0 ] || return 1

    if [ "$(sess_get "$_f" hard_ceiling)" -lt "$(sess_get "$_f" soft_deadline)" ]; then
        macon_warn "hard_ceiling precedes soft_deadline"
        return 1
    fi

    _interval=$(sess_get "$_f" interval)
    if [ "$_interval" -lt "$MACON_INTERVAL_FLOOR" ]; then
        macon_warn "interval is below the ${MACON_INTERVAL_FLOOR}s floor"
        return 1
    fi
    if [ "$_interval" -gt "$MACON_INTERVAL_CEIL" ]; then
        macon_warn "interval is above the ${MACON_INTERVAL_CEIL}s ceiling"
        return 1
    fi

    return 0
}

# A recorded PID is only ours if the process is alive AND is the helper.
# The name match is what survives PID recycling within one uptime; see
# plat_process_matches.
sess_helper_alive() {
    _p=$(cat "$(sess_pid_path)" 2>/dev/null)
    _sess_is_number "$_p" || return 1
    plat_process_matches "$_p" 'macon-helper'
}

# The dangerous window: settings applied, helper killed, machine never
# rebooted, so the boot failsafe never fires. Detected by comparing three
# things; healing is deliberately NOT done here, so a read command stays a
# read command.
sess_orphaned() {
    plat_sleep_disabled || return 1
    sess_helper_alive && return 1

    _hb=$(cat "$(sess_heartbeat_path)" 2>/dev/null)
    _sess_is_number "$_hb" || return 0

    _interval=$(sess_get "$(sess_desc_path)" interval)
    _sess_is_number "$_interval" || _interval=300
    _stale_after=$((_interval * MACON_HEARTBEAT_GRACE))

    [ $(( $(macon_now) - _hb )) -gt "$_stale_after" ]
}
