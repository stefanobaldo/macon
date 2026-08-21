#!/bin/sh
# The power snapshot is the ONLY record of the original values that exists
# anywhere: macOS exposes no readable source of power defaults. There is no
# plist of profiles in powerd.bundle, nothing under /System/Library, and no
# pmset verb that prints them. If the snapshot is lost while the machine is
# modified, the information is gone for good.
#
# Hence the two defences here: never snapshot an already-modified machine,
# and keep a forensic copy of the plists powerd actually persists.

_snap_dir() {
    printf '%s\n' "${MACON_STATE:-$HOME/.local/state/macon}"
}

snap_path() {
    printf '%s/snapshot\n' "$(_snap_dir)"
}

snap_exists() {
    [ -f "$(snap_path)" ]
}

_snap_field() {
    awk -F= -v k="$1" '$1 == k { print $2; exit }' "$(snap_path)"
}

# The module's only input validation. These values become pmset arguments on
# the restore path, and they are read back from a file on disk.
_snap_is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
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

# Refuses with a DIFFERENT rc per reason, because the caller's advice differs by
# reason and there is no second way for it to learn which one happened:
#
#   1  the machine already looks modified   -- `macon off`, or restore by hand
#   2  the current values could not be read -- pmset itself is not answering
#   3  the snapshot could not be written    -- a question of who owns the file
#
# One rc for all three made bin/macon print the first of them whichever had
# actually happened, so a user whose snapshot was merely unwritable was told
# their machine looked modified -- about a machine they could see was not.
# The rc carries the reason, the way snap_restore's already does.
snap_save() {
    if snap_looks_active; then
        macon_warn "refusing to snapshot: the machine already looks modified"
        return 1
    fi

    _sleep=$(plat_pmset_read sleep)
    _disksleep=$(plat_pmset_read disksleep)
    _powernap=$(plat_pmset_read powernap)

    # An unreadable pmset prints nothing and still exits 0. Recording that
    # would produce a file that passes snap_exists and restores nothing, while
    # the caller reads success and goes on to modify the machine. Fail closed:
    # failing to arm is recoverable, a poisoned snapshot is not.
    for _v in "$_sleep" "$_disksleep" "$_powernap"; do
        if ! _snap_is_number "$_v"; then
            macon_warn "refusing to snapshot: could not read the current power values"
            return 2
        fi
    done

    _dir=$(_snap_dir)
    mkdir -p "$_dir" || return 3

    # Write to a temp file in the same directory and rename over the target.
    # Redirecting straight at the real path truncates it before the write is
    # known to succeed, destroying a valid snapshot that cannot be rebuilt.
    _tmp="$_dir/snapshot.tmp.$$"
    if ! {
        printf 'sleep=%s\n' "$_sleep"
        printf 'disksleep=%s\n' "$_disksleep"
        printf 'powernap=%s\n' "$_powernap"
    } > "$_tmp"; then
        rm -f "$_tmp"
        macon_warn "could not write a snapshot in $_dir"
        return 3
    fi

    # -f, and it is not tidiness. A session armed under sudo used to leave a
    # ROOT-OWNED snapshot in the user's own state directory, and it outlives the
    # session: only `macon off` and the boot failsafe consume one, so the
    # ordinary ending leaves it behind. The next unprivileged arm renames over a
    # file it cannot write, and BSD mv ASKS before doing that -- but only when
    # stdin is a terminal, which is exactly how `macon on` is documented to be
    # run. Answering no failed the arm; answering nothing at all, in a script,
    # replaced the file silently. -f is what makes the two agree, and this
    # rename is macon replacing its own state file, which is never a question
    # worth stopping an arm to ask.
    #
    # The cleanup is here as well as on the write path above: the rename is the
    # other way this can fail, and it fails with the temp file already on disk.
    # Every declined arm used to leave one.
    if ! mv -f "$_tmp" "$(snap_path)"; then
        rm -f "$_tmp"
        macon_warn "could not replace the snapshot at $(snap_path)"
        return 3
    fi
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
    # Clearing disablesleep runs first and unconditionally: it is the single
    # call that gives the machine back its ability to sleep, so it must happen
    # even when the snapshot is missing or unusable.
    plat_pmset_disablesleep 0
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        # The one otherwise-invisible failure: nothing else reports it, and the
        # machine is left unable to sleep.
        macon_warn "failed to clear disablesleep"
    fi

    _args=$(snap_restore_args)
    if [ -z "$_args" ]; then
        # No usable snapshot, so nothing was reapplied. Callers print their own
        # human-facing message here; the rc alone carries the fact.
        return 1
    fi

    # Intentionally unquoted: $_args is a validated argument list.
    # shellcheck disable=SC2086
    plat_pmset_apply_ac $_args
    _apply_rc=$?
    if [ "$_rc" -eq 0 ]; then
        _rc=$_apply_rc
    fi
    return "$_rc"
}

