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

# Is the lid shut? `AppleClamshellState` is the Hall sensor, and it flips at
# roughly a centimetre of lid gap -- verified: it turns Yes in the same 0.2s
# sample in which macOS turns the display off and begins clamshell sleep.
# Reacting to it therefore reproduces the system's own trigger point rather
# than approximating it. A Mac with no lid has no such key and reads open,
# which is the answer that makes the caller do nothing.
#
# `-d 1` bounds the output: unlike plat_sleep_disabled, which runs once per
# session, this runs twice a second for a whole night.
plat_clamshell_closed() {
    ioreg -r -k AppleClamshellState -d 1 -w0 2>/dev/null |
        grep -q '"AppleClamshellState" = Yes'
}

# Is a real display lit? Every framebuffer publishes `IOMFBBrightnessLevel`,
# but only one of them is attached to a panel: on the verified machine the
# built-in display reads its true backlight level while two unused framebuffers
# sit at a constant 65536 whether the screen is on or off. Counting those would
# make "lit" permanently true, and the caller would blank the display in a loop
# for ever.
#
# `DisplayAttributes` carrying `ProductAttributes` is what separates them -- it
# is the block describing an actual attached panel. A reading that cannot be
# taken at all reports NOT lit, so an unreadable machine makes macon do nothing
# rather than blank a display it cannot observe.
plat_display_lit() {
    [ "$(ioreg -r -k IOMFBBrightnessLevel -d 1 -w0 2>/dev/null | awk '
        function flush() { if (attrs && level != "" && level + 0 != 0) lit = 1 }
        /^\+-o /                                   { flush(); attrs = 0; level = "" }
        /"DisplayAttributes" = .*ProductAttributes/ { attrs = 1 }
        /"IOMFBBrightnessLevel" = /                 { level = $NF }
        END                                        { flush(); print (lit ? 1 : 0) }
    ')" = "1" ]
}

# Turn the display off now. An ACTION, not a setting: it changes no power value,
# so there is nothing for the snapshot to record and nothing for a restore to
# undo. That is the whole reason this is the mechanism -- it cannot add a way to
# leave the Mac unable to sleep.
plat_display_sleep_now() {
    _plat_root_run pmset displaysleepnow
}

# The alert that precedes the spoken phrase. A stock system sound, so there is
# nothing to ship and nothing to find missing: with the lid shut the speaker is
# muffled and the sentence can be lost, but the tone is unmistakable.
MACON_ANNOUNCE_SOUND=/System/Library/Sounds/Glass.aiff

# Beep and speak, on the user's own audio session.
#
# This lives here, with the other things that touch the real machine, and not
# in the helper that calls it. That is not tidiness: it is what keeps the test
# suite quiet. Every test loads tests/fake-platform.sh, so the fake is what
# answers here and no run of the suite can ever reach a speaker -- on this
# machine or on a CI runner, where `say` is also installed. A version of this
# living in the helper would be silent only for as long as every test file
# remembered to stub it, which is a convention, not a guarantee.
#
# Verified on the real machine, and it is the whole reason this is not three
# lines: `say` run as root returns 0 and produces NO SOUND. Speech synthesis is
# a per-user service the root domain cannot reach, and it fails silently rather
# than reporting anything -- the exit status is 0 either way. `afplay` as root
# does play, but the tone and the phrase go through the same path deliberately:
# two mechanisms for one announcement is how a tone with no phrase survives
# unnoticed for a month.
#
# `launchctl asuser` rather than `sudo -u` alone. Both work today, because the
# helper is started from the user's terminal and inherits its GUI session. Only
# asuser keeps working if the helper is ever moved under a launchd system
# daemon, and that regression would be invisible for the same reason the root
# case is: status 0, no sound, nothing in any log.
plat_say_as_user() {
    _plat_user=$1
    _plat_phrase=$2

    _plat_uid=$(id -u "$_plat_user" 2>/dev/null) || return 0
    case "$_plat_uid" in
        '' | *[!0-9]*) return 0 ;;
    esac

    # Detached, and the result deliberately unchecked. This runs inside the
    # half-second lid cadence while `say` takes seconds to finish a sentence, so
    # waiting would stretch every slice the announcement lands in. Like the
    # blank, a failed announcement is cosmetic: it can never leave the Mac
    # unable to sleep.
    #
    # Arguments stay arguments. Building `sh -c "say '$_plat_phrase'"` would put
    # the phrase through a round of shell parsing it has no business surviving,
    # and the helper's rule is that root evaluates nothing.
    #
    # stdin is closed explicitly, as it is everywhere else this project puts a
    # process in the background. Root never gets a password prompt out of `sudo
    # -u`, and `launchctl asuser` would not have got this far without being
    # root -- but that is an invariant held in another file, and a prompt
    # reading the helper's own stdin is not a failure anyone would find.
    (
        launchctl asuser "$_plat_uid" sudo -u "$_plat_user" \
            afplay "$MACON_ANNOUNCE_SOUND"
        launchctl asuser "$_plat_uid" sudo -u "$_plat_user" \
            say "$_plat_phrase"
    ) < /dev/null > /dev/null 2>&1 &
}

