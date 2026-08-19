<!-- If this closes an issue, say so here: Closes #N -->

## What this changes

<!-- What the change does and why it is shaped this way. Written for someone
     reading the repository, not for someone who watched it being made. -->

## Checklist

- [ ] `sh tests/lint.sh` and `sh tests/run.sh` pass.
- [ ] Commits are signed off (`git commit -s`) and follow Conventional Commits.
- [ ] If this touches the power snapshot, the boot failsafe, the activation
      ladder or the poll order, it says below why no failure path can leave a
      Mac unable to sleep — and `MACON_REAL_TESTS=1 sh tests/real/run.sh` was
      run on a machine on AC power.
