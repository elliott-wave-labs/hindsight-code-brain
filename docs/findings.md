# Findings

Things that went wrong, and what they taught. Each of these cost real hours.

## Contents

- [A clean exit is not evidence of work](#a-clean-exit-is-not-evidence-of-work)
- [`/health` is not a liveness check](#health-is-not-a-liveness-check)
- [A generation probe is the wrong liveness test](#a-generation-probe-is-the-wrong-liveness-test)
- [Merge commits are 31% of the work and produce nothing](#merge-commits-are-31-of-the-work-and-produce-nothing)
- [The diff pass only ever covers the newest 300 commits](#the-diff-pass-only-ever-covers-the-newest-300-commits)
- ["Is dev ahead of main" picks the dead branch](#is-dev-ahead-of-main-picks-the-dead-branch)
- [An open IDE is not a running build](#an-open-ide-is-not-a-running-build)
- [Never ingest from a working tree](#never-ingest-from-a-working-tree)
- [The thing eating your machine may not be your process](#the-thing-eating-your-machine-may-not-be-your-process)

---

## A clean exit is not evidence of work

The most expensive lesson here, and it recurred **four separate times** in
four different disguises. Each time, a process exited zero having accomplished
nothing, which is indistinguishable from exiting zero having finished — and the
completion rule read the exit code.

1. **Nothing left to do.** The honest case, and the one the rule was written
   for.
2. **Lock contention.** The ingest tool takes a per-bank lock, and a second
   runner exits **zero** with "another run holds the lock … nothing to do".
   Thirteen repositories were marked complete in twelve seconds.
3. **Every extraction failed.** The tool returns zero once it has *handed over*
   every commit; extraction happens afterwards, asynchronously. A crashed model
   shows up as `rc=0` with nothing gained. One repository was marked complete
   with 25 of its 4,659 commits ingested.
4. **Extractions never finished.** `extraction drained — 0 done, 0 failed, 50
   still pending at timeout`. Nothing failed; the work was simply slower than
   the 4,500-second window, so the node count had not moved when the pass was
   scored. The same repository stopped at 192 of 300 commits.

Variants 3 and 4 are worse than a crash, because the tool then records the
repository's HEAD as ingested and every subsequent run is a legitimate no-op.
The failure is self-concealing.

**The rule:** read what the run *said it achieved*. Never `$?` alone. And treat
"failed" and "still running" as different conditions — a failure wants backoff,
a timeout wants patience.

## `/health` is not a liveness check

A model server sat at **0% CPU for 31 minutes**, wedged, while passing every
health check. The endpoint is served by the HTTP thread and says nothing about
the decode loop.

What works instead is sampling cumulative process CPU time (`ps -o time=`) and
comparing across intervals, gated on there actually being queued work — with an
empty queue, flat CPU is the correct state, not a wedge. Two consecutive flat
intervals before acting, because a restart kills in-flight work.

The natural place to look would be the server's `/slots` endpoint, but the build
in use returns `null` for `state` and `n_decoded`.

## A generation probe is the wrong liveness test

The obvious fix to the above — send a tiny prompt and see if it answers — is
actively wrong. **The probe occupies a slot.** With the server throttled to two
slots during a build, both are saturated by real work, so the probe queues
behind it and times out against a perfectly healthy server.

Measured: the model answered a manual request in **0.2 seconds** while the
identical probe from the watchdog timed out at **60**. The watchdog then
restarted a healthy server and took the failed-operation count from 83 to 180.

A monitor must not consume the resource it is monitoring.

## Merge commits are 31% of the work and produce nothing

`git show --format= <merge-sha>` prints **nothing**. Git shows no diff for a
merge unless asked with `-m` or `--cc`. So every merge commit costs a full model
extraction and contributes a document whose entire content is
`Merge pull request #769 from ...`.

In one 4,659-commit repository, 1,476 commits — **31%** — were merges. Adding
`--no-merges` to the revision walk removes all of that. And because the ingest
cap is a *count*, skipping merges also means the commits that do get read are
300 real changes instead of roughly 207.

## The diff pass only ever covers the newest 300 commits

`DEEPEN_DIFF_TARGET` is hardcoded to 300 with no environment override, and the
walk is `git rev-list -n 300 HEAD`. This is easy to miss and it invalidates any
estimate built from `rev-list --count HEAD`.

Confirmed empirically: a repository with 3,228 commits had exactly 300 diff
documents. An ETA built on total history was wrong by more than 4×.

## "Is dev ahead of main" picks the dead branch

Choosing an integration branch by asking whether `dev` is ahead of `main` looks
right and is wrong, because **diverged branches are each ahead of the other**.

A real case: `dev` was 12 commits ahead of `main`, so the test picked `dev` —
which had been abandoned eleven months earlier, while `main` carried 98 commits
and was live. The same test is correct for the repository next to it, where
`main` is 4,000 commits stale.

Use the most recent commit date. It is the only signal that does not lie about
an abandoned branch.

## An open IDE is not a running build

The throttle that drops the model from 16 slots to 2 during builds matched
`SWBBuildService` — which Xcode spawns when it opens a project and keeps alive
for the entire session. So it meant "the IDE is open", and the IDE is open
essentially always.

The model ran at 2 slots for twelve hours with zero compiler processes alive, at
roughly 70% of the throughput it could have had. Nothing looked broken: the
profile marker, the plist, and the running process all agreed with each other.
They were consistently wrong, so every consistency check passed.

Match only processes that exist *while compiling* — `swift-frontend` and its
equivalents, not the IDE's long-lived build service.

**The general shape:** when three sources agree and the system still behaves
oddly, check whether they are three views of the same cached assumption rather
than three independent observations.

## Never ingest from a working tree

A working checkout changes branch several times a day, carries rebased and
abandoned commits, and is mid-edit most of the time. Ingesting from it records
history that never happened, and a multi-hour walk can have the ground move
under it halfway through.

Ingest from a clone pinned to the integration branch, which nothing but the
refresher touches — which also makes `git reset --hard` safe there in a way it
never is in a working tree.

## The thing eating your machine may not be your process

The model server was being killed repeatedly by the OS. Every app-level profile
showed it behaving. The actual cause was **17 GB held by two device log
streams** left running from an unrelated debugging session; killing them took
swap from 25.9 GB to 7.6 GB and free memory from 10% to 85%.

When a machine is under pressure but your process profiles as innocent, profile
the **system**, not the process. Per-process attribution is the only thing that
can see a cost you are paying but not performing.
