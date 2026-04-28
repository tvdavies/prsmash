---
name: review-queue
description: Fetches open GitHub PRs waiting for your review. Use when user says "review queue", "PRs to review", "what needs my review", "pending reviews", "PRs needing attention", "what should I review", "check review requests", "review stats", "who reviewed today", "team reviews", or "review activity". Also supports checking another team member's queue.
metadata:
  author: tvd
  version: 1.1.0
---

# Review Queue

## Review Queue (default)

Shows open PRs waiting for review, with re-review detection.

### Usage

```bash
# Your own queue
~/.claude/skills/review-queue/scripts/review-queue.sh

# Another team member's queue
~/.claude/skills/review-queue/scripts/review-queue.sh --user USERNAME
```

### Presenting Results

1. The output JSON has `in_repo` (boolean), `user` (login), and `prs` (array)
2. Each PR object includes `needsRereview` (boolean), `myReviewState` (e.g. "COMMENTED", "APPROVED", or null), and `myReviewAt` (ISO timestamp or null)
3. If `user` is not the current user, mention whose queue is being shown in the heading
4. Split PRs into two groups: **Re-review** (`needsRereview` is true) shown first, then **Fresh review** (everything else)
5. If `in_repo` is true, show tables with columns: #, Title (linked), Author, Age, and for re-review PRs add a "Last Review" column showing the state
6. If `in_repo` is false, add a Repo column to the tables
7. If there are no PRs, relay the message

## Review Stats

Shows how many PRs each team member has reviewed in a given period.

### Usage

```bash
# Today's stats (default)
~/.claude/skills/review-queue/scripts/review-stats.sh

# Stats since a specific date
~/.claude/skills/review-queue/scripts/review-stats.sh --since 2026-03-28

# Specific repo (auto-detected if in a git repo)
~/.claude/skills/review-queue/scripts/review-stats.sh --repo OWNER/REPO
```

> **Setup:** `review-stats.sh` needs the team's GitHub logins. Either set
> `REVIEW_QUEUE_TEAM="alice bob carol"` in your shell, or create
> `~/.config/review-queue/team` with one login per line.

### Presenting Results

1. The output JSON has `repo`, `since`, and `reviewers` (array of per-person stats)
2. Each reviewer object has: `user`, `reviewsToday` (total review actions), `prsReviewed` (array of PRs with details), `approved`, `changesRequested`, `commented`
3. Show a summary table with columns: Reviewer, PRs Reviewed, Approvals, Changes Requested, Comments
4. Below the table, optionally list the specific PRs each person reviewed (title linked, with their review action)
