#!/usr/bin/env bash
#
# Fail if the tree carries anything that must not be published: an absolute
# home path, a credential, or a private identifier from the environment this
# was originally built in.
#
# The private-identifier list is NOT in this repository. A denylist naming the
# things you are hiding is itself a disclosure — it tells a reader exactly which
# company, product and people to search for. It lives outside the clone and is
# supplied by path:
#
#   FORBIDDEN_TERMS_FILE=~/.hindsight/deployment/forbidden-terms.txt ./scripts/check-clean.sh
#
# When that file is absent (a fresh clone, or CI) the structural checks below
# still run — those are the ones that matter to everyone, and they are the ones
# that catch a mistake made by someone who never had the private list.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
fails=0

report() { printf '  %s\n' "$*"; fails=$(( fails + 1 )); }

files() {
  git ls-files 2>/dev/null || find . -type f -not -path './.git/*'
}

echo "check-clean: absolute home paths"
# __HOME__ is the deliberate placeholder; a real /Users/<name> or /home/<name>
# is not. Caught structurally rather than by name so it fires for contributors
# whose username nobody has listed anywhere.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if grep -nE '/(Users|home)/[A-Za-z0-9._-]+' "$f" >/dev/null 2>&1; then
    while IFS= read -r hit; do
      report "$f:$hit"
    done < <(grep -nE '/(Users|home)/[A-Za-z0-9._-]+' "$f" | head -5)
  fi
done < <(files)
[ "$fails" -eq 0 ] && echo "  clean"

before=$fails
echo "check-clean: credentials"
# Shapes, not values. A pattern that matched a specific key would only ever
# catch the key already leaked.
CRED='(gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|pa-[A-Za-z0-9_-]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,})'
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if grep -nE "$CRED" "$f" >/dev/null 2>&1; then
    report "$f: credential-shaped string"
  fi
done < <(files)
[ "$fails" -eq "$before" ] && echo "  clean"

before=$fails
echo "check-clean: private identifiers"
TERMS="${FORBIDDEN_TERMS_FILE:-}"
if [ -n "$TERMS" ] && [ -f "$TERMS" ]; then
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      # Skip this script: it would match its own documentation of the check.
      case "$f" in */check-clean.sh) continue ;; esac
      if grep -niE "$pat" "$f" >/dev/null 2>&1; then
        report "$f: matches private pattern"
      fi
    done < <(files)
  done < "$TERMS"
  [ "$fails" -eq "$before" ] && echo "  clean"
else
  echo "  skipped (no FORBIDDEN_TERMS_FILE; structural checks above still ran)"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "FAILED — $fails problem(s)"
  exit 1
fi
echo "PASSED"
