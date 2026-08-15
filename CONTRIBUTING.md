# Contributing

macon is developed by a single maintainer. Issues and questions are welcome.
Large pull requests will probably be declined for now — open an issue first so
we can talk before you write code.

## Ground rules

- Everything in this repository is written in English.
- Shell is POSIX `sh` only. No bashisms, no zshisms: `/bin/bash` on macOS is
  3.2.57 and targeting it buys nothing POSIX does not already give.
- `sh tests/lint.sh` must pass before you push. It is the whole lint gate, and
  it is exactly what CI runs — including the executables in `bin/` and
  `libexec/`, which carry no extension and which a plain `find -name '*.sh'`
  therefore misses.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`). One commit per coherent
  change.
- Branches mirror the same vocabulary: `feat/<slug>`, `fix/<slug>`,
  `docs/<slug>`, `chore/<slug>`, kebab-case.
- Function-local variables are prefixed `_` and are, in POSIX `sh`, **global
  anyway** — there is no `local`. The rule that keeps that survivable: never
  read a `_temp` after calling another `macon` function that assigns the same
  name. Short names (`_v`, `_p`, `_rc`, `_d`) are shared across modules on
  purpose, so this is a real constraint and not a theoretical one. Note that a
  call inside `$( )` runs in a subshell and cannot clobber the caller — several
  places are safe only because of that, which is worth knowing before you
  "simplify" one of them into a direct call.
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

`sh tests/lint.sh` runs the lint gate. CI pins shellcheck to the version named
in `.github/workflows/ci.yml`; findings are renamed between shellcheck releases
(`SC2317` became `SC2329`), so a much older or newer local shellcheck can
disagree with CI about a file neither of you changed. If a finding appears that
you cannot reproduce, compare `shellcheck --version` with the pinned one first.

`MACON_REAL_TESTS=1 sh tests/real/run.sh` runs the opt-in suite that applies and
restores real settings. It requires macon to be installed, requires AC power, and
will prompt for sudo. It captures a baseline before mutating and fails if the
machine does not return to it.

## Developer Certificate of Origin

Every commit must carry a `Signed-off-by` line (`git commit -s`), certifying the
[Developer Certificate of Origin](https://developercertificate.org/): that you
wrote the change or otherwise have the right to submit it under this project's
license. Pull requests with unsigned commits fail the DCO check.
