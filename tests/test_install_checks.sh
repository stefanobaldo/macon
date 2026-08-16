#!/bin/sh
# The installer, exercised through the half that can be run safely.
#
# install.sh keeps everything that touches the machine in a function that only
# an executed run calls, so sourcing it here defines the functions and does
# nothing else. tests/test_source_inert.sh is the proof of that, and it is what
# this file leans on: nothing here may write outside its temporary prefix,
# register a LaunchDaemon, or reach for sudo -- a password prompt inside a test
# suite is a hang, not a failure.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state

# Inherited on purpose, and the reason install.sh honours an inherited value:
# sourcing does not change $0, so the script's own fallback resolves the source
# tree from the *test* file's directory -- tests/ -- and would install nothing.
# The same is true of the privileged half, which is why it re-enters install.sh
# as a script rather than sourcing it under sudo.
SRC_DIR=$REPO_DIR
export SRC_DIR
# shellcheck source=install.sh
. "$REPO_DIR/install.sh"

# --- the macOS floor --------------------------------------------------------

assert_ok "a supported major version passes" install_check_macos 26
assert_ok "the exact floor passes" install_check_macos 13
assert_fail "an older major version fails" install_check_macos 12
assert_fail "a Catalina-era version fails" install_check_macos 10
assert_fail "a non-numeric version fails" install_check_macos abc
assert_fail "an empty version fails" install_check_macos ""

# `[ -lt ]` in bash 3.2 exits 2 -- not false -- on an operand it cannot parse
# into intmax_t, so an absurd value makes the comparison fall through and the
# floor silently stops being a floor. Bounded, it is refused instead.
assert_fail "an absurdly long version fails instead of falling through" \
    install_check_macos 99999999999999999999

OUT=$(install_check_macos 12 2>&1) || :
assert_contains "$OUT" "13" "the refusal names the required version"

# --- the required binaries --------------------------------------------------

# Every required binary must exist on any supported machine.
assert_ok "the required binaries are present" install_check_binaries

# id is in the list because install_check_not_root is fed `id -u`, and an empty
# uid used to be allowed through. Proven by emptying PATH: command -v and printf
# are builtins, so the function still runs and reports everything as missing.
# Emptying the search path is the point of this one.
# shellcheck disable=SC2123,SC2030,SC2031
missing_binaries() ( PATH=/var/empty; install_check_binaries 2>&1 )
OUT=$(missing_binaries) || :
assert_contains "$OUT" " id" "id is one of the required binaries"
assert_contains "$OUT" " pmset" "and so are the ones the tool calls directly"
assert_fail "an empty PATH fails the binary check" missing_binaries

# --- refusing to run as root ------------------------------------------------
#
# The uid is a parameter so the refusal can be asserted by a suite that is not
# root. `macon failsafe install` renders a LaunchDaemon naming MACON_STATE from
# its OWN environment, so an installer running under sudo would name root's
# state directory instead of the user's -- and sudo has already stripped an
# exported MACON_STATE by then, so no amount of dropping back can recover it.
# Running the whole script as the user, and sudo'ing the steps that need root,
# is the only shape that keeps that value true.

assert_ok "an unprivileged install is allowed" install_check_not_root 501
assert_fail "running the installer as root is refused" install_check_not_root 0

# A safety check must fail closed. `[ "" -eq 0 ]` errors and exits 2 rather
# than returning false, so an unreadable uid used to reach `|| return 0` and be
# ALLOWED -- and an empty $(id -u) is what a sanitised PATH with no id on it
# produces.
assert_fail "an empty uid is refused, not allowed" install_check_not_root ""
assert_fail "a non-numeric uid is refused" install_check_not_root root
assert_fail "an absurdly long uid is refused" install_check_not_root 99999999999999999999
OUT=$(install_check_not_root "" 2>&1) || :
assert_contains "$OUT" "could not read" "and says why rather than erroring from test"

OUT=$(install_check_not_root 0 2>&1) || :
assert_contains "$OUT" "sudo" "the refusal explains that the script sudo's what it needs"
assert_contains "$OUT" "failsafe" "and says which step depends on the invoking user"

OUT=$(install_check_not_root 0 someone 2>&1) || :
assert_contains "$OUT" "sh install.sh" "under sudo it prints the command to re-run"

