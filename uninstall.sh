#!/bin/sh
# Removes macon: the boot failsafe, the CLI, the helper and the libraries.
#
# Usage: sh uninstall.sh [--force]   (as yourself -- NOT under sudo)
#
# It refuses while this Mac still looks like it is holding a session. That is
# the whole safety story of this file: removing the CLI and the LaunchDaemon
# takes away the command that restores the power configuration AND the boot
# job that would have restored it if nobody ran the command. Doing that while
# sleep is disabled leaves a Mac that cannot sleep and no tool left to fix it.
#
# Session records and the power snapshot are deliberately left in place; the
# script says where they are.
#
# Sourcing this file defines the functions and removes nothing -- see the single
# statement at the very end.
set -u

MACON_PREFIX=${MACON_PREFIX:-/usr/local}
MACON_FS_PLIST=${MACON_FS_PLIST:-/Library/LaunchDaemons/local.macon.failsafe.plist}

# The same defaults the library modules use, restated rather than sourced: this
# script has to keep working when the installed tree is half-removed, or gone.
uninstall_state_dir() {
    printf '%s\n' "${MACON_STATE:-$HOME/.local/state/macon}"
}

uninstall_run_dir() {
    printf '%s\n' "${MACON_RUN:-/var/run/macon}"
}

# Same reasoning as the installer, plus one of its own: under sudo, HOME is the
# root account's, so the snapshot check below would look in a directory that
# never holds one and report a modified machine as safe to strand.
uninstall_check_not_root() {
    # Guarded before the comparison, and it fails CLOSED: `[ "" -eq 0 ]` errors
    # and exits 2 rather than returning false, so an unreadable uid would take
    # the `|| return 0` branch and allow exactly what this refuses. An empty
    # $(id -u) is what a sanitised PATH produces. 10 digits is the whole range
    # of a 32-bit uid_t.
    case "$1" in
        '' | *[!0-9]*)
            printf 'macon: could not read the current user id; refusing to uninstall\n' >&2
            return 1
            ;;
    esac
    if [ "${#1}" -gt 10 ]; then
        printf 'macon: could not read the current user id; refusing to uninstall\n' >&2
        return 1
    fi
    [ "$1" -eq 0 ] || return 0
    printf 'macon: do not run the uninstaller as root.\n' >&2
    printf 'macon: it runs sudo for the steps that need root, and it has to read\n' >&2
    printf 'macon: YOUR state directory to know whether this Mac can still sleep.\n' >&2
    if [ -n "${2:-}" ]; then
        printf 'macon: re-run it without sudo: sh uninstall.sh\n' >&2
    fi
    return 1
}

# Is a process from the run directory still alive?
#
# Deliberately conservative in two ways. It does not match the command line, so
# a recycled pid counts as a helper; and it uses ps rather than `kill -0`,
# because the helper runs as root while this script does not -- `kill -0` would
# answer EPERM, a false negative on exactly the case this exists for. Refusing
# an uninstall that could have gone ahead costs a rerun. The other error costs
# a Mac that cannot sleep.
uninstall_helper_alive() {
    _pid=$(cat "$(uninstall_run_dir)/helper.pid" 2>/dev/null) || return 1
    case "$_pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    ps -p "$_pid" -o pid= >/dev/null 2>&1
}

# A snapshot exists only between `macon on` and a successful `macon off`. Its
# presence means the machine still holds values macon changed -- and it is the
# only record of what they were, since macOS exposes no power defaults to
# reconstruct them from.
uninstall_snapshot_present() {
    [ -f "$(uninstall_state_dir)/snapshot" ]
}

# Read straight from the IORegistry rather than through lib/platform.sh:
# SleepDisabled is the one bit that decides whether closing the lid suspends,
# and this script must be able to answer that question with the installed tree
# already broken.
uninstall_sleep_disabled() {
    ioreg -r -k SleepDisabled 2>/dev/null | grep -q '"SleepDisabled" = Yes'
}

# Everything that makes removing macon unsafe right now, as a word list.
uninstall_blockers() {
    _b=""
    uninstall_helper_alive && _b="$_b session"
    uninstall_sleep_disabled && _b="$_b sleep-disabled"
    uninstall_snapshot_present && _b="$_b snapshot"
    printf '%s\n' "${_b# }"
}

uninstall_explain_blockers() {
    printf 'macon: refusing to uninstall -- this Mac may be left unable to sleep:\n' >&2
    # Intentionally unquoted: $1 is the word list uninstall_blockers built.
    # shellcheck disable=SC2086
    for _r in $1; do
        case "$_r" in
            session)
                printf '  - a session is still running (%s/helper.pid)\n' \
                    "$(uninstall_run_dir)" >&2
                ;;
            sleep-disabled)
                printf '  - clamshell sleep is DISABLED right now\n' >&2
                ;;
            snapshot)
                printf '  - the power snapshot is still on disk: %s/snapshot\n' \
                    "$(uninstall_state_dir)" >&2
                ;;
        esac
    done
    printf "\nrun 'macon off' first: it restores the power configuration and\n" >&2
    printf 'clears the snapshot. Then run this again.\n' >&2
    printf 'To remove macon anyway and restore the settings by hand:\n' >&2
    printf '  sh uninstall.sh --force\n' >&2
    return 0
}

