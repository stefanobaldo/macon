#!/bin/sh
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
# shellcheck source=lib/decide.sh
. "$MACON_LIB/decide.sh"

# Signature: NOW CEILING SOFT POLICY BUSY OFFAC STRIKES

assert_eq "continue" "$(macon_decide 100 900 500 restore unknown 0 2)" \
    "before every deadline the loop continues"

assert_eq "end:soft-deadline" "$(macon_decide 500 900 500 restore unknown 0 2)" \
    "at the soft deadline with policy=restore the session ends"

# Every other rung-4 case lands exactly on the deadline. Polls are 30s apart, so
# in practice a sample falls PAST it, never on it -- this pins that the test is
# '>=' and not '=='. Without it the deadline could stop firing entirely and only
# the hard ceiling would ever end a session.
assert_eq "end:soft-deadline" "$(macon_decide 700 900 500 restore unknown 0 2)" \
    "past the soft deadline, not only exactly on it, the session ends"

assert_eq "end:hard-ceiling" "$(macon_decide 900 900 500 restore yes 0 2)" \
    "at the ceiling the session ends even while busy"

assert_eq "end:no-ac" "$(macon_decide 100 900 500 restore yes 2 2)" \
    "losing AC for the strike count ends the session"

assert_eq "end:done" "$(macon_decide 100 900 500 restore no 0 2)" \
    "a completion source reporting finished ends the session early"

assert_eq "extend" "$(macon_decide 500 900 500 extend yes 0 2)" \
    "at the soft deadline with policy=extend and still busy, extend"

# Rung 4 extends only when BOTH conjuncts hold. Each is pinned on its own here,
# so dropping either one -- or turning the && into an || -- is caught.
assert_eq "end:soft-deadline" "$(macon_decide 500 900 500 restore yes 0 2)" \
    "policy=restore ends at the soft deadline even while busy"

# Spec 7.4 bars 'extend' without a completion source at the CLI, so this input
# should never occur in production. It is asserted anyway because macon_decide
# accepts BUSY=unknown by contract, and if that CLI check is ever bypassed the
# function must fail toward ending rather than toward extending. Not dead.
assert_eq "end:soft-deadline" "$(macon_decide 500 900 500 extend unknown 0 2)" \
    "extend without a completion source does not extend"

# The completion source is rung 3 and the soft deadline is rung 4, so work
# that finished exactly at the deadline ends as 'done' -- the truthful reason.
assert_eq "end:done" "$(macon_decide 500 900 500 extend no 0 2)" \
    "policy=extend with work finished does not extend"

# Ordering is the invariant. The ceiling must beat every other signal.
assert_eq "end:hard-ceiling" "$(macon_decide 900 900 500 extend yes 0 2)" \
    "ceiling beats an extend policy reporting busy"
assert_eq "end:hard-ceiling" "$(macon_decide 900 900 500 restore yes 5 2)" \
    "ceiling beats a pending no-ac abort"
assert_eq "end:hard-ceiling" "$(macon_decide 1000 900 500 extend yes 0 2)" \
    "past the ceiling still ends"

# AC loss beats a busy completion source, but not the ceiling.
assert_eq "end:no-ac" "$(macon_decide 100 900 500 extend yes 3 2)" \
    "no-ac beats a busy completion source"

assert_eq "end:no-ac" "$(macon_decide 100 900 500 restore no 3 2)" \
    "no-ac beats a completion source reporting finished"

# The rung that matters most: without this case an ordering that put the soft
# deadline ahead of the AC check would extend the session on battery -- exactly
# the state rung 2 exists to prevent -- and every other assertion would pass.
assert_eq "end:no-ac" "$(macon_decide 500 900 500 extend yes 3 2)" \
    "no-ac beats an extend policy at the soft deadline"

# Below the strike count, AC loss does not end anything.
assert_eq "continue" "$(macon_decide 100 900 500 restore yes 1 2)" \
    "one strike is not enough to abort"
