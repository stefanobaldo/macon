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

# --- the lid and the panel --------------------------------------------------
#
# Both readers run twice a second for a whole night, and both decide whether to
# blank a screen. The display one is the reason this section exists: the machine
# publishes three framebuffers and only one of them is attached to a panel, so
# the naive reading of "is any brightness non-zero" is TRUE FOR EVER -- the two
# unused ones sit at a constant 65536 with the screen off. That would blank the
# display in a loop for as long as the lid stayed shut.

FIXTURES="$MACON_STATE/ioreg-fixtures"
mkdir -p "$FIXTURES"

cat > "$SHIM/ioreg" <<'EOF'
#!/bin/sh
# Answers by the key the caller asked for, the way the real ioreg does.
_key=
for _a in "$@"; do
    case "$_a" in
        AppleClamshellState | IOMFBBrightnessLevel) _key=$_a ;;
    esac
done
[ -n "$_key" ] && [ -f "$MACON_STATE/ioreg-fixtures/$_key" ] &&
    cat "$MACON_STATE/ioreg-fixtures/$_key"
exit 0
EOF
chmod 755 "$SHIM/ioreg"

fake_ioreg() { cat > "$FIXTURES/$1"; }

# shellcheck disable=SC2030,SC2031
ioreg_via_shim() ( PATH="$SHIM:$PATH"; export PATH; "$@" )

# Captured verbatim from `ioreg -r -k AppleClamshellState -d 1 -w0` on macOS 26.
# AppleClamshellCausesSleep sits next to it and stays Yes even while sleep is
# disabled, so a reader matching loosely on "Clamshell" would answer with the
# wrong key entirely.
fake_ioreg AppleClamshellState <<'EOF'
  |   "AppleClamshellCausesSleep" = Yes
  |   "AppleClamshellState" = No
  |   "Last Sleep Reason" = "Clamshell Sleep"
EOF
assert_fail "an open lid reads open" ioreg_via_shim plat_clamshell_closed

fake_ioreg AppleClamshellState <<'EOF'
  |   "AppleClamshellCausesSleep" = Yes
  |   "AppleClamshellState" = Yes
  |   "Last Sleep Reason" = "Clamshell Sleep"
EOF
assert_ok "a shut lid reads closed" ioreg_via_shim plat_clamshell_closed

# A Mac with no lid publishes no such key at all.
fake_ioreg AppleClamshellState < /dev/null
assert_fail "a machine with no clamshell key reads open" \
    ioreg_via_shim plat_clamshell_closed

# The shape of `ioreg -r -k IOMFBBrightnessLevel -d 1 -w0`: three framebuffers,
# one of them carrying the DisplayAttributes block that describes a real
# attached panel. Trimmed to the lines the parser reads.
_fb_lit() {
    fake_ioreg IOMFBBrightnessLevel <<EOF
+-o IOMobileFramebufferShim  <class IOMobileFramebufferShim, id 0x100000632>
      "DisplayAttributes" = {"TiledDisplayInfo"={},"ProductAttributes"={"ManufacturerID"="00-10-fa","ProductID"=55204023186497}}
      "IOMFBBrightnessLevelMA" = 18446744073709551615
      "IOMFBBrightnessLevel" = $1
+-o IOMobileFramebufferShim  <class IOMobileFramebufferShim, id 0x100000631>
      "IOMFBBrightnessLevelIDAC" = 18446744073709551615
      "IOMFBBrightnessLevel" = 65536
+-o IOMobileFramebufferShim  <class IOMobileFramebufferShim, id 0x100000630>
      "IOMFBBrightnessLevel" = 65536
EOF
}

_fb_lit 2245246
assert_ok "a panel at its real backlight level reads lit" \
    ioreg_via_shim plat_display_lit

# The assertion the whole discriminator exists for.
_fb_lit 0
assert_fail "a dark panel reads dark, though two idle framebuffers sit at 65536" \
    ioreg_via_shim plat_display_lit

