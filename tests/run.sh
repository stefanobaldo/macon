#!/bin/sh
# Runs every tests/test_*.sh in its own subshell.
# Usage: sh tests/run.sh [name-fragment]
set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TESTS_DIR="$REPO_DIR/tests"
MACON_LIB="$REPO_DIR/lib"
export REPO_DIR TESTS_DIR MACON_LIB

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
