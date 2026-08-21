#!/bin/sh
# Installs macon. Environment verification happens here, once, rather than on
# every invocation.
#
# Usage: sh install.sh [--force]   (as yourself -- NOT under sudo; see below)
#        MACON_PREFIX=/opt/x sh install.sh
#
# It refuses while this Mac is holding a session, for the same reason
# uninstall.sh does and with the same three blockers: cp replaces the running
# root helper in place, and a bash reading its script lazily can take a syntax
# error or execute unintended bytes at its next read. The helper dies with the
# power settings still applied, and nothing detects the orphan until someone
# runs macon status, macon on, or reboots.
#
# Sourcing this file defines the functions and does nothing else -- see the
# single statement at the very end -- which is what makes the checks testable
# without a suite that writes to /usr/local.
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

# A session descriptor exists from the moment `macon on` hands one to the root
# helper until the session ends. It brackets a session more tightly than the
# pid file at both ends: it is on disk before launchd is asked to start the
# helper, and it is unlinked only after the restore has run -- so a descriptor
# still present means an ending that did not complete.
#
# The power snapshot is deliberately NOT a blocker. It outlives every session
# that ends by itself -- the deadline path and the orphan heal both restore and
# leave it behind -- so its presence says nothing about whether one is running.
install_descriptor_present() {
    [ -f "$(install_run_dir)/session.conf" ]
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
    install_descriptor_present && _b="$_b descriptor"
    printf '%s\n' "${_b# }"
}

install_explain_blockers() {
    printf 'macon: refusing to install -- this Mac is holding a session:\n' >&2
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
            descriptor)
                printf '  - a session descriptor is present: %s/session.conf\n' \
                    "$(install_run_dir)" >&2
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

_INSTALL_NL='
'

# True when only root can change what is inside DIR.
#
# Both halves matter. An owner other than root can replace anything in the
# directory, and so can any member of a group that has write permission --
# `admin` on a Mac, which is every administrator account. A directory that does
# not exist yet is not a finding: the privileged half creates it, as root.
#
# Unreadable ownership fails CLOSED, and the length bound is not hygiene: `[
# -eq ]` on bash 3.2 exits 2 rather than returning false on an operand it cannot
# parse, so the comparison would fall through and the guard would stop guarding.
# The permission half, split out as a pure function so both of its clauses can
# be asserted: a root-owned directory that is group- or world-writable cannot be
# produced by a test suite that is not root.
#
# MODE is stat's octal digits, compared as TEXT. A leading zero is decimal to
# `[` and octal to $(( )), and 08 is a fatal arithmetic error rather than a
# value either of them could report -- so nothing here converts it to a number.
# An unreadable mode fails closed.
install_mode_is_root_only() {
    case "$1" in
        '' | *[!0-7]*) return 1 ;;
        *[2367]) return 1 ;;         # writable by other
        *[2367][0-7]) return 1 ;;    # writable by group
    esac
    return 0
}

install_dir_is_root_only() {
    [ -d "$1" ] || return 0
    _own=$(stat -f '%u' "$1" 2>/dev/null)
    case "$_own" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "${#_own}" -le 10 ] || return 1
    [ "$_own" -eq 0 ] || return 1
    install_mode_is_root_only "$(stat -f '%Lp' "$1" 2>/dev/null)"
}

# The directories this install would land in, or sit under, that someone other
# than root can write to. One per line, because a prefix may contain a space.
install_unsafe_dirs() {
    _bad=""
    for _leaf in "$1/bin" "$1/libexec"; do
        if [ -d "$_leaf" ] && ! install_dir_is_root_only "$_leaf"; then
            _bad="$_bad$_leaf$_INSTALL_NL"
        fi
    done
    _d=$1
    while [ -n "$_d" ] && [ "$_d" != "/" ] && [ "$_d" != "." ]; do
        if [ -d "$_d" ] && ! install_dir_is_root_only "$_d"; then
            _bad="$_bad$_d$_INSTALL_NL"
        fi
        _d=$(dirname "$_d")
    done
    printf '%s' "$_bad"
}

