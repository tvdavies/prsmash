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

record_review_disposition() {
  local repo=$1 pr_number=$2 head_oid=$3 source=${4:-automated-review}
  local file tmp
  file=$(review_disposition_file "$repo" "$pr_number" "$head_oid") || return 1
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1

  if jq -n \
      --arg repo "$repo" \
      --argjson pr "$pr_number" \
      --arg head "$head_oid" \
      --arg source "$source" \
      --arg reviewedAt "$(date -Is)" \
      '{repo: $repo, pr: $pr, head: $head, source: $source, reviewedAt: $reviewedAt}' \
      > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
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
        && review_disposition_exists "$repo" "$pr_number" "$head_oid"; then
      printf 'Skipping #%s (%s): this exact head already completed an automated review outside GitHub review state.\n' \
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
