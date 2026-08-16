#!/bin/sh
# Runner for the opt-in suite that mutates real power settings.
#
# Deliberately separate from tests/run.sh, which globs tests/test_*.sh and
# therefore never reaches this directory: the fake-backed suite is what CI runs
# and what a contributor runs without thinking, and neither should be able to
# change a machine's power configuration by accident. Getting here takes running
# a different script AND setting MACON_REAL_TESTS=1.
#
# Usage: MACON_REAL_TESTS=1 sh tests/real/run.sh
set -u

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TESTS_DIR="$REPO_DIR/tests"
export REPO_DIR TESTS_DIR

if [ "${MACON_REAL_TESTS:-0}" != "1" ]; then
    printf 'tests/real: MACON_REAL_TESTS is not 1; every file will skip itself.\n'
    printf 'tests/real: this suite requires macon installed, AC power, and sudo.\n\n'
fi

failed=0
for t in "$REPO_DIR"/tests/real/test_*.sh; do
    [ -f "$t" ] || continue
    printf '%s\n' "$(basename "$t")"
    sh "$t" || failed=$((failed + 1))
done
printf '\n%d failed\n' "$failed"
[ "$failed" -eq 0 ]
