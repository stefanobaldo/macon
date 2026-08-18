# macon

**macon** — short for *mac overnight*
Keep your Mac working with the lid closed.

Closing the lid is a clamshell event handled by `powerd` and firmware. It ignores
the assertions `caffeinate` takes, so `caffeinate` and terminal multiplexers do not
keep a lidded Mac awake. The setting that does — `pmset -a disablesleep 1` —
persists across reboots, so the hard part is not applying it. It is guaranteeing it
comes back.

macon applies it, watches the night, and restores your original configuration under
every failure mode: normal exit, crash, kill, power loss, and reboot.

## Requirements

- macOS 13 or later
- AC power

| | |
|---|---|
| Verified on | macOS 26.4 (Darwin 25.4), Apple M5 |
| Untested | every other version, and Intel Macs |

Intel Macs are untested rather than unsupported — nothing blocks them, but thermal
readout differs there and nobody has run it. The support table is updated when a
configuration is actually tested, not when it is expected to work.

## Install

    git clone https://github.com/stefanobaldo/macon.git
    cd macon
    sh install.sh

The installer verifies your macOS version and required tools, installs the CLI and
the root helper, and registers two LaunchDaemons: the boot failsafe and the daemon
that supervises the session helper. Run it as yourself, not with
`sudo` — it asks for a password when it needs one, and installing as root would
register the failsafe against root's state directory instead of yours.

## Use

    macon on 8                  # stay awake up to 8 hours, then restore
    macon off                   # restore right now
    macon status                # what is happening
    macon report --out ~/n.html # HTML report of past nights

End the session as soon as the work finishes, instead of waiting out the clock:

    macon run --max 12 -- ./nightly-job.sh        # ends when the process exits
    macon on 8 --sentinel                          # ends when a file appears
    macon on 8 --busy-check 'pgrep -q myjob' \
              --on-expire extend --max 12          # extends while your check says busy

`macon saved` shows the stored snapshot of your original power values, and
`macon log` prints a session's raw samples. `macon failsafe status` reports whether
the boot restore is registered, and `macon version` and `macon help` do what they
look like.

`macon status` leads with the version it is running, so pasting it into a bug
report says which macon produced the rest of the output.

### The screen

Close the lid during a session and the screen goes dark, as it normally would.

This does not happen by itself. Disabling clamshell sleep suppresses the whole
lid-close path, and turning the display off was part of it — so a session would
otherwise leave the panel lit under a shut lid until your `displaysleep` timer
ran out, or for ever if you have it set to Never. macon watches the lid twice a
second and puts the display out when it finds one shut over a lit screen.

**With an external display connected, expect it to be blanked too.** macOS
offers no way to sleep one display and not another, and this case has not been
tested on real hardware — if you work in clamshell mode with an external
monitor, wake it with a keypress and treat this as a rough edge. Nothing about
the session is affected either way: the Mac stays awake, and the screen is
cosmetic.

## How it stays safe

- A **hard ceiling** is evaluated before every other signal, so nothing — not a
  sentinel that never arrives, not a `--busy-check` stuck on "busy" — can hold the
  machine awake indefinitely.
- Losing AC power for two consecutive samples ends the session. Lid closed, sleep
  disabled and no AC is the worst state this tool can produce.
- A **boot failsafe** restores power at startup, because `disablesleep` survives
  reboots. macon refuses to start a session unless `launchd` has actually loaded
  it — a plist sitting on disk is not the same thing as a job that will run.
- The **session helper is supervised by `launchd`**, as a daemon named
  `local.macon.helper` that `install.sh` registers. Kill the helper mid-session and
  `launchd` starts it again; it picks the session back up from its own root-owned
  copy and carries on to the same deadline. Without that, a helper that died left
  the Mac awake until you next ran a macon command — now it restores by itself.
  macon refuses to start a session unless `launchd` has that job loaded, and there
  is no flag to override it. `macon status` reports it, and `sh install.sh` puts it
  back.
- Your original values are snapshotted before anything changes. macOS exposes no
  readable source of power defaults, so that snapshot is the only copy that exists —
  macon refuses to overwrite it with an already-modified state.
- The root helper is fixed, installed code. It never evaluates anything from the
  session; your `--busy-check` and hooks always run as you, never as root.

## Hooks

`--hook-end` runs after the restore, with `MACON_REASON` in its environment naming
why the session ended. It is one of:

| `MACON_REASON` | What happened |
|---|---|
| `done` | a completion source reported the work finished |
| `soft-deadline` | the requested duration ran out |
| `hard-ceiling` | the hard ceiling was reached — this one overrides everything |
| `no-ac` | AC power was lost for the configured number of samples |
| `manual` | you ran `macon off` |
| `orphan` | settings were found applied with no live helper, and healed |
| `reboot` | the machine restarted mid-session; the boot failsafe closed it out |
| `invalid-descriptor` | the session descriptor stopped being readable or valid |
| `descriptor-write-failed` | the descriptor could not be written during the session |

The last two end the session deliberately. A session macon can no longer evaluate
must not go on holding the machine awake, so it is ended rather than trusted.

`--hook-warn` runs `--pre-warn` minutes before the soft deadline. Both hooks run as
you, not as root.

## Closing the lid

Close the lid on a live session and macon says so out loud — an alert tone, then
`Mac on activated, 3 hours remaining`, counted to the hard ceiling. It is the only
confirmation available once the screen is dark, and it repeats every time the lid
is closed again, not once per session.

macon also puts the display out. Disabling clamshell sleep disables the whole
clamshell path, and turning the panel off was part of it, so without this the screen
burns under a shut lid for as long as your `displaysleep` timer takes — or for ever,
where that is `Never`.

Two flags turn the noise down:

| Flag | Effect |
|---|---|
| `--no-announce` | no tone and no speech; terminal output unchanged |
| `--quiet` | implies `--no-announce`, and suppresses macon's own terminal output too |

Neither touches system volume — macon does not change settings it would then have to
restore, and a muted Mac simply stays silent. Neither hides warnings or errors either:
those go to stderr, including the one that reports a restore that did not fully
succeed. Under `macon run`, `--quiet` silences macon and never the command you wrapped.

## Reporting

`macon report` renders a self-contained HTML file — one row per night, with the worst
thermal pressure reached and when. A single night cannot tell you whether closed-lid
operation is thermally sustainable on your machine, or whether moving it to a vertical
stand helped. Thirty nights can.

## Shell completions

`completions/macon.bash` and `completions/_macon` are not installed by `install.sh`.
Source the bash one from your profile, or put the zsh one on your `fpath`:

    . /path/to/macon/completions/macon.bash        # bash
    fpath=(/path/to/macon/completions $fpath)      # zsh, before compinit

## Optional integrations

`integrations/claude-code/` ships a skill that writes the sentinel when an agent
finishes its work, so an interactive session ends the moment the work is done rather
than at the deadline. It is opt-in and installed separately — `install.sh` never
touches it.

## Uninstall

    sh uninstall.sh

It refuses while a session is live or a snapshot is unrestored, rather than removing
the only thing that knows how to put your settings back.

It also stops the helper daemon before it deletes anything, and stops the uninstall
if `launchd` still has the job afterwards — removing the files underneath a loaded
`KeepAlive` job would leave a root daemon respawning a program that is gone, with no
macon left to take it out. It tells you the two commands to run by hand.

## License

MIT. See [LICENSE](LICENSE).
