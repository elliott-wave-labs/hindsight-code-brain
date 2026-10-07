# AGENTS.md

Instructions for AI coding agents working in this repository.

## What this project is

An operational layer around [Hindsight](https://github.com/vectorize-io/hindsight)
that ingests git diffs and pull request history into a local memory graph and
keeps it current. Read [README.md](README.md) first — the architecture section
is short and the rest of this file assumes it.

## Before you search this repository, query the brain

If the brain is running, it already knows this codebase's history. For any
question shaped like *why is this like this*, *what was tried before*, *when did
this change*, or *who decided it*, call the Hindsight MCP tools before grepping.
Grep finds the current state; the brain knows what was rejected on the way here,
which is usually the answer you actually want.

`skills/hindsight-code-brain/SKILL.md` covers the query patterns.

## Rules that matter here

**Never commit, stage, or push without being asked.** Leave your work unstaged
in the working tree so it can be reviewed as a diff. The git index belongs to
the developer; do not run `git add`, `git reset`, `git stash`, or `git checkout`
of paths.

**Never commit an absolute path or a credential.** Run `./scripts/check-clean.sh`
before you hand work back. The launchd plists carry a `__HOME__` placeholder on
purpose — a plist cannot expand `$HOME`, so the installer substitutes it.

**Verify against the running system, not against your reading of the code.**
This project exists on a machine where things fail in ways the source does not
predict. If a daemon is running, query it. "The code emits X, therefore X is in
the store" is an inference; reading the store is a fact, and where they disagree
the store is right.

**Do not trust an exit code as evidence of work.** This is the single most
expensive lesson in the project's history and it recurred four separate times:
a process exiting zero having done nothing looks exactly like a process exiting
zero having finished. Every completion check here reads what the run *said it
achieved*, never just `$?`. If you add a new one, do the same.

**Edit running scripts atomically.** Write to a temp file and rename over the
original. Bash reads scripts lazily by byte offset; an in-place edit of a
running script makes it resume in the middle of a different line.

**Do not add a `track`-style side effect, a global flag, or a singleton to avoid
passing something through.** Where a caller already owns the lifetime, pass it.

## Platform traps you will hit

These are macOS specific and all of them have cost real time:

- `launchctl kickstart -k` reuses the **cached** job definition. After editing a
  plist you need `bootout` then `bootstrap`, and sometimes `enable` first — a
  `bootout`/`bootstrap` pair can silently leave a job unloaded.
- `launchctl bootstrap` prints `Bootstrap failed: 5: Input/output error` while
  succeeding. Check for the process, not the message.
- launchd-spawned Homebrew Python is denied read access to `~/Documents` by TCC,
  surfacing as `[Errno 1] Operation not permitted`. Keep scripts the agents run
  outside protected directories.
- `zsh` does not word-split unquoted variables. Run loops over space-separated
  lists under `bash -lc`.
- There is no `timeout` command and `pgrep` has no `-c`.
- A `SIGSTOP`ped process is a prime jetsam target under memory pressure.
- `nohup` survives `SIGHUP` but not the process-group teardown an IDE shell does
  on exit. Long-running work belongs under launchd.

## Testing a change

There is no unit test suite; the system is mostly orchestration. What stands in
for one:

```bash
bash -n scripts/*.sh              # syntax
python3 -m compileall -q scripts  # syntax
./scripts/check-clean.sh          # leaks
```

For behavioural changes, exercise the path against a real repository and read
the log it writes. Every script logs to `~/.hindsight/logs/`.
