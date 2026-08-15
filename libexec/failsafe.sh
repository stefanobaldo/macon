#!/bin/sh
# Boot-time restore. The only component that holds the safety invariant
# across a reboot: disablesleep persists across reboots, so a helper killed
# by a panic would otherwise leave the machine unable to sleep forever.
set -u

MACON_LIB=${MACON_LIB:-/usr/local/libexec/macon/lib}

# How much uptime still counts as "this is the boot". Wide enough that a slow
# boot on a spinning-rust-era machine still fires, far narrower than any
# session.
MACON_BOOT_WINDOW=600

if [ -z "${MACON_FAILSAFE_SOURCED:-}" ]; then
    # shellcheck source=lib/common.sh
    . "$MACON_LIB/common.sh"
    # shellcheck source=lib/platform.sh
    . "$MACON_LIB/platform.sh"
    # shellcheck source=lib/snapshot.sh
    . "$MACON_LIB/snapshot.sh"
fi

# This runs at boot with nobody watching and no terminal to print to. The log
# is the entire account of what it decided and why, so every path writes one.
# Braced because a redirection that fails takes the whole command with it, and
# the failsafe must not stop because it could not write a log line.
failsafe_log() {
    { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "${MACON_FAILSAFE_LOG:-/var/log/macon-failsafe.log}"; } 2>/dev/null || :
}

# A plain decimal integer with no leading zeros. The second half is not
# pedantry: `[` reads a leading zero as decimal and $(( )) reads it as octal,
# so the guard below and the subtraction under it would disagree about the same
# value -- and `099` is not octal at all, which is a fatal arithmetic error in
# a non-interactive shell rather than an error this function could return.
_failsafe_is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
    esac
    [ "${#1}" -le 18 ]
}

# LaunchDaemon RunAtLoad fires on `launchctl bootstrap` as well as at boot.
# Installing the failsafe during an active session must not revert it and
# must not delete the snapshot, which is irreplaceable.
#
# When the boot time cannot be read this stands down rather than guessing.
# Guessing wrong in the other direction reverts a live session and destroys
# the only record of the original values; a machine that stays awake is
# recoverable by `macon off` or by the next boot, and that asymmetry is what
# decides the default.
failsafe_should_run() {
    _boot=$(plat_boot_time)
    if ! _failsafe_is_number "$_boot"; then
        failsafe_log "aborted: could not read a usable boot time ('$_boot')"
        return 1
    fi
    _up=$(( $(macon_now) - _boot ))
    if [ "$_up" -lt 0 ] || [ "$_up" -gt "$MACON_BOOT_WINDOW" ]; then
        failsafe_log "skipped: uptime ${_up}s is not a boot (install or reload)"
        return 1
    fi
    return 0
}

# Echoes the state directory holding the snapshot, or fails when none does.
#
# The snapshot lives under the user's state directory, and launchd starts a
# system daemon with no user context: $HOME is not the user's, so the default
# ${MACON_STATE:-$HOME/...} resolves to a path that does not exist and the
# failsafe restores nothing at all -- silently, at the one moment it is the
# only thing left holding the invariant.
#
# Only one machine-wide power configuration exists, so when more than one
# candidate holds a snapshot, the one written last is the one that describes
# the machine.
failsafe_find_state() {
    _best=""
    _best_at=0
    for _dir in "$@"; do
        [ -f "$_dir/snapshot" ] || continue
        _at=$(stat -f %m "$_dir/snapshot" 2>/dev/null)
        _failsafe_is_number "$_at" || _at=0
        if [ -z "$_best" ] || [ "$_at" -gt "$_best_at" ]; then
            _best=$_dir
            _best_at=$_at
        fi
    done
    [ -n "$_best" ] || return 1
    printf '%s\n' "$_best"
}

# Where to look. Overridable for the same reason MACON_STATE and MACON_RUN are:
# a default that only resolves to real home directories cannot be exercised
# without real home directories.
MACON_STATE_ROOTS=${MACON_STATE_ROOTS:-"/Users/*/.local/state/macon /var/root/.local/state/macon"}

# Points MACON_STATE at a directory that actually holds a snapshot, unless the
# caller has already said where to look.
failsafe_resolve_state() {
    [ -z "${MACON_STATE:-}" ] || return 0
    # Unquoted on purpose: the roots are a whitespace-separated list of globs,
    # and both the splitting and the expansion are wanted here. /bin/sh passes
    # an unmatched glob through literally, which failsafe_find_state then skips
    # for having no snapshot in it.
    # shellcheck disable=SC2086
    set -- $MACON_STATE_ROOTS
    if MACON_STATE=$(failsafe_find_state "$@"); then
        export MACON_STATE
        failsafe_log "using snapshot state directory $MACON_STATE"
    else
        unset MACON_STATE
    fi
}

failsafe_run() {
    failsafe_should_run || return 0

    _kept=0

    if plat_pmset_disablesleep 0; then
        failsafe_log "boot detected: disablesleep cleared"
    else
        # The single call that gives the machine its ability to sleep back.
        # Nothing downstream reports this, so it is logged here or nowhere.
        failsafe_log "boot detected: FAILED to clear disablesleep"
        _kept=1
    fi

    failsafe_resolve_state

    if ! snap_exists; then
        failsafe_log "no snapshot to restore"
        return 0
    fi

    _args=$(snap_restore_args)
    if [ -z "$_args" ]; then
        failsafe_log "snapshot holds no usable values; leaving it in place"
        return 0
    fi

    # shellcheck disable=SC2086
    if plat_pmset_apply_ac $_args; then
        failsafe_log "restored: $_args"
    else
        failsafe_log "FAILED to restore: $_args"
        _kept=1
    fi

    # The snapshot is deleted because it has been consumed. If any part of the
    # restore failed it has NOT been consumed, and deleting it there destroys
    # the only record of the original values while the machine is still
    # holding the wrong ones -- macOS cannot reconstruct them.
    if [ "$_kept" -eq 0 ]; then
        rm -f "$(snap_path)"
    else
        failsafe_log "keeping the snapshot: the restore did not fully succeed"
    fi
}

if [ -z "${MACON_FAILSAFE_SOURCED:-}" ]; then
    failsafe_run
fi
