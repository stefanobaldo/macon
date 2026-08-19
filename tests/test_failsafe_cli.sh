#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
MACON_CLI_SOURCED=1
export MACON_CLI_SOURCED
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=tests/fake-platform.sh
. "$TESTS_DIR/fake-platform.sh"
# shellcheck source=lib/decide.sh
. "$MACON_LIB/decide.sh"
# shellcheck source=lib/session.sh
. "$MACON_LIB/session.sh"
# shellcheck source=lib/snapshot.sh
. "$MACON_LIB/snapshot.sh"
# shellcheck source=lib/records.sh
. "$MACON_LIB/records.sh"
# shellcheck source=bin/macon
. "$REPO_DIR/bin/macon"

MACON_FS_PLIST="$MACON_STATE/local.macon.failsafe.plist"

# --- the rendered plist -----------------------------------------------------

OUT=$(cli_failsafe_plist /usr/local/libexec/macon/failsafe.sh)
assert_contains "$OUT" "local.macon.failsafe" "the plist carries the expected label"
assert_contains "$OUT" "<key>RunAtLoad</key>" "the plist runs at load"
assert_contains "$OUT" "/usr/local/libexec/macon/failsafe.sh" "the plist points at the program"
assert_contains "$OUT" "<?xml version" "the plist is well-formed XML"

# Well-formed to macOS itself, not merely to a substring match: launchd refuses
# a plist it cannot parse, and a failsafe that never loads is a failsafe that
# does not exist.
printf '%s\n' "$OUT" > "$MACON_STATE/test.plist"
assert_ok "plutil accepts the generated plist" plutil -lint "$MACON_STATE/test.plist"

# --- the state directory ----------------------------------------------------
#
# launchd starts a system daemon with NO user context, so a $HOME-relative
# default resolves to a path that holds no snapshot. The failsafe can find one
# on its own -- but that search is a heuristic (most recently written wins) and
# on a multi-user Mac a heuristic is a guess. Naming the directory here is what
# makes the boot restore deterministic and leaves discovery as the safety net
# it was meant to be.

OUT=$(cli_failsafe_plist /usr/local/libexec/macon/failsafe.sh "/Users/someone/.local/state/macon")
assert_contains "$OUT" "<key>EnvironmentVariables</key>" \
    "the plist carries an environment when a state directory is given"
assert_contains "$OUT" "<key>MACON_STATE</key>" "and names MACON_STATE"
assert_contains "$OUT" "/Users/someone/.local/state/macon" "and the directory to look in"
printf '%s\n' "$OUT" > "$MACON_STATE/test2.plist"
assert_ok "plutil accepts it with the environment too" plutil -lint "$MACON_STATE/test2.plist"
assert_eq "/Users/someone/.local/state/macon" \
    "$(plutil -extract EnvironmentVariables.MACON_STATE raw -o - "$MACON_STATE/test2.plist")" \
    "and macOS reads back exactly the directory that was given"

# --- the library paths -----------------------------------------------------
#
# libexec/failsafe.sh defaults MACON_LIB to /usr/local and sources four
# libraries from it before it reaches its first log line. A daemon inherits no
# environment at all, so under any other prefix an unnamed MACON_LIB is a boot
# job that dies before it logs anything -- while the plist file it was started
# from is still on disk, which is the only thing `macon status` and
# cli_preflight look at. The machine reports itself protected and is not.

OUT=$(cli_failsafe_plist /opt/macon/libexec/macon/failsafe.sh \
    "/Users/someone/.local/state/macon" \
    /opt/macon/libexec/macon/lib /opt/macon/libexec/macon)
printf '%s\n' "$OUT" > "$MACON_STATE/test5.plist"
assert_ok "a plist naming all three paths parses" plutil -lint "$MACON_STATE/test5.plist"
assert_eq "/opt/macon/libexec/macon/lib" \
    "$(plutil -extract EnvironmentVariables.MACON_LIB raw -o - "$MACON_STATE/test5.plist")" \
    "and macOS reads MACON_LIB back as the library directory it was given"
assert_eq "/opt/macon/libexec/macon" \
    "$(plutil -extract EnvironmentVariables.MACON_LIBEXEC raw -o - "$MACON_STATE/test5.plist")" \
    "and MACON_LIBEXEC alongside it"