# How many pmprefs-* backups to keep. The newest is what a by-hand recovery
# reads; the older ones matter only if the newest was taken after something had
# already gone wrong. One is created per arm, so without a bound the directory
# grows for as long as the tool is used -- 48 in three days on the verification
# machine.
#
# The value is a count this module deletes directories by, and it arrives from
# the environment, so it goes through the module's number check. A garbage value
# is NOT a zero: unvalidated, `$((n - garbage))` is `$((n - 0))` in a shell
# without `set -u`, which would delete every backup -- the whole forensic
# history this retention exists to preserve. Unset, empty and non-numeric all
# land on the same default, and quietly: this runs in the middle of an arm, and
# a knob nobody set correctly is no reason to abort a session.
#
# Bounded in length as well as in shape, and for a second reason: /bin/sh here
# is bash 3.2, whose arithmetic is intmax_t, so a value of 20 digits does not
# fail -- it WRAPS. $((13 - 10000000000000000000)) is a large positive number,
# which is an excess larger than the directory, and the loop below then removes
# every entry in it. Same erasure as a zero, reached through a value that is
# all digits. lib/session.sh bounds the same class of value at the same 18 for
# the same reason (MACON_NUMBER_MAX_DIGITS, and the note above _sess_is_number);
# the bound is restated here rather than read from there because lib/snapshot.sh
# sources no other library module, and tests/test_snapshot.sh loads it alone.
#
# A leading zero is rejected for the third reason lib/session.sh gives at
# _sess_is_number: $(( )) reads it as octal. `010` is not a spelling of ten, it
# IS eight -- a knob answering a different question than the one it was asked,
# and saying nothing -- and `099` is not valid octal at all, which makes the
# arithmetic an error rather than a value. Bare `0` is a real request, and stays
# one: it clears the directory, which lib/session.sh:105 preserves the same way.
MACON_PMPREFS_KEEP_MAX_DIGITS=18
MACON_PMPREFS_KEEP=${MACON_PMPREFS_KEEP:-10}
if ! _snap_is_number "$MACON_PMPREFS_KEEP" ||
    [ "${#MACON_PMPREFS_KEEP}" -gt "$MACON_PMPREFS_KEEP_MAX_DIGITS" ] ||
    { [ "$MACON_PMPREFS_KEEP" != 0 ] &&
        [ "${MACON_PMPREFS_KEEP#0}" != "$MACON_PMPREFS_KEEP" ]; }; then
    MACON_PMPREFS_KEEP=10
fi

# Removes the oldest backups until at most MACON_PMPREFS_KEEP remain.
#
# Ordering is the shell's own pathname expansion, which sorts: the names are
# pmprefs-YYYYmmdd-HHMMSS, so lexicographic order IS creation order. mtime is
# deliberately not consulted -- restoring the user's home from a backup rewrites
# it and would reorder the history.
#
# Only pmprefs-* directories are ever candidates. The `snapshot` file lives in
# the same directory and is the live restore source; it is not matched by the
# glob and must never be.
#
# Variables are prefixed _sp_ because the caller holds _dst and _backup_rc
# across this call, and in POSIX sh there is no `local`.
_snap_prune_plists() {
    _sp_n=0
    for _sp_d in "$(_snap_dir)"/pmprefs-*; do
        [ -d "$_sp_d" ] || continue
        _sp_n=$((_sp_n + 1))
    done

    _sp_excess=$((_sp_n - MACON_PMPREFS_KEEP))
    [ "$_sp_excess" -gt 0 ] || return 0

    for _sp_d in "$(_snap_dir)"/pmprefs-*; do
        [ -d "$_sp_d" ] || continue
        [ "$_sp_excess" -gt 0 ] || break
        rm -rf "$_sp_d" 2>/dev/null || :
        _sp_excess=$((_sp_excess - 1))
    done
    return 0
}

# Forensic only. Restoring these files at runtime does not make powerd
# re-read them; they exist so the real values can be recovered by hand if
# the snapshot is ever lost. Echoes the destination either way, but reports
# non-zero when no plist actually landed — an empty directory is not a defence.
snap_backup_plists() {
    _dst="$(_snap_dir)/pmprefs-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$_dst"
    plat_backup_pmprefs "$_dst"
    _backup_rc=$?
    # Never changes the verdict: a directory that cannot be removed is not a
    # reason to fail an arm.
    _snap_prune_plists
    printf '%s\n' "$_dst"
    return "$_backup_rc"
}
