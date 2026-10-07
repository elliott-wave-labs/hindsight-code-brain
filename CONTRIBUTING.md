# Contributing

Thanks for considering it. This project is small, opinionated, and written to be
read — most of its value is in the comments explaining why something is the way
it is, so the bar for prose is about the same as the bar for code.

## Before you open a pull request

```bash
./scripts/check-clean.sh    # no absolute paths, no credentials, no private identifiers
bash -n scripts/*.sh        # shell syntax
python3 -m compileall -q scripts
```

`check-clean.sh` also runs in CI. It will fail a change that hardcodes a home
directory, embeds a token, or reintroduces an identifier from the environment
this was originally built in.

## House style

**Comments explain the failure, not the mechanism.** Anyone can read the code
and see what it does. A comment earns its place by recording something the code
cannot show: a constraint, a platform quirk, or a bug that this line exists to
prevent. If you fix something subtle, leave the trap behind in a comment so the
next person does not have to rediscover it.

A good comment here looks like:

```sh
# bootout + bootstrap, never `launchctl load`: a wedged server is still loaded,
# so `load` is a no-op against exactly the failure this is here to clear.
```

Not:

```sh
# restart the server
```

**No magic numbers in new code.** Name the constant, and name it for what it is
rather than what type it is: `DRAIN_SECS`, not `TIMEOUT`.

**Record completion only after it happens.** If you add a state file, a
watermark, or a "done" marker, write it on success and never before. The whole
class of bugs this project kept hitting is work that looked finished because
something recorded it as finished early.

**Shell targets bash 3.2.** That is what macOS ships. No associative arrays, no
`${var^^}`. There is no `timeout` command either, and `pgrep` has no `-c`.

**Edit running scripts atomically.** `bash` reads a script lazily by byte
offset, so editing a file in place while it runs will make it jump into the
middle of a line. Write to a temporary file and `os.replace` / `mv` over it; the
running process keeps the old inode.

## Documentation

`docs/findings.md` is a log of things that went wrong and what they taught. If
you debug something non-obvious, add it there — a failure that cost you two
hours is worth four sentences.

Diagrams are Mermaid, inline in Markdown, so they render on GitHub without a
build step.

## Localization

User-facing strings live in `i18n/`. See [docs/i18n.md](docs/i18n.md). Adding a
language is a file; please do not hardcode English into a script.

## Licence

Contributions are accepted under the [MIT License](LICENSE), with the patent
terms described in [PATENTS.md](PATENTS.md).
