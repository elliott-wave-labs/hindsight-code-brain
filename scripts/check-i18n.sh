#!/usr/bin/env bash
#
# Every locale file must carry the same keys as en.json, with the same argument
# count in each string. A translation that takes a different number of
# arguments than its English original is a runtime bug rather than a typo,
# which is why this is mechanical rather than a review comment.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

python3 - "$PWD/i18n" <<'PY'
import json
import pathlib
import re
import sys

d = pathlib.Path(sys.argv[1])
src = json.loads((d / "en.json").read_text())
expected = {k: v for k, v in src.items() if isinstance(v, str)}


def arity(s):
    idx = re.findall(r"%(\d+)\$s", s)
    if idx:
        return max(int(i) for i in idx)
    return s.count("%s")


fails = 0
for p in sorted(d.glob("*.json")):
    if p.name == "en.json":
        continue
    try:
        other = json.loads(p.read_text())
    except json.JSONDecodeError as e:
        print(f"  {p.name}: invalid JSON — {e}")
        fails += 1
        continue

    missing = [k for k in expected if k not in other]
    extra = [k for k in other if k not in expected and not k.startswith("_")]
    for k in missing:
        print(f"  {p.name}: missing key {k}")
    for k in extra:
        print(f"  {p.name}: unknown key {k} (not in en.json)")
    fails += len(missing) + len(extra)

    for k, en in expected.items():
        tr = other.get(k)
        if isinstance(tr, str) and arity(tr) != arity(en):
            print(f"  {p.name}: {k} takes {arity(tr)} argument(s), English takes {arity(en)}")
            fails += 1

print("  clean" if not fails else f"  {fails} problem(s)")
sys.exit(1 if fails else 0)
PY
