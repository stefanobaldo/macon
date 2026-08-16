#!/bin/sh
# Installs macon. Environment verification happens here, once, rather than on
# every invocation.
#
# Usage: sh install.sh [--force]   (as yourself -- NOT under sudo; see below)
#        MACON_PREFIX=/opt/x sh install.sh
#
# It refuses while this Mac still looks like it is holding a session, for the
# same reason uninstall.sh does and with the same three blockers: cp replaces
# the running root helper in place, and a bash reading its script lazily can
# take a syntax error or execute unintended bytes at its next read. The helper
# dies with the power settings still applied, and nothing detects the orphan
# until someone runs macon status, macon on, or reboots.
#
# Sourcing this file with MACON_INSTALL_SOURCED=1 defines the functions and
# does nothing else, which is what makes the checks testable without a suite
# that writes to /usr/local.
set -u

MACON_MIN_MACOS=13
MACON_PREFIX=${MACON_PREFIX:-/usr/local}

# Where the components are copied FROM. An inherited value wins, because $0 is
# not the script when this file is sourced -- and the privileged half re-enters
# it as a script for the same reason.
SRC_DIR=${SRC_DIR:-$(cd "$(dirname "$0")" && pwd)}

install_check_macos() {
    case "$1" in
        '' | *[!0-9]*)
            printf 'macon: could not read the macOS version\n' >&2
            return 1
            ;;
    esac
    # `[ -lt ]` in bash 3.2 -- which is /bin/sh here -- parses its operands
    # into intmax_t and exits 2 on anything larger, rather than returning
    # false. An absurd value therefore does not fail the comparison below, it
    # falls through it, and the floor stops being a floor. A macOS major
    # version has never needed more than four digits.
    if [ "${#1}" -gt 4 ]; then
        printf 'macon: could not read the macOS version\n' >&2
        return 1
    fi
    if [ "$1" -lt "$MACON_MIN_MACOS" ]; then
        printf 'macon: macOS %s or later is required (found major version %s)\n' \
            "$MACON_MIN_MACOS" "$1" >&2
        return 1
    fi
    return 0
}

install_check_binaries() {
    _missing=""
    # id is in the list because install_check_not_root is fed `id -u`: with no
    # id on PATH that check gets an empty string, and a safety check handed an
    # empty operand is the failure mode this project keeps finding.
    for _b in pmset ioreg powermetrics launchctl sysctl awk sed id; do
        command -v "$_b" >/dev/null 2>&1 || _missing="$_missing $_b"
    done
    if [ -n "$_missing" ]; then
        printf 'macon: missing required binaries:%s\n' "$_missing" >&2
        return 1
    fi
    return 0
}

# Refuses an installer running as root. UID is a parameter so the refusal can
# be tested by a suite that is not root; SUDO_USER, when given, only changes
# the wording.
#
# This is not hygiene. `macon failsafe install` writes a LaunchDaemon whose
# environment names MACON_STATE, and it reads that value from its OWN
# environment -- so under sudo the boot failsafe would be told to look for a
# snapshot in root's state directory rather than in the user's. Dropping back
# to SUDO_USER for that one step cannot recover it either: sudo has already
# discarded an exported MACON_STATE by the time this script runs. The script
# runs as the user and sudo's the two steps that need root instead.
install_check_not_root() {
    # Guarded before the comparison, and it fails CLOSED. `[ "" -eq 0 ]` does
    # not return false, it errors and exits 2 -- so an unreadable uid would
    # take the `|| return 0` branch and allow exactly what this refuses. An
    # empty $(id -u) is not hypothetical: a sanitised PATH with no id on it
    # produces one. 10 digits is the whole range of a 32-bit uid_t.
    case "$1" in
        '' | *[!0-9]*)
            printf 'macon: could not read the current user id; refusing to install\n' >&2
            return 1
            ;;
    esac
    if [ "${#1}" -gt 10 ]; then
        printf 'macon: could not read the current user id; refusing to install\n' >&2
        return 1
    fi
    [ "$1" -eq 0 ] || return 0
    printf 'macon: do not run the installer as root.\n' >&2
    printf 'macon: it runs sudo for the steps that need root, and registers the\n' >&2
    printf 'macon: boot failsafe as you -- started under sudo, that job would look\n' >&2
    printf 'macon: for your power snapshot in the root account home, not yours.\n' >&2
    if [ -n "${2:-}" ]; then
        printf 'macon: re-run it without sudo: sh install.sh\n' >&2
    fi
    return 1
}

# Is SRC a macon source tree at all? Checked before the sudo prompt: the same
# mistake caught afterwards costs the user a password for an install that then
# fails on the first cp.
install_check_source() {
    for _f in bin/macon libexec/macon-helper libexec/failsafe.sh lib/common.sh; do
        if [ ! -f "$1/$_f" ]; then
            printf 'macon: %s is not a macon source tree (no %s)\n' "$1" "$_f" >&2
            return 1
        fi
    done
    return 0
}

