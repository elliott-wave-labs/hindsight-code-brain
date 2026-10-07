#!/usr/bin/env bash
#
# Full-fidelity ingest for one repo: commit messages AND per-commit diffs.
#
# Commit messages alone are not trustworthy history here — a large share of the
# older ones say little more than "WIP" — so the diff is the actual signal.
# `--git-ingest full` pairs each commit with its diff and the extractor binds
# the result to concrete code entities (classes, functions), which is what
# makes "what does this module do" answerable at all.
#
# deepen deepens at most DIFF_BATCH = 50 commits per invocation (hardcoded, not
# an env knob), and skips commits it has already deepened. So the loop below is
# the unit of progress: run again and again until a pass stops adding work.
set -uo pipefail

REPO_NAME="${1:?usage: ingest-full.sh <repo-name> [max_passes]}"
MAX_PASSES="${2:-500}"

# A pinned clone under ~/.hindsight/repos wins over the working checkout: the
# ingest walks whatever HEAD points at, and a working tree moves branch far
# more often than a multi-hour diff pass takes to finish.
if [ -d "$HOME/.hindsight/repos/$REPO_NAME/.git" ]; then
  REPO="$HOME/.hindsight/repos/$REPO_NAME"
else
  REPO="$HOME/Documents/GitHub/$REPO_NAME"
fi
DEEPEN="$HOME/.hindsight/coding-agents/dist/deepen.js"

# node is installed via nvm, which is a shell function and puts the binary in a
# version-stamped directory that launchd's PATH never contains. Resolve it here
# and fail loudly: when this was left to PATH, every deepen exited 127 and the
# loop below read "no new memories" as "repo finished", silently marking 14
# repos complete without ingesting a single commit.
NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  NODE="$(ls -1d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1)"
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  echo "FATAL: node not found (PATH=$PATH)" >&2
  exit 127
fi
API="http://127.0.0.1:9077"
BANK_ENC='coding-agent%3A%3Acodebase'
LOG="$HOME/.hindsight/logs/full-$REPO_NAME.log"

[ -d "$REPO/.git" ] || { echo "no such repo: $REPO"; exit 1; }

export API_URL="$API"
# One shared bank, so this tag is the only thing that keeps a fact traceable
# back to the repo it came from.
export HINDSIGHT_RETAIN_TAGS="repo:$REPO_NAME"

total_commits=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)
say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "$LOG"; }

nodes() {
  curl -s -m 20 "$API/v1/default/banks/$BANK_ENC/stats" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["total_nodes"])
except Exception: print(0)'
}

say "=== full ingest $REPO_NAME ($total_commits commits, diff batch 50) ==="
run_start=$(date +%s)