assert_eq "/Users/someone/.local/state/macon" \
    "$(plutil -extract EnvironmentVariables.MACON_STATE raw -o - "$MACON_STATE/test5.plist")" \
    "without displacing MACON_STATE"

# Escaping is per value, not per document.
OUT=$(cli_failsafe_plist /opt/failsafe.sh "/s&d" "/l<i>b" "/x&y")
printf '%s\n' "$OUT" > "$MACON_STATE/test6.plist"
assert_ok "library paths carrying XML metacharacters still parse" \
    plutil -lint "$MACON_STATE/test6.plist"
assert_eq "/l<i>b" \
    "$(plutil -extract EnvironmentVariables.MACON_LIB raw -o - "$MACON_STATE/test6.plist")" \
    "and MACON_LIB reads back as the path it was"
assert_eq "/x&y" \
    "$(plutil -extract EnvironmentVariables.MACON_LIBEXEC raw -o - "$MACON_STATE/test6.plist")" \
    "and so does MACON_LIBEXEC"

OUT=$(cli_failsafe_plist /usr/local/libexec/macon/failsafe.sh)
case "$OUT" in
    *EnvironmentVariables*)
        assert_eq "absent" "present" "no environment is written when no directory is given" ;;
    *)
        assert_eq "absent" "absent" "no environment is written when no directory is given" ;;
esac

# A path is not markup. An unescaped & or < makes the file unparseable, and
# launchd's answer to that is to not run the failsafe at all.
OUT=$(cli_failsafe_plist "/opt/a&b/failsafe.sh" "/Users/a<b>&c/.local/state/macon")
printf '%s\n' "$OUT" > "$MACON_STATE/test3.plist"
assert_ok "a path carrying XML metacharacters still parses" \
    plutil -lint "$MACON_STATE/test3.plist"
assert_eq "/Users/a<b>&c/.local/state/macon" \
    "$(plutil -extract EnvironmentVariables.MACON_STATE raw -o - "$MACON_STATE/test3.plist")" \
    "and reads back as the path it was, not as the escapes it was written with"
assert_eq "/opt/a&b/failsafe.sh" \
    "$(plutil -extract ProgramArguments.0 raw -o - "$MACON_STATE/test3.plist")" \
    "the program path survives escaping too"

# What `failsafe install` would write. Asserted through the same function the
# verb pipes into sudo, because the verb itself registers a boot-time root
# daemon and cannot be run here: without this, a plist installed with no
# environment at all would look exactly as green.
MACON_LIBEXEC=/opt/macon-libexec
MACON_LIB=/opt/macon-libexec/lib
OUT=$(cli_failsafe_plist_for_install)
assert_contains "$OUT" "/opt/macon-libexec/failsafe.sh" \
    "installing points the job at the installed failsafe"
assert_contains "$OUT" "$MACON_STATE" \
    "and names the state directory of the user installing it"
printf '%s\n' "$OUT" > "$MACON_STATE/test4.plist"
assert_ok "and produces a plist macOS will parse" plutil -lint "$MACON_STATE/test4.plist"

# The whole point of the three values: a prefix that is not /usr/local. The
# job must carry the libraries THIS CLI is running from, because that is what
# install.sh put on the machine.
assert_eq "$MACON_STATE" \
    "$(plutil -extract EnvironmentVariables.MACON_STATE raw -o - "$MACON_STATE/test4.plist")" \
    "and macOS reads the state directory back"
assert_eq "/opt/macon-libexec/lib" \
    "$(plutil -extract EnvironmentVariables.MACON_LIB raw -o - "$MACON_STATE/test4.plist")" \
    "and the library directory the failsafe will have to source from"
assert_eq "/opt/macon-libexec" \
    "$(plutil -extract EnvironmentVariables.MACON_LIBEXEC raw -o - "$MACON_STATE/test4.plist")" \
    "and the libexec directory it was installed into"

# --- status -----------------------------------------------------------------

rm -f "$MACON_FS_PLIST"
fake_set "launchd_$MACON_FS_LABEL" ""
OUT=$(cli_cmd_failsafe status); RC=$?
assert_contains "$OUT" "absent" "status reports an uninstalled failsafe"
assert_eq "1" "$RC" "and reports it as a failure"

