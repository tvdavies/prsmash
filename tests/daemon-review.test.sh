#!/usr/bin/env bash
#
# End to end through bin/prsmash as prsmashd runs it: --queue-file instead of
# the queue script, and PRSMASH_CONTROL_DIR set, so the review goes through
# prsmash-session (stubbed here) rather than `pi -p`. Real temporary git
# remotes, stubbed gh/pi/curl; nothing touches GitHub, a model or ntfy.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/control"

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
printf 'change\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" commit -qam change
HEAD=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" push -q origin HEAD:refs/pull/7738/head
# The commit the author pushes mid-review.
printf 'follow-up\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" commit -qam follow-up
NEXT=$(git -C "$TMP/source" rev-parse HEAD)

jq -nc --arg head "$HEAD" '{repo:"example/widgets",user:"alice",prs:[{
  number:7738,title:"Org overview",author:{login:"bob"},headRefOid:$head,
  needsRereview:false,queueSource:"review-request",repository:{nameWithOwner:"example/widgets"}
}]}' > "$TMP/queue.json"

cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') printf 'example/widgets\n' ;;
  'pr view') jq -nc --arg base "$TEST_BASE" --arg head "$TEST_HEAD" \
    '{number:7738,baseRefName:"main",baseRefOid:$base,headRefName:"widget",headRefOid:$head}' ;;
  'pr diff') printf 'widget.txt\n' ;;
  'api --paginate') echo '[[]]' ;;
  'api repos/example/widgets/pulls/7738') jq -nc --arg head "$TEST_HEAD" \
    '{head:{sha:$head},additions:10,deletions:2}' ;;
  'api user') echo alice ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
# The timer path must not be used when prsmashd runs the review.
cat > "$TMP/bin/pi" <<'PI'
#!/usr/bin/env bash
echo "pi $*" >> "$TEST_RUNNER_LOG"
exit 0
PI
# Stub prsmash-session:
#   steered     the PR moved and the reviewer followed it: the expected head
#               now holds NEXT and the approval was posted against NEXT
#   superseded  the move could not be steered: exit 75, nothing posted
cat > "$TMP/bin/prsmash-session" <<'SESSION'
#!/usr/bin/env bash
{
  echo "session $*"
  echo "controlDir=$PRSMASH_CONTROL_DIR"
  echo "expectedHeadAtStart=$(cat "$PRSMASH_REVIEW_EXPECTED_HEAD_FILE")"
} >> "$TEST_RUNNER_LOG"
case "$TEST_SESSION_MODE" in
  steered)
    printf '%s\n' "$TEST_NEXT" > "$PRSMASH_REVIEW_EXPECTED_HEAD_FILE"
    jq -n --arg head "$TEST_NEXT" '{repo:"example/widgets",pr:7738,head:$head,
      posting:"github-review",event:"APPROVE",verdict:"APPROVE",manualApprovalRequired:false}' \
      > "$PRSMASH_REVIEW_RESULT_FILE"
    echo '## ✅ Approved' ;;
  superseded)
    echo 'PRSMASH_SUPERSEDED: head was force-pushed or rebased'
    exit 75 ;;
esac
SESSION
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CURL_LOG"
CURL
chmod +x "$TMP/bin/"*
: > "$TMP/runner.log"
: > "$TMP/curl.log"

run_prsmash() {
  env PATH="$TMP/bin:$PATH" HOME="$TMP" TEST_BASE="$BASE" TEST_HEAD="$HEAD" TEST_NEXT="$NEXT" \
    TEST_SESSION_MODE="$1" TEST_RUNNER_LOG="$TMP/runner.log" TEST_CURL_LOG="$TMP/curl.log" \
    PRSMASH_SESSION_BIN="$TMP/bin/prsmash-session" PRSMASH_CONTROL_DIR="$TMP/control" \
    PRSMASH_QUEUE_SCRIPT=/nonexistent PRSMASH_SOURCE_REPO="$TMP/source" PRSMASH_ALLOW_CONCURRENT=1 \
    PRSMASH_LOG_DIR="$TMP/logs" PRSMASH_SLACK_APPROVAL_NOTIFY=false PRSMASH_MERGEABLE_POLL_SECS=0 \
    PRSMASH_NTFY_NOTIFY=true PRSMASH_NTFY_SERVER=https://ntfy.invalid PRSMASH_NTFY_TOPIC=test \
    "$ROOT/bin/prsmash" --all --queue-file "$TMP/queue.json" > "$TMP/output" 2>&1 \
    || { cat "$TMP/output" >&2; fail "prsmash failed"; }
}
status() { cut -d'|' -f1-2 "$TMP/logs/latest/pr-7738.status"; }
recorded() { [[ -f "$TMP/logs/review-dispositions/example_widgets-7738-$1.json" ]]; }

