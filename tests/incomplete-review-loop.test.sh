#!/usr/bin/env bash
#
# End to end through bin/prsmash, with real temporary git remotes and stubbed
# gh, pi and curl. Nothing touches GitHub, a model or ntfy.sh.
#
# Reproduces lleverage#7250: a re-review ends INCOMPLETE while GitHub still
# holds our older CHANGES_REQUESTED review on an earlier head. The run must
# report its own outcome, notify to match, and leave the head handled so the
# next tick skips it instead of reviewing it again.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/source"
git -C "$TMP/source" config user.email test@example.test
git -C "$TMP/source" config user.name Test
printf 'base\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" add widget.txt
git -C "$TMP/source" commit -qm base
BASE=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" remote add origin "$TMP/remote.git"
git -C "$TMP/source" push -q origin main
printf 'reviewed\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" commit -qam reviewed
OLD_HEAD=$(git -C "$TMP/source" rev-parse HEAD)
printf 'fixed\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" commit -qam fix
HEAD=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" push -q origin HEAD:refs/pull/5938/head

cat > "$TMP/queue.sh" <<'QUEUE'
#!/usr/bin/env bash
jq -nc --arg head "$TEST_HEAD" --arg since "$TEST_OLD_HEAD" '{repo:"example/widgets",user:"alice",prs:[{
  number:5938,title:"Fix widget",author:{login:"bob"},headRefOid:$head,
  needsRereview:true,myReviewCommit:$since,myReviewState:"CHANGES_REQUESTED",
  queueSource:"review-request",repository:{nameWithOwner:"example/widgets"}
}]}'
QUEUE
# GitHub keeps our earlier blocking review on the old head throughout.
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') printf 'example/widgets\n' ;;
  'pr view') jq -nc --arg base "$TEST_BASE" --arg head "$TEST_HEAD" \
    '{number:5938,baseRefName:"main",baseRefOid:$base,headRefName:"widget",headRefOid:$head}' ;;
  'pr diff') printf 'widget.txt\n' ;;
  'api --paginate') jq -nc --arg old "$TEST_OLD_HEAD" '[[{id:5381512887,user:{login:"alice"},
    state:"CHANGES_REQUESTED",commit_id:$old,submitted_at:"2026-10-01T15:25:05Z",
    body:"## 🔴 Changes Requested"}]]' ;;
  'api repos/example/widgets/pulls/5938') jq -nc --arg head "$TEST_HEAD" \
    '{head:{sha:$head},additions:10,deletions:2}' ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
# incomplete: the fixed helper posted a COMMENTED review and wrote its result.
# silent: an older helper withheld the INCOMPLETE report and wrote nothing.
cat > "$TMP/bin/pi" <<'PI'
#!/usr/bin/env bash
echo run >> "$TEST_PI_LOG"
echo '## ⚪ Review Incomplete (not approved)'
if [[ "$TEST_PI_MODE" == incomplete ]]; then
  jq -n --arg head "$PRSMASH_REVIEW_EXPECTED_HEAD" '{repo:"example/widgets",pr:5938,head:$head,
    posting:"github-review",event:"COMMENT",verdict:"INCOMPLETE",manualApprovalRequired:false}' \
    > "$PRSMASH_REVIEW_RESULT_FILE"
fi
exit 0
PI
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CURL_LOG"
CURL
chmod +x "$TMP/queue.sh" "$TMP/bin/gh" "$TMP/bin/pi" "$TMP/bin/curl"
: > "$TMP/pi.log"
: > "$TMP/curl.log"

run_prsmash() {
  env PATH="$TMP/bin:$PATH" HOME="$TMP" TEST_BASE="$BASE" TEST_HEAD="$HEAD" TEST_OLD_HEAD="$OLD_HEAD" \
    TEST_PI_MODE="$1" TEST_PI_LOG="$TMP/pi.log" TEST_CURL_LOG="$TMP/curl.log" \
    PRSMASH_QUEUE_SCRIPT="$TMP/queue.sh" PRSMASH_SOURCE_REPO="$TMP/source" \
    PRSMASH_LOG_DIR="$TMP/logs" PRSMASH_SLACK_APPROVAL_NOTIFY=false PRSMASH_MERGEABLE_POLL_SECS=0 \
    PRSMASH_NTFY_NOTIFY=true PRSMASH_NTFY_SERVER=https://ntfy.invalid PRSMASH_NTFY_TOPIC=test \
    "$ROOT/bin/prsmash" --all > "$TMP/output" 2>&1 || { cat "$TMP/output" >&2; fail "prsmash failed"; }
}
status() { cut -d'|' -f1-2 "$TMP/logs/latest/pr-5938.status"; }
pi_runs() { wc -l < "$TMP/pi.log" | tr -d ' '; }
disposition() {
  jq -r .source "$TMP/logs/review-dispositions/example_widgets-5938-$1.json" 2>/dev/null || true
}

# 1. INCOMPLETE posted: its own status and notification, head recorded.
run_prsmash incomplete
[[ $(status) == "OK|INCOMPLETE" ]] || fail "expected OK|INCOMPLETE, got $(status)"
[[ $(pi_runs) == 1 ]] || fail "review did not run"
[[ $(disposition "$HEAD") == incomplete-review ]] || fail "INCOMPLETE head was not recorded as handled"
rg -q 'Title: Review incomplete on #5938' "$TMP/curl.log" || fail "no incomplete notification"
if rg -qi 'changes requested' "$TMP/curl.log"; then
  fail "INCOMPLETE run sent a changes-requested notification from the stale review"
fi
rg -q '^incomplete=1$' "$TMP/logs/latest/summary.txt" || fail "summary did not count the incomplete review"
rg -q '^changes_requested=0$' "$TMP/logs/latest/summary.txt" || fail "summary counted a stale changes request"
rg -q "prsmashOutcome=INCOMPLETE head=$HEAD" "$TMP/logs/latest/"pr-5938-*.log || fail "log lacks the run outcome"

# 2. Next tick, same head: skipped without reviewing or notifying again.
notifications=$(wc -l < "$TMP/curl.log")
run_prsmash incomplete
[[ $(status) == "HANDLED|" ]] || fail "same head was not skipped: $(status)"
[[ $(pi_runs) == 1 ]] || fail "same head was reviewed again"
[[ $(wc -l < "$TMP/curl.log") == "$notifications" ]] || fail "skipped head sent a notification"

# 3. New commit, and the reviewer publishes nothing: NOT_POSTED, never the
#    stale CHANGES_REQUESTED, and the new head is recorded too.
printf 'more\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" commit -qam more
HEAD=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" push -q -f origin HEAD:refs/pull/5938/head
run_prsmash silent
[[ $(status) == "OK|NOT_POSTED" ]] || fail "expected OK|NOT_POSTED, got $(status)"
[[ $(pi_runs) == 2 ]] || fail "new head was not reviewed"
[[ $(disposition "$HEAD") == not-posted ]] || fail "unposted head was not recorded as handled"
rg -q 'Title: Review not posted for #5938' "$TMP/curl.log" || fail "no not-posted notification"
if rg -qi 'changes requested' "$TMP/curl.log"; then
  fail "unposted run reported the stale changes-requested review"
fi

# 4. And that head is skipped on the next tick as well.
run_prsmash silent
[[ $(status) == "HANDLED|" ]] || fail "unposted head was not skipped: $(status)"
[[ $(pi_runs) == 2 ]] || fail "unposted head was reviewed again"

echo "incomplete review loop tests passed"
