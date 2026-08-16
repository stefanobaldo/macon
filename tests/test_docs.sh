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
for _c in on run off status report saved log failsafe; do
    assert_ok "the README documents the '$_c' subcommand" grep -qF "macon $_c" "$README"
done

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
for _c in on run off status report saved log failsafe version help; do
    assert_ok "bash completion offers '$_c'" grep -qF "$_c" "$BASH_C"
    assert_ok "zsh completion offers '$_c'" grep -qF "$_c" "$ZSH_C"
done

# The changelog has to describe the release, not still be the empty heading
# Task 1 created.
CHANGELOG="$REPO_DIR/CHANGELOG.md"
assert_ok "the changelog names a version" grep -qE '^## \[?0\.1\.0' "$CHANGELOG"
