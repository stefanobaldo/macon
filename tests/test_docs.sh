#!/bin/sh
# The README is the only file a user reads before handing this tool a root
# password and a night with the lid closed, so what it claims is checked the
# same way everything else here is.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"

README="$REPO_DIR/README.md"
assert_ok "the README exists" test -f "$README"

for _s in "mac overnight" "macon on" "macon off" "macon status" "macon report" \
    "Requirements" "macOS 13" "MIT"; do
    assert_ok "the README documents '$_s'" grep -qF "$_s" "$README"
done

# Every subcommand in the CLI usage must appear in the README.
for _c in on run off 'done' status report saved log failsafe; do
    assert_ok "the README documents the '$_c' subcommand" grep -qF "macon $_c" "$README"
done

# The variable was never set by anything in this repository. It survived in the
# integration's docs alone, where it made the bundled skill trigger on a
# condition that could not occur.
assert_fail "no document still claims MACON_SENTINEL exists" \
    grep -rqF "MACON_SENTINEL" "$README" \
        "$REPO_DIR/integrations" "$REPO_DIR/CHANGELOG.md"

# And the flag is gone from the product, so it must be gone from the prose.
#
# CHANGELOG.md is deliberately NOT swept for the flag. Its [0.1.0-rc.1] section
# describes what that tag shipped, and v0.1.0-rc.1's annotated message was
# extracted from it -- editing the section would leave the tag and the changelog
# describing the same release differently, which is the drift CONTRIBUTING's
# release convention exists to prevent. The removal belongs under [Unreleased].
assert_fail "no document still offers --sentinel" \
    grep -rqF -- "--sentinel" "$README" "$REPO_DIR/integrations" \
        "$REPO_DIR/completions"

# The support table must state what was actually verified, not a promise. This
# is the assertion that has to fail if the real suite is ever skipped and the
# table left standing.
assert_ok "the README states the verified configuration" \
    grep -qF "Apple M5" "$README"
assert_ok "the README marks Intel as untested" \
    grep -qiE "intel.*(untested|not tested)" "$README"

# MACON_REASON is a hook contract: a user writes a script that switches on it,
# so every value the helper can pass has to be written down. The list grew from
# seven to nine during the build -- twice -- which is exactly why it is pinned
# here rather than trusted to stay current.
for _r in "done" soft-deadline hard-ceiling no-ac manual orphan reboot \
    invalid-descriptor descriptor-write-failed; do
    assert_ok "the README documents the '$_r' end reason" grep -qF "$_r" "$README"
done
assert_ok "the README names the hook variable carrying them" \
    grep -qF "MACON_REASON" "$README"

# The integration must not be wired into the main installer.
assert_fail "install.sh does not install the Claude Code skill" \
    grep -qF "integrations" "$REPO_DIR/install.sh"
assert_ok "the integration ships its own installer" \
    test -f "$REPO_DIR/integrations/claude-code/install.sh"
assert_ok "and explains the trade-off it makes" \
    test -f "$REPO_DIR/integrations/claude-code/README.md"
assert_ok "and carries the skill itself" \
    test -f "$REPO_DIR/integrations/claude-code/SKILL.md"

# Completions exist for both shells the CLI claims to support, and cover every
# subcommand. A completion that silently lags the CLI teaches the wrong surface.
BASH_C="$REPO_DIR/completions/macon.bash"
ZSH_C="$REPO_DIR/completions/_macon"
assert_ok "the bash completion exists" test -f "$BASH_C"
assert_ok "the zsh completion exists" test -f "$ZSH_C"
for _c in on run off 'done' status report saved log failsafe version help; do
    assert_ok "bash completion offers '$_c'" grep -qF "$_c" "$BASH_C"
    assert_ok "zsh completion offers '$_c'" grep -qF "$_c" "$ZSH_C"
done

# --- the launchd daemon the docs now promise --------------------------------
#
# The label and the descriptor path are READ OUT OF THE CODE and then looked for
# in the files, rather than typed here a second time. An assertion carrying its
# own copy of a name passes happily after a rename that left every document
# naming a job launchd does not have -- which is the exact failure this section
# exists to catch.
SECURITY="$REPO_DIR/SECURITY.md"
assert_ok "SECURITY.md exists" test -f "$SECURITY"

doc_default() {
    sed -n "s/^$2=\${$2:-\(.*\)}$/\1/p" "$1" | head -1
}
HELPER_LABEL=$(doc_default "$REPO_DIR/bin/macon" MACON_HELPER_LABEL)
# Guarded BEFORE it is used: a parse that came back empty turns every `grep -F`
# below into a match against nothing, and the whole section into decoration.
assert_contains "$HELPER_LABEL" "local.macon." \
    "the CLI's helper daemon label parses"
assert_ok "the README names the daemon launchd actually loads" \
    grep -qF "$HELPER_LABEL" "$README"
