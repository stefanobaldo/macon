---
name: macon-sentinel
description: Use when you are about to finish and hand back to the human, on a Mac that may be held awake by macon - runs `macon done` so the machine can restore its power configuration and sleep instead of staying awake until a deadline.
---

# macon sentinel

macon can hold this Mac awake with the lid closed, for a bounded session. When
the work is finished, `macon done` says so and the machine restores and sleeps
instead of burning the rest of the night waiting for a deadline.

You do not need to know whether a session is armed. `macon done` refuses
harmlessly when none is, so running it costs one line of output.

## When to run it

Run `macon done` when **all** of these are true:

- Every task you were asked to do is finished, or has failed in a way that more
  time will not fix.
- Nothing is still running that you intend to check on -- no build, no test run,
  no background process whose output you plan to read.
- You are about to stop working and hand back to the human.

## When not to run it

- You are pausing to think, or between steps of a task. Time is not what you are
  short of.
- Something failed and you are about to retry it.
- You are waiting on a long-running command. That is exactly the case the
  session exists to cover.
- You are unsure whether the work is done. Do not run it. Ending late costs some
  idle time; ending early costs the whole remaining job.

## It is your last real act

Everything durable happens **before** `macon done`:

- Write any handoff **to a file**, not only to the terminal.
- Make the commits and the pushes.
- Produce whatever report was asked for.

After it, only your closing message to the human.

`macon done` waits about two minutes before the machine can sleep, which covers
your closing message. It does not cover a `git push`. Use `--grace <seconds>` if
you need longer, or `--grace 0` if you are certain nothing is left.

## The trade-off, stated plainly

**This is a hint, not a control.** You can run it early because you believe you
are finished when you are not, or forget to run it at all. Both happen.

That is survivable only because this is the weakest signal macon has, and it
cannot extend anything:

- Run early, you lose the rest of the night's work. Nothing is left in a
  dangerous state -- the machine restores and sleeps, which is the safe
  direction.
- Never run, the session ends at its deadline exactly as it would have without
  you. Nothing is lost.
- The **hard ceiling** is evaluated before every other signal, including this
  one. Nothing you can do extends a session.