# The chown the privileged half already does covers the macon tree. It does not
# and cannot cover the directories ABOVE it, and that is where the boundary is
# crossed: this installer registers a permanently loaded LaunchDaemon whose
# program is PREFIX/libexec/macon/macon-helper, so anything that can write to a
# parent can swap the whole macon directory for its own and then have launchd
# run that code as root on demand, with a single `launchctl kickstart` any local
# account may issue. Not a password-gated privilege turned ungated -- an ungated
# one from the moment the install finishes.
#
# Refusing costs a real install on a real Mac -- Homebrew leaves /usr/local
# user-owned, which is the normal state of an Intel machine. Taking ownership
# instead would be macon reorganising another package manager's prefix, which it
# does not get to do and could not undo on uninstall. So the refusal is the
# default and the user is told exactly which directory, exactly what the risk
# is, and all three ways out.
install_explain_unsafe_dirs() {
    printf 'macon: refusing to install: these directories can be written to by\n' >&2
    printf 'macon: someone other than root:\n' >&2
    printf '%s' "$1" | while IFS= read -r _d; do
        [ -n "$_d" ] || continue
        printf 'macon:   %s\n' "$_d" >&2
    done
    printf 'macon:\n' >&2
    printf 'macon: this installer registers a launchd job that runs\n' >&2
    printf 'macon: %s/libexec/macon/macon-helper as ROOT, and leaves it\n' "$2" >&2
    printf 'macon: loaded. Anything that can write to a directory above that helper\n' >&2
    printf 'macon: can replace it, and then start its own code as root at any moment\n' >&2
    printf 'macon: with launchctl kickstart -- no password, and nothing you have to\n' >&2
    printf 'macon: type or run.\n' >&2
    printf 'macon: Homebrew leaves /usr/local user-owned, so on an Intel Mac this is\n' >&2
    printf 'macon: the normal state of the prefix rather than a sign of tampering.\n' >&2
    printf 'macon:\n' >&2
    printf 'macon: Give the directories above to root:\n' >&2
    printf 'macon:   sudo chown root:wheel DIR && sudo chmod go-w DIR\n' >&2
    printf 'macon: Do NOT do that to a prefix Homebrew manages -- it writes there\n' >&2
    printf 'macon: without sudo, and macon does not get to reorganise it. Install\n' >&2
    printf 'macon: under a prefix only root owns instead:\n' >&2
    printf 'macon:   MACON_PREFIX=/opt/macon sh install.sh\n' >&2
    printf 'macon: Or accept the risk, knowing what it is:\n' >&2
    printf 'macon:   sh install.sh --allow-unsafe-prefix\n' >&2
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

# Where the session helper's LaunchDaemon is registered, and the label launchd
# knows it by. The same two values bin/macon defines, restated here because
# install.sh does not source the CLI; a test pins the two defaults together so
# they cannot drift into registering one label and verifying another.
#
# Overridable, and they must be overridden ALONGSIDE the CLI's -- this
# installer really does register with launchd. The plist path only says
# where the file goes; its contents, Label included, are rendered by
# `macon __helper_plist`, so redirecting this alone writes the REAL label into a
# temporary file and bootstraps it. Only a test that overrides both here and in
# the CLI it calls is naming a job this machine does not have.
#
# Beside their only consumer rather than at the top of the file: the registration
# below must come after the copy, and a definition up with MACON_PREFIX would
# read as a knob of the install as a whole, which this is not.
MACON_HELPER_PLIST=${MACON_HELPER_PLIST:-/Library/LaunchDaemons/local.macon.helper.plist}
MACON_HELPER_LABEL=${MACON_HELPER_LABEL:-local.macon.helper}

# The session helper's LaunchDaemon. It is what supervises a running session:
# if the helper dies, launchd starts it again and it resumes from the
# root-owned descriptor. Without it `macon on` refuses outright, so this is not
# an optional extra.
#
# After the components are in place, deliberately. A job whose ProgramArguments
# point at a file that is not there yet crash-loops at ThrottleInterval per
# attempt, and the installer has no way to notice.
install_helper_daemon() {
    _p=$1

    # An upgrade over an existing install: bootstrapping a label launchd
    # already has fails with EIO, so unloading first is what makes this
    # idempotent rather than a no-op that silently keeps the old registration.
    #
    # Two statuses are ordinary and the rest are not. 0 is "booted out"; 3 is
    # ESRCH -- "No such process", verified as what launchctl answers about a
    # label it does not have, which is every first install. Anything else means
    # the old job may still be loaded, and `launchctl print` at the end of this
    # installer cannot tell a fresh registration from a surviving one: it sees a
    # job either way. So it is said here, where the number is still known, or it
    # is never said at all.
    _bo=0
    sudo launchctl bootout "system/$MACON_HELPER_LABEL" 2>/dev/null || _bo=$?
    if [ "$_bo" -ne 0 ] && [ "$_bo" -ne 3 ]; then
        printf 'macon: could not unload the existing %s (launchctl exited %s).\n' \
            "$MACON_HELPER_LABEL" "$_bo" >&2
        printf 'macon: if this install reports the daemon registered, the job\n' >&2
        printf 'macon: launchd is running may still be the OLD one. Take it out by\n' >&2
        printf 'macon: hand and run this installer again:\n' >&2
        printf 'macon:   sudo launchctl bootout system/%s\n' "$MACON_HELPER_LABEL" >&2
    fi

    # Rendered and checked before anything privileged touches the real path.
    #
    # `macon __helper_plist | sudo tee "$MACON_HELPER_PLIST"` reports TEE's
    # status, not the CLI's: a render that died still leaves the pipeline
    # exiting 0 over an EMPTY root-owned plist. chown and chmod both succeed on
    # it, bootstrap rejects it, and what stays on the machine is a file launchd
    # fails to parse at every boot until someone reinstalls.
    #
    # The temporary file is the user's own, created 0600 by mktemp under a
    # per-user TMPDIR on macOS, and it is copied rather than moved so the
    # destination's ownership is root's from the start.
    _tmp=$(mktemp "${TMPDIR:-/tmp}/macon-helper-plist.XXXXXX") || return 1

    # A signal landing between the mktemp and the rm would otherwise leave that
    # 0600 file behind, once per interrupted install. The three steps below
    # share ONE cleanup point rather than returning early, so the trap is
    # cleared again the moment it stops being needed and nothing global
    # outlives this function.
    trap 'rm -f "$_tmp"' EXIT HUP INT TERM

    _ok=1
    MACON_LIB="$_p/libexec/macon/lib" \
        MACON_LIBEXEC="$_p/libexec/macon" \
        "$_p/bin/macon" __helper_plist > "$_tmp" || _ok=0

    # `plutil -lint` rather than a test for a non-empty file. Both catch a
    # render that died before writing anything; only this catches one that died
    # HALFWAY, and a half-written plist is the more likely of the two -- the
    # renderer writes the envelope before the keys. Verified: it exits 1 on an
    # empty file and on a truncated one, and 0 on the real thing. launchd's own
    # answer to a plist it cannot parse is to not run the job, which is the
    # failure this whole function exists to keep off the machine.
    [ "$_ok" -eq 1 ] && { plutil -lint "$_tmp" > /dev/null 2>&1 || _ok=0; }
    [ "$_ok" -eq 1 ] && { sudo cp "$_tmp" "$MACON_HELPER_PLIST" || _ok=0; }

    rm -f "$_tmp"
    trap - EXIT HUP INT TERM
    [ "$_ok" -eq 1 ] || return 1

    sudo chown root:wheel "$MACON_HELPER_PLIST" || return 1
    sudo chmod 644 "$MACON_HELPER_PLIST" || return 1
    sudo launchctl bootstrap system "$MACON_HELPER_PLIST" || return 1
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
# The exports are needed by the CLI's own process and by nothing else. Every
# root component carries both paths explicitly: `macon on` restates them through
# /usr/bin/env on the far side of sudo, precisely because env_reset drops them,
# and the boot failsafe and the session helper daemon each name them in their
# own EnvironmentVariables. So a non-default prefix is a complete install, and
# the note says what to export rather than what will not work.
#
# What the note must not lose is that the exports have to outlive one shell.
# `macon off` is a macon command like any other: a user who exported them for
# the `macon on` and not for the terminal they run `off` in gets a CLI that
# cannot find its own libraries at the moment they want their sleep back.
install_prefix_note() {
    [ "$1" = "/usr/local" ] && return 0
    printf '\nnote: macon looks for its libraries under /usr/local by default.\n'
    printf 'Installed in %s, so export these before running it:\n' "$1"
    printf '  export MACON_LIB=%s/libexec/macon/lib\n' "$1"
    printf '  export MACON_LIBEXEC=%s/libexec/macon\n' "$1"
    printf 'Put them in your shell profile rather than one terminal: EVERY macon\n'
    printf 'command needs them, macon off included.\n'
    printf 'Nothing macon starts for itself depends on your environment -- the\n'
    printf 'boot failsafe and the helper daemon carry both paths in their own\n'
    printf 'LaunchDaemons, and macon on restates them across sudo -- so a session\n'
    printf 'starts here exactly as it would under /usr/local.\n'
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

# Everything below this line touches the machine: sudo, chown, and the boot
# failsafe. It is a function, and the one statement at the end of the file is
# the only thing that calls it.
#
# It used to be an `if [ -z "$MACON_INSTALL_SOURCED" ]; then ... fi` wrapped
# around the same sixty lines. That shape is a guard only while its two halves
# stay paired: one unbalanced `fi` -- an edit, a bad merge, a deletion that
# spanned one -- closes it early and turns the privileged half into top-level
# code. The test suite sources this file to reach the pure functions above, so
# from that moment on, sourcing it installs macon for real. That is not a
# hypothetical; it happened, into /usr/local, on a machine where nobody had
# asked for an install.
install_main() {
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
    _allow_unsafe=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) _force=1; shift ;;
            --allow-unsafe-prefix) _allow_unsafe=1; shift ;;
            *)
                printf 'usage: sh install.sh [--force] [--allow-unsafe-prefix]\n' >&2
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

    # The helper runs as root for a whole night. A parent directory anyone else
    # can write to makes that a root shell available for the asking.
    _unsafe=$(install_unsafe_dirs "$MACON_PREFIX")
    if [ -n "$_unsafe" ] && [ "$_allow_unsafe" -eq 0 ]; then
        install_explain_unsafe_dirs "$_unsafe" "$MACON_PREFIX"
        exit 1
    fi
    if [ -n "$_unsafe" ]; then
        printf 'macon: --allow-unsafe-prefix given; installing under a prefix whose\n' >&2
        printf 'macon: parent directories are writable by someone other than root.\n' >&2
        printf 'macon: Anyone who can write there can replace the root helper.\n' >&2
    fi

    printf 'installing macon into %s (sudo may ask for your password)\n' "$MACON_PREFIX"
    sudo sh "$SRC_DIR/install.sh" --install-files "$MACON_PREFIX" || exit 1

    printf 'installed. registering the boot failsafe...\n'
    MACON_LIB="$MACON_PREFIX/libexec/macon/lib" \
        MACON_LIBEXEC="$MACON_PREFIX/libexec/macon" \
        "$MACON_PREFIX/bin/macon" failsafe install || exit 1

    # The failsafe is the only thing that holds the safety invariant across a
    # reboot -- so it is checked rather than assumed. The verb above cannot
    # report its own failure: the sudo tee inside it can fail with the pipeline
    # still exiting 0.
    _rc=0
    _unregistered=""
    _fs=$(MACON_LIB="$MACON_PREFIX/libexec/macon/lib" \
        MACON_LIBEXEC="$MACON_PREFIX/libexec/macon" \
        "$MACON_PREFIX/bin/macon" failsafe status 2>/dev/null) || _fs=""
    if ! install_failsafe_registered "$_fs"; then
        _rc=1
        _unregistered="the boot failsafe"
        printf 'macon: the boot failsafe did NOT register.\n' >&2
        printf 'macon: without it, a panic or power loss leaves this Mac unable\n' >&2
        printf 'macon: to sleep until someone runs macon off by hand.\n' >&2
        printf 'macon: retry with: macon failsafe install\n' >&2
    fi

    # After the failsafe, deliberately. The failsafe is what gives this Mac its
    # sleep back after a crash; the helper daemon only lets a session start. An
    # install interrupted between the two leaves the invariant held and no
    # session startable, which is the right way round.
    printf 'registering the session helper daemon...\n'
    # Kept, not discarded. The check below is the authority on whether launchd
    # has the job, and it is blind to exactly one combination: a registration
    # that failed over a label that was already loaded. `launchctl print` sees a
    # job either way, and only this status says the job it sees is the old one.
    _hd=0
    install_helper_daemon "$MACON_PREFIX" || _hd=$?
    # The result, not the attempt -- the same distinction the failsafe's check
    # makes, and for the same reason: the sudo tee inside a pipeline can fail
    # with the pipeline still exiting 0.
    #
    # The wording says only what is true in every mode this branch is reachable
    # in. The plist may have been written and rejected, or never written at all
    # -- launchd not having the job is the one fact common to both, and it is
    # the fact `macon on` refuses on. And the fix named is re-running the
    # installer: there is deliberately no `macon helper` verb to point at, so
    # the failsafe's "retry with:" line has no counterpart here.
    if ! launchctl print "system/$MACON_HELPER_LABEL" >/dev/null 2>&1; then
        _rc=1
        _unregistered="${_unregistered:+$_unregistered and }the helper daemon"
        printf 'macon: the helper daemon did NOT register.\n' >&2
        printf "macon: launchd has no job '%s', and 'macon on' refuses without\n" \
            "$MACON_HELPER_LABEL" >&2
        printf 'macon: it -- no session can start until it is registered.\n' >&2
        printf 'macon: re-run this installer to retry; the daemon belongs at\n' >&2
        printf 'macon: %s\n' "$MACON_HELPER_PLIST" >&2
    elif [ "$_hd" -ne 0 ]; then
        # Registered, and not by this install. Silence here would be the worst
        # of the three outcomes: the installer would report success and the job
        # launchd runs tonight would be the previous version of the helper.
        _rc=1
        _unregistered="${_unregistered:+$_unregistered and }the helper daemon"
        printf 'macon: registering the helper daemon failed (exited %s), but\n' "$_hd" >&2
        printf "macon: launchd still has a job called '%s'. That job is the\n" \
            "$MACON_HELPER_LABEL" >&2
        printf 'macon: PREVIOUS registration, not this one. Take it out and\n' >&2
        printf 'macon: re-run this installer:\n' >&2
        printf 'macon:   sudo launchctl bootout system/%s\n' "$MACON_HELPER_LABEL" >&2
    fi

    install_prefix_note "$MACON_PREFIX"
    install_path_note "$MACON_PREFIX" "$PATH"
    if [ "$_rc" -eq 0 ]; then
        printf '\nmacon is installed. Try: macon status\n'
    else
        # Named rather than generic: the two jobs fail for different reasons
        # and are retried by different commands, and a reader who is told only
        # "something did not register" has to go and find out which.
        printf '\nmacon is installed, but %s did not register.\n' "$_unregistered" >&2
    fi
    # Not `exit`: this is the last command of the last command of the file, so
    # its status is the script's status either way, and a function that can
    # return normally is one this file can be sourced past.
    return "$_rc"
}

# The whole decision, in four lines that cannot come apart.
#
# `return` outside a function returns from a file that is being SOURCED, and is
# an error in a file that is being EXECUTED -- bash 3.2, which is /bin/sh here,
# reports it on stderr (discarded here) and carries on to the next command. That
# is the guard: sourcing stops inside the case, execution falls out of it and
# into install_main.
#
# The name test is what makes the bail-out conditional, and it is honest on its
# own terms -- $0 is this file only when the shell was told to run this file.
# Nothing depends on it being right, though: executed under some other name, the
# `*` branch is taken, `return` fails because the file is being executed, and
# the install proceeds. The one shape that gets past both is a script that is
# itself named install.sh sourcing this one.
#
# Mangling any of it cannot produce a silent install. The worst it can do is
# stop the installer from running, which the tests that execute this file catch
# on their first assertion.
case "${0##*/}" in
    install.sh) ;;                 # executed: fall through to install_main
    *) return 0 2>/dev/null ;;     # sourced: stop here, define nothing more
esac

install_main "$@"
