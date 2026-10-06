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
  'pr checks') jq -nc --arg b "${TEST_CHECKS:-pending}" '[{bucket:"pass"},{bucket:$b}]' \
    | jq -r '.[].bucket' ; [[ "${TEST_CHECKS:-pending}" != pending ]] || exit 8 ;;
  'api --paginate') jq -nc --arg old "$TEST_OLD_HEAD" '[[{id:5381512887,user:{login:"alice"},
    state:"CHANGES_REQUESTED",commit_id:$old,submitted_at:"2026-10-01T15:25:05Z",
    body:"## 🔴 Changes Requested"}]]' ;;
  # After a "moved" review, GitHub reports the author's newer push.
  'api repos/example/widgets/pulls/5938') jq -nc \
    --arg head "$(cat "$TEST_MOVED_FILE" 2>/dev/null || printf '%s' "$TEST_HEAD")" \
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
if [[ "$TEST_PI_MODE" == moved ]]; then
  # The author pushed mid-review; the helper refused the stale head.
  printf '%s\n' 1111111111111111111111111111111111111111 > "$TEST_MOVED_FILE"
elif [[ "$TEST_PI_MODE" == held ]]; then
  # The helper with PRSMASH_HOLD_INCOMPLETE=true: nothing posted, body kept.
  [[ "$PRSMASH_HOLD_INCOMPLETE" == true ]] || { echo "hold not requested" >&2; exit 1; }
  printf '## ⚪ Review Incomplete (not approved)\n\nCI is still running the SDK tests.\n' \
    > "${PRSMASH_REVIEW_RESULT_FILE%.json}.held.md"
  jq -n --arg head "$PRSMASH_REVIEW_EXPECTED_HEAD" --arg body "${PRSMASH_REVIEW_RESULT_FILE%.json}.held.md" \
    '{repo:"example/widgets",pr:5938,head:$head,posting:"held",event:"",verdict:"INCOMPLETE",
      manualApprovalRequired:false,heldBody:$body}' > "$PRSMASH_REVIEW_RESULT_FILE"
elif [[ "$TEST_PI_MODE" == incomplete ]]; then
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
    TEST_MOVED_FILE="$TMP/moved-head" \
    PRSMASH_QUEUE_SCRIPT="$TMP/queue.sh" PRSMASH_SOURCE_REPO="$TMP/source" \
    PRSMASH_LOG_DIR="$TMP/logs" PRSMASH_SLACK_APPROVAL_NOTIFY=false PRSMASH_MERGEABLE_POLL_SECS=0 \
    PRSMASH_NTFY_NOTIFY=true PRSMASH_NTFY_SERVER=https://ntfy.invalid PRSMASH_NTFY_TOPIC=test \
    PRSMASH_REQUIRED_TOOLS="${TEST_TOOLS:-gh}" TEST_CHECKS="${TEST_CHECKS:-pending}" \
    PRSMASH_HELD_RETRY_MINS="${TEST_HELD_RETRY_MINS:-45}" \
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

# 5. A new head whose review cannot finish is held: nothing posted, no push.
new_head() {
  printf '%s\n' "$1" > "$TMP/source/widget.txt"
  git -C "$TMP/source" commit -qam "$1"
  HEAD=$(git -C "$TMP/source" rev-parse HEAD)
  git -C "$TMP/source" push -q -f origin HEAD:refs/pull/5938/head
}
new_head held
notifications=$(wc -l < "$TMP/curl.log")
run_prsmash held
[[ $(status) == "OK|INCOMPLETE_HELD" ]] || fail "expected OK|INCOMPLETE_HELD, got $(status)"
[[ $(pi_runs) == 3 ]] || fail "held head was not reviewed"
[[ $(disposition "$HEAD") == incomplete-held ]] || fail "held head was not recorded"
record="$TMP/logs/review-dispositions/example_widgets-5938-$HEAD.json"
jq -e '.heldAttempts == 1 and .ciFinishedAtHold == false' "$record" >/dev/null \
  || fail "held record is wrong: $(cat "$record")"
