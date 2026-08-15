#!/bin/sh
# Boot-time restore. The only component that holds the safety invariant
# across a reboot: disablesleep persists across reboots, so a helper killed
# by a panic would otherwise leave the machine unable to sleep forever.
set -u

MACON_LIB=${MACON_LIB:-/usr/local/libexec/macon/lib}

# launchd starts a system daemon with no user context, and every state path in
# this project defaults to $HOME/... . Under `set -u` an unset HOME is not a
# missing fallback but a FATAL error, and it would land here after disablesleep
# had been cleared and before anything was restored -- with no log line to say
# why, because the shell exits before reaching one. /var/root is root's home on
# macOS, which is where this default belongs for a system daemon anyway.
: "${HOME:=/var/root}"
export HOME

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
    # shellcheck source=lib/records.sh
    . "$MACON_LIB/records.sh"
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

# Applies the snapshot and consumes it. KEPT is 1 when something has already
# failed, in which case the snapshot survives whatever happens here.
failsafe_restore_snapshot() {
    _kept=$1

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

# A night that ended in a panic is exactly a samples file with no row in the
# index: the row is written only when a session ends, and the reboot clears
# only /var/run, while both of these files live in the user's state directory.
# That asymmetry is the whole detector, and it needs nothing the crash
# destroyed. Without it, the most interesting night macon can record is the one
# night it silently discards.
#
# ended_at is the last sample, which is up to one poll before the machine
# actually died. That is the honest value and the one the column already means
# everywhere else: the last moment macon observed the session alive.
#
# This is bookkeeping and runs last, after the restore, where it cannot delay
# or fail the safety action.
failsafe_record_crashed() {
    [ -n "${MACON_STATE:-}" ] || return 0

    _idx=$(rec_index_path)
    # Appending to an existing file preserves its ownership; CREATING it here
    # would leave a root-owned index in a user-owned directory and break the
    # user's next write. No index also means no session has ever ended
    # normally, so there is nothing here worth reconstructing.
    [ -f "$_idx" ] || return 0

    for _s in "$MACON_STATE"/samples/*.tsv; do
        [ -f "$_s" ] || continue
        _sid=$(basename "$_s" .tsv)
        # awk rather than grep: the id comes from a filename and would be a
        # pattern to grep, and a field comparison is what is meant anyway.
        if awk -F'\t' -v id="$_sid" '$1 == id { f = 1 } END { exit !f }' "$_idx"; then
            continue
        fi
        _start=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$_s")
        _end=$(awk -F'\t' 'END { print $1 }' "$_s")
        if ! _failsafe_is_number "$_start" || ! _failsafe_is_number "$_end"; then
            failsafe_log "session $_sid has no usable timestamps; not recorded"
            continue
        fi
        if rec_close_session "$_sid" "$_start" "$_end" reboot; then
            failsafe_log "recorded session $_sid as ended by reboot"
        else
            failsafe_log "could not record session $_sid as ended by reboot"
        fi
    done
}

failsafe_run() {
    failsafe_should_run || return 0

    _run_kept=0

    if plat_pmset_disablesleep 0; then
        failsafe_log "boot detected: disablesleep cleared"
    else
        # The single call that gives the machine its ability to sleep back.
        # Nothing downstream reports this, so it is logged here or nowhere.
        failsafe_log "boot detected: FAILED to clear disablesleep"
        _run_kept=1
    fi

    failsafe_resolve_state
    failsafe_restore_snapshot "$_run_kept"
    failsafe_record_crashed
}

if [ -z "${MACON_FAILSAFE_SOURCED:-}" ]; then
    failsafe_run
fi
