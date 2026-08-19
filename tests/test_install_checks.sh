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

# And `ioreg`, because install.sh reads the IORegistry DIRECTLY -- it has to
# answer "is this Mac holding a session" with nothing installed yet, so it
# cannot go through lib/platform.sh and the suite's fake cannot reach it.
#
# Without this stub the cases below depend on whether the machine running them
# happens to have a macon session armed: a real `SleepDisabled = Yes` trips the
# installer's session guard, every run_installer refuses for a reason the case
# is not about, and the assertions fail. It never showed on CI, which has no
# session, and it showed the first time the suite was run on a maintainer's
# machine mid-session. The stub reports the machine these cases describe -- not
# armed -- and $SLEEP_DISABLED_STUB flips it for the ones that want the other
# answer.
SLEEP_DISABLED_STUB="$GUARD/sleep-disabled"
printf 'no\n' > "$SLEEP_DISABLED_STUB"
cat > "$GUARD/shim/ioreg" <<STUB
#!/bin/sh
if [ "\$(cat "$SLEEP_DISABLED_STUB")" = yes ]; then
    printf '  |   "SleepDisabled" = Yes\n'
fi
exit 0
STUB
chmod 755 "$GUARD/shim/ioreg"

# Proved in BOTH directions before anything is read through it. A stub that
# answers "not armed" by never printing anything passes these cases for the
# wrong reason and would go on passing if it were broken -- which the first
# version of it was.
#
# The subshell is deliberate, for the same reason it is above: the shimmed PATH
# must not outlive the call.
# shellcheck disable=SC2030,SC2031
guard_sleep_disabled() ( PATH="$GUARD/shim:$PATH"; export PATH; install_sleep_disabled )

assert_fail "the guard's ioreg stub reports a machine that is not armed" \
    guard_sleep_disabled
printf 'yes\n' > "$SLEEP_DISABLED_STUB"
assert_ok "and reports an armed one when told to" guard_sleep_disabled
printf 'no\n' > "$SLEEP_DISABLED_STUB"

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
# directories ABOVE it, and that is where the boundary is: the installer
# registers a permanently loaded LaunchDaemon running
# $PREFIX/libexec/macon/macon-helper as root, so anything that can write to a
# parent can swap that directory for its own and then start its code as root
# with `launchctl kickstart` -- no password, and nothing the user has to do. On
# a Homebrew Intel Mac /usr/local is exactly that -- user-owned -- so this is
# the normal state of a real machine rather than a hypothetical.

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
# The mechanism, not a generic scare. A user reading "the next time you type
# your password" would conclude that not running `macon on` keeps them safe;
# the loaded daemon means it does not, and the refusal has to say so.
assert_contains "$OUT" "launchctl kickstart" \
    "and names how that code gets to run: launchd, on demand"
assert_contains "$OUT" "no password" \
    "and that nothing gates it -- the warning no longer rests on a sudo prompt"
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

# And says where those exports are needed and where they are not. Both facts
# are read off bin/macon: `macon on` restates the two paths through
# /usr/bin/env on the far side of sudo -- which is what defeats env_reset --
# and both LaunchDaemons name them in EnvironmentVariables. A non-default
# prefix therefore arms a session like any other, and the one thing the user
# has to get right is that the exports outlive the shell they typed them in.
assert_contains "$OUT" "profile" "and says the exports must outlive one terminal"
assert_contains "$OUT" "macon off" "naming the command that suffers if they do not"
assert_contains "$OUT" "failsafe" "while saying what carries the paths on its own"

# The claim that must not come back. It deterred a valid install for as long as
# it stood, and the code it described has restated both paths across sudo since
# before this note was written.
case "$OUT" in
    *"refuses to arm"* | *"only /usr/local"*)
        assert_eq "supported" "refused" \
            "the note must not claim a non-default prefix cannot start a session" ;;
    *)
        assert_eq "supported" "supported" \
            "the note does not claim a non-default prefix cannot start a session" ;;
esac

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

# --- the helper daemon is part of an install --------------------------------
#
# A macon installed without it is a macon whose `on` refuses every time, so this
# is not an optional extra the installer may skip on a bad day.

assert_contains "$(cat "$REPO_DIR/install.sh")" "local.macon.helper" \
    "install.sh knows the helper daemon's label"

# Ordering, as a source-level claim rather than a behavioural one: registering a
# job whose ProgramArguments are not on disk yet gives launchd ten seconds of
# crash loop per attempt, and the installer has no way to notice.
#
# Both line numbers are CALL SITES, deliberately. An earlier version of this
# compared the constant's definition against the cp inside install_files, which
# measured where two pieces of text sit rather than what the installer does:
# moving the registration above the re-entry that copies the components left it
# green. These two lines are the ordering constraint itself -- the re-entry that
# puts the components on disk, and the call that registers a job pointing at
# them.
COPY_AT=$(grep -n 'install.sh" --install-files' "$REPO_DIR/install.sh" |
    head -1 | cut -d: -f1)
