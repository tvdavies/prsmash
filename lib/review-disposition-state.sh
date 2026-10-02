#!/usr/bin/env bash

review_disposition_state_init() {
  local log_root=$1
  REVIEW_DISPOSITION_DIR="${PRSMASH_REVIEW_DISPOSITION_DIR:-$log_root/review-dispositions}"
  mkdir -p "$REVIEW_DISPOSITION_DIR"
}

review_disposition_file() {
  local repo=$1 pr_number=$2 head_oid=$3 safe_repo
  [[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
  [[ "$head_oid" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 1
  safe_repo=$(printf '%s' "$repo" | tr -cs 'A-Za-z0-9._-' '_')
  printf '%s/%s-%s-%s.json' "$REVIEW_DISPOSITION_DIR" "$safe_repo" "$pr_number" "$head_oid"
}

review_disposition_exists() {
  local file
  file=$(review_disposition_file "$1" "$2" "$3") || return 1
  [[ -f "$file" ]]
}

# record_review_disposition REPO PR HEAD [SOURCE] [STARTED_AT] [ACTIVITY_REREVIEWS]
#
# STARTED_AT is when the review that produced this disposition began. Author
# activity after that moment can earn the same head another look (see
# review_disposition_decision); activity before it was already in front of the
# reviewer. ACTIVITY_REREVIEWS counts how many of those extra looks this head
# has had, so a bot that answers every review cannot loop us.
record_review_disposition() {
  local repo=$1 pr_number=$2 head_oid=$3 source=${4:-automated-review}
  local started_at=${5:-} activity_rereviews=${6:-0}
  local file tmp now
  file=$(review_disposition_file "$repo" "$pr_number" "$head_oid") || return 1
  [[ "$activity_rereviews" =~ ^[0-9]+$ ]] || activity_rereviews=0
  now=$(date -Is)
  [[ -n "$started_at" ]] || started_at=$now
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1

  if jq -n \
      --arg repo "$repo" \
      --argjson pr "$pr_number" \
      --arg head "$head_oid" \
      --arg source "$source" \
      --arg reviewedAt "$now" \
      --arg startedAt "$started_at" \
      --argjson activityRereviews "$activity_rereviews" \
      '{repo: $repo, pr: $pr, head: $head, source: $source, reviewedAt: $reviewedAt,
        startedAt: $startedAt, activityRereviews: $activityRereviews}' \
      > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

review_disposition_field() {
  local file
  file=$(review_disposition_file "$1" "$2" "$3") || return 1
  [[ -f "$file" ]] || return 1
  jq -r --arg field "$4" '.[$field] // empty' "$file" 2>/dev/null
}

# ISO-8601 timestamp -> epoch seconds; nothing for an empty or unparseable value.
iso_to_epoch() {
  [[ -n "${1:-}" ]] || return 0
  date -d "$1" +%s 2>/dev/null || true
}

# review_disposition_decision REPO PR HEAD LAST_ACTIVITY_AT [MAX_ACTIVITY_REREVIEWS]
#
# What to do with a head we may already have handled:
#   review    no disposition: review it
#   conflict  we posted a merge-conflict notice for it: the caller re-checks
#             mergeability and reviews only once the branch merges cleanly
#   activity  handled, but someone other than us commented after that review
#             started (evidence, a decision, an answer): one more look
#   handled   handled and nothing new: skip until a new commit arrives
#
# Activity re-reviews are capped per head (default 2) so an author-side bot
# that replies to every review cannot recreate the review loop.
review_disposition_decision() {
  local repo=$1 pr_number=$2 head_oid=$3 last_activity_at=${4:-} max=${5:-${PRSMASH_MAX_ACTIVITY_REREVIEWS:-2}}
  local file source started_at count activity_epoch started_epoch
  file=$(review_disposition_file "$repo" "$pr_number" "$head_oid") || { echo review; return 0; }
  [[ -f "$file" ]] || { echo review; return 0; }

  source=$(jq -r '.source // empty' "$file" 2>/dev/null || true)
  if [[ "$source" == merge-conflict ]]; then
    echo conflict
    return 0
  fi

  started_at=$(jq -r '.startedAt // .reviewedAt // empty' "$file" 2>/dev/null || true)
  count=$(jq -r '.activityRereviews // 0' "$file" 2>/dev/null || echo 0)
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  [[ "$max" =~ ^[0-9]+$ ]] || max=2
  activity_epoch=$(iso_to_epoch "$last_activity_at")
  started_epoch=$(iso_to_epoch "$started_at")

  if [[ -n "$activity_epoch" && -n "$started_epoch" ]] \
      && [[ "$activity_epoch" -gt "$started_epoch" ]] \
      && [[ "$count" -lt "$max" ]]; then
    echo activity
  else
    echo handled
  fi
}

# Reviews posted as issue comments are invisible to GitHub's review state, so
# the same review request remains eligible. Remove exact heads that prsmash has
# already reviewed through that path. A new head is still eligible.
filter_review_dispositions() {
  local queue_json=$1 item repo pr_number head_oid
  local kept='[]'

  while IFS= read -r item; do
    repo=$(jq -r '.repository.nameWithOwner // empty' <<<"$item")
    pr_number=$(jq -r '.number // empty' <<<"$item")
    head_oid=$(jq -r '.headRefOid // empty' <<<"$item")

    if [[ -n "$repo" && -n "$pr_number" && -n "$head_oid" ]] \
        && [[ $(review_disposition_decision "$repo" "$pr_number" "$head_oid" \
               "$(jq -r '.lastActivityAt // empty' <<<"$item")") == handled ]]; then
      # A merge-conflict head stays listed: review_pr_bg re-checks
      # mergeability and reviews it once the conflicts are gone.
      printf 'Skipping #%s (%s): prsmash already handled this exact head and nobody has commented since.\n' \
        "$pr_number" "$repo" >&2
      continue
    fi

    kept=$(jq -c --argjson item "$item" '. + [$item]' <<<"$kept")
  done < <(jq -c '.prs[]' <<<"$queue_json")

  jq -c --argjson prs "$kept" '.prs = $prs' <<<"$queue_json"
}

# Approval records created before durable dispositions were introduced must
# suppress repeat reviews regardless of whether they are pending or processed.
backfill_approval_review_dispositions() {
  local directory file repo pr_number head_oid
  local files=()

  for directory in "$@"; do
    shopt -s nullglob
    files=("$directory"/*.json)
    shopt -u nullglob

    for file in "${files[@]}"; do
      repo=$(jq -r '.repo // empty' "$file" 2>/dev/null || true)
      pr_number=$(jq -r '.pr // empty' "$file" 2>/dev/null || true)
      head_oid=$(jq -r '.head // empty' "$file" 2>/dev/null || true)
      [[ -n "$repo" && -n "$pr_number" && -n "$head_oid" ]] || continue
      review_disposition_exists "$repo" "$pr_number" "$head_oid" \
        || record_review_disposition "$repo" "$pr_number" "$head_oid" approval-record-backfill \
        || printf 'Could not backfill review disposition for %s#%s at %s\n' \
          "$repo" "$pr_number" "$head_oid" >&2
    done
  done
}

# Slack was not always available to create an approval record. Recover successful
# historical issue-comment reviews from their run logs so they cannot immediately
# re-enter the queue after this fix is deployed.
backfill_logged_issue_comment_dispositions() {
  local runs_dir=$1 log_file status_file repo pr_number head_oid
  local failed=0

  [[ -d "$runs_dir" ]] || return 0
  while IFS= read -r -d '' log_file; do
    [[ "$(basename "$log_file")" =~ ^pr-([0-9]+)- ]] || continue
    pr_number=${BASH_REMATCH[1]}
    status_file="$(dirname "$log_file")/pr-${pr_number}.status"
    [[ -f "$status_file" ]] || continue
    grep -q '^OK|' "$status_file" 2>/dev/null || continue
    grep -q '#issuecomment-' "$log_file" 2>/dev/null || continue

    repo=$(grep -m1 '^repo=' "$log_file" 2>/dev/null | cut -d= -f2- || true)
    head_oid=$(grep -m1 '^headRefOid=' "$log_file" 2>/dev/null | cut -d= -f2- || true)
    [[ -n "$repo" && -n "$head_oid" ]] || continue
    if ! review_disposition_exists "$repo" "$pr_number" "$head_oid" \
        && ! record_review_disposition "$repo" "$pr_number" "$head_oid" historical-issue-comment-backfill; then
      printf 'Could not backfill logged review disposition for %s#%s at %s\n' \
        "$repo" "$pr_number" "$head_oid" >&2
      failed=1
    fi
  done < <(find "$runs_dir" -mindepth 2 -maxdepth 2 -type f -name 'pr-*-*.log' -print0 2>/dev/null)

  return "$failed"
}
