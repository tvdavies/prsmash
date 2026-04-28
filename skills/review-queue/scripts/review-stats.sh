#!/usr/bin/env bash
set -eo pipefail

# Usage: review-stats.sh [--since DATE] [--repo OWNER/REPO]
# Outputs JSON with per-reviewer stats for the team.
# Default --since: today (UTC). Accepts ISO date like 2026-03-30.

# Team handles come from (in order of precedence):
#   1. $REVIEW_QUEUE_TEAM env var (space-separated GitHub logins)
#   2. ${REVIEW_QUEUE_TEAM_FILE:-$HOME/.config/review-queue/team}
#      (one login per line; blank lines and `#` comments ignored)
TEAM_FILE="${REVIEW_QUEUE_TEAM_FILE:-$HOME/.config/review-queue/team}"
TEAM_MEMBERS=()
if [ -n "${REVIEW_QUEUE_TEAM:-}" ]; then
  read -r -a TEAM_MEMBERS <<< "$REVIEW_QUEUE_TEAM"
elif [ -f "$TEAM_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -n "$line" ] && TEAM_MEMBERS+=("$line")
  done < "$TEAM_FILE"
fi

if [ ${#TEAM_MEMBERS[@]} -eq 0 ]; then
  echo "{\"error\": \"No team configured. Set REVIEW_QUEUE_TEAM (space-separated logins) or create $TEAM_FILE (one login per line). See config/team.example.\"}" >&2
  exit 1
fi

SINCE=""
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$SINCE" ]; then
  SINCE=$(date -u +%Y-%m-%d)
fi

# Auto-detect repo if not specified
if [ -z "$REPO" ]; then
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
  fi
fi

if [ -z "$REPO" ]; then
  echo '{"error": "No repo specified and not inside a git repository. Use --repo OWNER/REPO."}' >&2
  exit 1
fi

# Collect all PRs updated since the target date that have reviews
# Use gh search to find PRs with recent activity, then check reviews
all_reviewer_stats='[]'

for member in "${TEAM_MEMBERS[@]}"; do
  # Find PRs reviewed by this member, updated since target date
  prs=$(gh search prs \
    --reviewed-by="$member" \
    --repo "$REPO" \
    --updated=">=${SINCE}" \
    --json number,title,url,state \
    --jq '.' 2>/dev/null || echo '[]')

  if [ "$prs" = "[]" ] || [ -z "$prs" ]; then
    all_reviewer_stats=$(echo "$all_reviewer_stats" | jq --arg user "$member" '. + [{
      user: $user,
      reviewsToday: 0,
      prsReviewed: [],
      approved: 0,
      changesRequested: 0,
      commented: 0
    }]')
    continue
  fi

  # For each PR, fetch the actual review timestamps and filter to today
  pr_details='[]'
  while read -r pr_json; do
    number=$(echo "$pr_json" | jq -r '.number')
    title=$(echo "$pr_json" | jq -r '.title')
    url=$(echo "$pr_json" | jq -r '.url')

    reviews=$(gh pr view "$number" --repo "$REPO" --json reviews 2>/dev/null \
      | jq --arg user "$member" --arg since "$SINCE" '
        [.reviews[]
          | select(.author.login == $user and (.submittedAt | split("T")[0]) >= $since)
        ] | {
          count: length,
          states: [.[].state],
          latest: (last | .submittedAt // null)
        }
      ' 2>/dev/null || echo '{"count": 0, "states": [], "latest": null}')

    review_count=$(echo "$reviews" | jq '.count')
    if [ "$review_count" -gt 0 ]; then
      pr_details=$(echo "$pr_details" | jq \
        --argjson reviews "$reviews" \
        --arg title "$title" \
        --arg url "$url" \
        --argjson number "$number" \
        '. + [{number: $number, title: $title, url: $url, reviewCount: $reviews.count, states: $reviews.states, latestAt: $reviews.latest}]')
    fi
  done < <(echo "$prs" | jq -c '.[]')

  # Aggregate stats for this member
  all_reviewer_stats=$(echo "$all_reviewer_stats" | jq \
    --arg user "$member" \
    --argjson prs "$pr_details" '
    ($prs | map(.states) | flatten) as $all_states |
    . + [{
      user: $user,
      reviewsToday: ($all_states | length),
      prsReviewed: $prs,
      approved: ([$all_states[] | select(. == "APPROVED")] | length),
      changesRequested: ([$all_states[] | select(. == "CHANGES_REQUESTED")] | length),
      commented: ([$all_states[] | select(. == "COMMENTED")] | length)
    }]')
done

echo "$all_reviewer_stats" | jq --arg repo "$REPO" --arg since "$SINCE" '{
  repo: $repo,
  since: $since,
  reviewers: .
}'
