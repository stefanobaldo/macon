# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Nothing has been distributed yet. `0.1.0-rc.N` is the code the maintainer runs
overnight while the first release is being qualified in the field; `0.1.0` is
cut when it has been, and is the first version anyone else is meant to install.

## [Unreleased]

### Fixed

- `install.sh` no longer states that sudo will ask for a password. It is the only
  line in the project that promised a prompt, and it is wrong wherever sudo does
  not ask: a `NOPASSWD` rule, a timestamp still warm from an earlier `sudo`, or
  Touch ID configured for sudo, which asks for a fingerprint instead. The rest of
  the project describes the mechanism rather than the prompt, and this line now
  says the prompt *may* appear.
- `macon on` no longer reports that it saved a power snapshot when it did not.
  With a writable directory standing where the snapshot goes, the rename that
  writes it moved the temporary file *into* that directory and reported success,
  so the session armed with no snapshot at all and the CLI said otherwise. The
  power configuration was still safe to leave — the restore clears
  `disablesleep` first and unconditionally, so the Mac kept its ability to
  sleep — but `sleep`, `disksleep` and `powernap` were never put back. A path
  that is not a regular file is now refused before the rename, with the same
  message about ownership the other write failures already had.
- `macon on` no longer stops on an interactive prompt before anything is armed.
  A session armed with `sudo` left the power snapshot in the user's own state
  directory owned by root, and it outlives the session — only `macon off` and
  the boot failsafe consume one, so the ordinary ending leaves it behind. The
  next unprivileged `macon on` renamed over a file it could not write, which
  BSD `mv` asks about whenever it is run from a terminal; declining failed the
  arm, and the refusal said the machine already looked modified, about a machine
  that could sleep and reported no session. The rename no longer asks, and every
  failure path now removes the temporary file it wrote — a declined attempt used
  to leave one behind each time.
- A refused arm now says which refusal it is. Taking the snapshot can fail three
  ways — the machine already looks modified, the current values cannot be read,
  or the snapshot cannot be written — and all three printed the first of those
  messages, sending users to `macon off` for a session that did not exist.

### Changed

- `macon on` and `macon run` refuse to run as root. macon escalates for the
  steps that need it and is meant to be run as yourself. Under `sudo` it
  recorded root as the session owner, so the helper ran the user's own
  `--busy-check` and hooks as root rather than de-privileged, and it left the
  power snapshot in the user's state directory owned by root.
- `macon failsafe install` refuses to run as root, for the reason `install.sh`
  already did: `sudo` discards an exported `MACON_STATE`, so the boot failsafe
  would be registered against the default state directory instead of the
  configured one — and would look for the snapshot in the wrong place at the one
  moment it is the only thing left to restore the machine.

## [0.1.0-rc.2] - 2026-08-19

### Fixed

- The screen no longer stays lit under a closed lid. Disabling clamshell sleep
  suppresses the whole lid-close path, and turning the display off was part of
  it, so a session left the panel burning until the user's `displaysleep` timer
  expired — or indefinitely where that is set to Never. The helper now watches
  the lid twice a second and blanks the display whenever it finds one shut over
  a lit screen. An external display connected in clamshell mode is blanked with
  it; that case is untested on real hardware.
- Killing the session helper no longer strands the Mac awake. The root helper
  now runs under a `launchd` daemon, `local.macon.helper`, registered by
  `install.sh` and set to start the helper again after an abnormal death but not
  after a clean one. Killed mid-session, the helper is started again, reads the
  session back from its own root-owned copy and carries on to the same deadline.
  Before this, a killed helper left the machine unable to sleep with nothing
  watching it, until the next macon command noticed the orphan or the machine
  was rebooted.
- Installing, uninstalling and removing the boot failsafe no longer refuse over
  a power snapshot left behind by a session that ended on its own — which is how
  a session ordinarily ends, since macon takes a fresh snapshot on every arm
  rather than restoring values that were correct for a night already over. One
  session was enough to make the next install or uninstall refuse and send the
  user to `macon off` on a machine holding nothing. They now look at the session
  descriptor, which is on disk from the arm until the session ends, so every
  state the guard exists for is still refused: a live helper, a descriptor left
  by an ending that did not complete, and a Mac still reporting that sleep is
  disabled. The snapshot is kept and never blocks anything — it is the only
  record of the original values, because macOS exposes no readable power
  defaults.