# --- SRC_DIR ----------------------------------------------------------------

OUT=$(SRC_DIR=/opt/elsewhere \
    sh -c '. "$1/install.sh"; printf "%s\n" "$SRC_DIR"' sh "$REPO_DIR")
assert_eq "/opt/elsewhere" "$OUT" "an inherited SRC_DIR survives sourcing"

# The single quotes are the point: $SRC_DIR is read in the child shell, after
# install.sh has run there.
# shellcheck disable=SC2016
OUT=$(env -u SRC_DIR \
    sh -c 'cd "$1" && . ./install.sh; printf "%s\n" "$SRC_DIR"' sh "$REPO_DIR")
assert_eq "$REPO_DIR" "$OUT" "and without one it falls back to the script's own directory"

# --- refusing to install over a live session --------------------------------
#
# install_files cp's over $PREFIX/libexec/macon/macon-helper while that helper
# may be running as root, and cp replaces the file in place: a shell reads its
# script lazily, so the running helper can take a syntax error or execute
# unintended bytes at its next read. It dies with the power settings applied and
# leaves an orphan nothing detects until the next macon invocation -- and
# "upgrade macon" is a documented, ordinary operation. This is the mirror of the
# guard uninstall.sh has had all along, and it carries the same three blockers.

assert_fail "an empty run directory holds no live helper" install_helper_alive

printf 'not-a-pid\n' > "$MACON_RUN/helper.pid"
assert_fail "a garbage pid file is not a live helper" install_helper_alive
printf '\n' > "$MACON_RUN/helper.pid"
assert_fail "an empty pid file is not a live helper" install_helper_alive
printf '2147483647\n' > "$MACON_RUN/helper.pid"
assert_fail "a pid that no longer exists does not block forever" install_helper_alive

# ps, not `kill -0`: the helper runs as root and the installer does not, so
# `kill -0` would answer EPERM -- a false negative on exactly this case.
printf '%s\n' "$$" > "$MACON_RUN/helper.pid"
assert_ok "a live pid in helper.pid is a live helper" install_helper_alive
assert_contains "$(install_blockers)" "session" "and it blocks the install"
OUT=$(install_explain_blockers "$(install_blockers)" 2>&1)
assert_contains "$OUT" "macon off" "the refusal points at the command that fixes it"
assert_contains "$OUT" "--force" "and names the override for someone who means it"
assert_contains "$OUT" "in place" "and says what the copy would do to the running helper"
rm -f "$MACON_RUN/helper.pid"

assert_fail "with nothing saved there is no snapshot to worry about" \
    install_snapshot_present
: > "$MACON_STATE/snapshot"
assert_ok "a snapshot on disk is detected" install_snapshot_present
assert_contains "$(install_blockers)" "snapshot" "and blocks the install"
rm -f "$MACON_STATE/snapshot"

# install.sh calls ioreg directly and by design -- it has to answer this with
# nothing installed yet -- so a PATH shim tests the real seam.
SHIM="$MACON_STATE/ioreg-shim"
mkdir -p "$SHIM"
# The subshell is deliberate: the shimmed PATH must not outlive the call, or
# every later assertion would run against the fake ioreg.
# shellcheck disable=SC2030,SC2031
sleep_disabled_via_shim() ( PATH="$SHIM:$PATH"; export PATH; install_sleep_disabled )
# shellcheck disable=SC2030,SC2031
blockers_via_shim() ( PATH="$SHIM:$PATH"; export PATH; install_blockers )
fake_ioreg() {
    printf '#!/bin/sh\n%s\n' "$1" > "$SHIM/ioreg"
    chmod 755 "$SHIM/ioreg"
}

fake_ioreg 'printf "    | {\n    |   \"SleepDisabled\" = Yes\n    | }\n"'
assert_ok "SleepDisabled = Yes is detected" sleep_disabled_via_shim
assert_contains "$(blockers_via_shim)" "sleep-disabled" \
    "and blocks the install on its own, with no session and no snapshot"
fake_ioreg 'printf "    | {\n    |   \"SleepDisabled\" = No\n    | }\n"'
assert_fail "SleepDisabled = No is not a blocker" sleep_disabled_via_shim
fake_ioreg 'exit 0'
assert_fail "a machine that reports nothing is not a blocker" sleep_disabled_via_shim
rm -f "$SHIM/ioreg"