assert_ok "and so does SECURITY.md's table of what runs as root" \
    grep -qF "$HELPER_LABEL" "$SECURITY"

# Derived by running the code, not by matching a literal: this is the one path
# SECURITY.md offers as the bound on the unprivileged kickstart, so a helper
# that started reading somewhere else must not leave that paragraph standing.
DESC_PATH=$(unset MACON_RUN; . "$REPO_DIR/lib/common.sh"; . "$REPO_DIR/lib/session.sh"; sess_desc_path)
assert_contains "$DESC_PATH" "/session.conf" \
    "the session descriptor path derives from the code"
assert_ok "and is absolute" test "${DESC_PATH#/}" != "$DESC_PATH"
assert_ok "SECURITY.md names the file that bounds the kickstart exposure" \
    grep -qF "$DESC_PATH" "$SECURITY"

# Prose claims are matched against the file with its line wrapping removed, so
# a whole sentence can be pinned rather than the four words that happen to share
# a line with the keyword, and a reflow does not silently drop the pin.
says() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qF "$2"; }

assert_ok "the README says the daemon is registered at install time" \
    says "$README" "that \`install.sh\` registers"
assert_ok "and that a session cannot start without it" \
    says "$README" "Without that job, \`macon on\` refuses outright"

# "Outright" is the word under test. That the CLI refuses AT ALL is proven as
# behaviour in tests/test_on_rollback.sh, which runs cli_preflight against a
# machine launchd has no job on; what is pinned here is that the refusal has not
# since grown a way past it, which no other test on this branch would notice.
#
# Named flags were the wrong tool for that: a pattern listing --no-helper and
# two guesses beside it walks straight past --skip-helper, --unsupervised or a
# --force, and reads as coverage while providing none. So the GATE ITSELF is
# extracted and required to be unconditional. Every escape hatch has to reach it
# somehow, and there are only two ways in -- a test beside the call, or a parsed
# option consulted inside it -- and both are visible here whatever the flag ends
# up being called.
#
# The extraction is anchored on the exact `if ! cli_helper_daemon_loaded; then`
# line, and `macon status` has one of those too, further down. Requiring
# macon_die in what comes back is what tells the two apart: an anchor that stops
# matching -- because a condition was added beside the call -- silently lands on
# the status row instead, and the assertion fails there rather than passing on
# the wrong block.
gate_block() {
    awk '/^    if ! cli_helper_daemon_loaded; then$/ { f = 1 }
         f { print }
         f && /^    fi$/ { exit }' "$1"
}
GATE=$(gate_block "$REPO_DIR/bin/macon")
assert_contains "$GATE" "macon_die" \
    "and the CLI still refuses when launchd does not have the daemon"
mentions_option() { printf '%s' "$1" | grep -q 'OPT_'; }
assert_fail "with nothing that lets an option past it" mentions_option "$GATE"

# The other way in: leave the gate alone and teach the predicate to lie. It is
# two lines and asks launchd directly, which is the whole reason `on` can trust
# it -- an option consulted here would be an escape hatch the block above cannot
# see.
LOADED_FN=$(awk '/^cli_helper_daemon_loaded\(\) \{$/ { f = 1 }
                 f { print }
                 f && /^\}$/ { exit }' "$REPO_DIR/bin/macon")
assert_contains "$LOADED_FN" "plat_launchd_loaded" \
    "and it asks launchd, not a file or a flag"
assert_fail "and that answer is not overridable either" \
    mentions_option "$LOADED_FN"

assert_ok "SECURITY.md states the unprivileged kickstart plainly" \
    says "$SECURITY" \
    "any local account can \`launchctl kickstart\` it without a password"
assert_ok "and what bounds it" \
    says "$SECURITY" "exits 0 having applied nothing"

# The changelog has to name the version the CLI reports, not a version someone
# remembered to write down once. Cutting a release without a changelog section
# is the failure this catches, and it is silent everywhere else.
CHANGELOG="$REPO_DIR/CHANGELOG.md"
CLI_VERSION=$(sed -n 's/^MACON_VERSION=//p' "$REPO_DIR/bin/macon")
assert_ok "the CLI reports a version" test -n "$CLI_VERSION"
# Matched literally, brackets included. A regex on the bare version would let
# 0.1.0 match the [0.1.0-rc.1] heading -- a false pass at exactly the moment the
# first real release is cut.
assert_ok "the changelog names the version the CLI reports" \
    grep -qF "## [$CLI_VERSION]" "$CHANGELOG"
# And the unreleased section has to carry the change of the moment: a session
# that survives its helper being killed is the user-visible half of the whole
# supervision work, and a changelog that omits it describes a different tool.
assert_ok "the changelog names the helper daemon" \
    grep -qF "$HELPER_LABEL" "$CHANGELOG"
assert_ok "and says what that bought the user" \
    says "$CHANGELOG" "Killing the session helper no longer strands the Mac awake"
