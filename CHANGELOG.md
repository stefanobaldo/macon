# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `macon status` reports the version it is running, as its first row. The bug
  report template asks for this output, which previously could describe a
  problem without saying which macon had it.
- `macon version` prints the copyright and licence alongside the version.

## [0.1.0]

First release. Keeps a Mac awake with the lid closed and restores the original
power configuration under every failure mode it can be put through.

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