# The command prefix that puts a de-privileged command inside USER's own login
# session, or NOTHING when there is no such session to enter. Printed rather
# than executed, because the caller has to wrap it in its own timeout.
#
# The same regression plat_say_as_user was hardened against, reaching the other
# place that runs user code: --hook-end, --hook-warn and --busy-check all go
# through helper_run_as_user, which used plain `sudo -u`. That was enough while
# the helper was a descendant of the user's Terminal and inherited its Mach
# bootstrap namespace; it is now a launchd SYSTEM daemon and has none.
#
# Measured from a one-shot system daemon on this machine, running the same
# probes both ways. `sudo -u` alone: pgrep, a bare osascript and `display
# notification` all work, and `pbpaste` -- a per-user Mach service -- fails.
# Through asuser: all of them work. So the loss is narrower than "the GUI does
# not work", and it is real.
#
# The GUI session is CHECKED rather than assumed, and that is the whole reason
# this is a prefix and not an unconditional wrapper. `launchctl asuser` needs a
# session to attach to; on a machine where nobody is logged in it fails, and an
# unconditional form would stop running hooks that plain `sudo -u` runs today.
# A failed hook is not distinguishable from a hook that exited non-zero, so the
# question is asked in front instead of diagnosed behind. The cost is one
# `launchctl print` per hook or predicate, and those run at most once per poll.
plat_asuser_prefix() {
    _plat_u=$1

    _plat_uid=$(id -u "$_plat_u" 2>/dev/null) || return 0
    case "$_plat_uid" in
        '' | *[!0-9]*) return 0 ;;
    esac

    launchctl print "gui/$_plat_uid" > /dev/null 2>&1 || return 0
    printf 'launchctl asuser %s ' "$_plat_uid"
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

# Has launchd loaded JOB? The exit status is the ENTIRE signal (0 loaded, 113
# not); nothing here reads the output, whose shape changes between macOS
# releases. It works unprivileged, which is what lets `macon status` ask.
#
# It is still not proof the job would do anything -- a loaded job can point at a
# program that exits immediately, which is in fact what macon's own helper does
# when no session is armed. It is strictly more than a test for the plist file,
# which a job can outlive: verified, deleting the plist leaves the job loaded
# and still respawning.
plat_launchd_loaded() {
    launchctl print "system/$1" >/dev/null 2>&1
}

# `running`, `not running`, or nothing.
#
# Unlike plat_launchd_loaded this DOES parse, so it is best-effort by
# construction and every caller must treat empty as "no reading". The anchor is
# a single leading tab: `launchctl print` also emits `state = active` lines for
# nested endpoints, two tabs in, and a looser match would report one of those.
plat_launchd_state() {
    launchctl print "system/$1" 2>/dev/null |
        awk -F' = ' '$1 == "\tstate" { print $2; exit }'
}

# How many times launchd has started JOB since it loaded it. Best-effort for
# the same reason as plat_launchd_state.
#
# This is the respawn counter, maintained by launchd at no cost to macon: during
# a session, a value above 1 means the helper died and came back.
plat_launchd_runs() {
    launchctl print "system/$1" 2>/dev/null |
        awk '$1 == "runs" && $2 == "=" { print $3; exit }'
}

# Start a stopped job. Note what this does NOT do: on a job that is already
# running it is a no-op, and restarting one needs `kickstart -k`, which is
# root-only. Verified.
plat_launchd_kickstart() {
    _plat_root_run launchctl kickstart "system/$1"
}

# Register a job. LABEL is unused here -- launchd reads it from the plist -- and
# is in the signature so the test fake can model the resulting state.
#
# Bootstrapping over an already-loaded label fails with EIO (verified), so
# callers must ensure the label is not loaded first.
plat_launchd_bootstrap() {
    _plat_root_run launchctl bootstrap system "$2"
}

# Stop and unregister a job. Verified: SIGTERM, the process is gone, the job is
# unloaded, and KeepAlive does NOT respawn it. This is the only thing that stops
# a KeepAlive job -- `launchctl kill` kills the process and launchd revives it.
#
# On a job that is not loaded it returns 3 ("No such process"), which callers
# distinguish from a real failure.
plat_launchd_bootout() {
    _plat_root_run launchctl bootout "system/$1"
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
