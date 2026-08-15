#!/bin/sh
# Session descriptor: data only, never shell fragments. The root helper
# reads this file and must be able to trust every field, so validation
# happens before anything acts on it.

MACON_INTERVAL_FLOOR=30
MACON_HEARTBEAT_GRACE=3   # missed polls tolerated before declaring an orphan

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
    if [ -f "$_f" ]; then
        grep -v "^$_k=" "$_f" > "$_f.tmp" 2>/dev/null || :
        mv "$_f.tmp" "$_f"
    fi
    printf '%s=%s\n' "$_k" "$_v" >> "$_f"
}

sess_get() {
    [ -f "$1" ] || return 0
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

_sess_is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

sess_validate() {
    _f=$1
    _ok=0

    for _k in started_at soft_deadline hard_ceiling interval strikes; do
        _v=$(sess_get "$_f" "$_k")
        if ! _sess_is_number "$_v"; then
            macon_warn "descriptor field '$_k' is not numeric: '$_v'"
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

    if [ "$(sess_get "$_f" interval)" -lt "$MACON_INTERVAL_FLOOR" ]; then
        macon_warn "interval is below the ${MACON_INTERVAL_FLOOR}s floor"
        return 1
    fi

    return 0
}

# A recorded PID is only ours if the process is alive AND is the helper.
# /var/run is cleared at boot, so a recycled PID cannot survive a reboot,
# but it can be recycled within one uptime.
sess_helper_alive() {
    _p=$(cat "$(sess_pid_path)" 2>/dev/null)
    _sess_is_number "$_p" || return 1
    ps -o command= -p "$_p" 2>/dev/null | grep -q 'macon-helper'
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
