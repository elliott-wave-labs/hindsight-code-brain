#!/usr/bin/env bash
#
# Walk the history of each repo named in backfill.queue, one at a time, under
# launchd so the run survives the shell that started it. nohup was not enough:
# it protects against SIGHUP but not the process-group teardown an IDE shell
# does on exit, which killed the first Android run twenty seconds in.
#
# This is the exception path. The routine path is auto-ingest.sh, which takes
# new merges on the pinned clones a single pass at a time; the org-wide backfill
# phases are retired behind phase1.disabled. A repo lands here only when it
# needs its history walked once — newly pinned, or left short by a bug.
#
# The queue is a text file rather than plist arguments because a plist edit
# needs bootout+bootstrap to take effect (launchd caches the job definition and
# `kickstart -k` reuses the cached one), while a text file is just a text file.
set -uo pipefail

DEPLOY="$HOME/.hindsight/deployment"
QUEUE="$DEPLOY/backfill.queue"
LOG="$HOME/.hindsight/logs/backfill.log"

say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "$LOG"; }

# Drain the queue in order. Re-read it every iteration so a name appended while
# a long repo is running is picked up in the same invocation.
while :; do
  for m in llm.paused backfill.paused; do
    [ -e "$DEPLOY/$m" ] && { say "stopping — $m is set"; exit 0; }
  done

  [ -s "$QUEUE" ] || { say "queue empty — done"; exit 0; }
  REPO_NAME="$(head -1 "$QUEUE" | tr -d ' \n')"
  [ -n "$REPO_NAME" ] || { tail -n +2 "$QUEUE" > "$QUEUE.new"; mv "$QUEUE.new" "$QUEUE"; continue; }

  say "=== backfill $REPO_NAME (queue: $(wc -l < "$QUEUE" | tr -d ' ')) ==="
  bash "$DEPLOY/ingest-full.sh" "$REPO_NAME"
  rc=$?
  say "=== backfill $REPO_NAME exited rc=$rc ==="

  if [ "$rc" -eq 0 ]; then
    # Pop only on success. A failed repo stays at the head so the next load
    # retries it — the same rule auto-ingest.sh uses for its sha watermark, and
    # for the same reason: recording completion before it happened is how work
    # gets silently skipped.
    tail -n +2 "$QUEUE" > "$QUEUE.new" && mv "$QUEUE.new" "$QUEUE"
  else
    say "leaving $REPO_NAME at the head of the queue for the next run"
    exit "$rc"
  fi
done
