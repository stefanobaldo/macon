# Security Policy

macon asks for your root password. It installs a LaunchDaemon and runs a helper
as root. That deserves a stated threat model rather than a boilerplate file.

## What runs as root

| Component | Privilege | What it does |
|---|---|---|
| `macon` | the invoking user | parses flags, validates them, writes the session descriptor, reads state |
| `macon-helper` | root | applies `pmset`, runs the watch loop, samples, restores |
| `local.macon.failsafe` | root, via `launchd` | restores the power configuration at boot |

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
