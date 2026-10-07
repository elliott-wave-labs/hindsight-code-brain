---
name: hindsight-code-brain
description: Query the local Hindsight code brain — full commit history and pull-request discussion across every repo in the org, in one connected memory graph. Use BEFORE grepping or reading files to answer "why is it like this / who decided / what was rejected / when did this change", and at the start of any non-trivial task. Also use to record durable findings and to correct memory that turns out to be wrong.
---

# Hindsight code brain

A local Hindsight daemon holding **one shared memory bank** built from every
repository in the org: complete commit messages (subject *and* body, uncapped)
and full pull-request discussion — review threads, approvals, change requests,
who merged, what was rejected and on whose objection.

Because it is one bank rather than one per repo, entities link **across** repo
boundaries. A message defined in a schema repo and consumed in three services
is one node, not four disconnected ones. That is the whole point: it answers
questions no single checkout can.

Everything runs on this machine. The daemon, the database and the extraction
model are local.

## What is in it, and what is not

**In:** commit messages across all repos and all history; PR titles, bodies,
review comments, inline review threads, approval and change-request states,
open/merge/close timestamps and authorship.

**Not in:** source files. It has never seen a function body. It knows a change
was made, argued about and merged — not what line 40 currently says.

That boundary decides tool choice. "Why does this retry three times" is a
memory question. "What does this function do" is a read-the-file question.
Asking memory to recite code produces confident paraphrase of a commit message
describing code that has since changed.

## Choose the right tool

| You need | Call | Cost |
|---|---|---|
| What the project already knows: architecture, conventions, decisions | `hindsight_search_knowledge_pages` | fast |
| The full text of a page a search surfaced | `hindsight_read_knowledge_page` | fast |
| An inventory of what exists before you start | `hindsight_list_knowledge_pages` | fast |
| **Why** something behaves this way; the decision and its literal values | `hindsight_reflect` | seconds — it reasons over the whole bank |
| Save a durable finding, or correct a wrong memory | `hindsight_ingest_document` | fast |
| Register a new feature/initiative so later sessions find it | `hindsight_capture_initiative` | fast |
| Memory looks stale or empty | `hindsight_sync_status` | fast |
| Tools or config look broken | `hindsight_diagnose` | fast |

**Search pages first, reflect second.** Pages are curated summaries and answer
most questions immediately. `reflect` runs an agentic synthesis over the entire
bank and is markedly slower — reach for it when pages are too shallow and you
need the root cause or the exact decided value.

Do not open with `reflect` on a vague question. It reasons over what you gave
it, so "why is the player slow" returns a survey. Ask the narrow question you
actually want answered.

## Scoping to one repository

Every fact carries a `repo:<name>` tag recording where it came from, even
though all repos share a bank.

**The MCP tools take a query string and nothing else — there is no tag
parameter.** Scope by naming the repo in the query itself ("in the auth
service, why…"). The fact text and its source document carry the repo name, so
this genuinely narrows retrieval; it is not a hint being ignored.

For hard tag filtering, use the CLI or the control-plane UI, not MCP:

```bash
hindsight tag list <bank>
hindsight memory recall <bank> "<query>" --tags repo:<name>
```

## Writing back

Unlike a read-only index, this memory improves when you use it.

**Record durable findings** with `hindsight_ingest_document` — design notes,
research, anything you want future sessions to know. Not the current
conversation; that is captured automatically at session end.

**Correct wrong memory the moment you catch it.** This is the mechanism, and
skipping it lets a stale fact keep being served:

> Ingest a document titled `Correction: <topic>` stating what memory claimed,
> what is actually true, and the evidence. The newer fact supersedes the stale
> one in future retrieval.

**Register initiatives** with `hindsight_capture_initiative` after a plan is
approved and *before* writing code. Call it again with `relates_to_page_id`
when scope or rationale materially changes — never mint a second page for the
same initiative. Bug fixes, refactors and chores are not initiatives.

## Crediting is mandatory

If anything retrieved reaches your reply — quoted, paraphrased, or merely
confirming what you were already going to say — open that part with:

```
> 🧠 **From Hindsight memory** — <the specific facts you drew on>
```

Rewriting a snippet in your own words does not make it yours. If results do not
bear on the turn, ignore them silently; an unhelpful search needs no mention.

## Reading results honestly

Facts are **leads carrying provenance**, not conclusions. Each traces to a
commit or a PR thread. Verify against the checkout before acting, and cite the
file you actually read rather than the memory that pointed at it.

Calibration that matters:

- **Memory is historical.** A decision recorded two years ago may have been
  reversed by a commit nobody described well. Recency in the result is not
  recency in the code.
- **A PR argument is not a conclusion.** Review threads contain rejected
  proposals stated confidently. Check whether the thing being argued for
  actually merged.
- **Absence is not evidence.** Nothing retrieved means nothing was *indexed* —
  say it that way, never "this was never discussed".
- **Never fill a gap from your own priors.** An unanswered question stays
  unanswered.

## When it is not working

`hindsight_sync_status` reports whether the bank is queryable and whether
extraction is still running. Ingestion is automatic and background: `synced:
false` means in progress, not broken — there is nothing to run.

`hindsight_diagnose` returns the resolved bank, workspace, harness, config
location and API endpoint. Use it when tools resolve but return nothing, which
usually means the session resolved to a different bank than you expect.

Extraction is done by a local model and is slow by design — a large repo's
first ingest takes hours. Queries stay fast throughout; they do not wait on it.
