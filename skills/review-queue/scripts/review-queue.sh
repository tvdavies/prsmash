#!/usr/bin/env bash
set -eo pipefail

# Usage: review-queue.sh [--user USERNAME]
TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) TARGET_USER="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Detect if we're in a git repo and get the owner/repo
CURRENT_REPO=""
if git rev-parse --is-inside-work-tree &>/dev/null; then
  CURRENT_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
fi

if [ -n "$TARGET_USER" ]; then
  REVIEW_USER="$TARGET_USER"
else
  REVIEW_USER=$(gh api user --jq .login)
fi

# Fetch open PRs requesting this user's review (non-draft)
if [ -n "$CURRENT_REPO" ]; then
  prs=$(gh search prs \
    --review-requested="$REVIEW_USER" \
    --state=open \
    --draft=false \
    --repo "$CURRENT_REPO" \
    --json repository,title,author,url,number,createdAt \
    --jq '.')
else
  prs=$(gh search prs \
    --review-requested="$REVIEW_USER" \
    --state=open \
    --draft=false \
    --json repository,title,author,url,number,createdAt \
    --jq '.')
fi

# Filter out dependabot and Snyk PRs
prs=$(echo "$prs" | jq '[.[] | select(
  (.author.login | test("dependabot|snyk"; "i") | not) and
  (.title | startswith("[Snyk]") | not)
)]')

if [ -z "$prs" ] || [ "$prs" = "[]" ]; then
  if [ -n "$TARGET_USER" ]; then
    echo "No PRs are currently waiting for ${TARGET_USER}'s review."
  else
    echo "No PRs are currently waiting for your review."
  fi
  exit 0
fi

# Filter out PRs where any reviewer has requested changes, and enrich with review state
echo "$prs" | jq -c '.[]' | while read -r pr; do
  repo=$(echo "$pr" | jq -r '.repository.nameWithOwner')
  number=$(echo "$pr" | jq -r '.number')

  review_info=$(gh pr view "$number" --repo "$repo" --json reviews,commits 2>/dev/null \
    | jq --arg me "$REVIEW_USER" '{
      changes_requested: ([.reviews | group_by(.author.login)[] | last | select(.state == "CHANGES_REQUESTED")] | length),
      all_cr_authors: [.reviews | group_by(.author.login)[] | last | select(.state == "CHANGES_REQUESTED") | .author.login],
      my_review: ([.reviews[] | select(.author.login == $me)] | last | {state, submittedAt}),
      last_commit: (.commits | last | .committedDate)
    }' 2>/dev/null || echo '{"changes_requested": 0, "all_cr_authors": [], "my_review": {"state": null, "submittedAt": null}, "last_commit": null}')

  include=$(echo "$review_info" | jq --arg me "$REVIEW_USER" '
    .changes_requested == 0 or
    .my_review.state != null or (
      ([.all_cr_authors[] | select(. != $me)] | length) == 0
      and .my_review.state == "CHANGES_REQUESTED"
      and .last_commit > .my_review.submittedAt
    )
  ')

  if [ "$include" = "true" ]; then
    echo "$pr" | jq --argjson info "$review_info" '. + {
      myReviewState: $info.my_review.state,
      myReviewAt: $info.my_review.submittedAt,
      lastCommitAt: $info.last_commit,
      needsRereview: ($info.my_review.state != null)
    }'
  fi
done | jq -s --arg current_repo "$CURRENT_REPO" --arg user "$REVIEW_USER" '{in_repo: ($current_repo != ""), repo: $current_repo, user: $user, prs: .}'
