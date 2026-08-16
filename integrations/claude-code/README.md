# macon + Claude Code

An optional skill that lets an agent end a macon session the moment its work is
finished, instead of leaving the Mac awake until the deadline.

`install.sh` in the repository root never touches this directory. Installing it is
a separate, deliberate act:

    sh integrations/claude-code/install.sh

It copies `SKILL.md` into `~/.claude/skills/macon-sentinel/` and does nothing else
— no root, no LaunchDaemon, no change to macon itself.

## How it works

Start the session with a sentinel:

    macon on 8 --sentinel

macon prints the sentinel's path and exports `MACON_SENTINEL` for the session.
When the agent has finished everything it was asked to do, it writes that file,
and macon ends the session at its next poll — restoring your power configuration
and letting the machine sleep.

## The trade-off, stated plainly

**This is a hint, not a control.** An agent can write the sentinel early because
it believes it is finished when it is not, or forget to write it at all. Both
happen.

That is survivable only because the sentinel is the *weakest* signal in the poll
order, and cannot extend anything:

- Written early, you lose the rest of the night's work. Nothing is left in a
  dangerous state — the machine restores and sleeps, which is the safe direction.
- Never written, the session ends at its soft deadline exactly as it would have
  without this integration. You have lost nothing.
- Written by an agent that has gone wrong in some more creative way, the **hard
  ceiling** is still evaluated before every other signal, including this one. No
  file an agent can write extends a session.

So the worst case is a night that ends sooner than you wanted. If that is a bad
trade for your work, do not install this — use `--busy-check` with a predicate
you trust, or just a deadline.

## Uninstall

    rm -rf ~/.claude/skills/macon-sentinel
