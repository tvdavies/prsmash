#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/review-timeout.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }
for values in '0 7200 1001' '2700 0 1001' '2700 7200 0' 'invalid 7200 1001' '7201 7200 1001'; do
  # shellcheck disable=SC2086
  if validate_review_timeout_config $values 2>/dev/null; then
    fail "invalid timeout configuration accepted: $values"
  fi
done
validate_review_timeout_config 2700 7200 1001

# Exercise the runner with real temporary git remotes and stubbed GitHub/pi.
# No network request, model execution or two-hour wait occurs.
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
printf 'new\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" commit -qam change
HEAD=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" push -q origin HEAD:refs/pull/5938/head

cat > "$TMP/queue.sh" <<'QUEUE'
#!/usr/bin/env bash
jq -nc --arg head "$TEST_HEAD" --arg since "${TEST_SINCE:-}" '{repo:"example/widgets",user:"alice",prs:[{
  number:5938,title:"Fix widget",author:{login:"bob"},headRefOid:$head,
  needsRereview:($since != ""),myReviewCommit:$since,
  queueSource:"review-request",repository:{nameWithOwner:"example/widgets"}
}]}'
QUEUE
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') printf 'example/widgets\n' ;;
  'api repos/example/widgets') printf 'example/widgets\n' ;;
  'api user') printf 'alice\n' ;;
  'pr view') jq -nc --arg base "$TEST_BASE" --arg head "$TEST_HEAD" \
    '{number:5938,baseRefName:"main",baseRefOid:$base,headRefName:"widget",headRefOid:$head}' ;;
  'pr diff') printf 'widget.txt\n' ;;
  'api --paginate') printf '[[]]\n' ;;
  'api repos/example/widgets/pulls/5938') jq -nc --arg head "$TEST_HEAD" \
    --argjson lines "$TEST_LINES" '{head:{sha:$head},additions:$lines,deletions:0}' ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
cat > "$TMP/bin/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
[[ "$1" == --kill-after=60 ]] || exit 1
printf '%s\n' "$2" > "$TEST_TIMEOUT_CAPTURE"
shift 2
exec "$@"
TIMEOUT
cat > "$TMP/bin/pi" <<'PI'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_PI_CAPTURE"
# A successful review posts through the helper, which writes its result file.
# Without one the run counts as NOT_POSTED and the head is recorded as handled.
if [[ "$TEST_PI_EXIT" == 0 && -n "${PRSMASH_REVIEW_RESULT_FILE:-}" ]]; then
  jq -n --arg head "$PRSMASH_REVIEW_EXPECTED_HEAD" '{repo:"example/widgets",pr:5938,head:$head,
    posting:"github-review",event:"APPROVE",verdict:"APPROVE",manualApprovalRequired:false}' \
    > "$PRSMASH_REVIEW_RESULT_FILE"
fi
exit "$TEST_PI_EXIT"
PI
chmod +x "$TMP/queue.sh" "$TMP/bin/gh" "$TMP/bin/pi" "$TMP/bin/timeout"

run_review() {
  local expected=$1 lines=$2 exit_code=$3
  # Every completed review now records its head as handled, approvals
  # included. This test re-runs one head on purpose to exercise the timeout
  # budget, so it starts each run without those records (the timeout state
  # lives separately, in review-timeouts/).
  rm -rf "$TMP/logs/review-dispositions"
  env PATH="$TMP/bin:$PATH" TEST_BASE="$BASE" TEST_HEAD="$HEAD" TEST_LINES="$lines" \
    TEST_SINCE="${TEST_SINCE:-}" \
    TEST_PI_EXIT="$exit_code" TEST_TIMEOUT_CAPTURE="$TMP/timeout" TEST_PI_CAPTURE="$TMP/pi" \
    PRSMASH_QUEUE_SCRIPT="$TMP/queue.sh" PRSMASH_SOURCE_REPO="$TMP/source" \
    PRSMASH_LOG_DIR="$TMP/logs" PRSMASH_NTFY_NOTIFY=false PRSMASH_SLACK_APPROVAL_NOTIFY=false PRSMASH_MERGEABLE_POLL_SECS=0 \
    PRSMASH_REVIEW_TIMEOUT=2700 PRSMASH_MAX_REVIEW_TIMEOUT=7200 PRSMASH_LARGE_PR_LINES=1001 \
    "$ROOT/bin/prsmash" --all > "$TMP/output" 2>&1 || {
      cat "$TMP/output" >&2
      fail "runner failed"
    }
  [[ $(cat "$TMP/timeout") == "$expected" ]] || fail "expected $expected seconds"
  rg -q -- '--independent-checks' "$TMP/pi" || fail "review did not receive independent-checks policy"
}

run_review 2700 1000 124
run_review 5400 1000 124
run_review 7200 1000 124
run_review 7200 1000 0
run_review 2700 1000 124

# A pushed revision starts afresh, even if the preceding head timed out.
previous_head=$HEAD
printf 'another\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" commit -qam next
HEAD=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" push -q origin HEAD:refs/pull/5938/head
run_review 2700 1000 0
run_review 7200 1001 0
TEST_SINCE=$previous_head run_review 2700 1000 0
rg -q -- "--since $previous_head" "$TMP/pi" || fail "incremental review lost its previous head"

echo "review timeout tests passed"
