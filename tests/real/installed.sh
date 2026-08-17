#!/bin/sh
# Sourcing this file defines one function and does nothing else.

# Prints every installed path that is not what this checkout would install,
# one per line, and returns non-zero when there is any. Paths are printed as
# they sit under the prefix, because the reader's next move is to look at the
# installed file, not the source it should have come from.
real_installed_drift() {
    _repo=$1
    _prefix=$2
    _drift=0

    # The same set install.sh copies, in the same order.
    for _pair in \
        "bin/macon|bin/macon" \
        "libexec/macon-helper|libexec/macon/macon-helper" \
        "libexec/failsafe.sh|libexec/macon/failsafe.sh"; do
        _src=${_pair%%|*}
        _dst=${_pair#*|}
        if cmp -s "$_repo/$_src" "$_prefix/$_dst"; then :; else
            printf '%s\n' "$_dst"
            _drift=1
        fi
    done

    # lib/*.sh goes in by glob, so it is walked by glob here too: a check
    # written from a list of names stops covering the file the day one is added.
    for _lib in "$_repo"/lib/*.sh; do
        [ -f "$_lib" ] || continue
        _dst="libexec/macon/lib/$(basename "$_lib")"
        if cmp -s "$_lib" "$_prefix/$_dst"; then :; else
            printf '%s\n' "$_dst"
            _drift=1
        fi
    done

    # And the other direction: install.sh copies but never removes, so a lib the
    # checkout dropped stays in the prefix and bin/macon goes on sourcing it.
    # Only a walk of the installed side can find a file the repo does not name.
    for _lib in "$_prefix"/libexec/macon/lib/*.sh; do
        [ -f "$_lib" ] || continue
        _base=$(basename "$_lib")
        if [ -f "$_repo/lib/$_base" ]; then continue; fi
        printf '%s\n' "libexec/macon/lib/$_base"
        _drift=1
    done

    [ "$_drift" -eq 0 ]
}
