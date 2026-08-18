# Security Policy

macon asks for your root password. It installs two LaunchDaemons and runs a
helper as root. That deserves a stated threat model rather than a boilerplate
file.

## What runs as root

| Component | Privilege | What it does |
|---|---|---|
| `macon` | the invoking user | parses flags, validates them, writes the session descriptor, reads state |
| `macon-helper` | root | applies `pmset`, runs the watch loop, samples, restores |
| `local.macon.failsafe` | root, via `launchd` | restores the power configuration at boot |
| `local.macon.helper` | root, via `launchd` | runs `macon-helper watch` for the length of a session, and starts it again if it dies abnormally |

## The helper daemon is permanently loaded

`install.sh` registers `local.macon.helper` and leaves it loaded. It is a
`KeepAlive` job, so `launchd` starts it when it is loaded and restarts it
whenever it dies abnormally — which is the point: a session whose helper is
killed resumes instead of leaving this Mac unable to sleep. Between sessions the
job stays loaded with no process running.

**While it sits there idle, any local account can `launchctl kickstart` it
without a password, and the process starts as root.** That is a real change to
the threat model and it is stated here rather than softened.

What bounds it was measured, not assumed:

- The process `launchd` starts takes no argument an attacker can choose and
  reads nothing supplied from outside: `ProgramArguments` in the plist is fixed
  at `macon-helper watch`, and `watch` works from its own root-owned copy of the
  session descriptor, at `/var/run/macon/session.conf`. With no descriptor there
  it exits 0 having applied nothing. That file is written by root, owned by
  root, mode 0644, inside a root-owned directory an unprivileged user cannot
  create anything in — so a user without a password cannot put one there for it
  to read.
- With a session already running, `kickstart` on a running job is a no-op.
  `kickstart -k`, `bootout` and `bootstrap` all require root. An unprivileged
  user cannot disturb a session in progress.

So on a prefix only root can write to, the exposure this adds is: start a root
process that reads one file and exits.

That bound holds because the program `launchd` starts, and the libraries it
sources, can be replaced only by root. It is a statement about the prefix, not
about the daemon. `install.sh` refuses to install under a prefix whose own
directories — or any directory above them — can be written to by someone other
than root, which is exactly the state Homebrew leaves `/usr/local` in on an
Intel Mac, and `--allow-unsafe-prefix` exists to override that refusal. Under
that override the bound above does not hold: whoever can write above
`<prefix>/libexec/macon` can replace `macon-helper` or anything under its
`lib/`, and then `launchctl kickstart` runs their code as root — with no
password and nothing the user has to do.

That capability is not entirely new. `local.macon.failsafe` has pointed into
the same prefix since 0.1.0 and runs as root at every boot, so an unsafe prefix
already handed root to whoever could write there. What the helper daemon
changes is *when* root arrives: at the next boot before, on demand now. Install
under a prefix only root owns, and the refusal that is the default will keep
you there.

## Design rules

1. **The root code is fixed and installed.** `macon-helper` and `failsafe.sh`
   are ordinary files installed by `install.sh`, owned by root and readable by
   anyone who wants to audit them. Nothing privileged is generated, templated or
   assembled at runtime.
2. **The helper never evaluates content from the session descriptor.** The
   descriptor carries data — numbers, enumerations, absolute paths — and never
   shell fragments. Every field is validated before anything acts on it:
   numbers are numeric, enumerations are in range, paths are absolute.
3. **User-supplied commands always run de-privileged.** `--busy-check` and the
   termination hooks are executed as the invoking user through `sudo -u`, never
   as root. This is also required for correctness: root cannot reach a user's
   tmux socket.
4. **The helper works from its own copy.** The descriptor arrives in a
   user-writable file; the helper validates it, copies it to root-owned storage,
   and afterwards reads only its own copy. The hard ceiling cannot be moved
   after the session has started.

On a single-admin Mac the user already holds sudo, so none of this is a boundary
against that user. What it buys is that a flag-parsing bug cannot become root
code execution, and that a malformed hook cannot run privileged.

## Reporting a vulnerability

Please report privately through GitHub's private vulnerability reporting on this
repository (**Security → Report a vulnerability**). Do not open a public issue
for a security problem.

Include the macOS version (`sw_vers`), the chip
(`sysctl -n machdep.cpu.brand_string`), the exact commands involved, and what an
attacker would gain. Expect an acknowledgement within a week.

## Out of scope

- Anyone who already has root on the machine. macon does not defend against
  that and does not claim to.
- Physical access to an unlocked machine.
- Third-party code under `integrations/`, which `install.sh` never installs.