# The same defaults the library modules use, restated rather than sourced --
# the mirror of uninstall.sh's reason: this script runs BEFORE anything is
# installed, and sourcing the tree it is about to copy would mean running code
# out of a source tree it has not finished checking.
install_run_dir() {
    printf '%s\n' "${MACON_RUN:-/var/run/macon}"
}

install_state_dir() {
    printf '%s\n' "${MACON_STATE:-$HOME/.local/state/macon}"
}

# Is a process from the run directory still alive? Deliberately conservative in
# the same two ways uninstall_helper_alive is: no command-line match, so a
# recycled pid counts as a helper, and ps rather than `kill -0`, because the
# helper runs as root while this script does not -- `kill -0` would answer
# EPERM, a false negative on exactly the case this exists for.
install_helper_alive() {
    _pid=$(cat "$(install_run_dir)/helper.pid" 2>/dev/null) || return 1
    case "$_pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    ps -p "$_pid" -o pid= >/dev/null 2>&1
}

# A snapshot exists only between `macon on` and a successful `macon off`. Its
# presence means the machine still holds values macon changed.
install_snapshot_present() {
    [ -f "$(install_state_dir)/snapshot" ]
}

# Read straight from the IORegistry: SleepDisabled is the one bit that decides
# whether closing the lid suspends, and this script has to be able to answer
# that with nothing installed yet.
install_sleep_disabled() {
    ioreg -r -k SleepDisabled 2>/dev/null | grep -q '"SleepDisabled" = Yes'
}

# Everything that makes installing over this machine unsafe right now, as a word
# list. The same three blockers, in the same words, as uninstall.sh.
install_blockers() {
    _b=""
    install_helper_alive && _b="$_b session"
    install_sleep_disabled && _b="$_b sleep-disabled"
    install_snapshot_present && _b="$_b snapshot"
    printf '%s\n' "${_b# }"
}

install_explain_blockers() {
    printf 'macon: refusing to install -- this Mac looks like it is holding a session:\n' >&2
    # Intentionally unquoted: $1 is the word list install_blockers built.
    # shellcheck disable=SC2086
    for _r in $1; do
        case "$_r" in
            session)
                printf '  - a session is still running (%s/helper.pid)\n' \
                    "$(install_run_dir)" >&2
                ;;
            sleep-disabled)
                printf '  - clamshell sleep is DISABLED right now\n' >&2
                ;;
            snapshot)
                printf '  - the power snapshot is still on disk: %s/snapshot\n' \
                    "$(install_state_dir)" >&2
                ;;
        esac
    done
    printf '\ninstalling copies over the running root helper in place, and a shell\n' >&2
    printf 'reads its script lazily: the helper can take a syntax error at its next\n' >&2
    printf 'read and die with the power settings still applied, leaving an orphan\n' >&2
    printf 'nothing detects until the next macon invocation.\n' >&2
    printf "\nrun 'macon off' first, then install. To install anyway:\n" >&2
    printf '  sh install.sh --force\n' >&2
    return 0
}

