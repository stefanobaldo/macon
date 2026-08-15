#!/bin/sh
# The project's lint gate, in one place so CI and a working session run exactly
# the same command.
#
# This exists because a session lost a CI cycle to a lint that was green
# locally: the two sides ran different invocations AND different shellcheck
# versions, and neither difference was visible from either side. One script and
# a pinned version in CI removes both halves.
#
# Usage: sh tests/lint.sh
set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR" || exit 1

# The executables carry no extension, so `find -name '*.sh'` cannot reach them.
# They are named explicitly and included only when present, so the gate becomes
# real for each one the moment it lands rather than when someone remembers to
# add it. They go in the SAME invocation as everything else on purpose: a file
# passed as input is a file shellcheck will follow a `source=` directive into,
# which is what keeps the tests that source them free of SC1091.
extra=""
for f in bin/macon libexec/macon-helper install.sh uninstall.sh; do
    [ -f "$f" ] && extra="$extra $f"
done

# Intentionally unquoted: $extra is a list of paths this script just built.
# shellcheck disable=SC2086
find . -name '*.sh' -not -path './.git/*' -print0 |
    xargs -0 shellcheck -s sh -S style $extra
