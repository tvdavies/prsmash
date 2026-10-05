#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/review-outcome.sh
source "$ROOT/lib/review-outcome.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

repo=lleverage-ai/lleverage
pr=7250
head=638a9f7e4be5899b6a0d4d2822b23b546f88c688
old_head=be19bfb79cbaef359864275ff9a39ce6115e9748
started=2026-10-02T07:10:01Z
result="$TMP/review-result.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_result() {
  local posting=$1 event=$2 verdict=$3 manual=${4:-false} result_head=${5:-$head}
  jq -n --arg repo "$repo" --argjson pr "$pr" --arg head "$result_head" \
    --arg posting "$posting" --arg event "$event" --arg verdict "$verdict" \
    --argjson manual "$manual" \
    '{repo: $repo, pr: $pr, head: $head, posting: $posting, event: $event,
      verdict: $verdict, manualApprovalRequired: $manual}' > "$result"
}

expect() {
  local want_state=$1 want_source=$2 reviews=${3:-[]} state source
  IFS=$'\t' read -r state source <<<"$(review_run_outcome "$result" "$repo" "$pr" "$head" "$reviews" tvdavies "$started")"
  [[ "$state" == "$want_state" ]] || fail "expected state $want_state, got $state"
  [[ "${source:-}" == "$want_source" ]] || fail "expected disposition '$want_source' for $want_state, got '${source:-}'"
}

# The #7250 regression: the run posted nothing and GitHub still holds our older
# CHANGES_REQUESTED review on an older head. That must not be this run's result.
stale_reviews=$(jq -nc --arg old "$old_head" '[[{id: 5381512887, user: {login: "tvdavies"},
  state: "CHANGES_REQUESTED", commit_id: $old, submitted_at: "2026-10-01T15:25:05Z"}]]')
rm -f "$result"
expect NOT_POSTED not-posted "$stale_reviews"

# An old CHANGES_REQUESTED on this same head, from before this run, is stale too.
same_head_old=$(jq -nc --arg head "$head" '[{user: {login: "tvdavies"}, state: "CHANGES_REQUESTED",
  commit_id: $head, submitted_at: "2026-10-02T07:00:00Z"}]')
expect NOT_POSTED not-posted "$same_head_old"

# INCOMPLETE posted through the helper: its own state, and the head is handled.
write_result github-review COMMENT INCOMPLETE
expect INCOMPLETE incomplete-review "$stale_reviews"

# Every helper outcome maps to the event it actually submitted.
write_result github-review APPROVE APPROVE
expect APPROVED "" "$stale_reviews"
write_result github-review APPROVE APPROVE_WITH_SUGGESTIONS
expect APPROVED ""
write_result github-review REQUEST_CHANGES REQUEST_CHANGES
expect CHANGES_REQUESTED ""
write_result issue-comment COMMENT CHANGES_SUGGESTED
expect COMMENTED issue-comment-review "$stale_reviews"
write_result issue-comment COMMENT APPROVE true
expect MANUAL_APPROVAL_REQUIRED manual-approval-required
write_result issue-comment COMMENT ""
expect COMMENTED issue-comment-review

# A result file for another head (or PR) is not evidence for this one.
write_result github-review APPROVE APPROVE false "$old_head"
expect NOT_POSTED not-posted "$stale_reviews"

# Without a result file, accept only our review of this exact head from during
# this run: an older helper that posted but wrote no result.
rm -f "$result"
fresh=$(jq -nc --arg head "$head" --arg old "$old_head" '[[
  {user: {login: "tvdavies"}, state: "CHANGES_REQUESTED", commit_id: $old, submitted_at: "2026-10-01T15:25:05Z"},
  {user: {login: "someone-else"}, state: "APPROVED", commit_id: $head, submitted_at: "2026-10-02T07:15:00Z"},
  {user: {login: "tvdavies"}, state: "COMMENTED", commit_id: $head, submitted_at: "2026-10-02T07:16:00Z"}
]]')
expect COMMENTED commented-review "$fresh"
fresh_approved=$(jq -nc --arg head "$head" '[{user: {login: "tvdavies"}, state: "APPROVED",
  commit_id: $head, submitted_at: "2026-10-02T07:16:00Z"}]')
expect APPROVED "" "$fresh_approved"
expect NOT_POSTED not-posted ''
expect NOT_POSTED not-posted 'not json'

# Status -> ntfy mapping. INCOMPLETE and NOT_POSTED never say "changes requested".
[[ $(ntfy_kind_for_state APPROVED) == approved ]] || fail "APPROVED kind"
[[ $(ntfy_kind_for_state CHANGES_REQUESTED) == changes-requested ]] || fail "CHANGES_REQUESTED kind"
[[ $(ntfy_kind_for_state COMMENTED) == commented ]] || fail "COMMENTED kind"
[[ $(ntfy_kind_for_state MANUAL_APPROVAL_REQUIRED) == awaiting-approval ]] || fail "manual kind"
[[ $(ntfy_kind_for_state INCOMPLETE) == incomplete ]] || fail "INCOMPLETE kind"
[[ $(ntfy_kind_for_state NOT_POSTED) == not-posted ]] || fail "NOT_POSTED kind"

