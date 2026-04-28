# prsmash

Review your GitHub PR queue in parallel with Claude Code.

`prsmash` fetches every open PR waiting for your review, lets you pick
which ones to handle with `fzf`, and runs `/pr-review` against each in
parallel — reporting approved / changes-requested / commented as they
finish.

```text
prsmash — automated PR review queue

Fetching review queue...
Found 4 PRs in acme/web

Launching 4 reviews in parallel...
  started #4821 — Fix flaky auth test (alice)
  started #4830 — Bump deps (bob)
  ...

[1/4] #4830 Approved              Bump deps (bob) — 1m12s
[2/4] #4821 Changes requested     Fix flaky auth test (alice) — 2m04s
...

Done — 4 reviewed, 0 errored
  3 approved  1 changes requested
```

## Prerequisites

- `bash`, `jq`, `fzf`
- [`gh` CLI](https://cli.github.com/) authenticated (`gh auth status`)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on PATH)
- A `/pr-review` Claude Code skill that accepts `--headless --pr <N>`.
  `prsmash` shells out to:

  ```bash
  claude -p "/pr-review --headless --pr <N>" --permission-mode bypassPermissions
  ```

  You very likely already have one — it's the same skill you'd use to
  review any single PR. If yours doesn't speak those flags, edit the
  `claude -p ...` call in `bin/prsmash` to match.

## Install

```bash
git clone https://github.com/tvdavies/prsmash.git ~/src/prsmash
mkdir -p ~/.local/bin
ln -s ~/src/prsmash/bin/prsmash ~/.local/bin/prsmash
```

`prsmash` resolves `lib/review-queue.sh` relative to its own location
(symlinks included), so nothing else needs configuring. Confirm with:

```bash
prsmash --dry-run
```

## Usage

```bash
prsmash              # pick PRs via fzf, review the selected ones in parallel
prsmash --all        # review everything in the queue, no prompt
prsmash --dry-run    # list what would be reviewed and exit
```

## Layout

```
bin/prsmash          → symlink into ~/.local/bin/
lib/review-queue.sh  resolved automatically by prsmash
```

## Notes

- Dependabot and Snyk PRs are filtered out of the queue.
- A PR you've already left `CHANGES_REQUESTED` on is re-surfaced as
  "re-review" once the author pushes new commits.
- Each `claude` invocation is retried once on 5xx / `overloaded_error`
  after a 30-second backoff.
- Per-review logs live at `/tmp/prsmash-<PR#>.log`.
