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
Trusted authors: bob,dave
Human approval: untrusted authors with 1001+ changed lines

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
      -p "/skill:pr-review --headless --post --independent-checks --pr <N>"
   ```

4. Records the run's own outcome from the posting helper's result file
   (never from an older GitHub review), appends our latest GitHub review
   to the log for context, and cleans up worktrees and temp refs when the
   run finishes (also on Ctrl-C, including the whole child process tree).

Before reviewing, prsmash asks GitHub whether the PR merges cleanly (polling
briefly while GitHub computes it). A PR that conflicts with its base is not
reviewed. Instead prsmash trial-merges the head into the current base tip with
`git merge-tree`, posts one short comment naming the conflicting files
(modify/delete and rename conflicts flagged first), says who has to do what,
and promises a re-review once the branch merges cleanly. It posts again only
when the set of conflicting files changes. `prsmash-merge-check PR` prints the
notice prsmash would post, without posting anything.

Every finished outcome (approval, changes requested, `INCOMPLETE`,
`NOT_POSTED`, merge conflict) is recorded against its exact head in
`review-dispositions/`, so overlapping runs never review one head twice. A
recorded head is reviewed again when:

- a new commit arrives (a new head);
- it was recorded as conflicting and GitHub now reports it mergeable;
- a person other than us comments on the PR or a review thread after that
  review started, for example to post evidence or a decision. Bots do not
  count, and this is capped at `PRSMASH_MAX_ACTIVITY_REREVIEWS` (default 2)
  extra looks per head, so a reply loop cannot recreate the old review loop.

A review that ends `INCOMPLETE` (the review itself could not finish, nothing
critical found) is posted as a COMMENTED review on the reviewed head; it never
approves, requests changes or dismisses an earlier blocking review. Every
posting short of an approval must carry a "To move this forward" section that
names who acts next; the posting helper refuses it otherwise.

Reviews are guarded by locks: interactive runs take a global lock, while
scheduled runs overlap and take one lock per PR. A PR already being reviewed
by another run is skipped, not double-reviewed.

Reviews run independently of CI and CodeRabbit. The reviewer records their
current status, assesses available findings, and publishes the code verdict
without waiting for either check. Required checks still gate merging. CodeRabbit
changes requests and unresolved threads do not hold up the review queue; other
reviewers' blocking requests retain their existing queue behaviour.

PRs changing 1,001 or more lines get up to two hours for their first attempt.
Smaller reviews start at 45 minutes; after a timeout on the same head, the next
attempt gets 90 minutes, then two hours. Successful reviews and new heads reset
the small-PR budget. Scheduled runs allow 2h10m for review and cleanup.

## Human approval policy

Automatic approval is held back only when both of these conditions are true:

1. The PR author is not in `PRSMASH_TRUSTED_AUTHORS` (default
   `bastiaan-bit,bethandutton,bram-lleverage,corixdean,eddial,emile-naude,gsasu,jaythegeek,joostverdoorn,lkooy,lorenzofiumi91,marcuslleverage,matteo-chi,noahvrijn,tijmenvanetten,tomvanwees-wq,tvdavies`). Logins are comma or space separated and
   matched case-insensitively.
2. Additions + deletions are at least `PRSMASH_APPROVAL_LINE_LIMIT` (default
   `1001`, meaning the PR changes more than 1,000 lines). The legacy
   `PRSMASH_APPROVAL_MAX_LINES` name remains a fallback when the primary variable
   is unset.

| Author | Changed lines | Result |
| --- | ---: | --- |
| Trusted | Any size | GitHub approval |
| Untrusted | 1,000 or fewer | GitHub approval |
| Untrusted | 1,001 or more | Review comment awaiting human approval |

The held review still carries its `Approved` verdict, but is posted as a comment
with a generic human-approval banner. The run reports **"Review posted, awaiting
your approval"** and sends you a Slack DM with the PR link.

Set `PRSMASH_AUTO_APPROVE_ALL=true` to bypass both checks and approve every
eligible PR regardless of author or size. The value accepts `true` or `false`
case-insensitively; any other non-empty value fails rather than silently changing
the policy. Setting `PRSMASH_TRUSTED_AUTHORS` to an empty string remains a
compatible way to disable the gate and approve every eligible PR.

Only an approval verdict is gated. `REQUEST_CHANGES` and plain comment reviews
are posted normally regardless of author, size, or the override; the policy
never turns a passing review into a failing one.

Reviews posted as issue comments, including manual-gated reviews, are
deduplicated per PR head SHA. Once an exact head has passed automated review,
scheduled runs skip it rather than repeatedly reviewing code GitHub still shows
as review-requested. A pushed commit has a new SHA and is reviewed normally.

## Push notifications (ntfy)

Every action taken on a PR is published to an [ntfy.sh](https://ntfy.sh)
topic (`prsmash` by default), so outcomes arrive as phone push
notifications — subscribe to the topic in the ntfy app:

| Outcome | Priority | Tag |
| --- | --- | --- |
| Approved | default | ✅ |
| Commented | default | 💬 |
| Changes requested | high | ⚠️ |
| Awaiting your approval | high | 👀 |
| Review incomplete (commented, not approved) | default | ⌛ |
| Review not posted (head will not be retried) | high | ❔ |
| Review failed | **urgent** (max) | 🚨 |

Each notification describes what this run did, never an earlier review
still showing on GitHub. Each notification links to the PR (tap to open).
Skips (`LOCKED`, `HANDLED`) are silent — nothing was done to the PR. A run that dies
before reviewing (invalid queue response) also publishes an urgent
failure.

Failures are rate limited to one notification per PR per
`PRSMASH_NTFY_FAILURE_COOLDOWN_MINS` (default 60): a systemic outage
errors every PR on every 5-minute tick, which would otherwise be
thousands of urgent pushes. Successes are never rate limited.

Note: public ntfy.sh topics are readable by anyone who guesses the
name, and notifications include PR titles. Set `PRSMASH_NTFY_TOPIC` to
something unguessable (or `PRSMASH_NTFY_SERVER` to a self-hosted ntfy)
if that matters to you. A topic reserved on your ntfy account needs
`PRSMASH_NTFY_TOKEN` (an access token such as `tk_...`); without it
ntfy.sh rejects every publish with 403. `PRSMASH_NTFY_NOTIFY=false`
disables the feature entirely.

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

The trusted-author list and changed-line limit are passed to the skill together.
When both conditions require human sign-off, the skill reports
`PRSMASH_MANUAL_APPROVAL_REQUIRED=true` and
`PRSMASH_MANUAL_APPROVAL_REASON_CODE=untrusted-author-over-line-limit`.

## Prerequisites

- `bash`, `jq`, `fzf`, `flock`, `git`, `curl` (for ntfy notifications)
- [`gh` CLI](https://cli.github.com/) authenticated (`gh auth status`)
- [pi](https://github.com/earendil-works/pi-coding-agent) on PATH
- A `pr-review` skill that accepts `--headless --post --independent-checks --pr <N>`
- Optional, for Slack notifications and reaction approvals: a `slack.sh`
  helper supporting `resolve`, `send`, `profile` and `reactions`, plus
  `SLACK_MCP_XOXC_TOKEN` / `SLACK_MCP_XOXD_TOKEN` in the environment.
  Without it, large reviews for untrusted authors are still posted as
  comments — you just have to approve them on GitHub yourself.

## Install

```bash
git clone https://github.com/tvdavies/prsmash.git ~/src/prsmash
mkdir -p ~/.local/bin
ln -sf ~/src/prsmash/bin/prsmash ~/.local/bin/prsmash
ln -sf ~/src/prsmash/bin/prsmash-model ~/.local/bin/prsmash-model
```

Then point it at your setup (env vars, with these defaults):

| Variable | Default | Purpose |
| --- | --- | --- |
| `PRSMASH_SOURCE_REPO` | `~/dev/lleverage-ai/lleverage` | Local clone of the repo whose PRs you review |
| `PR_REVIEW_SKILL_DIR` | `~/.claude/skills/pr-review` | The pi `pr-review` skill directory |
| `PRSMASH_QUEUE_SCRIPT` | `~/.claude/skills/review-queue/scripts/review-queue.sh` | Queue script (a copy lives in `lib/review-queue.sh`) |
| `PI_PRSMASH_MODEL` | _(unset)_ | Model passed to `pi --model`; overrides the saved model file |
| `PRSMASH_MODEL_FILE` | `~/.prsmash/model` | One-line file holding the default model, managed by `prsmash-model` |
| `PRSMASH_TRUSTED_AUTHORS` | `bastiaan-bit,bethandutton,bram-lleverage,corixdean,eddial,emile-naude,gsasu,jaythegeek,joostverdoorn,lkooy,lorenzofiumi91,marcuslleverage,matteo-chi,noahvrijn,tijmenvanetten,tomvanwees-wq,tvdavies` | Authors whose large PRs may be approved automatically (empty disables the gate) |
| `PRSMASH_APPROVAL_LINE_LIMIT` | `1001` | First changed-line count that requires an untrusted author to get human approval |
| `PRSMASH_APPROVAL_MAX_LINES` | _(unset)_ | Legacy fallback name for `PRSMASH_APPROVAL_LINE_LIMIT` |
| `PRSMASH_AUTO_APPROVE_ALL` | `false` | Set to `true` to bypass author and size gating for every eligible PR |
| `PI_PRSMASH_THINKING` | `high` | Reasoning level passed to `pi --thinking` |
| `PRSMASH_REVIEW_TIMEOUT` | `2700` | Initial timeout in seconds for smaller reviews |
| `PRSMASH_MAX_REVIEW_TIMEOUT` | `7200` | Maximum timeout in seconds; used immediately for large PRs and after repeated timeouts |
| `PRSMASH_LARGE_PR_LINES` | `1001` | Additions + deletions at which a PR gets the maximum timeout immediately |
| `PRSMASH_LOG_DIR` | `~/.prsmash` | Locks, run logs, notification markers |
| `PRSMASH_SLACK_SCRIPT` | `~/.claude/skills/slack/scripts/slack.sh` | Slack send helper |
| `PRSMASH_SLACK_APPROVAL_NOTIFY` | `true` | Toggle Slack notifications |
| `PRSMASH_SLACK_APPROVAL_TARGET` | `@tom` | DM target (resolved via the helper) |
| `PRSMASH_SLACK_APPROVAL_CHANNEL` | _(unset)_ | Explicit channel ID, skips target resolution |
| `PRSMASH_SLACK_APPROVAL_USER` | _(the token's own user)_ | Whose reaction is allowed to approve |
| `PRSMASH_APPROVE_REACTIONS` | `+1,thumbsup,white_check_mark,heavy_check_mark` | Reactions that approve (first is the one the DM suggests) |
| `PRSMASH_REJECT_REACTIONS` | `-1,thumbsdown,x,no_entry_sign` | Reactions that drop the approval |
| `PRSMASH_APPROVAL_PENDING_TTL_DAYS` | `14` | Days before an unanswered approval is dropped |
| `PRSMASH_NTFY_NOTIFY` | `true` | Toggle ntfy push notifications |
| `PRSMASH_NTFY_SERVER` | `https://ntfy.sh` | ntfy server to publish to |
| `PRSMASH_NTFY_TOPIC` | `prsmash` | ntfy topic for review outcome notifications |
| `PRSMASH_NTFY_TOKEN` | _(unset)_ | ntfy access token, required when the topic is reserved |
| `PRSMASH_MAX_ACTIVITY_REREVIEWS` | `2` | Extra reviews of one head earned by people commenting after a review |
| `PRSMASH_MERGEABLE_POLL_ATTEMPTS` | `4` | Reads of the PR while GitHub computes mergeability |
| `PRSMASH_MERGEABLE_POLL_SECS` | `3` | Seconds between those reads |
| `PRSMASH_NTFY_FAILURE_COOLDOWN_MINS` | `60` | Minimum minutes between failure notifications for the same PR |