IFS=$'\t' read -r title priority tags <<<"$(ntfy_message_spec incomplete 7250)"
[[ "$title" == "Review incomplete on #7250" && "$priority" == default && "$tags" == hourglass ]] \
  || fail "incomplete ntfy spec: $title|$priority|$tags"
IFS=$'\t' read -r title priority tags <<<"$(ntfy_message_spec not-posted 7250)"
[[ "$title" == "Review not posted for #7250" && "$priority" == high ]] \
  || fail "not-posted ntfy spec: $title|$priority|$tags"
IFS=$'\t' read -r title priority tags <<<"$(ntfy_message_spec changes-requested 7250)"
[[ "$title" == "Changes requested on #7250" && "$priority" == high && "$tags" == warning ]] \
  || fail "changes-requested ntfy spec"
IFS=$'\t' read -r title priority tags <<<"$(ntfy_message_spec failed 7250)"
[[ "$priority" == urgent ]] || fail "failed ntfy spec"
for kind in incomplete not-posted; do
  if ntfy_message_spec "$kind" 7250 | grep -qi 'changes requested'; then
    fail "$kind notification mentions changes requested"
  fi
  if ntfy_message_body "$kind" "Title" alice 1m0s | grep -qi 'changes requested'; then
    fail "$kind notification body mentions changes requested"
  fi
done
ntfy_message_body incomplete "Title" alice 6m14s | grep -q 'not approved' \
  || fail "incomplete body does not say it is not approved"
if ntfy_message_spec bogus 7250 >/dev/null; then
  fail "unknown ntfy kind produced a message"
fi

[[ $(ntfy_kind_for_state CONFLICTING) == conflicting ]] || fail "CONFLICTING kind"
IFS=$'\t' read -r title priority tags <<<"$(ntfy_message_spec conflicting 7250)"
[[ "$title" == "Merge conflicts on #7250" && "$priority" == default ]] || fail "conflicting ntfy spec"
ntfy_message_body conflicting "Title" alice 0m0s | grep -q 're-review once resolved' \
  || fail "conflicting body does not promise the re-review"

# A non-blocking verdict posted as an issue comment, with the result file
# missing (lleverage#7734: the reviewer pointed the helper elsewhere). Our
# comment from during the run is the review; an older one is not.
rm -f "$result"
comments=$(jq -nc --arg at "2026-10-02T07:15:00Z" --arg head "$head" \
  '[[{user:{login:"tvdavies"},created_at:$at,body:("review\n\n<!-- pr-review reviewed-head=" + $head + " -->")}]]')
IFS=$'\t' read -r state source <<<"$(review_run_outcome "$result" "$repo" "$pr" "$head" '[]' tvdavies "$started" "$comments")"
[[ "$state|$source" == "COMMENTED|issue-comment-review" ]] || fail "issue comment during the run: $state|$source"
old_comment=$(jq -nc '[[{user:{login:"tvdavies"},created_at:"2026-10-01T07:15:00Z"}]]')
IFS=$'\t' read -r state source <<<"$(review_run_outcome "$result" "$repo" "$pr" "$head" '[]' tvdavies "$started" "$old_comment")"
[[ "$state" == NOT_POSTED ]] || fail "an issue comment from before the run counted: $state"
unmarked=$(jq -nc '[[{user:{login:"tvdavies"},created_at:"2026-10-02T07:15:00Z",body:"an unrelated comment"}]]')
IFS=$'\t' read -r state source <<<"$(review_run_outcome "$result" "$repo" "$pr" "$head" '[]' tvdavies "$started" "$unmarked")"
[[ "$state" == NOT_POSTED ]] || fail "an unmarked comment of ours counted as a review: $state"
other_head=$(jq -nc --arg old "$old_head" \
  '[[{user:{login:"tvdavies"},created_at:"2026-10-02T07:15:00Z",body:("review\n<!-- pr-review reviewed-head=" + $old + " -->")}]]')
IFS=$'\t' read -r state source <<<"$(review_run_outcome "$result" "$repo" "$pr" "$head" '[]' tvdavies "$started" "$other_head")"
[[ "$state" == NOT_POSTED ]] || fail "a review comment for another head counted: $state"
someone_else=$(jq -nc '[[{user:{login:"bob"},created_at:"2026-10-02T07:15:00Z"}]]')
IFS=$'\t' read -r state source <<<"$(review_run_outcome "$result" "$repo" "$pr" "$head" '[]' tvdavies "$started" "$someone_else")"
[[ "$state" == NOT_POSTED ]] || fail "someone else's comment counted: $state"

echo "review-outcome tests passed"
