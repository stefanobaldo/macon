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
#        sh tests/lint.sh --list    (print the file list, one path per line)
set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR" || exit 1

# Every shell file in the project, one per line, relative to the repository
# root. It is a function, and --list publishes it, because this is not the only
# gate that needs the list: tests/run.sh parses each of these with `sh -n`
# before it runs a single test. A second list written over there is a list that
# drifts, and the file that falls off it is the file nothing checks.
#
# The executables carry no extension, so `find -name '*.sh'` cannot reach them.
# They are named explicitly and included only when present, so a gate becomes
# real for each one the moment it lands rather than when someone remembers to
# add it.
lint_files() {
    for _f in bin/macon libexec/macon-helper install.sh uninstall.sh; do
        [ -f "$_f" ] && printf '%s\n' "$_f"
    done
    find . -name '*.sh' -not -path './.git/*'
}

if [ "${1:-}" = "--list" ]; then
    lint_files
    exit 0
fi

# All of them go into the SAME shellcheck invocation on purpose: a file passed
# as input is a file shellcheck will follow a `source=` directive into, which is
# what keeps the tests that source them free of SC1091.
#
# Read into "$@" rather than word split, so a path containing a space stays one
# argument.
set --
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    set -- "$@" "$_f"
done <<EOF
$(lint_files)
EOF

shellcheck -s sh -S style "$@"
