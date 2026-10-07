#!/usr/bin/env bash
#
# repo-keeper.sh — sync every local clone and feed its git history to Hindsight.
#
# Run by launchd on two triggers (see com.hindsight.repokeeper.plist):
#   WatchPaths    — the clone root changed, so a repo was probably just added
#   StartInterval — periodic, so known repos stay current
#
# Safe to run concurrently with itself (it refuses), on a machine with no
# network (fetches fail soft), and repeatedly (the server deduplicates).

set -uo pipefail

CONFIG="${HINDSIGHT_DEPLOY_CONFIG:-$HOME/.hindsight/deployment/config.env}"
[ -r "$CONFIG" ] || { echo "no config at $CONFIG" >&2; exit 78; }
# shellcheck disable=SC1090
. "$CONFIG"

CLONE_ROOT="${CLONE_ROOT:-$HOME/Documents/GitHub}"
GITLOG_LIMIT="${GITLOG_LIMIT:-300}"
# 9077 is DEFAULT_DAEMON_PORT in the plugin runtime, and the profile is created
# on it. If you change one, change both - the plugin and this script are two
# independent clients of the same daemon.
API_URL="${HINDSIGHT_API_URL:-http://127.0.0.1:9077}"
LOG_DIR="$HOME/.hindsight/logs"
LOCK="$HOME/.hindsight/.keeper.lock"

# Shared per-repo ingest (PR discussion + git history). Resolved relative to
# this script so the repo can live anywhere.
CODE_BRAIN_SCRIPTS="${CODE_BRAIN_SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export CODE_BRAIN_SCRIPTS
. "$CODE_BRAIN_SCRIPTS/lib/ingest-repo.sh"

mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/keeper.log" 2>&1
echo "=== $(date -u +%FT%TZ) keeper start ==="

# --- Mutual exclusion --------------------------------------------------------
# mkdir is atomic on every filesystem we care about. macOS has no flock(1), and
# a PID file has a TOCTOU window this does not.
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than an hour is a crashed run, not a live one.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    echo "stale lock (>60m), reclaiming"
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || { echo "lock race, exiting"; exit 0; }
  else
    echo "another keeper is running, exiting"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# --- Settle ------------------------------------------------------------------
# WatchPaths fires on the first filesystem event, which for `git clone` is an
# empty directory. Waiting lets the clone finish before we look at it.
sleep "${SETTLE_SECONDS:-90}"

# --- Daemon health -----------------------------------------------------------
# No point walking 300 repos to post at a socket that is not listening.
if ! curl -fsS --max-time 10 "$API_URL/health" >/dev/null 2>&1; then
  echo "daemon not responding at $API_URL, exiting"
  exit 0
fi

shopt -s nullglob

skipped=0; synced=0; ingested=0; failed=0

for gitdir in "$CLONE_ROOT"/*/.git "$CLONE_ROOT"/*/*/.git; do
  repo="${gitdir%/.git}"
  name="$(basename "$repo")"

  # Vendored third-party clones we deliberately do not remember.
  for d in $DENY; do
    [ "$name" = "$d" ] && { skipped=$((skipped+1)); continue 2; }
  done

  # A clone still in progress, or a repo with no commits, is not ingestable.
  # Ingesting it truncated would write a partial history the server then
  # considers done, because idempotency keys on the head sha.
  [ -e "$repo/.git/index.lock" ] && { echo "  $name: clone in progress, skip"; skipped=$((skipped+1)); continue; }
  git -C "$repo" rev-parse HEAD >/dev/null 2>&1 || { echo "  $name: no HEAD, skip"; skipped=$((skipped+1)); continue; }

  # --- Sync ------------------------------------------------------------------
  # Never move a branch under a checkout someone is working in. Also never gate
  # ingest on the fetch: GitHub is an optimization here, not a dependency, so a
  # network failure degrades to ingesting the code as it stands on disk.
  case " $SKIP_SYNC " in
    *" $name "*) echo "  $name: sync skipped (worked in locally)" ;;
    *)
      if git -C "$repo" fetch --quiet --prune --tags origin 2>/dev/null; then
        git -C "$repo" merge --ff-only --quiet '@{u}' 2>/dev/null
        synced=$((synced+1))
      else
        echo "  $name: fetch failed, ingesting local state"
      fi
      ;;
  esac

  # --- Ingest ----------------------------------------------------------------
  # PR discussion then git history, via the shared function so this and the
  # tier scripts cannot drift. message mode, not full: measured full-diff
  # ingest is ~70x the cost. The server deduplicates on a gitlog-head:<sha>
  # tag and on chat:<id> for PRs, so an unchanged repo costs one HTTP request
  # rather than a re-extraction.
  if ingest_repo "$repo" "$GITLOG_LIMIT" >>"$LOG_DIR/ingest-$name.log" 2>&1; then
    ingested=$((ingested+1))
  else
    echo "  $name: ingest failed (see ingest-$name.log)"
    failed=$((failed+1))
  fi
done

echo "=== $(date -u +%FT%TZ) done: $ingested ingested, $synced synced, $skipped skipped, $failed failed ==="
