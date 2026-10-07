#!/usr/bin/env bash
#
# Pin a repo for automatic ingest: make a clone under ~/.hindsight/repos on the
# branch that repo actually integrates on, so auto-ingest.sh picks it up.
#
#   pin-repo.sh my-app dev
#   pin-repo.sh my-service                    # branch defaults to the remote HEAD
#
# The clone is --local, so it hardlinks the object store of the checkout you
# already have: a 700 MB repo costs almost nothing and no network round trip.
# Its remote is repointed at the origin URL so later refreshes do not depend on
# the working tree being in any particular state.
set -euo pipefail

NAME="${1:?usage: pin-repo.sh <repo-name> [branch]}"
BRANCH="${2:-}"
SRC="$HOME/Documents/GitHub/$NAME"
DST="$HOME/.hindsight/repos/$NAME"

[ -d "$SRC/.git" ] || { echo "no checkout at $SRC" >&2; exit 1; }

mkdir -p "$HOME/.hindsight/repos"

if [ ! -d "$DST/.git" ]; then
  git clone --local --no-checkout "$SRC" "$DST"
  git -C "$DST" remote set-url origin "$(git -C "$SRC" remote get-url origin)"
fi

if [ -z "$BRANCH" ]; then
  BRANCH="$(git -C "$DST" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  BRANCH="${BRANCH:-main}"
fi

git -C "$DST" fetch origin "$BRANCH"
git -C "$DST" checkout -B "$BRANCH" "origin/$BRANCH"

echo
echo "pinned $NAME"
echo "  path:    $DST"
echo "  branch:  $BRANCH"
echo "  head:    $(git -C "$DST" log -1 --format='%h %ad %s' --date=short | cut -c1-72)"
echo "  commits: $(git -C "$DST" rev-list --count HEAD)"
echo
echo "auto-ingest.sh will pick it up on its next pass."