rg -q 'CI is still running' "$(jq -r .heldBody "$record")" || fail "held body was not kept"
[[ $(wc -l < "$TMP/curl.log") == "$notifications" ]] || fail "a held review sent a notification"
rg -q '^held=1$' "$TMP/logs/latest/summary.txt" || fail "summary did not count the held review"

# 6. CI still running: skipped. CI finished: retried.
run_prsmash held
[[ $(status) == "HANDLED|" ]] || fail "held head retried while CI was running: $(status)"
[[ $(pi_runs) == 3 ]] || fail "held head reviewed while CI was running"
TEST_CHECKS=pass run_prsmash held
[[ $(status) == "OK|INCOMPLETE_HELD" ]] || fail "CI finishing did not retry: $(status)"
[[ $(pi_runs) == 4 ]] || fail "held head was not retried after CI finished"
jq -e '.heldAttempts == 2 and .ciFinishedAtHold == true' "$record" >/dev/null \
  || fail "second hold not recorded: $(cat "$record")"
TEST_CHECKS=pass run_prsmash held
[[ $(status) == "HANDLED|" ]] || fail "finished CI retried twice: $(status)"

# 7. Backoff passes: the last attempt gives up and pushes once, privately.
TEST_CHECKS=pass TEST_HELD_RETRY_MINS=0 run_prsmash held
[[ $(status) == "OK|INCOMPLETE_GAVE_UP" ]] || fail "third hold did not give up: $(status)"
[[ $(pi_runs) == 5 ]] || fail "backoff did not retry"
rg -q 'Title: Review stuck on #5938' "$TMP/curl.log" || fail "no stuck notification"
rg -q 'CI is still running the SDK tests' "$TMP/curl.log" || fail "stuck notification lacks the reason"
TEST_CHECKS=pass TEST_HELD_RETRY_MINS=0 run_prsmash held
[[ $(status) == "HANDLED|" ]] || fail "a head that gave up was retried: $(status)"
[[ $(pi_runs) == 5 ]] || fail "a head that gave up was reviewed again"

# 8. A missing review tool is pushed once, not every tick.
TEST_TOOLS="gh no-such-review-tool" run_prsmash held
rg -q 'Review tools missing from PATH: no-such-review-tool' "$TMP/output" || fail "missing tool not printed"
[[ $(rg -c 'Title: Review tools missing: no-such-review-tool' "$TMP/curl.log") == 1 ]] \
  || fail "missing tool not pushed"
TEST_TOOLS="gh no-such-review-tool" run_prsmash held
[[ $(rg -c 'Title: Review tools missing' "$TMP/curl.log") == 1 ]] || fail "missing tool pushed again"

# 9. The author pushes mid-review and nothing is posted: superseded, no push,
#    and the old head is recorded (lleverage#7824's false "not posted" alert).
new_head moved
notifications=$(wc -l < "$TMP/curl.log")
run_prsmash moved
rm -f "$TMP/moved-head"
[[ $(status) == "OK|SUPERSEDED" ]] || fail "expected OK|SUPERSEDED, got $(status)"
[[ $(disposition "$HEAD") == superseded ]] || fail "superseded head was not recorded"
[[ $(wc -l < "$TMP/curl.log") == "$notifications" ]] || fail "a superseded review sent a notification"
rg -q '^superseded=1$' "$TMP/logs/latest/summary.txt" || fail "summary did not count the superseded review"

# 10. An unmoved head that publishes nothing is still NOT_POSTED and alerts.
new_head silent-again
run_prsmash silent
[[ $(status) == "OK|NOT_POSTED" ]] || fail "unmoved silent review not NOT_POSTED: $(status)"
rg -q 'Title: Review not posted for #5938' <(tail -n 3 "$TMP/curl.log") || fail "NOT_POSTED stopped alerting"

echo "incomplete review loop tests passed"
