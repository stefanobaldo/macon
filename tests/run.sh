#!/bin/sh
# Runs every tests/test_*.sh in its own subshell.
# Usage: sh tests/run.sh [name-fragment]
set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TESTS_DIR="$REPO_DIR/tests"
MACON_LIB="$REPO_DIR/lib"
export REPO_DIR TESTS_DIR MACON_LIB

# Every shell file has to PARSE before a single test runs, and the run stops
# here if one does not.
#
# It runs first because a test file that sources install.sh or uninstall.sh is
# reading a script the shell parses lazily: a file left unbalanced by an edit or
# a mistaken deletion does not fail cleanly, it runs a different program than
# the one on disk -- in the installer's case, the privileged half at top level,
# where sourcing it means installing macon for real. `sh -n` costs milliseconds
# and catches that before anything is executed.
#
# The list comes from tests/lint.sh, which is where it lives, so the syntax gate
# and the lint gate cannot come to cover different files.
syntax_checked=0
syntax_bad=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    syntax_checked=$((syntax_checked + 1))
    if sh -n "$REPO_DIR/$f"; then :; else
        printf 'SYNTAX ERROR: %s\n' "$f" >&2
        syntax_bad=$((syntax_bad + 1))
    fi
done <<EOF
$(sh "$TESTS_DIR/lint.sh" --list)
EOF

if [ "$syntax_checked" -eq 0 ]; then
    printf 'tests/run.sh: the syntax gate found no files to check\n' >&2
    exit 1
fi
if [ "$syntax_bad" -ne 0 ]; then
    printf '\n%d file(s) do not parse; no tests were run\n' "$syntax_bad" >&2
    exit 1
fi
printf 'syntax: %d file(s) parse\n\n' "$syntax_checked"

filter=${1:-}
failed=0
total=0

for t in "$TESTS_DIR"/test_*.sh; do
    [ -f "$t" ] || continue
    name=$(basename "$t")
    if [ -n "$filter" ]; then
        case "$name" in *"$filter"*) ;; *) continue ;; esac
    fi
    total=$((total + 1))
    printf '%s\n' "$name"
    if sh "$t"; then :; else failed=$((failed + 1)); fi
done

printf '\n%d file(s), %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