# 1. Steered review: runs through prsmash-session, pinned with --head, and the
#    outcome and disposition land on the head it was steered onto.
run_prsmash steered
[[ $(status) == "OK|APPROVED" ]] || { cat "$TMP/output" >&2; fail "expected OK|APPROVED, got $(status)"; }
if rg -q '^pi ' "$TMP/runner.log"; then fail "the timer runner (pi -p) was used"; fi
rg -q -- "--head $HEAD" "$TMP/runner.log" || fail "review was not pinned with --head"
rg -q "controlDir=$TMP/control" "$TMP/runner.log" || fail "control dir not passed to the session"
rg -q "expectedHeadAtStart=$HEAD" "$TMP/runner.log" || fail "expected-head file did not start at the reviewed head"
recorded "$NEXT" || fail "no disposition for the steered head"
if recorded "$HEAD"; then fail "the head the review moved off was recorded"; fi
rg -q "prsmashOutcome=APPROVED head=$NEXT" "$TMP/logs/latest/"pr-7738-*.log || fail "log lacks the steered outcome"

# 2. Superseded: nothing recorded, no notification, counted separately.
rm -rf "$TMP/logs/review-dispositions"
notifications=$(wc -l < "$TMP/curl.log")
run_prsmash superseded
[[ $(status) == "OK|SUPERSEDED" ]] || { cat "$TMP/output" >&2; fail "expected OK|SUPERSEDED, got $(status)"; }
[[ -z "$(ls "$TMP/logs/review-dispositions" 2>/dev/null)" ]] || fail "a superseded review recorded a disposition"
[[ $(wc -l < "$TMP/curl.log") == "$notifications" ]] || fail "a superseded review sent a notification"
rg -q '^superseded=1$' "$TMP/logs/latest/summary.txt" || fail "summary did not count the superseded review"

# 3. Without prsmashd (the timer path) the review still runs `pi -p`, pinned.
: > "$TMP/runner.log"
rm -rf "$TMP/logs/review-dispositions"
env PATH="$TMP/bin:$PATH" HOME="$TMP" TEST_BASE="$BASE" TEST_HEAD="$HEAD" TEST_RUNNER_LOG="$TMP/runner.log" \
  TEST_CURL_LOG="$TMP/curl.log" PRSMASH_QUEUE_SCRIPT=/nonexistent PRSMASH_SOURCE_REPO="$TMP/source" \
  PRSMASH_ALLOW_CONCURRENT=1 PRSMASH_LOG_DIR="$TMP/logs" PRSMASH_SLACK_APPROVAL_NOTIFY=false \
  PRSMASH_MERGEABLE_POLL_SECS=0 PRSMASH_NTFY_NOTIFY=false \
  "$ROOT/bin/prsmash" --all --queue-file "$TMP/queue.json" > "$TMP/output" 2>&1 \
  || { cat "$TMP/output" >&2; fail "timer-path prsmash failed"; }
rg -q "^pi .*-p /skill:pr-review .*--head $HEAD" "$TMP/runner.log" || fail "timer path did not run pi -p with --head"

# 4. --approvals-only applies reactions and leaves no run directory behind.
runs_before=$(ls "$TMP/logs/runs" | wc -l)
env PATH="$TMP/bin:$PATH" HOME="$TMP" PRSMASH_LOG_DIR="$TMP/logs" PRSMASH_SOURCE_REPO="$TMP/source" \
  PRSMASH_ALLOW_CONCURRENT=1 PRSMASH_SLACK_APPROVAL_NOTIFY=false "$ROOT/bin/prsmash" --approvals-only > "$TMP/output" 2>&1 \
  || { cat "$TMP/output" >&2; fail "--approvals-only failed"; }
[[ $(ls "$TMP/logs/runs" | wc -l) == "$runs_before" ]] || fail "--approvals-only created a run directory"

echo "daemon review tests passed"
