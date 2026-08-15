# macon

**macon** — short for *mac overnight*

Keeps a Mac awake with the lid closed, on AC power, for a bounded period, and
guarantees the power configuration returns to its original values afterwards —
under normal exit, crash, kill, power loss and reboot. Closing the lid is a
clamshell event handled by `powerd`; it ignores the assertions `caffeinate`
takes, so the only mechanism that works is one that persists across reboots.
Reverting it reliably is the hard part of the problem, and the reason this
project exists.

**Status: under development.** Nothing here is installable yet.

## License

MIT — see [LICENSE](LICENSE).