# The sibling keys are not the key. Matching on a prefix would read
# IOMFBBrightnessLevelMA -- UINT64_MAX -- and call a dark screen lit for ever.
fake_ioreg IOMFBBrightnessLevel <<'EOF'
+-o IOMobileFramebufferShim  <class IOMobileFramebufferShim, id 0x100000632>
      "DisplayAttributes" = {"ProductAttributes"={"ManufacturerID"="00-10-fa"}}
      "IOMFBBrightnessLevelMA" = 18446744073709551615
      "IOMFBBrightnessLevelIDAC" = 18446744073709551615
      "IOMFBBrightnessLevel" = 0
EOF
assert_fail "the MA and IDAC siblings are not read as the brightness" \
    ioreg_via_shim plat_display_lit

# A framebuffer with a lit level but no attached panel is not a lit display.
fake_ioreg IOMFBBrightnessLevel <<'EOF'
+-o IOMobileFramebufferShim  <class IOMobileFramebufferShim, id 0x100000631>
      "IOMFBBrightnessLevel" = 65536
EOF
assert_fail "a framebuffer with no attached panel is not a lit display" \
    ioreg_via_shim plat_display_lit

# Unreadable has to reach the caller as "not lit": blanking a display macon
# cannot observe would fire every cadence, for ever, on evidence it does not
# have.
fake_ioreg IOMFBBrightnessLevel < /dev/null
assert_fail "an unreadable framebuffer tree reads dark" \
    ioreg_via_shim plat_display_lit

# --- the escalation decision ------------------------------------------------
#
# The two pmset writers are the only functions in this project that must behave
# differently depending on who is running them, and both answers are dangerous
# in opposite directions: an unprivileged CLI that does not escalate silently
# fails to arm (pmset refuses AND exits 0, so nothing downstream notices), while
# a root helper that DOES escalate asks for a password at 03:00 with nobody
# there and leaves the Mac unable to sleep.
#
# uid 0 is unreachable from a suite that does not run as root, so the decision
# is asserted directly instead of by reaching the branch -- the same shape
# helper_needs_sudo is tested with, and for the same reason.
assert_fail "root runs privileged commands directly" plat_needs_sudo 0
assert_ok "an unprivileged user escalates" plat_needs_sudo 501
assert_ok "any non-zero uid escalates, not just the usual one" plat_needs_sudo 1

# The wiring, not just the decision: a shim proves the mutating writers
# actually route through it. Without this the predicate could be correct and
# unused, which is what it was before this test existed.
cat > "$SHIM/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*"
EOF
cat > "$SHIM/pmset" <<'EOF'
#!/bin/sh
printf 'direct %s\n' "$*"
EOF
cat > "$SHIM/id" <<'EOF'
#!/bin/sh
printf '%s\n' "${MACON_FAKE_UID:-501}"
EOF
chmod 755 "$SHIM/sudo" "$SHIM/pmset" "$SHIM/id"

# Same shape, and the same reason, as boot_time_via_shim above.
# shellcheck disable=SC2030,SC2031
pmset_via_shim() ( PATH="$SHIM:$PATH"; export PATH; "$@" )

MACON_FAKE_UID=501
export MACON_FAKE_UID
assert_eq "sudo pmset -a disablesleep 1" \
    "$(pmset_via_shim plat_pmset_disablesleep 1)" \
    "an unprivileged disablesleep write goes through sudo"
assert_eq "sudo pmset -c sleep 0 disksleep 0" \
    "$(pmset_via_shim plat_pmset_apply_ac sleep 0 disksleep 0)" \
    "an unprivileged timer write goes through sudo"

assert_eq "sudo pmset displaysleepnow" \
    "$(pmset_via_shim plat_display_sleep_now)" \
    "an unprivileged blank goes through sudo"

MACON_FAKE_UID=0
assert_eq "direct displaysleepnow" \
    "$(pmset_via_shim plat_display_sleep_now)" \
    "the root helper blanks the display without ever invoking sudo"
assert_eq "direct -a disablesleep 0" \
    "$(pmset_via_shim plat_pmset_disablesleep 0)" \
    "root's disablesleep write never invokes sudo"
assert_eq "direct -c sleep 1 disksleep 10" \
    "$(pmset_via_shim plat_pmset_apply_ac sleep 1 disksleep 10)" \
    "root's timer write never invokes sudo"
unset MACON_FAKE_UID

teardown_state
