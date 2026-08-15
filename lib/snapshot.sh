#!/bin/sh
# The power snapshot is the ONLY record of the original values that exists
# anywhere: macOS exposes no readable source of power defaults. There is no
# plist of profiles in powerd.bundle, nothing under /System/Library, and no
# pmset verb that prints them. If the snapshot is lost while the machine is
# modified, the information is gone for good.
#
# Hence the two defences here: never snapshot an already-modified machine,
# and keep a forensic copy of the plists powerd actually persists.

snap_path() {
    printf '%s/snapshot\n' "${MACON_STATE:-$HOME/.local/state/macon}"
}

snap_exists() {
    [ -f "$(snap_path)" ]
}

# True when the machine already looks like a macon session is in effect.
# Snapshotting now would record zeros as "original" — permanently, and with
# no way to reconstruct the real values.
snap_looks_active() {
    if plat_sleep_disabled; then
        return 0
    fi
    [ "$(plat_pmset_read sleep)" = "0" ] &&
        [ "$(plat_pmset_read disksleep)" = "0" ] &&
        [ "$(plat_pmset_read powernap)" = "0" ]
}

snap_save() {
    if snap_looks_active; then
        macon_warn "refusing to snapshot: the machine already looks modified"
        return 1
    fi
    mkdir -p "${MACON_STATE:-$HOME/.local/state/macon}"
    {
        printf 'sleep=%s\n' "$(plat_pmset_read sleep)"
        printf 'disksleep=%s\n' "$(plat_pmset_read disksleep)"
        printf 'powernap=%s\n' "$(plat_pmset_read powernap)"
    } > "$(snap_path)"
}

_snap_field() {
    awk -F= -v k="$1" '$1 == k { print $2; exit }' "$(snap_path)"
}

_snap_is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Echoes the pmset argument list, e.g. "sleep 1 disksleep 10 powernap 1".
# Values are validated because they end up as command arguments.
snap_restore_args() {
    snap_exists || return 0
    _args=""
    for _k in sleep disksleep powernap; do
        _v=$(_snap_field "$_k")
        if _snap_is_number "$_v"; then
            _args="$_args $_k $_v"
        fi
    done
    printf '%s\n' "${_args# }"
}

snap_restore() {
    plat_pmset_disablesleep 0
    _args=$(snap_restore_args)
    if [ -n "$_args" ]; then
        # Intentionally unquoted: $_args is a validated argument list.
        # shellcheck disable=SC2086
        plat_pmset_apply_ac $_args
    fi
}

# Forensic only. Restoring these files at runtime does not make powerd
# re-read them; they exist so the real values can be recovered by hand if
# the snapshot is ever lost.
snap_backup_plists() {
    _dst="${MACON_STATE:-$HOME/.local/state/macon}/pmprefs-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$_dst"
    cp /Library/Preferences/com.apple.PowerManagement*.plist "$_dst"/ 2>/dev/null
    printf '%s\n' "$_dst"
}
