# prsmash

Review your GitHub PR queue in parallel with [pi](https://github.com/earendil-works/pi-coding-agent).

`prsmash` fetches every open PR waiting for your review, lets you pick
which ones to handle with `fzf` (or reviews everything with `--all`),
and runs a `/pr-review` skill against each in parallel — each review in
its own isolated, verified git worktree — reporting approved /
needs-manual-approval / changes-requested as they finish.

```text
prsmash — automated PR review queue

Run logs: ~/.prsmash/runs/20260703-103000-2066728
Source repo: ~/dev/acme/web
Auto-approval limit: PRs must be < 1000 changed lines

Fetching review queue...
Found 4 PRs in acme/web

Launching 4 reviews in parallel...
  started #4821 — Fix flaky auth test (alice)
  started #4830 — Bump deps (bob)
  ...

[1/4] #4830 Approved              Bump deps (bob) — 1m12s
[2/4] #4821 Changes requested     Fix flaky auth test (alice) — 2m04s
[3/4] #4835 Manual approval needed  Rework billing engine (carol) — 4m31s
...

Done — 4 reviewed, 0 errored
  2 approved  1 need manual approval  1 changes requested
  logs: ~/.prsmash/runs/20260703-103000-2066728
```

## How it works

For each selected PR, `prsmash`:

1. Fetches the PR head into `refs/prsmash/<run-id>/pr-<N>` and creates a
   **detached worktree** of your source repo at exactly that commit.
2. **Verifies the context**: worktree `HEAD` must match the GitHub head
   SHA, the worktree must be clean, and `git diff --name-only` must
   match `gh pr diff --name-only` exactly. A mismatch fails the review
   rather than reviewing the wrong code.
3. Runs `pi` inside the worktree with the `pr-review` skill:

   ```bash
   pi --model "$MODEL" --session-dir <run>/sessions/pr-<N> \
      --skill "$PR_REVIEW_SKILL_DIR" \
      -p "/skill:pr-review --headless --pr <N>"
   ```

4. Appends the review that was actually posted to GitHub to the log,
   and cleans up worktrees and temp refs when the run finishes (also on
   Ctrl-C, including the whole child process tree).

Reviews are guarded by locks: one global lock per machine (concurrent
runs exit early) and one lock per PR (a PR already being reviewed by
another run is skipped, not double-reviewed).

## Auto-approval line limit

Large PRs shouldn't be rubber-stamped by an agent. If a PR that would
be approved has **≥ `--approval-line-limit` changed lines** (default
1000), the review is still posted but the run reports **"Manual
approval needed"** instead of approving, and (optionally) sends you a
Slack DM with the PR link and size — deduplicated per head SHA, so you
are only pinged once per pushed state.

The limit is passed to the skill as `PRSMASH_APPROVAL_LINE_LIMIT`; the
skill signals back by printing `PRSMASH_MANUAL_APPROVAL_REQUIRED=true`.

## Prerequisites

- `bash`, `jq`, `fzf`, `flock`, `git`
- [`gh` CLI](https://cli.github.com/) authenticated (`gh auth status`)
- [pi](https://github.com/earendil-works/pi-coding-agent) on PATH
- A `pr-review` skill that accepts `--headless --pr <N>`
- Optional, for Slack notifications: a `slack.sh` helper script plus
  `SLACK_MCP_XOXC_TOKEN` / `SLACK_MCP_XOXD_TOKEN` in the environment

## Install

```bash
git clone https://github.com/tvdavies/prsmash.git ~/src/prsmash
mkdir -p ~/.local/bin
cp ~/src/prsmash/bin/prsmash ~/.local/bin/prsmash
```

Then point it at your setup (env vars, with these defaults):

| Variable | Default | Purpose |
| --- | --- | --- |
| `PRSMASH_SOURCE_REPO` | `~/dev/lleverage-ai/lleverage` | Local clone of the repo whose PRs you review |
| `PR_REVIEW_SKILL_DIR` | `~/agent-skills/skills/pr-review` | The pi `pr-review` skill directory |
| `PRSMASH_QUEUE_SCRIPT` | `~/.claude/skills/review-queue/scripts/review-queue.sh` | Queue script (a copy lives in `lib/review-queue.sh`) |
| `PI_PRSMASH_MODEL` | `anthropic-claude-code/claude-opus-4-7` | Model passed to `pi --model` |
| `PRSMASH_APPROVAL_LINE_LIMIT` | `1000` | Auto-approval size threshold |
| `PRSMASH_LOG_DIR` | `~/.prsmash` | Locks, run logs, notification markers |
| `PRSMASH_SLACK_SCRIPT` | `~/.claude/skills/slack/scripts/slack.sh` | Slack send helper |
| `PRSMASH_SLACK_MANUAL_APPROVAL_NOTIFY` | `true` | Toggle Slack notifications |
| `PRSMASH_SLACK_MANUAL_APPROVAL_TARGET` | `@tom` | DM target (resolved via the helper) |
| `PRSMASH_SLACK_MANUAL_APPROVAL_CHANNEL` | _(unset)_ | Explicit channel ID, skips target resolution |

Confirm with:

```bash
prsmash --dry-run
```

## Usage

```bash
prsmash                          # pick PRs via fzf, review selected in parallel
prsmash --all                    # review everything in the queue, no prompt
prsmash --dry-run                # list what would be reviewed and exit
prsmash --include-implicit      # also surface implicit re-review candidates (manual mode)
prsmash --approval-line-limit 500  # tighten the auto-approval threshold
prsmash --model <provider/model>   # override the pi model
```

### Re-reviews

- A PR you've already reviewed is tagged `[re-review]` when your review
  is explicitly re-requested.
- With `--include-implicit`, PRs you previously reviewed where the
  author has **pushed since your review without re-requesting you** are
  surfaced as `[implicit re-review]`. These are never included in
  `--all` runs — you must select them by hand in `fzf`.

## Run on a schedule (systemd)

`systemd/` contains user units that run `prsmash --all` every 30
minutes:

```bash
cp systemd/prsmash-hourly.* ~/.config/systemd/user/
# edit WorkingDirectory/PATH in the service to match your machine
systemctl --user daemon-reload
systemctl --user enable --now prsmash-hourly.timer
```

A second repository needs its own service/timer names, working directory, log
root, and outer lock so its queue and run state cannot collide with the first.
The included Erys units are staggered two minutes after the Lleverage schedule:

```bash
mkdir -p ~/.prsmash-erys ~/.config/systemd/user
cp systemd/prsmash-erys.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now prsmash-erys.timer
```

The Erys repository's default `CODEOWNERS` rule requests review from Tom when a
pull request becomes ready. Drafts and pull requests without a review request
remain outside scheduled `--all` runs, matching the Lleverage queue semantics.

## Layout

```
bin/prsmash                    the main script
lib/review-queue.sh            builds the PR queue JSON (gh + jq)
systemd/prsmash-hourly.*       primary timer for prsmash --all
systemd/prsmash-erys.*         staggered Erys timer with isolated logs and locks
```

Each run writes to `$PRSMASH_LOG_DIR/runs/<run-id>/` (symlinked from
`$PRSMASH_LOG_DIR/latest`):

```
queue.json               the queue that was fetched
pr-<N>-<repo>.log        full review log + posted GitHub review body
pr-<N>.status            machine-readable outcome
sessions/pr-<N>/         pi session for the review
summary.txt              reviewed/approved/errored counts
```

## Notes

- Your own PRs, Dependabot and Snyk PRs are filtered out of the queue.
- PRs where **someone else** has requested changes are skipped; your own
  `CHANGES_REQUESTED` review re-surfaces the PR once the author pushes.
- Each review is retried once after a 30-second backoff on transient
  API errors (5xx, `overloaded_error`, `api_error`, `rate_limit`,
  service unavailable).