: > "$MACON_FS_PLIST"
fake_set "launchd_$MACON_FS_LABEL" "not running"
OUT=$(cli_cmd_failsafe status); RC=$?
assert_contains "$OUT" "installed" "status reports an installed failsafe"
assert_contains "$OUT" "$MACON_FS_PLIST" "and names the file"
assert_eq "0" "$RC" "and exits zero for the one healthy state"

# The state this check exists for, and the one the file test could not see: the
# plist is present, parses, and launchd has never been told about it. It used to
# be reported as a healthy install, which is what let a machine believe it had a
# boot restore it did not have.
fake_set "launchd_$MACON_FS_LABEL" ""
OUT=$(cli_cmd_failsafe status); RC=$?
assert_contains "$OUT" "NOT LOADED" "a plist launchd has not loaded is not 'installed'"
assert_eq "1" "$RC" "and it is a failure rather than a variant of success"
# install.sh decides with `case $out in installed*)`, so the wording is load
# bearing: this state must not start with the word the installer accepts.
assert_fail "the installer's own test does not accept it" \
    sh -c "case \"$OUT\" in installed*) exit 0 ;; esac; exit 1"

fake_set "launchd_$MACON_FS_LABEL" "not running"
# The verb defaults to the one that changes nothing.
OUT=$(cli_cmd_failsafe)
assert_contains "$OUT" "installed" "no verb means status"

# An unknown verb must not fall through to install: these verbs load and unload
# a boot-time root daemon.
try_failsafe() {
    ( cli_cmd_failsafe "$@" )
}
assert_fail "an unknown verb is refused" try_failsafe wobble
assert_fail "and so is one that merely looks like install" try_failsafe INSTALL

# --- remove ------------------------------------------------------------------
#
# `macon failsafe remove` strips off the machine the only component that holds
# the invariant across a reboot. cli_preflight refuses to ARM a session without
# it and uninstall.sh refuses to remove macon while a session holds -- but the
# verb that performs exactly that removal used to check nothing. Run mid-session,
# a panic at 03:00 reboots into disablesleep with nothing left to clear it.
#
# `sudo` is a shell function here, so the verb can be driven to the end without
# a password prompt -- which inside a suite is a hang rather than a failure. It
# records what it was asked to run and does nothing, which is also how "the
# refusal never reached the removal" is asserted.
SUDO_LOG="$MACON_STATE/sudo"
#
# `rm` is the one command run for real. The verb no longer trusts rm's exit
# status -- which is 0 for a file it did not remove -- and re-checks that the
# plist is gone, so a shim that only recorded would make the success path
# unreachable and every removal look like a failure. The launchctl calls stay
# inert, which is the part that needs a password.
# shellcheck disable=SC2317,SC2329
#
# SUDO_RM_INERT makes the removal record itself and change nothing, which is
# what a `sudo rm` that failed looks like from the caller: rm exits 0 for a file
# it did not remove, so that case is indistinguishable by status alone.
SUDO_RM_INERT=0
# shellcheck disable=SC2317,SC2329
sudo() {
    printf '%s\n' "$*" >> "$SUDO_LOG"
    case "${1:-}" in
        rm)
            if [ "$SUDO_RM_INERT" -eq 0 ]; then
                shift
                rm "$@"
            fi
            ;;
    esac
}

quiet_remove() {
    : > "$SUDO_LOG"
    ( cli_cmd_failsafe remove "$@" ) >/dev/null 2>&1
}

# A clean machine: no session, sleep enabled, nothing saved.
clear_blockers() {
    rm -f "$(sess_pid_path)" "$(snap_path)"
    fake_set sleep_disabled no
    mkdir -p "$(sess_run_dir)"
}

clear_blockers
assert_eq "" "$(cli_failsafe_blockers)" "an idle machine blocks nothing"
assert_ok "and the failsafe can be removed" quiet_remove
assert_contains "$(cat "$SUDO_LOG")" "rm -f $MACON_FS_PLIST" \
    "the removal reaches the plist"

# A snapshot on disk means the machine still holds values macon changed.
clear_blockers
printf 'sleep=1\ndisksleep=10\npowernap=1\n' > "$(snap_path)"
assert_contains "$(cli_failsafe_blockers)" "snapshot" "a stored snapshot is a blocker"
assert_fail "and the removal is refused" quiet_remove
assert_eq "" "$(cat "$SUDO_LOG")" "the refusal never reached launchctl or rm"

