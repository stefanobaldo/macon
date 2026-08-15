# Contributing

macon is developed by a single maintainer. Issues and questions are welcome.
Large pull requests will probably be declined for now — open an issue first so
we can talk before you write code.

## Ground rules

- Everything in this repository is written in English.
- Shell is POSIX `sh` only. No bashisms, no zshisms: `/bin/bash` on macOS is
  3.2.57 and targeting it buys nothing POSIX does not already give.
- `shellcheck -s sh -S style` must pass on every script before you push.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`). One commit per coherent
  change.
- Branches mirror the same vocabulary: `feat/<slug>`, `fix/<slug>`,
  `docs/<slug>`, `chore/<slug>`, kebab-case.
- `main` is protected. Changes land by pull request with a linear history
  (rebase merge). Versions are annotated tags on `main`, SemVer `0.x`.

## The safety invariant

macon disables a Mac's ability to sleep. No change may introduce a path that
leaves a machine permanently unable to sleep — not on crash, not on kill, not
on power loss, not on reboot. A pull request that touches the poll order, the
activation ladder, the boot failsafe or the power snapshot will be read against
that invariant before anything else.

## Tests

`sh tests/run.sh` runs the fake-backed suite. It never touches the machine's
power configuration and is what CI runs.

`MACON_REAL_TESTS=1 sh tests/real/run.sh` runs the opt-in suite that applies and
restores real settings. It requires macon to be installed, requires AC power, and
will prompt for sudo. It captures a baseline before mutating and fails if the
machine does not return to it.

## Developer Certificate of Origin

Every commit must carry a `Signed-off-by` line (`git commit -s`), certifying the
[Developer Certificate of Origin](https://developercertificate.org/): that you
wrote the change or otherwise have the right to submit it under this project's
license. Pull requests with unsigned commits fail the DCO check.