Confirm with:

```bash
prsmash --dry-run
```

## Usage

```bash
prsmash                          # pick PRs via fzf, review selected in parallel
prsmash --all                    # review everything in the queue, no prompt
prsmash --dry-run                # list what would be reviewed and exit
prsmash --include-implicit           # also surface implicit re-review candidates (manual mode)
prsmash --trusted-authors alice,bob  # override who is trusted for large PRs
prsmash --trusted-authors ''         # approve every eligible PR (no author gate)
prsmash --approval-line-limit 2001  # require human approval above 2,000 changed lines
PRSMASH_AUTO_APPROVE_ALL=true prsmash --all  # bypass approval gating
prsmash --model <provider/model>     # override the pi model for this run only
```

### Changing the default model

`prsmash-model` manages the persistent default, picked from the models pi
actually knows about:

```bash
prsmash-model                    # pick interactively (fzf) from pi --list-models
prsmash-model <provider/model>   # set directly (validated against pi's registry)
prsmash-model --show             # effective default and where it comes from
prsmash-model --list             # valid provider/model ids
prsmash-model --clear            # back to the built-in default
```

The choice is saved to `~/.prsmash/model` and read by every run, including the
scheduled systemd runs. Precedence: `--model` flag > `PI_PRSMASH_MODEL` env >
model file > built-in default (`anthropic-claude-code/claude-opus-4-8`).

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
lib/review-outcome.sh          maps a finished review to its status and ntfy message
lib/review-disposition-state.sh  exact heads already handled, and when they earn another look
lib/merge-conflicts.sh         mergeability check, trial merge and the conflict notice
bin/prsmash-merge-check        print the conflict notice for a PR without posting it
lib/review-timeout.sh          adaptive review timeouts
tests/*.test.sh                bash tests with stubbed gh, pi and curl
systemd/prsmash-hourly.*       half-hourly timer for prsmash --all
```

Each run writes to `$PRSMASH_LOG_DIR/runs/<run-id>/` (symlinked from
`$PRSMASH_LOG_DIR/latest`):

```
queue.json               the queue that was fetched
pr-<N>-<repo>.log        full review log + our latest GitHub review body
pr-<N>.status            machine-readable outcome: OK|<STATE>|<secs>, LOCKED, HANDLED or ERR
                         (STATE: APPROVED, CHANGES_REQUESTED, COMMENTED,
                         MANUAL_APPROVAL_REQUIRED, INCOMPLETE, NOT_POSTED,
                         CONFLICTING)
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
