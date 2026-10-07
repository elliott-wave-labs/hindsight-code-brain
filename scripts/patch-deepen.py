#!/usr/bin/env python3
"""Re-apply our local patches to the vendored deepen.js.

deepen.js ships inside @vectorize-io/hindsight-coding-agents, so an npm update
or a reinstall silently reverts anything changed here. Run this after either.
Idempotent: it reports "already applied" rather than double-patching.

PATCH 1 — skip merge commits in the full-diff pass.
    deepen picks commits with `git rev-list -n <target> HEAD`, which includes
    merges. A merge's diff, by the exact command deepen then runs
    (`git show --format= <sha>`), is EMPTY — git shows no diff for a merge
    unless asked with -m/--cc. So every merge costs one full LLM extraction
    and contributes a document whose only content is "Merge pull request
    #769 from ...".

    In one 4,659-commit app repo that is 1,476 of them — 31% of the work,
    producing nothing. Because the cap is a count, skipping merges also means
    the 300 commits that do get deepened are 300 real changes instead of ~207.
"""
import re
import sys
from pathlib import Path

TARGET = Path.home() / ".hindsight/coding-agents/dist/deepen.js"

OLD = '["-C", REPO, "rev-list", `-n`, String(DEEPEN_DIFF_TARGET), "HEAD"]'
NEW = '["-C", REPO, "rev-list", "--no-merges", `-n`, String(DEEPEN_DIFF_TARGET), "HEAD"]'


def main() -> int:
    if not TARGET.exists():
        print(f"not found: {TARGET}", file=sys.stderr)
        return 1

    src = TARGET.read_text()

    if NEW in src:
        print("  patch 1 (--no-merges): already applied")
        return 0

    if OLD not in src:
        print(
            "  patch 1 (--no-merges): ANCHOR NOT FOUND — deepen.js has changed "
            "upstream, re-derive the patch before trusting the diff pass",
            file=sys.stderr,
        )
        return 2

    backup = TARGET.with_suffix(".js.orig")
    if not backup.exists():
        backup.write_text(src)
        print(f"  backed up pristine copy -> {backup.name}")

    TARGET.write_text(src.replace(OLD, NEW, 1))
    print("  patch 1 (--no-merges): applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