# Copies the components into PREFIX. The only function here that writes
# anything, and the only one the tests point at a temporary directory.
#
# Every lib/*.sh goes in, by glob rather than by name: bin/macon sources all of
# them at startup, so one missing file is not a broken subcommand, it is a CLI
# where nothing runs at all -- including `off`, the command that gives the Mac
# its ability to sleep back.
install_files() {
    _p=$1
    case "$_p" in
        /*) ;;
        *)
            printf 'macon: the install prefix must be an absolute path: %s\n' "$_p" >&2
            return 1
            ;;
    esac
    mkdir -p "$_p/bin" "$_p/libexec/macon/lib" || return 1
    cp "$SRC_DIR/bin/macon" "$_p/bin/macon" || return 1
    cp "$SRC_DIR/libexec/macon-helper" "$_p/libexec/macon/macon-helper" || return 1
    cp "$SRC_DIR/libexec/failsafe.sh" "$_p/libexec/macon/failsafe.sh" || return 1
    cp "$SRC_DIR"/lib/*.sh "$_p/libexec/macon/lib/" || return 1
    chmod 755 "$_p/bin/macon" "$_p/libexec/macon/macon-helper" \
        "$_p/libexec/macon/failsafe.sh" || return 1
    chmod 644 "$_p"/libexec/macon/lib/*.sh || return 1
    return 0
}

# `macon failsafe install` reports success even when the sudo tee inside it
# failed, so its exit status cannot be trusted; STATUS is what `macon failsafe
# status` printed afterwards.
install_failsafe_registered() {
    case "$1" in
        installed*) return 0 ;;
    esac
    return 1
}

# The installed CLI hard-defaults MACON_LIB and MACON_LIBEXEC to /usr/local.
# Installed anywhere else it is a CLI that cannot find its own libraries, and
# nothing says so until the next invocation.
#
# The note stops at what is actually true. The boot failsafe is fine: the
# LaunchDaemon carries both paths in its own environment. `macon on` is NOT:
# it starts the root helper through sudo, and sudo's env_reset drops
# MACON_LIB before the helper reads it -- verified on this platform -- so the
# helper looks under /usr/local whatever the user exported. That fails closed
# (the session refuses to arm rather than arming unwatched), but a user told
# only "export these two" would find out at the first `macon on`.
install_prefix_note() {
    [ "$1" = "/usr/local" ] && return 0
    printf '\nnote: macon looks for its libraries under /usr/local by default.\n'
    printf 'Installed in %s, so export these before running it:\n' "$1"
    printf '  export MACON_LIB=%s/libexec/macon/lib\n' "$1"
    printf '  export MACON_LIBEXEC=%s/libexec/macon\n' "$1"
    printf 'The boot failsafe carries both paths in its LaunchDaemon, so it is\n'
    printf 'unaffected. Starting a session is not: macon on launches the root\n'
    printf 'helper through sudo, which drops these variables, so it looks in\n'
    printf '/usr/local and the session refuses to arm. Until that is fixed,\n'
    printf 'only /usr/local supports starting a session.\n'
    return 0
}

# PREFIX/bin is where `macon` lands; PATHVAL is the PATH to look for it in.
install_path_note() {
    case ":$2:" in
        *":$1/bin:"*) return 0 ;;
    esac
    printf '\nnote: %s/bin is not on your PATH; add it to run macon by name.\n' "$1"
    return 0
}

if [ -z "${MACON_INSTALL_SOURCED:-}" ]; then
    # The privileged half, re-entered under sudo by the branch below. It is a
    # re-entry rather than a `sudo sh -c '... . install.sh ...'` so that no
    # path has to survive being embedded in a quoted string, and so that $0 --
    # which is this file again -- resolves the source tree by itself.
    if [ "${1:-}" = "--install-files" ]; then
        if [ "$#" -ne 2 ]; then
            printf 'macon: --install-files is internal; run: sh install.sh\n' >&2
            exit 2
        fi
        install_files "$2" || exit 1
        # The helper is started with sudo and runs as root for the whole
        # session; a copy of it that the invoking user can rewrite is a root
        # shell waiting to be asked for.
        chown -R root:wheel "$2/libexec/macon" "$2/bin/macon" ||
            printf 'macon: warning: could not set ownership under %s\n' "$2" >&2
        exit 0
    fi

    _force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) _force=1; shift ;;
            *)
                printf 'usage: sh install.sh [--force]\n' >&2
                exit 1
                ;;
        esac
    done

    install_check_not_root "$(id -u)" "${SUDO_USER:-}" || exit 1
    install_check_macos "$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" || exit 1
    install_check_binaries || exit 1
    install_check_source "$SRC_DIR" || exit 1

    # Before the sudo prompt and before anything is copied: install_files cp's
    # over the running root helper in place. The mirror of the guard
    # uninstall.sh has had all along.
    _blockers=$(install_blockers)
    if [ -n "$_blockers" ]; then
        if [ "$_force" -eq 0 ]; then
            install_explain_blockers "$_blockers"
            exit 1
        fi
        printf 'macon: --force given; installing over what looks like a live\n' >&2
        printf 'macon: session. If the helper dies, restore this Mac by hand:\n' >&2
        printf 'macon:   sudo pmset -a disablesleep 0\n' >&2
        printf 'macon: and reapply the values in %s/snapshot\n' \
            "$(install_state_dir)" >&2
    fi

    printf 'installing macon into %s (sudo will ask for your password)\n' "$MACON_PREFIX"
    sudo sh "$SRC_DIR/install.sh" --install-files "$MACON_PREFIX" || exit 1

    printf 'installed. registering the boot failsafe...\n'
    MACON_LIB="$MACON_PREFIX/libexec/macon/lib" \
        MACON_LIBEXEC="$MACON_PREFIX/libexec/macon" \
        "$MACON_PREFIX/bin/macon" failsafe install || exit 1

    # Registering the failsafe is the installer's last act and the only thing
    # that holds the safety invariant across a reboot -- so it is checked
    # rather than assumed. The verb above cannot report its own failure: the
    # sudo tee inside it can fail with the pipeline still exiting 0.
    _rc=0
    _fs=$(MACON_LIB="$MACON_PREFIX/libexec/macon/lib" \
        MACON_LIBEXEC="$MACON_PREFIX/libexec/macon" \
        "$MACON_PREFIX/bin/macon" failsafe status 2>/dev/null) || _fs=""
    if ! install_failsafe_registered "$_fs"; then
        _rc=1
        printf 'macon: the boot failsafe did NOT register.\n' >&2
        printf 'macon: without it, a panic or power loss leaves this Mac unable\n' >&2
        printf 'macon: to sleep until someone runs macon off by hand.\n' >&2
        printf 'macon: retry with: macon failsafe install\n' >&2
    fi

    install_prefix_note "$MACON_PREFIX"
    install_path_note "$MACON_PREFIX" "$PATH"
    if [ "$_rc" -eq 0 ]; then
        printf '\nmacon is installed. Try: macon status\n'
    else
        printf '\nmacon is installed, but the boot failsafe is not registered.\n' >&2
    fi
    exit "$_rc"
fi
