#!/bin/sh
# The installer, exercised through the half that can be run safely.
#
# install.sh guards everything that touches the machine behind
# MACON_INSTALL_SOURCED, so sourcing it here defines the functions and does
# nothing else. Nothing in this file may write outside its temporary prefix,
# register a LaunchDaemon, or reach for sudo -- a password prompt inside a test
# suite is a hang, not a failure.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state

MACON_INSTALL_SOURCED=1
export MACON_INSTALL_SOURCED

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

OUT=$(install_check_not_root 0 2>&1) || :
assert_contains "$OUT" "sudo" "the refusal explains that the script sudo's what it needs"
assert_contains "$OUT" "failsafe" "and says which step depends on the invoking user"

OUT=$(install_check_not_root 0 someone 2>&1) || :
assert_contains "$OUT" "sh install.sh" "under sudo it prints the command to re-run"

# --- SRC_DIR ----------------------------------------------------------------

OUT=$(MACON_INSTALL_SOURCED=1 SRC_DIR=/opt/elsewhere \
    sh -c '. "$1/install.sh"; printf "%s\n" "$SRC_DIR"' sh "$REPO_DIR")
assert_eq "/opt/elsewhere" "$OUT" "an inherited SRC_DIR survives sourcing"

# The single quotes are the point: $SRC_DIR is read in the child shell, after
# install.sh has run there.
# shellcheck disable=SC2016
OUT=$(env -u SRC_DIR MACON_INSTALL_SOURCED=1 \
    sh -c 'cd "$1" && . ./install.sh; printf "%s\n" "$SRC_DIR"' sh "$REPO_DIR")
assert_eq "$REPO_DIR" "$OUT" "and without one it falls back to the script's own directory"

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

assert_eq "" "$(install_path_note /usr/local "/bin:/usr/local/bin:/usr/bin")" \
    "a prefix already on PATH needs no note"
OUT=$(install_path_note /opt/macon "/bin:/usr/bin")
assert_contains "$OUT" "/opt/macon/bin" "a prefix off PATH is pointed out"

teardown_state