# The $ is part of the pattern, not an expansion: it is what tells the call site
# apart from the definition a few lines above it.
# shellcheck disable=SC2016
REG_AT=$(grep -n 'install_helper_daemon "\$MACON_PREFIX"' "$REPO_DIR/install.sh" |
    head -1 | cut -d: -f1)
assert_ok "the components are copied before the daemon is registered" \
    test "$COPY_AT" -lt "$REG_AT"

# bootstrap over an already-loaded label fails with EIO (verified), so an
# upgrade must unload first or it silently keeps the old registration.
assert_contains "$(cat "$REPO_DIR/install.sh")" "bootout" \
    "an upgrade unloads the existing job before registering the new one"

# --- the two copies of the daemon's identity agree --------------------------
#
# install.sh cannot source bin/macon, so both files carry the same two defaults.
# Drift between them is invisible and expensive: install.sh would bootstrap one
# label while the check that follows asks launchd about another, and a perfectly
# good install would report itself failed. The plist path is pinned for the same
# reason -- `macon off` boots the job out through the CLI's copy of it.
helper_default() {
    sed -n "s/^$2=\${$2:-\(.*\)}$/\1/p" "$1" | head -1
}
CLI_LABEL=$(helper_default "$REPO_DIR/bin/macon" MACON_HELPER_LABEL)
CLI_PLIST=$(helper_default "$REPO_DIR/bin/macon" MACON_HELPER_PLIST)
# Read before compared: two defaults that both failed to parse would be equal,
# and this whole section would pass by measuring nothing.
assert_eq "local.macon.helper" "$CLI_LABEL" "the CLI's default label parses"
assert_contains "$CLI_PLIST" "/Library/LaunchDaemons/" \
    "and so does its default plist path"
assert_eq "$CLI_LABEL" "$(helper_default "$REPO_DIR/install.sh" MACON_HELPER_LABEL)" \
    "install.sh registers the label the CLI asks launchd about"
assert_eq "$CLI_PLIST" "$(helper_default "$REPO_DIR/install.sh" MACON_HELPER_PLIST)" \
    "and writes the plist where the CLI expects it"

# --- what install_helper_daemon actually runs -------------------------------
#
# The assertions above are claims about the source. This one runs the function,
# behind a PATH shim in front of sudo and launchctl -- the same technique
# tests/test_source_inert.sh uses, with one difference that matters: those shims
# REFUSE, and these must succeed, or the function returns at its first sudo and
# never reaches the bootstrap whose ordering is the point.
#
# Nothing real is touched. Every privileged step goes through sudo, and sudo is
# a stub that records its arguments and returns 0 without executing them, so no
# tee, chown, chmod or launchctl reaches the machine.

HW="$MACON_STATE/helper-daemon"
HSHIM="$HW/shim"
HCALLS="$HW/calls"
mkdir -p "$HSHIM" "$HW/prefix/bin"
: > "$HCALLS"
for _c in sudo launchctl; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' \
        "$_c" "$HCALLS" > "$HSHIM/$_c"
    chmod 755 "$HSHIM/$_c"
done

# sudo again, this time able to fail one call. Every privileged step runs
# through it, so a stub that can only ever return 0 leaves the status handling
# below with nothing to handle. TEST_BOOTOUT_RC is read at run time and
# defaults to 0, so the successful run above is unchanged by it.
cat > "$HSHIM/sudo" <<SHIM
#!/bin/sh
printf 'sudo %s\n' "\$*" >> "$HCALLS"
case "\$*" in
    *bootout*) exit "\${TEST_BOOTOUT_RC:-0}" ;;
esac
exit 0
SHIM
chmod 755 "$HSHIM/sudo"

# The prefix's CLI, standing in for the one an install has just copied there.
# install_helper_daemon calls it by absolute path, so nothing here depends on
# the shimmed PATH.
#
# It emits a real plist, not a marker, because install_helper_daemon runs
# `plutil -lint` over what it rendered -- and plutil is not shimmed, so this
# fixture is checked by the same tool the installer trusts. The verb it was
# called with goes in as a string value, so the evidence survives inside a
# document that parses.
cat > "$HW/prefix/bin/macon" <<'STUB'
#!/bin/sh
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Verb</key><string>$1</string>
</dict>
</plist>
PLIST
STUB
chmod 755 "$HW/prefix/bin/macon"

# The shimmed PATH stays inside the subshell, here and in the positive control
# below: escaping it would leave the rest of this file -- and teardown_state --
# running against fakes.
# shellcheck disable=SC2030,SC2031
run_shimmed() ( PATH="$HSHIM:$PATH"; export PATH; "$@" )

# shellcheck disable=SC2030,SC2031
run_helper_daemon() (
    PATH="$HSHIM:$PATH"
    export PATH
    MACON_HELPER_PLIST="$HW/local.macon.test.plist"
    MACON_HELPER_LABEL=local.macon.test
    install_helper_daemon "$HW/prefix"
)

