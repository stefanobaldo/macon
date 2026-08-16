---
name: macon-sentinel
description: Use when working inside a macon session (the MACON_SENTINEL environment variable is set) and you have finished everything that was asked - writes the sentinel file so the Mac can stop staying awake and go back to sleep.
---

# macon sentinel

`macon on --sentinel` keeps this Mac awake with the lid closed and watches for a
file. Writing that file ends the session early: the machine restores its normal
power configuration and sleeps, instead of burning the rest of the night waiting
for a deadline.

## When to write it

Write the sentinel when **all** of these are true:

- `MACON_SENTINEL` is set in your environment. If it is not, there is no macon
  session and there is nothing to do.
- Every task you were asked to do is finished, or has failed in a way that more
  time will not fix.
- Nothing is still running that you intend to check on — no build, no test run,
  no background process whose output you plan to read.
- You are about to stop working and hand back to the human.

## When not to write it

- You are pausing to think, or between steps of a task. Time is not what you are
  short of.
- Something failed and you are about to retry it.
- You are waiting on a long-running command. That is exactly the case the session
  exists to cover.
- You are unsure whether the work is done. Do not write it. Ending late costs
  some idle time; ending early costs the whole remaining job.

## How

    printf 'done\n' > "$MACON_SENTINEL"

That is the entire contract. macon polls for the file, and ends the session at
its next poll — within `--interval` seconds, 300 by default.

Do not delete it, do not write it in advance, and do not write it "to be safe".
The file means *the work is finished*, and it is the only thing you can say that
shortens the night.
