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

# All keys in ONE invocation. pmset validates the whole set per call and
# rejects combinations such as sleep>0 with disksleep=0; applying keys one
# at a time passes through states pmset itself considers invalid.
plat_pmset_apply_ac() {
    pmset -c "$@"
}

plat_pmset_disablesleep() {
    pmset -a disablesleep "$1"
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
