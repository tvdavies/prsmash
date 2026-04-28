# prsmash

Review your GitHub PR queue in parallel with Claude Code.

`prsmash` fetches every PR waiting for your review (via the bundled
`review-queue` Claude Code skill), lets you pick which ones to handle with
`fzf`, and runs `/pr-review` against each in parallel — reporting
approved / changes-requested / commented as they finish.

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
- A `/pr-review` Claude Code skill that accepts `--headless --pr <number>`
  flags. `prsmash` shells out to:

  ```bash
  claude -p "/pr-review --headless --pr <N>" --permission-mode bypassPermissions
  ```

  If your `/pr-review` skill doesn't speak those flags, edit
  `bin/prsmash` accordingly or grab a compatible one from a teammate.

## Install

Clone somewhere persistent, then symlink the two pieces into place:

```bash
git clone https://github.com/tvdavies/prsmash.git ~/src/prsmash
cd ~/src/prsmash

# 1. The CLI
mkdir -p ~/.local/bin
ln -s "$PWD/bin/prsmash" ~/.local/bin/prsmash

# 2. The Claude Code skill
mkdir -p ~/.claude/skills
ln -s "$PWD/skills/review-queue" ~/.claude/skills/review-queue
```

Confirm `~/.local/bin` is on your `PATH`, then `prsmash --dry-run` to test.

(If you'd rather copy than symlink, swap `ln -s` for `cp -r` — you just
won't get updates from `git pull`.)

## Configure your team (for `review-stats`)

`review-stats.sh` needs the GitHub logins of the people whose review
activity you want to track. Two options:

**Env var** (one-off / per-shell):

```bash
export REVIEW_QUEUE_TEAM="alice bob carol"
```

**Config file** (recommended):

```bash
mkdir -p ~/.config/review-queue
cp config/team.example ~/.config/review-queue/team
$EDITOR ~/.config/review-queue/team
```

The default queue and `prsmash` itself don't need this — only
`review-stats.sh` does.

## Usage

```bash
prsmash              # pick PRs via fzf, review the selected ones in parallel
prsmash --all        # review everything in the queue, no prompt
prsmash --dry-run    # list what would be reviewed and exit
```

From inside Claude Code you can also drive the skill directly:

- "what's in my review queue?"
- "what should I review?"
- "review stats today"
- "what did the team review this week?"

## Layout

```
bin/prsmash                                      → ~/.local/bin/prsmash
skills/review-queue/SKILL.md                     → ~/.claude/skills/review-queue/SKILL.md
skills/review-queue/scripts/review-queue.sh      → ditto
skills/review-queue/scripts/review-stats.sh      → ditto
config/team.example                              → ~/.config/review-queue/team
```

## Notes

- Dependabot and Snyk PRs are filtered out of the queue.
- A PR you've already left `CHANGES_REQUESTED` on is re-surfaced as
  "re-review" once the author pushes new commits.
- Retries: each `claude` invocation is retried once on 5xx /
  `overloaded_error` after a 30s backoff.
- Logs for each parallel review live at `/tmp/prsmash-<PR#>.log`.
