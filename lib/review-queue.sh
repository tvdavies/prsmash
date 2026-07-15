#!/usr/bin/env bash
set -eo pipefail

# Usage: review-queue.sh [--user USERNAME] [--include-implicit]
#
# Queue sources:
#   review-request      — PRs where our review is explicitly requested
#   threads-resolved    — PRs we previously blocked (CHANGES_REQUESTED/DISMISSED)
#                         where the author has since resolved every review thread
#                         and either pushed new commits or replied after our review.
#                         Always included: the author has done everything GitHub
#                         lets them do; waiting for an explicit re-request would
#                         deadlock the PR.
#   previously-reviewed — looser implicit re-review candidates (author pushed after
#                         our review, threads not necessarily resolved). Only
#                         included with --include-implicit, for manual selection.
TARGET_USER=""
INCLUDE_IMPLICIT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) TARGET_USER="$2"; shift 2 ;;
    --include-implicit) INCLUDE_IMPLICIT=true; shift ;;
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

search_prs() {
  local mode="$1"
  local args=(--state=open --draft=false --json repository,title,author,url,number,createdAt --jq '.')

  if [ "$mode" = "requested" ]; then
    args=(--review-requested="$REVIEW_USER" "${args[@]}")
  else
    args=(--reviewed-by="$REVIEW_USER" "${args[@]}")
  fi

  if [ -n "$CURRENT_REPO" ]; then
    args=("${args[@]}" --repo "$CURRENT_REPO")
  fi

  gh search prs "${args[@]}"
}

# Explicit review requests plus previously-reviewed PRs. Previously-reviewed PRs
# are always fetched so we can detect thread-resolved re-review candidates; the
# looser "author pushed, threads still open" candidates are only surfaced with
# --include-implicit.
requested_prs=$(search_prs requested)
reviewed_prs=$(search_prs reviewed)

prs=$(jq -s '
  (.[0] // [] | map(. + {queueSource: "review-request"})) as $requested
  | (.[1] // [] | map(. + {queueSource: "previously-reviewed"})) as $reviewed
  | ($requested + $reviewed)
  | group_by(.repository.nameWithOwner + "#" + (.number | tostring))
  | map((map(select(.queueSource == "review-request")) | first) // first)
' <(printf '%s\n' "$requested_prs") <(printf '%s\n' "$reviewed_prs"))

# Filter out dependabot and Snyk PRs
prs=$(echo "$prs" | jq --arg me "$REVIEW_USER" '[.[] | select(
  .author.login != $me and
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

# Enrich each PR with review, commit, and thread state in one GraphQL call, then
# decide inclusion per queue source.
echo "$prs" | jq -c '.[]' | while read -r pr; do
  repo=$(echo "$pr" | jq -r '.repository.nameWithOwner')
  owner="${repo%/*}"
  name="${repo#*/}"
  number=$(echo "$pr" | jq -r '.number')

  raw=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          headRefOid
          commits(last: 1) { nodes { commit { committedDate } } }
          reviews(last: 100) { nodes { author { login } state submittedAt commit { oid } } }
          reviewThreads(first: 100) {
            nodes {
              isResolved
              comments(last: 1) { nodes { author { login } createdAt } }
            }
          }
        }
      }
    }' -f owner="$owner" -f repo="$name" -F number="$number" 2>/dev/null || true)

  if [ -z "$raw" ]; then
    continue
  fi

  review_info=$(echo "$raw" | jq --arg me "$REVIEW_USER" '
    .data.repository.pullRequest as $pr
    | ($pr.reviews.nodes | map(select(.author.login != null)) | sort_by(.submittedAt)) as $reviews
    | ($reviews | group_by(.author.login) | map(last)) as $latest_per_author
    | ([$reviews[] | select(.author.login == $me)] | last) as $mine
    | {
        head_oid: $pr.headRefOid,
        last_commit: ($pr.commits.nodes | last | .commit.committedDate),
        changes_requested: ([$latest_per_author[] | select(.state == "CHANGES_REQUESTED")] | length),
        all_cr_authors: [$latest_per_author[] | select(.state == "CHANGES_REQUESTED") | .author.login],
        my_review: (if $mine == null then {state: null, submittedAt: null, commit: null}
                    else {state: $mine.state, submittedAt: $mine.submittedAt, commit: ($mine.commit.oid // null)} end),
        threads_total: ($pr.reviewThreads.nodes | length),
        threads_unresolved: ([$pr.reviewThreads.nodes[] | select(.isResolved | not)] | length),
        last_other_thread_activity: ([$pr.reviewThreads.nodes[].comments.nodes[]
                                       | select(.author.login != $me) | .createdAt] | max // null)
      }')

  decision=$(echo "$review_info" | jq \
    --arg source "$(echo "$pr" | jq -r '.queueSource')" \
    --argjson implicit "$([ "$INCLUDE_IMPLICIT" = true ] && echo true || echo false)" '
    (.my_review.submittedAt) as $mine_at
    | (.last_commit != null and $mine_at != null and .last_commit > $mine_at) as $pushed_since
    | (.last_other_thread_activity != null and $mine_at != null and .last_other_thread_activity > $mine_at) as $replied_since
    | if $source == "review-request" then
        # Never reviewed: review unless another reviewer is already blocking
        # (the author has work to do first). Already reviewed: only re-review
        # when the author pushed or replied since — re-reviewing an unchanged
        # PR on every run just re-rolls the findings dice and spams the author.
        (if .my_review.state == null then
          {include: (.changes_requested == 0), source: $source, implicitRereview: false}
        else
          {include: ($pushed_since or $replied_since), source: $source, implicitRereview: false}
        end)
      elif (.my_review.state == "CHANGES_REQUESTED" or .my_review.state == "DISMISSED")
           and .threads_unresolved == 0
           and ($pushed_since or $replied_since) then
        {include: true, source: "threads-resolved", implicitRereview: false}
      elif $implicit and .my_review.state != null and $pushed_since then
        {include: true, source: $source, implicitRereview: true}
      else
        {include: false, source: $source, implicitRereview: false}
      end')

  if [ "$(echo "$decision" | jq -r '.include')" = "true" ]; then
    echo "$pr" | jq --argjson info "$review_info" --argjson decision "$decision" '. + {
      queueSource: $decision.source,
      myReviewState: $info.my_review.state,
      myReviewAt: $info.my_review.submittedAt,
      myReviewCommit: $info.my_review.commit,
      headRefOid: $info.head_oid,
      lastCommitAt: $info.last_commit,
      threadsUnresolved: $info.threads_unresolved,
      needsRereview: ($info.my_review.state != null),
      implicitRereview: $decision.implicitRereview
    }'
  fi
done | jq -s --arg current_repo "$CURRENT_REPO" --arg user "$REVIEW_USER" '{in_repo: ($current_repo != ""), repo: $current_repo, user: $user, prs: .}'