# Clamshell sleep still disabled is the blocker that catches a modified machine
# whose snapshot has already gone.
clear_blockers
fake_set sleep_disabled yes
assert_contains "$(cli_failsafe_blockers)" "sleep-disabled" \
    "a machine that cannot sleep is a blocker"
assert_fail "and the removal is refused" quiet_remove

# A live helper is a live session.
clear_blockers
printf '4242\n' > "$(sess_pid_path)"
fake_set proc_4242 '/usr/local/libexec/macon/macon-helper start /var/run/macon/session.conf'
assert_contains "$(cli_failsafe_blockers)" "session" "a live helper is a blocker"
assert_fail "and the removal is refused" quiet_remove
assert_eq "" "$(cat "$SUDO_LOG")" "still without touching the plist"

# The refusal has to be actionable: it names what it found and the way out.
OUT=$( ( cli_cmd_failsafe remove ) 2>&1 )
assert_contains "$OUT" "macon off" "the refusal points at the command that fixes it"
assert_contains "$OUT" "--force" "and names the override for someone who means it"
assert_contains "$OUT" "$(sess_pid_path)" "and the pid file it found"

# uninstall.sh --force reaches this verb with the blockers deliberately present.
# Without the passthrough, the whole --force path would stop here.
assert_ok "--force removes it anyway" quiet_remove --force
assert_contains "$(cat "$SUDO_LOG")" "rm -f $MACON_FS_PLIST" \
    "and the removal really runs"

# An unrecognised flag must not be read as consent.
assert_fail "an unknown flag on remove is refused" quiet_remove --yes-really
assert_eq "" "$(cat "$SUDO_LOG")" "and removes nothing"
clear_blockers

# A removal that did not remove. `rm -f` exits 0 for a file it left in place, so
# the verb used to print "boot failsafe removed." over a plist still on disk --
# and the caller most likely to act on that sentence is a user about to trust
# the machine to a night with no boot restore.
clear_blockers
: > "$MACON_FS_PLIST"
SUDO_RM_INERT=1
: > "$SUDO_LOG"
OUT=$( ( cli_cmd_failsafe remove ) 2>&1 )
RC=$?
SUDO_RM_INERT=0
assert_eq "1" "$RC" "a removal that removed nothing fails"
assert_contains "$OUT" "still installed" "and says the failsafe is still there"
assert_contains "$OUT" "$MACON_FS_PLIST" "and names the file that would not go"
assert_fail "and never announces a removal" \
    sh -c "case \"$OUT\" in *'boot failsafe removed'*) exit 0 ;; esac; exit 1"
assert_ok "the attempt did reach rm" \
    sh -c "grep -q 'rm -f' '$SUDO_LOG'"
rm -f "$MACON_FS_PLIST"
clear_blockers

# --- the helper daemon's plist ----------------------------------------------
#
# Three keys carry the whole design, and each of them has a way of being subtly
# wrong that produces a job which looks fine and is not.

P=$(cli_helper_plist /usr/local/libexec/macon/macon-helper \
    /Users/someone/.local/state/macon /usr/local/libexec/macon/lib \
    /usr/local/libexec/macon)

assert_contains "$P" "<key>Label</key><string>local.macon.helper</string>" \
    "the plist declares the helper's own label"
assert_contains "$P" "<string>watch</string>" \
    "the daemon runs the watch verb, never a descriptor path"

# A bare <true/> here would restart the helper for ever after every clean
# ending, because ending a session IS an exit 0. The dict is the contract.
assert_contains "$P" "<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>" \
    "KeepAlive respawns an abnormal death and not a clean exit"
case "$P" in
    *"<key>KeepAlive</key><true/>"*)
        assert_eq "dict" "true" "KeepAlive must not be a bare true" ;;
    *) assert_eq "dict" "dict" "KeepAlive is not a bare true" ;;
esac

assert_contains "$P" "<key>ThrottleInterval</key><integer>10</integer>" \
    "a crash loop is rate-bounded by launchd itself"