# The refusal has to be WIRED IN, and the main block is the one part sourcing
# cannot reach -- so the script is run for real, with a PATH shim standing in
# for sudo. That shim is what makes this safe in both directions: a suite that
# actually asked for a password would hang rather than fail, so a regression
# that let the installer through is caught here instead of blocking on a prompt.
GUARD="$MACON_STATE/guard"
mkdir -p "$GUARD/shim" "$GUARD/run" "$GUARD/state" "$GUARD/prefix"
printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >> "%s"\nexit 97\n' \
    "$GUARD/sudo-calls" > "$GUARD/shim/sudo"
chmod 755 "$GUARD/shim/sudo"
printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$GUARD/state/snapshot"

# shellcheck disable=SC2030,SC2031
run_installer() (
    PATH="$GUARD/shim:$PATH"
    export PATH
    MACON_RUN="$GUARD/run" MACON_STATE="$GUARD/state" MACON_PREFIX="$GUARD/prefix" \
        SRC_DIR="$REPO_DIR" \
        sh "$REPO_DIR/install.sh" "$@" 2>&1
)

: > "$GUARD/sudo-calls"
_rc=0
OUT=$(run_installer) || _rc=$?
assert_eq "1" "$_rc" "the installer refuses over a machine that looks modified"
assert_contains "$OUT" "refusing to install" "and says so"
assert_eq "" "$(cat "$GUARD/sudo-calls")" "without asking for a password first"

# The prefix here is under a temporary directory this user owns, so it is also
# an unsafe prefix -- both overrides are needed to reach the install itself.
: > "$GUARD/sudo-calls"
OUT=$(run_installer --force --allow-unsafe-prefix) || :
assert_contains "$(cat "$GUARD/sudo-calls")" "--install-files" \
    "the overrides carry the install past both refusals"
assert_contains "$OUT" "--force given" "having said what it is overriding"

_rc=0
OUT=$(run_installer --wobble) || _rc=$?
assert_eq "1" "$_rc" "an unknown flag is refused rather than ignored"
assert_contains "$OUT" "usage:" "with the usage line"

# --- a prefix whose parents are not root's ----------------------------------
#
# The chown the privileged half does covers the macon tree. It cannot cover the
# directories ABOVE it, and that is where the boundary is: `macon on` starts
# $PREFIX/libexec/macon/macon-helper with `sudo nohup`, so anything that can
# write to a parent can swap that directory for its own and have its code run as
# root the next time the user types their password. On a Homebrew Intel Mac
# /usr/local is exactly that -- user-owned -- so this is the normal state of a
# real machine rather than a hypothetical.

assert_ok "a root-owned system directory is root-only" install_dir_is_root_only /usr
assert_ok "and so are the ones this install mirrors" install_dir_is_root_only /usr/libexec
assert_fail "a directory this user owns is not" install_dir_is_root_only "$MACON_STATE"
assert_ok "a directory that does not exist yet is not a finding" \
    install_dir_is_root_only "$MACON_STATE/never-created"

# The permission half, on its own: a root-owned directory that is group- or
# world-writable cannot be created by a suite that is not root, so the clause
# that catches one is asserted through the pure function. Group write is not a
# lesser case -- `admin` is every administrator account on a Mac, and a member
# of it can replace the helper without ever being root.
assert_ok "0755 is root-only" install_mode_is_root_only 755
assert_ok "and so is 0700" install_mode_is_root_only 700
assert_ok "and a sticky root-only directory" install_mode_is_root_only 1755
assert_fail "0775 is writable by the group" install_mode_is_root_only 775
assert_fail "0757 is writable by everyone" install_mode_is_root_only 757
assert_fail "and 0777 by both" install_mode_is_root_only 777
assert_fail "1777 too, sticky bit or not" install_mode_is_root_only 1777
assert_fail "an unreadable mode is refused rather than assumed" \
    install_mode_is_root_only ""
assert_fail "and so is one that is not octal at all" install_mode_is_root_only drwx

