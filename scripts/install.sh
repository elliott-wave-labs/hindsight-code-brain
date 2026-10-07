#!/usr/bin/env bash
#
# Install the agents and scripts onto this machine.
#
# The tracked plists carry a __HOME__ placeholder because a launchd plist cannot
# expand $HOME — ProgramArguments are literal strings, so a path has to be
# written in. Substituting at install time is what keeps an absolute path out of
# the repository.
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$HOME/.hindsight/deployment"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/.hindsight/logs"

mkdir -p "$DEPLOY" "$LOGS" "$AGENTS" "$HOME/.hindsight/repos"

echo "installing scripts -> $DEPLOY"
for f in "$SRC"/*.sh "$SRC"/*.py; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in install.sh) continue ;; esac
  install -m 0755 "$f" "$DEPLOY/$(basename "$f")"
  echo "  $(basename "$f")"
done
if [ -d "$SRC/lib" ]; then
  mkdir -p "$DEPLOY/lib"
  for f in "$SRC"/lib/*; do
    install -m 0755 "$f" "$DEPLOY/lib/$(basename "$f")"
    echo "  lib/$(basename "$f")"
  done
fi

echo "installing launch agents -> $AGENTS"
for p in "$SRC"/*.plist; do
  [ -e "$p" ] || continue
  dest="$AGENTS/$(basename "$p")"
  sed "s|__HOME__|$HOME|g" "$p" > "$dest"
  if grep -q '__HOME__' "$dest"; then
    echo "  ERROR: placeholder survived substitution in $(basename "$p")" >&2
    exit 1
  fi
  echo "  $(basename "$p")"
done

if [ ! -f "$DEPLOY/config.env" ]; then
  cat > "$DEPLOY/config.env" <<'EOF'
# hindsight-code-brain configuration.
#
# NOT tracked by git and deliberately outside the clone: it holds the forge
# owner you ingest from and any API token, and neither belongs in a public
# repository.

# Where your working checkouts live. Pinned clones are made from these, so a
# --local clone costs almost nothing.
CLONE_ROOT="$HOME/Documents/GitHub"

# Forge owner (organisation or user) for pull request ingest.
ORG=""

# Optional. gh's own auth is used when this is empty.
# GITHUB_TOKEN=""
EOF
  chmod 600 "$DEPLOY/config.env"
  echo "wrote config template -> $DEPLOY/config.env (set ORG before ingesting PRs)"
fi

cat <<EOF

installed.

  next:
    1. set ORG in $DEPLOY/config.env
    2. start the daemon:   uvx hindsight-embed -p coding-agent daemon start
    3. start the console:  uvx hindsight-embed -p coding-agent ui start
    4. pin a repo:         $SRC/pin-repo.sh <repo-name> [branch]
    5. load the agents:    launchctl bootstrap gui/\$(id -u) $AGENTS/com.hindsight.autoingest.plist

  console: http://localhost:19077
EOF
