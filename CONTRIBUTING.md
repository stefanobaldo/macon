# Contributing

macon is developed by a single maintainer. Issues and questions are welcome.
Large pull requests will probably be declined for now — open an issue first so
we can talk before you write code.

## Issues

Open one when you hit something macon got wrong, or when you want it to do
something it does not. There are two templates; pick the one that fits and
delete whatever does not apply — they are a scaffold, not a form.

A report is only as useful as it is reproducible. macon is verified on one
machine, so the version, the chip, the exact command and the output of `macon
status` are what decide whether a problem can be looked into at all. Paste
them rather than describing them.

Anything with a security impact does not go here. macon runs as root; report it
privately through **Security → Report a vulnerability** on this repository, as
`SECURITY.md` describes.

What happens next: the maintainer reproduces it, labels it, and either accepts
it or closes it saying why. An issue that touches the path restoring a Mac's
ability to sleep — the power snapshot, the boot failsafe, the activation
ladder, the poll order — carries the `safety` label and is read before anything
else. Silence is not a verdict; if an issue goes quiet, say so on it.

Not every change needs an issue first. Something found and fixed in the same
sitting can go straight to a pull request. An issue earns its keep when the
work is not happening now — that is what keeps it from being lost.

When a pull request resolves an issue, its body says `Closes #N`, so the issue
closes on merge and the two stay linked in the record.

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
  (rebase merge). Versions are annotated tags on `main`, SemVer.

## Releases

Nothing has been distributed yet. What exists is `0.1.0-rc.N`, the code the
maintainer runs overnight while the first release is qualified against real
nights; `0.1.0` is cut once it has been, and is the first version anyone else is
meant to install. The pre-release identifier is written `rc.1`, with the dot:
SemVer compares dot-separated numeric identifiers numerically, and `rc1` would
be one alphanumeric identifier instead, sorting `rc10` before `rc2`.

`macon status` reports the running version as its first row, and a bug report is
only actionable if it carries one, so the version the CLI reports and the
changelog must agree. `tests/test_docs.sh` enforces that: it reads
`MACON_VERSION` out of `bin/macon` and requires `CHANGELOG.md` to carry a
heading for it. Cutting a version without writing its section fails the suite.

**A tag's message is that version's changelog section, extracted rather than
retyped.** The changelog is already the release notes; a tag written by hand is
a second description of the same release that can drift from the first, and a
tag is public and permanent.

```sh
v=0.1.0-rc.2
{ printf 'macon %s\n\n' "$v"
  awk -v v="$v" '$0 ~ "^## \\["v"\\]" {f=1; next} f && /^## / {exit} f' CHANGELOG.md
} | git tag -a --cleanup=whitespace "v$v" -F -
```

`--cleanup=whitespace` is not optional. `git tag -a` defaults to `--cleanup=strip`,
which drops every line beginning with `#` — that is every Markdown heading in the
section, so the `### Fixed` and `### Added` groupings vanish from the tag with no
warning and no error.

The changelog read is always the one on `main`, and the tag may point at an
older commit than that — `git tag -a ... <commit>`. `main` is what records the
release history; a section can be corrected or renamed after the commit it
describes, and the tag should carry the correction rather than the draft.

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

Everything under `tests/` except `tests/real/` runs against
`tests/fake-platform.sh` and cannot change a power setting. `tests/run.sh` globs
`tests/test_*.sh` only, so it never descends into `tests/real/` — reaching the
mutating suite takes running a different script *and* setting the variable.
Run it when you touch the platform layer, the activation ladder, the boot
failsafe or the snapshot; those are the paths the fake cannot tell you the truth
about. It restores from an `EXIT` trap, so an assertion that fails mid-cycle
still hands the machine back its ability to sleep.

## Developer Certificate of Origin

Every commit must carry a `Signed-off-by` line (`git commit -s`), certifying the
[Developer Certificate of Origin](https://developercertificate.org/): that you
wrote the change or otherwise have the right to submit it under this project's
license. Pull requests with unsigned commits fail the DCO check.
