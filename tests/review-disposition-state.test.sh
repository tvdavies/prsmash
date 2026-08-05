#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/review-disposition-state.sh
source "$ROOT/lib/review-disposition-state.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
review_disposition_state_init "$TMP/logs"

repo=lleverage-ai/lleverage
pr=5938
reviewed_head=3fe402e15f8fe7403b4edd8d6975b807c369068e
new_head=4fe402e15f8fe7403b4edd8d6975b807c369068e

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

record_review_disposition "$repo" "$pr" "$reviewed_head" issue-comment-review
review_disposition_exists "$repo" "$pr" "$reviewed_head" \
  || fail "recorded disposition was not found"
review_disposition_exists "$repo" "$pr" "$new_head" \
  && fail "a disposition for an old head suppressed a new head"

queue=$(jq -nc \
  --arg repo "$repo" \
  --arg old "$reviewed_head" \
  --arg new "$new_head" \
  '{repo: $repo, user: "tvdavies", prs: [
    {number: 5938, headRefOid: $old, repository: {nameWithOwner: $repo}},
    {number: 5938, headRefOid: $new, repository: {nameWithOwner: $repo}},
    {number: 6000, headRefOid: $old, repository: {nameWithOwner: $repo}}
  ]}')
filtered=$(filter_review_dispositions "$queue" 2>/dev/null)
[[ $(jq '.prs | length' <<<"$filtered") -eq 2 ]] \
  || fail "filter did not remove exactly the reviewed head"
[[ $(jq -r '.prs[0].headRefOid' <<<"$filtered") == "$new_head" ]] \
  || fail "filter removed the new head"
[[ $(jq -r '.prs[1].number' <<<"$filtered") == 6000 ]] \
  || fail "filter removed an unrelated PR"

backfill_root="$TMP/backfill"
review_disposition_state_init "$backfill_root"
mkdir -p "$backfill_root/pending-approvals" "$backfill_root/processed-approvals"
for directory in pending-approvals processed-approvals; do
  jq -n \
    --arg repo "$repo" \
    --argjson pr "$pr" \
    --arg head "$reviewed_head" \
    '{repo: $repo, pr: $pr, head: $head}' \
    > "$backfill_root/$directory/existing.json"
done
backfill_approval_review_dispositions \
  "$backfill_root/pending-approvals" "$backfill_root/processed-approvals"
review_disposition_exists "$repo" "$pr" "$reviewed_head" \
  || fail "approval record was not backfilled"

logged_root="$TMP/logged"
review_disposition_state_init "$logged_root"
mkdir -p "$logged_root/runs/run-1"
cat > "$logged_root/runs/run-1/pr-5938-lleverage-ai_lleverage.log" <<EOF
repo=$repo
headRefOid=$reviewed_head
Posted: https://github.com/$repo/pull/$pr#issuecomment-123
EOF
printf 'OK|COMMENTED|10\n' > "$logged_root/runs/run-1/pr-5938.status"
backfill_logged_issue_comment_dispositions "$logged_root/runs"
review_disposition_exists "$repo" "$pr" "$reviewed_head" \
  || fail "successful historical issue-comment review was not backfilled"

parallel_root="$TMP/parallel"
review_disposition_state_init "$parallel_root"
pids=()
for _ in $(seq 1 50); do
  record_review_disposition "$repo" "$pr" "$reviewed_head" parallel-writer &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "parallel disposition writer failed"
done
parallel_file=$(review_disposition_file "$repo" "$pr" "$reviewed_head")
jq -e --arg repo "$repo" --arg head "$reviewed_head" \
  '.repo == $repo and .head == $head' "$parallel_file" >/dev/null \
  || fail "parallel writers left invalid JSON"

if record_review_disposition "$repo" not-a-number "$reviewed_head" manual 2>/dev/null; then
  fail "invalid PR number was accepted"
fi
if record_review_disposition "$repo" "$pr" not-a-sha manual 2>/dev/null; then
  fail "invalid head was accepted"
fi

echo "review-disposition-state tests passed"