for pass in $(seq 1 "$MAX_PASSES"); do
  before=$(nodes); t0=$(date +%s)

  marker="$(wc -c <"$LOG")"
  "$NODE" "$DEEPEN" --repo "$REPO" --harness cursor-cli --api-url "$API" \
    --git-ingest full --gitlog-limit 1000000 >>"$LOG" 2>&1
  rc=$?

  after=$(nodes); took=$(( $(date +%s) - t0 ))
  gained=$(( after - before ))

  say "pass $pass: +$gained memories in ${took}s (total $after, rc=$rc)"

  # deepen takes a per-bank lock and a second runner exits ZERO with
  # "another run holds the lock … nothing to do". That is the most dangerous
  # shape available: a clean exit that did no work. It read as "this pass
  # added nothing", which read as "repo finished", and phase1 marked 13 repos
  # complete in 12 seconds while another ingest held the lock. Checked before rc, and
  # deliberately not counted as a failure, because waiting is the correct
  # response to contention.
  if tail -c "+$(( marker + 1 ))" "$LOG" | grep -q 'holds the lock'; then
    say "  bank lock held by another run — waiting 120s (not progress, not failure)"
    sleep 120
    continue
  fi

  # A FAILED pass is not a finished repo. Keeping these two apart is the whole
  # point: when deepen could not start at all (rc=127, node missing) every pass
  # "gained" nothing, which read as completion and marked the repo done.
  if [ "$rc" -ne 0 ]; then
    fails=$(( ${fails:-0} + 1 ))
    if [ "$fails" -ge 3 ]; then
      say "=== $REPO_NAME ABORTED: 3 consecutive failures (last rc=$rc) ==="
      exit 1
    fi
    say "  pass failed (rc=$rc), retry $fails/3 after backoff"
    sleep $(( fails * 30 ))
    continue
  fi
  fails=0

  # A pass whose extractions FAILED is not a clean pass, however cleanly deepen
  # exited. deepen returns 0 once it has handed every commit to the API; the
  # extraction that turns a diff into facts happens afterwards and asynchronously,
  # so a crashed model shows up here as rc=0 with nothing gained — which is
  # indistinguishable from "already done" unless you read the drain line.
  #
  # This shipped: llama-server died twice during one large repo, every one
  # of the 100 commits it had handed over failed with APIConnectionError, both
  # passes gained nothing, and the repo was marked complete with 25 of its 4,659
  # commits ingested. The gitlog skip then made the next run a no-op too.
  drained_failed=$(tail -c "+$(( marker + 1 ))" "$LOG" \
    | sed -n 's/.*extraction drained — [0-9]* done, \([0-9]*\) failed.*/\1/p' | tail -1)
  drained_failed="${drained_failed:-0}"

  # ... and a pass whose extractions never FINISHED is not a clean pass either.
  # deepen gives the queue 4,500 s and then gives up waiting:
  #
  #     [wait] extraction drained — 0 done, 0 failed, 50 still pending at timeout
  #
  # Nothing failed there. The work was simply slower than the window, so the
  # node count had not moved by the time the pass was scored — which is the
  # completion condition. That same large repo stopped at 192 of its 300 commits
  # exactly this way: passes 6 and 7 each enqueued 50 commits, neither drained,
  # both scored zero, and the repo was called complete.
  #
  # Checked separately from failures because the response differs: a failure
  # wants backoff, a timeout wants the loop to come round again and let the
  # queue catch up.
  drained_pending=$(tail -c "+$(( marker + 1 ))" "$LOG" \
    | sed -n 's/.*extraction drained — .*, \([0-9]*\) still pending at timeout.*/\1/p' | tail -1)
  drained_pending="${drained_pending:-0}"

  if [ "$drained_pending" -gt 0 ] && [ "$drained_failed" -eq 0 ]; then
    slow=$(( ${slow:-0} + 1 ))
    say "  $drained_pending extractions still running at drain timeout — not counting it as clean ($slow/20)"
    if [ "$slow" -ge 20 ]; then
      say "=== $REPO_NAME ABORTED: 20 consecutive passes that never drained ==="
      exit 1
    fi
    quiet=0
    # Let the server-side queue drain rather than piling another 50 on top.
    sleep 300
    continue
  fi
  slow=0

  if [ "$drained_failed" -gt 0 ]; then
    degraded=$(( ${degraded:-0} + 1 ))
    say "  $drained_failed extractions failed this pass — not counting it as clean ($degraded/10)"
    # Bounded, so a handful of commits that can never extract cannot spin here
    # forever. Ten consecutive degraded passes means something is broken that
    # retrying will not fix.
    if [ "$degraded" -ge 10 ]; then
      say "=== $REPO_NAME ABORTED: 10 consecutive passes with failed extractions ==="
      exit 1
    fi
    quiet=0
    # Give the model room to come back before handing it another 50 commits.
    sleep 60
    continue
  fi
  degraded=0

  # Only a SUCCESSFUL pass that adds nothing means every commit already carries
  # its diff. Two in a row, to ride out one empty-but-healthy pass.
  if [ "$gained" -le 0 ]; then
    if [ "${quiet:-0}" -eq 1 ]; then
      say "=== $REPO_NAME complete: no new memories across two clean passes ==="
      break
    fi
    quiet=1
  else
    quiet=0
  fi
done

say "=== $REPO_NAME finished in $(( $(date +%s) - run_start ))s ==="