- The power-preference backups no longer grow without bound. One `pmprefs-*`
  directory was created on every arm and nothing ever removed them: 48 of them
  accumulated in three days of use on the verification machine.

### Added

- Closing the lid on a live session now plays an alert tone and speaks
  `Mac on activated, <time> remaining`, counted to the hard ceiling. With the
  screen already dark it is the only confirmation the session is holding. The
  trigger is the lid closing, not the display blanking, so a lid shut over a
  screen that had already timed out still announces.
- `--no-announce` silences that announcement, and `--quiet` implies it while
  also suppressing macon's own terminal output. Warnings and errors are
  unaffected — they go to stderr — and under `macon run` neither flag touches
  the output of the wrapped command.
- `macon status` reports the version it is running, as its first row. The bug
  report template asks for this output, which previously could describe a
  problem without saying which macon had it.
- `macon version` prints the copyright and licence alongside the version.
- `macon status` reports the helper daemon: whether `launchd` has the job,
  whether a process is running, and `launchd`'s own start count. The count is
  printed raw rather than judged — a clean session sits at two, and every
  respawn adds one.
- `macon on` refuses to start a session unless `launchd` has the helper daemon
  loaded, with no flag to override it; re-running `install.sh` registers it
  again. `uninstall.sh` boots the daemon out before it removes the components
  and aborts if `launchd` still has the job, rather than leaving a root job
  respawning a program that is gone.
- `MACON_PMPREFS_KEEP` sets how many `pmprefs-*` backup directories are kept in
  the state directory, newest first; the default is 10. The newest is what a
  by-hand recovery reads, and the older ones matter only if the newest was taken
  after something had already gone wrong. `0` keeps none. A value that is not a
  plain positive number falls back to the default, quietly — this runs in the
  middle of an arm, and a mistyped knob is no reason to abort a session.

## [0.1.0-rc.1] - 2026-08-16

The first complete version. Keeps a Mac awake with the lid closed and restores
the original power configuration under every failure mode it can be put through.

### Added

- `macon on <hours>` — snapshot the current power configuration, disable
  clamshell sleep, and watch the session from a root helper until it ends.
- `macon run --max <hours> -- <cmd>` — the same, ending when the wrapped process
  exits.
- Completion sources that end a session early: a wrapped process, a sentinel
  file (`--sentinel`), and a user-supplied predicate (`--busy-check`).
  `--on-expire extend` extends past the soft deadline while the predicate still
  reports busy, never past the hard ceiling.
- A hard ceiling evaluated before every other signal, so no completion source
  can hold the machine awake indefinitely.
- Session abort after two consecutive samples off AC power.
- A boot failsafe registered as a LaunchDaemon, because `disablesleep` survives
  reboots. It restores at startup and reconstructs the index row for a session
  that ended with the machine.
- `macon off`, `macon status`, `macon saved`, `macon log`,
  `macon failsafe {install,remove,status}`.
- `macon report` — a self-contained HTML report of past nights, with the worst
  thermal pressure reached and when.
- `--hook-end` and `--hook-warn`, run as the invoking user with `MACON_REASON`
  naming why the session ended.
- Orphan detection and healing: settings applied with no live helper are
  reported by `status` and restored by the next `on`.
- `install.sh` and `uninstall.sh`, both refusing to run as root and refusing to
  strand a machine mid-session.
- Shell completions for bash and zsh, and an optional Claude Code integration
  that writes the sentinel when an agent finishes its work. Neither is installed
  by `install.sh`.

### Notes

- Verified on macOS 26.4 (Darwin 25.4), Apple M5. Every other configuration,
  Intel included, is untested rather than unsupported.
- The root helper is fixed, installed code. It never evaluates anything read
  from the session descriptor, and user-supplied commands always run
  de-privileged.
