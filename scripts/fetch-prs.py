#!/usr/bin/env python3
"""
Fetch a repository's pull-request discussion and emit it in the shape
`deepen.js --conversations` expects: [{ id, turns: [{role, text, timestamp}] }].

Why PRs and not issues: a repo whose work is tracked in an external planner has
issues=0, and the review thread is where the reasoning lives anyway. Commit
messages say what changed; PR threads say what was rejected and on whose
objection. Measured on one real repo, PR discussion is ~5x the volume of the
entire commit history.

Why GraphQL and not REST: REST needs one call per PR for comments, another for
reviews, another for review threads. GraphQL returns all of it with the PR, so
a 1,800-PR repo costs ~36 requests instead of ~5,400.

Idempotency: deepen.js dedupes on `chat:<id>`, so re-running is safe and cheap.
The watermark exists to avoid re-FETCHING, not to avoid re-ingesting.

Known limitation: because the id is stable per PR, a PR that gains comments
after it was first ingested is skipped rather than updated. That is the right
trade for merged PRs, which are the bulk and are immutable in practice.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

QUERY = """
query($owner:String!,$name:String!,$n:Int!,$after:String){
  repository(owner:$owner,name:$name){
    pullRequests(first:$n,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}){
      pageInfo{hasNextPage endCursor}
      nodes{
        number title body state createdAt mergedAt closedAt updatedAt
        author{login}
        mergedBy{login}
        additions deletions changedFiles
        baseRefName headRefName
        reviewRequests(first:20){nodes{requestedReviewer{... on User{login}}}}
        reviews(first:50){nodes{state body submittedAt author{login}}}
        comments(first:100){nodes{body createdAt author{login}}}
        reviewThreads(first:50){nodes{isResolved path comments(first:30){nodes{body createdAt author{login}}}}}
      }
    }
  }
}
"""


def login(node):
    """GitHub returns null for deleted accounts and for bots in some shapes."""
    return (node or {}).get("login") or "unknown"


def gh_graphql(owner, name, page_size, after):
    cmd = [
        "gh", "api", "graphql",
        "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"n={page_size}",
        "-f", f"query={QUERY}",
    ]
    if after:
        cmd += ["-F", f"after={after}"]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:400])
    data = json.loads(out.stdout)
    if "errors" in data:
        raise RuntimeError(json.dumps(data["errors"])[:400])
    return data["data"]["repository"]["pullRequests"]


def header_turn(repo, pr):
    """
    Structured fields as literal text.

    deepen.js scopes retainMetadata to the whole file rather than per document,
    so per-PR structured fields cannot ride as real metadata through this path.
    Stating them as plain text instead lets extraction lift them into facts,
    which is what makes "who approved this and when" answerable at all.
    """
    reviewers = [login(r.get("requestedReviewer")) for r in pr["reviewRequests"]["nodes"]]
    approvers = [login(r["author"]) for r in pr["reviews"]["nodes"] if r["state"] == "APPROVED"]
    states = [r["state"] for r in pr["reviews"]["nodes"]]
    unresolved = sum(1 for t in pr["reviewThreads"]["nodes"] if not t["isResolved"])

    lines = [
        f"Pull request #{pr['number']} in {repo}: {pr['title']}",
        f"State: {pr['state']}",
        f"Author: {login(pr['author'])}",
        f"Opened: {pr['createdAt']}",
    ]
    if pr.get("mergedAt"):
        lines.append(f"Merged: {pr['mergedAt']} by {login(pr.get('mergedBy'))}")
    elif pr.get("closedAt"):
        lines.append(f"Closed without merging: {pr['closedAt']}")
    if reviewers:
        lines.append(f"Review requested from: {', '.join(sorted(set(reviewers)))}")
    if approvers:
        lines.append(f"Approved by: {', '.join(sorted(set(approvers)))}")
    if states:
        lines.append(f"Review states: {', '.join(states)}")
    if unresolved:
        lines.append(f"Unresolved review threads at close: {unresolved}")
    lines.append(
        f"Branch: {pr['headRefName']} into {pr['baseRefName']} "
        f"({pr['changedFiles']} files, +{pr['additions']}/-{pr['deletions']})"
    )
    return "\n".join(lines)


def to_conversation(repo, pr):
    turns = [{"role": "user", "text": header_turn(repo, pr), "timestamp": pr["createdAt"]}]

    if (pr.get("body") or "").strip():
        turns.append({
            "role": "user",
            "text": f"{login(pr['author'])} wrote in the PR description:\n\n{pr['body']}",
            "timestamp": pr["createdAt"],
        })

    events = []
    for r in pr["reviews"]["nodes"]:
        if (r.get("body") or "").strip():
            events.append((r["submittedAt"],
                           f"{login(r['author'])} reviewed ({r['state']}):\n\n{r['body']}"))
    for c in pr["comments"]["nodes"]:
        if (c.get("body") or "").strip():
            events.append((c["createdAt"],
                           f"{login(c['author'])} commented:\n\n{c['body']}"))
    for t in pr["reviewThreads"]["nodes"]:
        status = "resolved" if t["isResolved"] else "unresolved"
        for c in t["comments"]["nodes"]:
            if (c.get("body") or "").strip():
                where = f" on {t['path']}" if t.get("path") else ""
                events.append((c["createdAt"],
                               f"{login(c['author'])} commented{where} ({status} thread):\n\n{c['body']}"))

    # Chronological, so the extracted narrative matches how the debate actually
    # unfolded rather than how the API grouped it.
    for ts, text in sorted(events, key=lambda e: e[0] or ""):
        turns.append({"role": "user", "text": text, "timestamp": ts})

    return {"id": f"pr-{repo}-{pr['number']}", "turns": turns}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--owner", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--since", default=None,
                    help="ISO timestamp; stop paging once PRs are older (they are UPDATED_AT desc)")
    ap.add_argument("--page-size", type=int, default=50)
    ap.add_argument("--max-prs", type=int, default=0, help="0 = no limit")
    args = ap.parse_args()

    convos, after, fetched, newest = [], None, 0, None

    while True:
        try:
            page = gh_graphql(args.owner, args.repo, args.page_size, after)
        except Exception as e:
            # GitHub is an optimization here, not a dependency. A failure must
            # leave the git-only ingest intact rather than abort the repo.
            print(f"  pr-fetch failed for {args.repo}: {e}", file=sys.stderr)
            break

        nodes = page["nodes"]
        if not nodes:
            break

        stop = False
        for pr in nodes:
            if newest is None:
                newest = pr["updatedAt"]
            if args.since and pr["updatedAt"] <= args.since:
                stop = True
                break
            convos.append(to_conversation(args.repo, pr))
            fetched += 1
            if args.max_prs and fetched >= args.max_prs:
                stop = True
                break

        if stop or not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]

    Path(args.out).write_text(json.dumps(convos), encoding="utf-8")
    chars = sum(len(t["text"]) for c in convos for t in c["turns"])
    print(f"  {args.repo}: {len(convos)} PRs, {chars} chars -> {args.out}")
    if newest:
        print(f"WATERMARK={newest}")


if __name__ == "__main__":
    main()
