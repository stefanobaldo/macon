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
OUT=$(cli_cmd_failsafe status)
assert_contains "$OUT" "absent" "status reports an uninstalled failsafe"
: > "$MACON_FS_PLIST"
OUT=$(cli_cmd_failsafe status)
assert_contains "$OUT" "installed" "status reports an installed failsafe"
assert_contains "$OUT" "$MACON_FS_PLIST" "and names the file"

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

teardown_state
