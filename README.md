# prsmash

Review your GitHub PR queue in parallel with [pi](https://github.com/earendil-works/pi-coding-agent).

`prsmash` fetches every open PR waiting for your review, lets you pick
which ones to handle with `fzf` (or reviews everything with `--all`),
and runs a `/pr-review` skill against each in parallel — each review in
its own isolated, verified git worktree — reporting approved /
awaiting-your-approval / changes-requested as they finish.

```text
prsmash — automated PR review queue

Run logs: ~/.prsmash/runs/20260703-103000-2066728
Source repo: ~/dev/acme/web
Auto-approve authors: bob,dave

Fetching review queue...
Found 4 PRs in acme/web

Launching 4 reviews in parallel...
  started #4821 — Fix flaky auth test (alice)
  started #4830 — Bump deps (bob)
  ...

[1/4] #4830 Approved                          Bump deps (bob) — 1m12s
[2/4] #4821 Changes requested                 Fix flaky auth test (alice) — 2m04s
[3/4] #4835 Review posted, awaiting your approval  Rework billing engine (carol) — 4m31s
...

Done — 4 reviewed, 0 errored
  2 approved  1 changes requested
  1 awaiting your approval — review posted, approval left to you
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

## Trusted authors

Not every PR should be rubber-stamped by an agent, so approval is
gated on who wrote the PR. `PRSMASH_TRUSTED_AUTHORS` (default
`jaythegeek,corixdean,gsasu,beddial`) is a comma or space separated
list of GitHub logins, matched case-insensitively:

- **On the list** — the review is submitted as a real GitHub
  **approval**, exactly as before.
- **Not on the list** — the identical review is posted as a
  **comment**, carrying its `Approved` verdict plus a banner
  explaining that a human makes the approval call. The run reports
  **"Review posted, awaiting your approval"** and sends you a Slack DM
  with the PR link.

Set the list to an empty string to turn the gate off and approve every
eligible PR.

Only the approval is gated. `REQUEST_CHANGES` and plain comment
reviews are posted normally whoever the author is, and the gate never
turns a pass into a fail — an ungated PR gets the same verdict, just
without the green tick.

Reviews posted as issue comments, including manual-gated reviews, are
deduplicated per PR head SHA. Once an exact head has passed automated review,
scheduled runs skip it rather than repeatedly reviewing code GitHub still shows
as review-requested. A pushed commit has a new SHA and is reviewed normally.

## Approving from Slack

React to that DM and the next run applies your decision — 👍 approves
the PR, 👎 drops it. There is no separate poller: every run checks
pending approvals before it does anything else, including runs that
find an empty queue, so a reaction is picked up within a tick.

```text
Checking 2 pending approval(s) for Slack reactions...
  Approved #5973 on your Slack reaction
  #5981 left unapproved on your reaction
```

Each decision is applied exactly once. A pending approval is a JSON
record in `pending-approvals/`; acting on it moves the record to
`processed-approvals/` with its outcome, so the same reaction is never
replayed. The reviewed head is recorded independently in
`review-dispositions/`, so a missing or unavailable Slack integration cannot
cause the expensive automated review to run again. Three further guards sit
behind that:

- A dedicated lock, so overlapping runs never race the same record.
- The approval is refused if the PR head has moved since the review —
  approving would be signing off code nobody read. prsmash reviews the
  new head and asks again.
- Before approving, it checks GitHub for an existing approval from you
  at that exact commit, so even a crash mid-flight cannot double-approve.

Anything that fails transiently (GitHub unreachable, Slack unreadable)
is left pending and retried on the next run rather than dropped.

Only reactions from the Slack account the tokens belong to count;
`PRSMASH_SLACK_APPROVAL_USER` overrides whose reaction is trusted,
which matters if you point the DMs at a shared channel. A 👎 alongside
a 👍 is treated as a 👎, so changing your mind fails safe. Unanswered
approvals are dropped after `PRSMASH_APPROVAL_PENDING_TTL_DAYS`
(default 14).

The list is passed to the skill as `PRSMASH_TRUSTED_AUTHORS`; the
skill signals a downgrade back by printing
`PRSMASH_MANUAL_APPROVAL_REQUIRED=true` and
`PRSMASH_MANUAL_APPROVAL_REASON_CODE=untrusted-author`.

`PRSMASH_APPROVAL_LINE_LIMIT` is a second, independent downgrade rule
supported by the skill (reason code `approval-line-limit`). `prsmash`
deliberately leaves it unset, so size alone never blocks an approval.

## Prerequisites

- `bash`, `jq`, `fzf`, `flock`, `git`
- [`gh` CLI](https://cli.github.com/) authenticated (`gh auth status`)
- [pi](https://github.com/earendil-works/pi-coding-agent) on PATH
- A `pr-review` skill that accepts `--headless --pr <N>`
- Optional, for Slack notifications and reaction approvals: a `slack.sh`
  helper supporting `resolve`, `send`, `profile` and `reactions`, plus
  `SLACK_MCP_XOXC_TOKEN` / `SLACK_MCP_XOXD_TOKEN` in the environment.
  Without it, reviews for untrusted authors are still posted as
  comments — you just have to approve them on GitHub yourself.

## Install

```bash
git clone https://github.com/tvdavies/prsmash.git ~/src/prsmash
mkdir -p ~/.local/bin
ln -sf ~/src/prsmash/bin/prsmash ~/.local/bin/prsmash
```

Then point it at your setup (env vars, with these defaults):

| Variable | Default | Purpose |
| --- | --- | --- |
| `PRSMASH_SOURCE_REPO` | `~/dev/lleverage-ai/lleverage` | Local clone of the repo whose PRs you review |
| `PR_REVIEW_SKILL_DIR` | `~/agent-skills/skills/pr-review` | The pi `pr-review` skill directory |
| `PRSMASH_QUEUE_SCRIPT` | `~/.claude/skills/review-queue/scripts/review-queue.sh` | Queue script (a copy lives in `lib/review-queue.sh`) |
| `PI_PRSMASH_MODEL` | `openai-codex/gpt-5.6-sol` | Model passed to `pi --model` |
| `PRSMASH_TRUSTED_AUTHORS` | `jaythegeek,corixdean,gsasu,beddial` | Authors whose PRs may be approved automatically (empty disables the gate) |
| `PI_PRSMASH_THINKING` | `high` | Reasoning level passed to `pi --thinking` |
| `PRSMASH_REVIEW_TIMEOUT` | `2700` | Seconds before a single review is killed (p99 is ~32m) |
| `PRSMASH_LOG_DIR` | `~/.prsmash` | Locks, run logs, notification markers |
| `PRSMASH_SLACK_SCRIPT` | `~/.claude/skills/slack/scripts/slack.sh` | Slack send helper |
| `PRSMASH_SLACK_APPROVAL_NOTIFY` | `true` | Toggle Slack notifications |
| `PRSMASH_SLACK_APPROVAL_TARGET` | `@tom` | DM target (resolved via the helper) |
| `PRSMASH_SLACK_APPROVAL_CHANNEL` | _(unset)_ | Explicit channel ID, skips target resolution |
| `PRSMASH_SLACK_APPROVAL_USER` | _(the token's own user)_ | Whose reaction is allowed to approve |
| `PRSMASH_APPROVE_REACTIONS` | `+1,thumbsup,white_check_mark,heavy_check_mark` | Reactions that approve (first is the one the DM suggests) |
| `PRSMASH_REJECT_REACTIONS` | `-1,thumbsdown,x,no_entry_sign` | Reactions that drop the approval |
| `PRSMASH_APPROVAL_PENDING_TTL_DAYS` | `14` | Days before an unanswered approval is dropped |

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
prsmash --trusted-authors alice,bob  # override who may be approved automatically
prsmash --trusted-authors ''         # approve every eligible PR (no author gate)
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

## Layout

```
bin/prsmash                    the main script
lib/review-queue.sh            builds the PR queue JSON (gh + jq)
systemd/prsmash-hourly.*       half-hourly timer for prsmash --all
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
