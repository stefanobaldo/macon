#!/bin/sh
# The poll-order decision, isolated as a pure function so the invariant is
# testable without waiting for a night to pass.
#
# The order below IS the safety guarantee. The hard ceiling is evaluated
# first and unconditionally, which is what stops any liveness source --
# including a sentinel that never arrives, or a --busy-check that always
# reports busy -- from holding the machine awake indefinitely.
#
# Arguments:
#   NOW CEILING SOFT POLICY BUSY OFFAC STRIKES
#   POLICY : restore | extend
#   BUSY   : yes | no | unknown   (unknown = no completion source configured)
macon_decide() {
    _now=$1
    _ceiling=$2
    _soft=$3
    _policy=$4
    _busy=$5
    _offac=$6
    _strikes=$7

    # 1. The ceiling, before anything else.
    if [ "$_now" -ge "$_ceiling" ]; then
        printf 'end:hard-ceiling\n'
        return 0
    fi

    # 2. Lid closed, sleep disabled and no AC is the worst state this tool
    #    can produce: the battery drains to zero with nowhere for heat to go.
    if [ "$_offac" -ge "$_strikes" ]; then
        printf 'end:no-ac\n'
        return 0
    fi

    # 3. The work reported itself finished.
    if [ "$_busy" = "no" ]; then
        printf 'end:done\n'
        return 0
    fi

    # 4. The requested time ran out.
    if [ "$_now" -ge "$_soft" ]; then
        if [ "$_policy" = "extend" ] && [ "$_busy" = "yes" ]; then
            printf 'extend\n'
        else
            printf 'end:soft-deadline\n'
        fi
        return 0
    fi

    printf 'continue\n'
}
