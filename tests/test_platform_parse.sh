#!/bin/sh
# The real parsers in lib/platform.sh, exercised against real command output.
#
# tests/fake-platform.sh replaces that file wholesale, so everything else in
# this suite runs against the fake and none of these parsers is executed at all.
# plat_boot_time is the one whose failure is silent AND permanent: it is the
# only input to the boot guard in libexec/failsafe.sh, and a wrong answer there
# does not misreport a number, it stands the failsafe down at every boot for
# ever -- while `macon failsafe status` still says "installed", so the machine
# reports itself protected and is not.
#
# Unlike plat_process_matches this is a pure text parser, so it needs no
# privileged state to test: a PATH shim feeds it the output of the real
# command, captured from a real Mac.
# shellcheck source=tests/helpers.sh
. "$TESTS_DIR/helpers.sh"
setup_state
# shellcheck source=lib/common.sh
. "$MACON_LIB/common.sh"
# shellcheck source=lib/platform.sh
. "$MACON_LIB/platform.sh"

SHIM="$MACON_STATE/shim"
mkdir -p "$SHIM"

# The fixture reaches the shim through a QUOTED heredoc, so nothing in it is
# expanded on the way: this text is data, and it carries `$` and `{` for real.
fake_sysctl() {
    {
        printf '#!/bin/sh\n'
        printf "cat <<'FIXTURE'\n"
        printf '%s\n' "$1"
        printf 'FIXTURE\n'
    } > "$SHIM/sysctl"
    chmod 755 "$SHIM/sysctl"
}

# The subshell is deliberate: the shimmed PATH must not outlive the call.
# shellcheck disable=SC2030,SC2031
boot_time_via_shim() ( PATH="$SHIM:$PATH"; export PATH; plat_boot_time )

# --- real output ------------------------------------------------------------
#
# Captured verbatim from `sysctl -n kern.boottime` on macOS 26.

fake_sysctl '{ sec = 1785863447, usec = 434664 } Tue Aug  4 14:10:47 2026'
assert_eq "1785863447" "$(boot_time_via_shim)" \
    "the boot time is the sec field of kern.boottime"

# What the caller does with it: _failsafe_is_number refuses anything that is not
# plain digits, and the uptime is computed with $(( )). A value that still
# carried the trailing comma would be refused there and the failsafe would
# stand down at a real boot.
assert_eq "" "$(boot_time_via_shim | tr -d '0-9')" \
    "and it is digits only, with the comma stripped"

# --- the field is matched by name, not by substring -------------------------
#
# The trap this guards is `$i ~ /sec/`, which also matches "usec" and returns
# MICROSECONDS -- an uptime near 1.8 billion seconds, so failsafe_should_run
# takes its "not a boot" branch at every boot, permanently.
#
# On today's line the two spellings happen to agree: `sec` comes first, so a
# greedy pattern stops on it and reads the same field. The property is therefore
# pinned by putting the fields in the other order, which is the only way to make
# the difference observable without waiting for macOS to change its format --
# and the exact-match parser answers with the field it was asked for either way.
fake_sysctl '{ usec = 434664, sec = 1785863447 } Tue Aug  4 14:10:47 2026'
assert_eq "1785863447" "$(boot_time_via_shim)" \
    "usec is not read as sec, whichever field comes first"

# --- nothing usable ---------------------------------------------------------
#
# Every one of these has to reach the caller as a value it will REFUSE, never as
# a number it will believe. The empty string is what _failsafe_is_number rejects
# first.

fake_sysctl ''
assert_eq "" "$(boot_time_via_shim)" "no output parses to nothing"

fake_sysctl 'kern.boottime: unavailable'
assert_eq "" "$(boot_time_via_shim)" "output with no sec field parses to nothing"

fake_sysctl '{ sec = }'
assert_eq "" "$(boot_time_via_shim)" "a sec field with nothing after it parses to nothing"

# A sysctl that fails is not the same as one that answers strangely, and the
# parser has to survive both.
printf '#!/bin/sh\nprintf "boom\\n" >&2\nexit 1\n' > "$SHIM/sysctl"
chmod 755 "$SHIM/sysctl"
assert_eq "" "$(boot_time_via_shim 2>/dev/null)" "a sysctl that fails parses to nothing"

teardown_state
