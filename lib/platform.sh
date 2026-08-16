#!/bin/sh
# The only file that knows macOS command syntax. Everything else calls
# these functions, which is what makes the dangerous paths testable.

plat_macos_major() {
    sw_vers -productVersion | cut -d. -f1
}

# Reads a key from the "AC Power" block of `pmset -g custom`.
# Block order varies between machines, so the parser does not assume
# which block comes first.
plat_pmset_read() {
    pmset -g custom 2>/dev/null | awk -v key="$1" '
        /^AC Power/      { ac = 1; next }
        /^Battery Power/ { ac = 0 }
        ac && $1 == key  { print $2; exit }
    '
}

# Writing a pmset key requires root, and this file's two callers sit on
# opposite sides of that line. `bin/macon` runs as the user: its activation
# ladder, its rollback and `macon off` all mutate, and all of them must
# escalate. `libexec/macon-helper` and `libexec/failsafe.sh` are already root
# and must NEVER reach for sudo -- the helper's sudo timestamp expires during
# the night it is watching, so a restore that needed a password would fail at
# 03:00 with nobody there to type it, which is the exact failure this project
# exists to make impossible.
#
# A pure predicate rather than an inline test, for the same reason
# `helper_needs_sudo` is one: the case that matters (uid 0 -> run direct)
# cannot be reached by a suite that does not run as root, so it is tested by
# calling the decision rather than by reaching the branch.
plat_needs_sudo() {
    [ "$1" -ne 0 ]
}

_plat_root_run() {
    if plat_needs_sudo "$(id -u)"; then
        sudo "$@"
    else
        "$@"
    fi
}

# All keys in ONE invocation. pmset validates the whole set per call and
# rejects combinations such as sleep>0 with disksleep=0; applying keys one
# at a time passes through states pmset itself considers invalid.
plat_pmset_apply_ac() {
    _plat_root_run pmset -c "$@"
}

# Note that pmset's exit code is not on its own evidence the write landed:
# refused for lack of privilege it prints "'pmset' must be run as root" and
# still exits 0. Every caller that depends on this having taken effect
# re-reads the machine afterwards rather than trusting the status.
plat_pmset_disablesleep() {
    _plat_root_run pmset -a disablesleep "$1"
}

# SleepDisabled does not appear in `pmset -g` on modern macOS. The value
# lives in the IORegistry, as Yes/No rather than 1/0.
plat_sleep_disabled() {
    ioreg -r -k SleepDisabled 2>/dev/null | grep -q '"SleepDisabled" = Yes'
}

plat_power_source() {
    if pmset -g batt 2>/dev/null | grep -q "'AC Power'"; then
        printf 'ac\n'
    else
        printf 'battery\n'
    fi
}

plat_battery_pct() {
    pmset -g batt 2>/dev/null | awk '
        NR > 1 {
            for (i = 1; i <= NF; i++)
                if ($i ~ /%/) { gsub(/[;%]/, "", $i); print $i; exit }
        }'
}

# CPU_Speed_Limit from `pmset -g therm` is an Intel SMC metric and is never
# populated on Apple Silicon. Thermal pressure comes from powermetrics,
# which requires root.
plat_thermal_pressure() {
    _lvl=$(powermetrics --samplers thermal -n 1 -i 100 2>/dev/null |
        awk -F': ' '/pressure level/ { print $2; exit }')
    if [ -n "$_lvl" ]; then printf '%s\n' "$_lvl"; else printf 'unknown\n'; fi
}

# kern.boottime prints "{ sec = 1785863447, usec = 242957 } ...".
# Match the field exactly: a greedy .*sec pattern matches "usec" and returns
# microseconds, which yields an uptime near 1.8 billion seconds.
plat_boot_time() {
    sysctl -n kern.boottime 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++)
                if ($i == "sec") { v = $(i + 2); gsub(/[^0-9]/, "", v); print v; exit }
        }'
}

plat_launchctl() {
    launchctl "$@"
}

# Is PID a live process whose command matches PATTERN? Both halves matter.
# Liveness alone is not enough: ${MACON_RUN} is cleared at boot so a recorded
# PID cannot survive a reboot, but within one uptime the kernel will happily
# hand that number to an unrelated process. Matching the command is the only
# thing that tells "our helper" apart from "whoever inherited its PID".
plat_process_matches() {
    ps -o command= -p "$1" 2>/dev/null | grep -q "$2"
}

# Copies the PowerManagement preference plists into DEST. Returns non-zero
# when nothing landed: /bin/sh passes an unmatched glob through literally, so
# a bare `cp <glob>` cannot be trusted to have produced anything. Count what
# actually copied instead — the caller uses this to know whether the forensic
# defence really ran.
plat_backup_pmprefs() {
    _dest=$1
    _copied=0
    for _f in /Library/Preferences/com.apple.PowerManagement*.plist; do
        [ -f "$_f" ] || continue
        if cp "$_f" "$_dest"/ 2>/dev/null; then
            _copied=$((_copied + 1))
        fi
    done
    [ "$_copied" -gt 0 ]
}
