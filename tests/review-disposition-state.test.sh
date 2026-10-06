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

# What a recorded head means for the next tick.
decision_root="$TMP/decision"
review_disposition_state_init "$decision_root"
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "") == review ]] \
  || fail "an unrecorded head was not reviewable"
# Started 10:00 in +02:00, i.e. 08:00Z. Comparisons must be by instant, not text.
record_review_disposition "$repo" "$pr" "$reviewed_head" approved-review "2026-10-02T10:00:00+02:00"
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "") == handled ]] \
  || fail "no activity still re-reviewed"
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "2026-10-02T09:30:00Z") == activity ]] \
  || fail "a comment after the review started (09:30Z > 08:00Z) did not earn a look"
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "2026-10-02T07:59:00Z") == handled ]] \
  || fail "a comment from before the review re-reviewed it"
record_review_disposition "$repo" "$pr" "$reviewed_head" approved-review "2026-10-02T08:00:00Z" 2
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "2026-10-02T09:30:00Z") == handled ]] \
  || fail "activity re-reviews were not capped at two"
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "2026-10-02T09:30:00Z" 3) == activity ]] \
  || fail "the cap is not configurable"
record_review_disposition "$repo" "$pr" "$reviewed_head" merge-conflict
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "2026-10-02T09:30:00Z") == conflict ]] \
  || fail "a merge-conflict head did not defer to mergeability"
# Records written before startedAt existed fall back to reviewedAt.
legacy=$(review_disposition_file "$repo" "$pr" "$new_head")
jq -n --arg head "$new_head" '{repo:"lleverage-ai/lleverage",pr:5938,head:$head,source:"incomplete-review",
  reviewedAt:"2026-10-02T10:37:00+02:00"}' > "$legacy"
[[ $(review_disposition_decision "$repo" "$pr" "$new_head" "2026-10-02T08:40:00Z") == activity ]] \
  || fail "legacy record did not use reviewedAt"

# Held INCOMPLETE: retried when someone answers, CI finishes or the backoff
# passes, up to PRSMASH_MAX_HELD_ATTEMPTS rounds in all.
checks_finished=false
held_head_checks_finished() { [[ "$checks_finished" == true ]]; }
now_iso=$(date -Is)
record_review_disposition "$repo" "$pr" "$reviewed_head" incomplete-held "$now_iso" 0 \
  '{"heldAttempts":1,"ciFinishedAtHold":false}'
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "") == handled ]] \
  || fail "a fresh hold with CI running was retried at once"
checks_finished=true
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "") == held-retry ]] \
  || fail "CI finishing after the hold did not retry"
record_review_disposition "$repo" "$pr" "$reviewed_head" incomplete-held "$now_iso" 0 \
  '{"heldAttempts":1,"ciFinishedAtHold":true}'
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "") == handled ]] \
  || fail "CI that had already finished at hold time retried again"
[[ $(review_disposition_decision "$repo" "$pr" "$reviewed_head" "$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)") == held-retry ]] \
  || fail "a comment after the held review did not retry"
[[ $(PRSMASH_HELD_RETRY_MINS=0 review_disposition_decision "$repo" "$pr" "$reviewed_head" "") == held-retry ]] \
  || fail "the backoff did not retry"
record_review_disposition "$repo" "$pr" "$reviewed_head" incomplete-held "$now_iso" 0 \
  '{"heldAttempts":3,"ciFinishedAtHold":false}'
[[ $(PRSMASH_HELD_RETRY_MINS=0 review_disposition_decision "$repo" "$pr" "$reviewed_head" "$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)") == handled ]] \
  || fail "held retries were not capped at three"
[[ $(PRSMASH_MAX_HELD_ATTEMPTS=4 review_disposition_decision "$repo" "$pr" "$reviewed_head" "") == held-retry ]] \
  || fail "the held cap is not configurable"
[[ $(review_disposition_field "$repo" "$pr" "$reviewed_head" heldAttempts) == 3 ]] \
  || fail "extra fields were not merged into the record"

echo "review-disposition-state tests passed"