# The prefix reaches `sudo rm -rf` below. A relative one deletes nothing under
# the prefix -- but the LaunchDaemon removal that runs first is absolute, so
# the script would strip the real boot failsafe off the machine, leave the real
# installation in place, and report success.
uninstall_check_prefix() {
    case "$1" in
        /*) return 0 ;;
    esac
    printf 'macon: the install prefix must be an absolute path: %s\n' "$1" >&2
    return 1
}

uninstall_failsafe_present() {
    [ -f "$MACON_FS_PLIST" ]
}

# Reached when the plist is still there after everything that should have
# removed it. Removing the components now is the one thing that must not
# happen: it leaves a RunAtLoad root job pointing at a deleted program, an
# error at every boot, and no macon left to take it out.
uninstall_explain_stuck_failsafe() {
    printf 'macon: the boot failsafe could not be removed:\n' >&2
    printf 'macon:   %s\n' "$MACON_FS_PLIST" >&2
    printf 'macon: nothing else was removed -- deleting the components now would\n' >&2
    printf 'macon: leave a boot job pointing at a program that is gone.\n' >&2
    printf 'macon: remove it by hand, then run this again:\n' >&2
    printf 'macon:   sudo launchctl bootout system %s\n' "$MACON_FS_PLIST" >&2
    printf 'macon:   sudo rm -f %s\n' "$MACON_FS_PLIST" >&2
    return 0
}

# Removing the boot failsafe goes through the CLI, which refuses while this Mac
# still looks like it is holding a session -- the same three blockers checked
# here. FORCE is the decision already taken above, passed through: without it,
# `uninstall.sh --force` would stop at the verb it calls, having warned the user
# that it was going ahead.
uninstall_failsafe_remove() {
    [ -x "$MACON_PREFIX/bin/macon" ] || return 0
    if [ "$1" -eq 1 ]; then
        MACON_LIB="$MACON_PREFIX/libexec/macon/lib" \
            MACON_LIBEXEC="$MACON_PREFIX/libexec/macon" \
            "$MACON_PREFIX/bin/macon" failsafe remove --force || :
    else
        MACON_LIB="$MACON_PREFIX/libexec/macon/lib" \
            MACON_LIBEXEC="$MACON_PREFIX/libexec/macon" \
            "$MACON_PREFIX/bin/macon" failsafe remove || :
    fi
    return 0
}

uninstall_state_note() {
    printf 'Your session records and power snapshot were left in place:\n'
    printf '  %s\n' "$(uninstall_state_dir)"
    printf 'Remove them yourself if you want them gone.\n'
    return 0
}

# Everything below this line touches the machine: sudo launchctl, sudo rm -f
# and sudo rm -rf. It is a function, and the one statement at the end of the
# file is the only thing that calls it.
#
# It used to be an `if [ -z "$MACON_UNINSTALL_SOURCED" ]; then ... fi` wrapped
# around the same lines. That shape is a guard only while its two halves stay
# paired: one unbalanced `fi` closes it early and turns the removals into
# top-level code, which the test suite that sources this file for its pure
# functions then runs for real. The installer had exactly that defect and it
# cost a real, unasked-for installation.
uninstall_main() {
    _force=0
    case "${1:-}" in
        --force) _force=1 ;;
        '') ;;
        *)
            printf 'usage: sh uninstall.sh [--force]\n' >&2
            exit 1
            ;;
    esac

    uninstall_check_not_root "$(id -u)" "${SUDO_USER:-}" || exit 1
    uninstall_check_prefix "$MACON_PREFIX" || exit 1

    _blockers=$(uninstall_blockers)
    if [ -n "$_blockers" ]; then
        if [ "$_force" -eq 0 ]; then
            uninstall_explain_blockers "$_blockers"
            exit 1
        fi
        printf 'macon: --force given; removing macon while this Mac may be unable\n' >&2
        printf 'macon: to sleep. Restore it by hand:\n' >&2
        printf 'macon:   sudo pmset -a disablesleep 0\n' >&2
        printf 'macon: and reapply the values in %s/snapshot\n' \
            "$(uninstall_state_dir)" >&2
    fi

    printf 'removing the boot failsafe...\n'
    uninstall_failsafe_remove "$_force"

    # The result is checked, not the attempt. `macon failsafe remove` exits 0
    # whether or not the plist actually went, and the CLI above may not have
    # run at all -- it dies sourcing its libraries if any of them are missing,
    # which is precisely the half-broken installation someone reaches for the
    # uninstaller to clean up. So the direct removal is not an else-branch: it
    # runs whenever the file is still there.
    if uninstall_failsafe_present; then
        sudo launchctl bootout system "$MACON_FS_PLIST" 2>/dev/null ||
            sudo launchctl unload -w "$MACON_FS_PLIST" 2>/dev/null || :
        sudo rm -f "$MACON_FS_PLIST"
    fi

    if uninstall_failsafe_present; then
        uninstall_explain_stuck_failsafe
        exit 1
    fi

    printf 'removing %s/bin/macon and %s/libexec/macon...\n' \
        "$MACON_PREFIX" "$MACON_PREFIX"
    sudo rm -f "$MACON_PREFIX/bin/macon" || exit 1
    sudo rm -rf "$MACON_PREFIX/libexec/macon" || exit 1

    printf '\nmacon is uninstalled.\n'
    uninstall_state_note
}

# The whole decision, in four lines that cannot come apart. `return` outside a
# function returns from a file that is being SOURCED and is an error in one that
# is being EXECUTED -- bash 3.2, which is /bin/sh here, reports it on stderr
# (discarded) and carries on. Sourcing stops inside the case; execution falls out
# of it and into uninstall_main. Executed under some other name the `*` branch is
# taken, `return` fails because the file is being executed, and the uninstall
# proceeds. install.sh carries the same four lines, for the same reason.
case "${0##*/}" in
    uninstall.sh) ;;               # executed: fall through to uninstall_main
    *) return 0 2>/dev/null ;;     # sourced: stop here
esac

uninstall_main "$@"