# Wired into the directory check, on a real root-owned directory that macOS
# itself leaves world-writable.
assert_ok "/Users/Shared is there to test against" test -d /Users/Shared
assert_fail "a root-owned but world-writable directory is not root-only" \
    install_dir_is_root_only /Users/Shared

UNSAFE=$(install_unsafe_dirs "$MACON_STATE/prefix-check")
assert_contains "$UNSAFE" "$MACON_STATE" \
    "a prefix under a user-owned directory reports the parent"
assert_eq "" "$(install_unsafe_dirs /usr)" \
    "a prefix whose whole chain belongs to root reports nothing"

OUT=$(install_explain_unsafe_dirs "$UNSAFE" "$MACON_STATE/prefix-check" 2>&1)
assert_contains "$OUT" "$MACON_STATE" "the refusal names the exact directory"
assert_contains "$OUT" "as ROOT" "and states what runs from there with privilege"
assert_contains "$OUT" "MACON_PREFIX=" "and offers a prefix only root owns"
assert_contains "$OUT" "--allow-unsafe-prefix" "and the override for someone who means it"
assert_contains "$OUT" "Homebrew" "and says why an Intel Mac lands here"

# Wired in, like the session guard: sourcing cannot reach the main block.
: > "$GUARD/sudo-calls"
rm -f "$GUARD/state/snapshot"
_rc=0
OUT=$(run_installer) || _rc=$?
assert_eq "1" "$_rc" "the installer refuses a prefix root does not own"
assert_contains "$OUT" "refusing to install" "and says so"
assert_eq "" "$(cat "$GUARD/sudo-calls")" "without asking for a password first"

: > "$GUARD/sudo-calls"
OUT=$(run_installer --allow-unsafe-prefix) || :
assert_contains "$(cat "$GUARD/sudo-calls")" "--install-files" \
    "--allow-unsafe-prefix carries the install past it"
assert_contains "$OUT" "--allow-unsafe-prefix given" \
    "having said what it is overriding"

# --- laying out a prefix ----------------------------------------------------

P="$MACON_STATE/prefix"
assert_ok "install_files succeeds into a temp prefix" install_files "$P"
assert_ok "the CLI is installed" test -x "$P/bin/macon"
assert_ok "the helper is installed" test -x "$P/libexec/macon/macon-helper"
assert_ok "the failsafe is installed" test -x "$P/libexec/macon/failsafe.sh"
assert_ok "the libraries are installed" test -f "$P/libexec/macon/lib/decide.sh"

assert_eq "755" "$(stat -f '%Lp' "$P/bin/macon")" "the CLI is executable"
assert_eq "755" "$(stat -f '%Lp' "$P/libexec/macon/macon-helper")" "so is the helper"
assert_eq "755" "$(stat -f '%Lp' "$P/libexec/macon/failsafe.sh")" "so is the failsafe"
assert_eq "644" "$(stat -f '%Lp' "$P/libexec/macon/lib/decide.sh")" \
    "the libraries are sourced, not executed"

