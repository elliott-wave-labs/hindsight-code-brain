#!/usr/bin/env bash
#
# Minimal string lookup. Sourced, not executed.
#
#   . "$(dirname "$0")/lib/i18n.sh"
#   t status.paused
#   t ingest.repo_complete my-app 300
#
# Locale comes from HCB_LOCALE, then LANG, then "en". A key missing from the
# active locale falls back to English rather than printing the raw key, so a
# partial translation degrades to mixed output instead of gibberish.
#
# Deliberately not bash-4: macOS ships bash 3.2, which has no associative
# arrays, so lookups go through python3 rather than an in-memory map. That is
# one interpreter start per string, which is irrelevant at the rate these are
# printed (a handful per run) and not worth a cache that would then go stale
# against an edited locale file.

HCB_I18N_DIR="${HCB_I18N_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/i18n}"

t() {
  local key="$1"; shift
  python3 - "$HCB_I18N_DIR" "${HCB_LOCALE:-${LANG%%.*}}" "$key" "$@" <<'PY'
import json
import pathlib
import re
import sys

d = pathlib.Path(sys.argv[1])
locale = sys.argv[2] or "en"
key = sys.argv[3]
args = sys.argv[4:]


def load(name):
    p = d / f"{name}.json"
    if not p.is_file():
        return {}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError:
        # A malformed translation must not take the caller down; English is
        # still better than a traceback in the middle of an ingest log.
        sys.stderr.write(f"i18n: {p.name} is not valid JSON, ignoring\n")
        return {}


# en first, then the bare language, then the full regional code — later writes
# win, so a regional file overrides a bare one and both override English.
table = {}
for name in ("en", locale.split("-")[0].split("_")[0], locale.replace("_", "-")):
    table.update({k: v for k, v in load(name).items() if isinstance(v, str)})

s = table.get(key)
if s is None:
    # Loud, not silent: an unknown key is a bug in the caller, and printing the
    # key itself is the only output that identifies which caller.
    sys.stderr.write(f"i18n: unknown key {key}\n")
    print(key)
    sys.exit(0)


def fill(template, values):
    """Substitute %1$s / %2$s, falling back to positional %s.

    Explicit indices exist so a translator can reorder arguments; word order
    differs between languages and a string that can only take its arguments in
    English order cannot be translated correctly.
    """
    if re.search(r"%\d+\$s", template):
        def repl(m):
            i = int(m.group(1)) - 1
            return values[i] if 0 <= i < len(values) else m.group(0)
        return re.sub(r"%(\d+)\$s", repl, template)
    if "%s" in template:
        try:
            return template % tuple(values)
        except TypeError:
            # Wrong argument count. Print the template rather than crashing;
            # check-i18n.sh is where this is supposed to be caught.
            sys.stderr.write(f"i18n: {key} expects a different argument count\n")
            return template
    return template


print(fill(s, args))
PY
}