# A system daemon inherits nothing. MACON_STATE is where the snapshot lives,
# and without it lib/snapshot.sh falls back to a $HOME this job does not have.
assert_contains "$P" "<key>MACON_STATE</key><string>/Users/someone/.local/state/macon</string>" \
    "the state directory is named, because the daemon has no HOME to derive it from"
assert_contains "$P" "<key>MACON_LIB</key><string>/usr/local/libexec/macon/lib</string>" \
    "the library path is named"
assert_contains "$P" "<key>MACON_LIBEXEC</key><string>/usr/local/libexec/macon</string>" \
    "the libexec path is named"

# RunAtLoad would be redundant -- KeepAlive already starts the job at load --
# and a reader who saw both would reasonably wonder which one was doing the work.
case "$P" in
    *RunAtLoad*) assert_eq "absent" "present" "RunAtLoad is not restated" ;;
    *) assert_eq "absent" "absent" "RunAtLoad is not restated" ;;
esac

# A path is XML text, not markup. launchd's answer to a plist it cannot parse
# is to not run the job -- discovered on the morning it was needed.
P=$(cli_helper_plist "/opt/a & b/macon-helper" "" "" "")
assert_contains "$P" "/opt/a &amp; b/macon-helper" "the program path is XML-escaped"

# --- what install.sh actually writes ----------------------------------------
#
# Everything above passes literal arguments, so the composition is untested by
# it: a for_install that pointed the job at the wrong file, or at a bare
# "macon-helper" with no directory, would render just as well and read just as
# green. install.sh has no second opinion to compare against -- this function's
# output IS the plist that lands in /Library/LaunchDaemons.
#
# MACON_LIB and MACON_LIBEXEC are the /opt values set further up, which is the
# case that matters: a hard-coded /usr/local would be invisible under the
# default prefix.
P=$(cli_helper_plist_for_install)
assert_contains "$P" "<string>/opt/macon-libexec/macon-helper</string>" \
    "the daemon's program is composed from MACON_LIBEXEC"
assert_contains "$P" "<key>MACON_LIB</key><string>/opt/macon-libexec/lib</string>" \
    "and it carries the library path this CLI is running from"
assert_contains "$P" "<key>MACON_LIBEXEC</key><string>/opt/macon-libexec</string>" \
    "and the libexec directory it was installed into"
assert_contains "$P" "<key>MACON_STATE</key><string>$MACON_STATE</string>" \
    "and the state directory of the user installing it"
printf '%s\n' "$P" > "$MACON_STATE/helper-install.plist"
assert_ok "and produces a plist macOS will parse" \
    plutil -lint "$MACON_STATE/helper-install.plist"
assert_eq "/opt/macon-libexec/macon-helper" \
    "$(plutil -extract ProgramArguments.0 raw -o - "$MACON_STATE/helper-install.plist")" \
    "and macOS reads that program back as an absolute path"

# The verb install.sh calls, dispatched the way install.sh dispatches it: a real
# subprocess with both paths in its environment. Nothing else in the suite runs
# it, so the entry point could stop routing __helper_plist entirely -- or route
# it to the failsafe's renderer -- and every assertion above would still hold.
#
# The paths are this checkout's, not the /opt strings above, because the
# subprocess has to SOURCE what MACON_LIB names before it can render anything.
MACON_LIB="$REPO_DIR/lib"
MACON_LIBEXEC="$REPO_DIR/libexec"
EXPECT=$(cli_helper_plist_for_install)
#
# MACON_CLI_SOURCED is cleared for the child: this file exports it so sourcing
# the CLI does not run it, and inheriting it would make the subprocess skip the
# very dispatch block under test and exit 0 with no output.
V=$(MACON_CLI_SOURCED='' MACON_LIB="$REPO_DIR/lib" \
    MACON_LIBEXEC="$REPO_DIR/libexec" MACON_STATE="$MACON_STATE" \
    sh "$REPO_DIR/bin/macon" __helper_plist)
assert_contains "$V" "<key>Label</key><string>local.macon.helper</string>" \
    "the __helper_plist verb renders the helper's daemon"
assert_contains "$V" "<string>$REPO_DIR/libexec/macon-helper</string>" \
    "with the program path built from the environment install.sh hands it"
assert_eq "$EXPECT" "$V" \
    "and the verb is that renderer, not a second copy of it"

teardown_state
