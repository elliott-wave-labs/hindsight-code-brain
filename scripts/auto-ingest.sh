#!/usr/bin/env bash
#
# Keep the pinned clones under ~/.hindsight/repos current, and ingest whatever
# arrived on their integration branch since the last run.
#
# This is the "I merged something, the brain should know" path. It deliberately
# watches the integration branch rather than the working checkout: a working
# tree moves branch several times a day, carries rebased and abandoned commits,
# and is mid-edit most of the time, so ingesting from it records history that
# never happened. A merge to dev is the first moment a change is real.
#
# Each repo is pinned to its own branch because there is no single right answer:
# one app repo integrates on dev (its main is ~4,000 commits stale), while
# a service next to it integrates on main (its dev stopped a year ago).
# Pick per repo by most recent commit, never by "is dev ahead of main":
# diverged branches are each ahead of the other, and that test picks the
# dead one whenever a branch was abandoned mid-flight.
#
# Run from launchd on an interval. One pass, then exit — a long-lived loop here
# would hold its own copy of the script across edits and outlive a pause.
#
# --- v2: make this reactive instead of polled --------------------------------
# Polling is the wrong shape for this. A merge is an event the forge already
# knows about, and we are paying a `git fetch` per pinned repo every 15 minutes
# to rediscover it, with up to 15 minutes of staleness in exchange.
#
# The obvious answer — a GitHub Actions workflow on `push` that calls us — does
# not work as stated: a hosted runner cannot reach a laptop behind NAT, and
# opening an inbound path (tunnel, ngrok, port forward) to a machine holding
# the whole org's source is a bad trade for 15 minutes of latency.
#
# A SELF-HOSTED RUNNER on this machine is the version that does work. The
# workflow triggers on `push` to the integration branch, GitHub dispatches to
# the runner over its own outbound long-lived connection — no inbound hole —
# and the job invokes the ingest directly for exactly the repo and sha that
# moved. That removes the fetch-per-interval, removes the staleness window, and
# removes the sha bookkeeping below, because the event carries the sha.
#
# Three things that must survive the move, because they are not incidental:
#   - the refusals above (bulk ingest running, build running, pause marker set,
#     model down). A runner will happily start a job while a diff pass holds
#     the bank lock, and contending for that lock is what produced the
#     "13 repos complete in 12 seconds" bug. The job must decline, not queue.
#   - serialisation. Two pushes a minute apart would be two concurrent jobs;
#     the bank takes one writer. `concurrency:` with no cancel-in-progress.
#   - retry on failure. The sha-only-on-success rule below is what makes a
#     failed pass retry rather than be silently marked done; the workflow needs
#     its own equivalent, since a failed job is not re-delivered.
#
# Keep this script as the fallback either way: it is also the backfill path for
# anything pushed while the machine was asleep, which no event can replay.
set -uo pipefail

REPOS="$HOME/.hindsight/repos"
DEPLOY="$HOME/.hindsight/deployment"
STATE="$DEPLOY/autoingest.state"
LOG="$HOME/.hindsight/logs/auto-ingest.log"
FULL="$DEPLOY/ingest-full.sh"
API="http://127.0.0.1:9077"

say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >>"$LOG"; }

# --- refuse to run rather than contend -------------------------------------
# Every one of these is a case where starting would either fight something for
# the bank lock or spend the machine the developer is trying to use.
# Only the markers that mean "stop doing work on this machine". phase1.paused
# and phase2.paused are deliberately NOT here: those say a bulk backfill is off,
# which is now the permanent state, and treating them as a pause would mean this
# watcher never ran again. `hs pause` always sets llm.paused, so the manual pause
# still reaches us.
for m in llm.paused autoingest.paused; do
  [ -e "$DEPLOY/$m" ] && { say "skip — $m is set"; exit 0; }
done

if pgrep -f 'phase1\.sh|phase2\.sh|ingest-full\.sh|deepen\.js' >/dev/null 2>&1; then
  say "skip — a bulk ingest is already running"
  exit 0
fi

if pgrep -f 'xcodebuild|swift-frontend|xctest' >/dev/null 2>&1; then
  say "skip — a build or test run is using the machine"
  exit 0
fi

curl -s -m 10 "$API/health" >/dev/null 2>&1 || { say "skip — api daemon down"; exit 0; }
curl -s -m 10 http://127.0.0.1:8081/health >/dev/null 2>&1 || { say "skip — model not loaded"; exit 0; }

[ -d "$REPOS" ] || { say "no pinned clones"; exit 0; }
touch "$STATE"

# --- one pass over every pinned clone --------------------------------------
for dir in "$REPOS"/*/; do
  [ -d "$dir/.git" ] || continue
  name="$(basename "$dir")"

  # The branch is whatever the clone is already on. That is set once when the
  # repo is pinned, so the watcher never has to guess an integration branch.
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || { say "$name: detached, skipping"; continue; }

  git -C "$dir" fetch origin "$branch" --quiet 2>/dev/null || { say "$name: fetch failed"; continue; }
  remote_sha="$(git -C "$dir" rev-parse "origin/$branch" 2>/dev/null)"
  [ -n "$remote_sha" ] || { say "$name: no origin/$branch"; continue; }

  last="$(awk -v r="$name" '$1 == r { print $2 }' "$STATE" | tail -1)"
  if [ "$remote_sha" = "$last" ]; then
    continue
  fi

  local_sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  new=$(git -C "$dir" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo "?")
  say "$name: $branch moved to ${remote_sha:0:9} (+$new commits) — ingesting"

  # Nothing but this script writes to the pinned clone, so a hard reset is
  # safe here in a way it never is in a working tree.
  git -C "$dir" reset --hard "origin/$branch" --quiet 2>/dev/null || {
    say "$name: reset failed, leaving at ${local_sha:0:9}"; continue; }

  # ONE pass, never the full 300-commit walk. ingest-full.sh normally loops
  # until two passes in a row add nothing, which is right for a deliberate
  # backfill and wrong here: most pinned repos sit well under the 300-commit
  # diff cap (lib-axon and lib-db-live are at zero), so a single merge into one
  # of them would quietly turn a merge notification into a multi-hour walk of
  # history nobody asked for at that moment.
  #
  # Capping at one pass means a merge costs at most 50 commits. If a merge
  # really did bring more than that, the surplus is picked up by the next
  # merge — the gap closes gradually instead of all at once, and the machine
  # stays usable while you work.
  if bash "$FULL" "$name" 1 >>"$LOG" 2>&1; then
    # Record only on success: a failed pass must be retried next interval, and
    # writing the sha first would mark the work done and never look again.
    grep -v "^$name " "$STATE" >"$STATE.new" 2>/dev/null || true
    printf '%s %s\n' "$name" "$remote_sha" >>"$STATE.new"
    mv "$STATE.new" "$STATE"
    say "$name: ingested through ${remote_sha:0:9}"
  else
    say "$name: ingest failed, will retry next interval"
  fi
done