# The recorder is proved to record before anything is read out of it: a shim
# directory that was never reached would otherwise make the greps below fail for
# a reason that has nothing to do with install_helper_daemon.
assert_ok "the shim accepts a privileged command" run_shimmed sudo -n true
assert_contains "$(cat "$HCALLS")" "sudo -n true" "and records it"
: > "$HCALLS"

assert_ok "install_helper_daemon runs to the end" run_helper_daemon
CALLED=$(cat "$HCALLS")
assert_contains "$CALLED" "bootout system/local.macon.test" \
    "it boots the label out before registering it"
# The path, not the file: the sudo shim records its arguments and writes
# nothing, so there is no plist on disk here to have been written. What this
# pins is that the job is bootstrapped from MACON_HELPER_PLIST -- the same path
# the CLI's daemon checks look at.
assert_contains "$CALLED" "bootstrap system $HW/local.macon.test.plist" \
    "and bootstraps the plist path it installs to"
# The order is the assertion, not the presence: bootstrap over a label launchd
# already has fails with EIO (verified), so a bootout that ran afterwards -- or
# not at all -- leaves an upgrade running the old registration.
BOOTOUT_AT=$(printf '%s\n' "$CALLED" | grep -n 'bootout' | head -1 | cut -d: -f1)
BOOTSTRAP_AT=$(printf '%s\n' "$CALLED" | grep -n 'bootstrap' | head -1 | cut -d: -f1)
assert_ok "the bootout comes first, which is what makes an upgrade take" \
    test "$BOOTOUT_AT" -lt "$BOOTSTRAP_AT"

# --- a bootout that booted nothing out --------------------------------------
#
# `|| :` on that bootout swallowed every status it could return. Two of them
# are ordinary -- 0, booted out, and 3, ESRCH, the label was not loaded, which
# is every first install -- and any other means the OLD job may still be there.
# The installer's own `launchctl print` check cannot tell the difference: it
# sees a registered job either way. This function is the only place the number
# exists.

: > "$HCALLS"
TEST_BOOTOUT_RC=3
export TEST_BOOTOUT_RC
OUT=$(run_helper_daemon 2>&1)
case "$OUT" in
    *"could not unload"*)
        assert_eq "quiet" "warned" \
            "ESRCH is a first install and must not be reported as a problem" ;;
    *)
        assert_eq "quiet" "quiet" \
            "a label launchd never had is not a finding" ;;
esac

: > "$HCALLS"
TEST_BOOTOUT_RC=5
OUT=$(run_helper_daemon 2>&1)
assert_contains "$OUT" "could not unload" \
    "any other status is reported instead of swallowed"
assert_contains "$OUT" "5" "naming the status launchctl actually returned"
assert_contains "$(cat "$HCALLS")" "bootstrap system" \
    "and the registration is still attempted -- this warns, it does not abort"
unset TEST_BOOTOUT_RC

# --- a render that produced no plist ----------------------------------------
#
# The old form piped the CLI into `sudo tee`, and a pipeline reports its LAST
# command: a CLI that died still left the whole thing exiting 0 over an EMPTY
# root-owned plist. chown and chmod succeed on it, bootstrap rejects it, and
# what stays behind is a file launchd fails to parse at every boot until
# someone reinstalls.
#
# These replace the prefix CLI, so they come after every assertion that needs a
# working one.

: > "$HCALLS"
printf '#!/bin/sh\nexit 1\n' > "$HW/prefix/bin/macon"
chmod 755 "$HW/prefix/bin/macon"
assert_fail "a CLI that cannot render the plist fails the registration" \
    run_helper_daemon
assert_fail "and nothing is installed at the plist path" \
    grep -q "local.macon.test.plist" "$HCALLS"
assert_fail "and no job is bootstrapped over it" grep -q bootstrap "$HCALLS"

# The half a pipeline cannot see at all: exit 0 with nothing on stdout.
: > "$HCALLS"
printf '#!/bin/sh\nexit 0\n' > "$HW/prefix/bin/macon"
chmod 755 "$HW/prefix/bin/macon"
assert_fail "an empty render fails the registration too" run_helper_daemon
assert_fail "and installs nothing either" \
    grep -q "local.macon.test.plist" "$HCALLS"

# And the case a non-empty test cannot see: exit 0 having written HALF a plist.
# It is the likelier of the two failures, because the renderer emits the
# envelope before the keys -- a CLI killed partway through leaves a document
# that opens and never closes. launchd's answer to a plist it cannot parse is
# to not run the job, silently, at every boot.
: > "$HCALLS"
printf '#!/bin/sh\nprintf "<?xml version=\\"1.0\\"?>\\n<plist version=\\"1.0\\">\\n<dict>\\n"\n' \
    > "$HW/prefix/bin/macon"
chmod 755 "$HW/prefix/bin/macon"
assert_fail "a truncated render fails the registration" run_helper_daemon
assert_fail "and no truncated plist reaches the install path" \
    grep -q "local.macon.test.plist" "$HCALLS"
assert_fail "and no job is bootstrapped over one" grep -q bootstrap "$HCALLS"

teardown_state