# bin/macon sources EVERY library at startup, unconditionally. One missing file
# does not break one subcommand, it breaks all of them -- including `off`, the
# command that gives the Mac its ability to sleep back. So the installed set is
# compared against the source set rather than against a list written here,
# which a library added later would silently fall off.
src_libs=$(for f in "$REPO_DIR"/lib/*.sh; do basename "$f"; done | sort)
inst_libs=$(for f in "$P"/libexec/macon/lib/*.sh; do basename "$f"; done | sort)
assert_eq "$src_libs" "$inst_libs" "every lib/*.sh in the tree is installed"
assert_ok "including report.sh, which bin/macon sources like the rest" \
    test -f "$P/libexec/macon/lib/report.sh"

# The whole inventory, exactly. This is what keeps anything that is not a
# component -- integrations/, docs, tests, a stray template -- out of the
# prefix as the tree grows.
installed=$(cd "$P" && find . -type f | sed 's|^\./||' | sort)
expected=$( {
    printf 'bin/macon\n'
    printf 'libexec/macon/failsafe.sh\n'
    printf 'libexec/macon/macon-helper\n'
    for f in "$REPO_DIR"/lib/*.sh; do
        printf 'libexec/macon/lib/%s\n' "$(basename "$f")"
    done
} | sort)
assert_eq "$expected" "$installed" "the prefix holds exactly the components and nothing else"

prefix_mentions_integrations() {
    printf '%s\n' "$installed" | grep -q integrations
}
assert_fail "nothing from integrations/ is installed" prefix_mentions_integrations

# Nothing is written into share/ yet, and an empty directory in /usr/local is
# litter the uninstaller would have to know about.
assert_fail "no empty share directory is created" test -d "$P/share"

# The installed CLI must resolve its libraries from the prefix, not the repo.
OUT=$(MACON_LIB="$P/libexec/macon/lib" MACON_LIBEXEC="$P/libexec/macon" \
    "$P/bin/macon" version)
assert_contains "$OUT" "macon " "the installed CLI reports its version"

# Re-running the installer over an existing install is the upgrade path.
assert_ok "installing over an existing prefix succeeds" install_files "$P"
assert_eq "$expected" "$(cd "$P" && find . -type f | sed 's|^\./||' | sort)" \
    "and leaves the same inventory behind"

# --- awkward prefixes -------------------------------------------------------

PS="$MACON_STATE/pre fix"
assert_ok "a prefix containing a space installs cleanly" install_files "$PS"
OUT=$(MACON_LIB="$PS/libexec/macon/lib" MACON_LIBEXEC="$PS/libexec/macon" \
    "$PS/bin/macon" version)
assert_contains "$OUT" "macon " "and the CLI installed there runs"

# The prefix reaches `rm -rf` in uninstall.sh and `mkdir -p` here. A relative
# one would resolve against whatever directory the script happens to be in.
assert_fail "a relative prefix is refused" install_files "relative/prefix"

# --- a source tree with nothing in it ---------------------------------------

assert_ok "the repository is recognised as a source tree" \
    install_check_source "$REPO_DIR"
mkdir -p "$MACON_STATE/empty-src"
assert_fail "an empty directory is not, and is refused before the sudo prompt" \
    install_check_source "$MACON_STATE/empty-src"

install_from_empty_src() (
    SRC_DIR="$MACON_STATE/empty-src"
    mkdir -p "$SRC_DIR"
    install_files "$MACON_STATE/prefix-from-empty" 2>/dev/null
)
assert_fail "installing from a tree with no components fails" install_from_empty_src

# --- the note for a non-default prefix --------------------------------------
#
# The installed CLI hard-defaults MACON_LIB and MACON_LIBEXEC to /usr/local.
# Installed anywhere else it is a CLI that cannot find its own libraries, and
# the failure arrives at the next invocation rather than here.

assert_eq "" "$(install_prefix_note /usr/local)" "the default prefix needs no note"
OUT=$(install_prefix_note /opt/macon)
assert_contains "$OUT" "MACON_LIB" "a non-default prefix names MACON_LIB"
assert_contains "$OUT" "MACON_LIBEXEC" "and MACON_LIBEXEC"
assert_contains "$OUT" "/opt/macon/libexec/macon/lib" "with the value to give it"

# And says what those exports do NOT buy. Verified on this platform: sudo's
# env_reset drops MACON_LIB before the root helper reads it, so `macon on`
# under a non-default prefix cannot arm. A note that stopped at "export these
# two" would be a reassurance rather than an instruction.
assert_contains "$OUT" "sudo" "and names what still will not work"
assert_contains "$OUT" "failsafe" "while saying the boot failsafe is unaffected"

# --- the failsafe registered, or it did not ---------------------------------
#
# `macon failsafe install` exits 0 even when the sudo tee inside it failed, so
# the installer checks the status afterwards instead of believing it.

assert_ok "an installed failsafe reads as registered" \
    install_failsafe_registered "installed: /Library/LaunchDaemons/local.macon.failsafe.plist"
assert_fail "an absent one does not" install_failsafe_registered "absent"
assert_fail "and neither does no output at all" install_failsafe_registered ""
assert_fail "nor a line that merely mentions installing" \
    install_failsafe_registered "not installed"

assert_eq "" "$(install_path_note /usr/local "/bin:/usr/local/bin:/usr/bin")" \
    "a prefix already on PATH needs no note"
OUT=$(install_path_note /opt/macon "/bin:/usr/bin")
assert_contains "$OUT" "/opt/macon/bin" "a prefix off PATH is pointed out"

teardown_state
