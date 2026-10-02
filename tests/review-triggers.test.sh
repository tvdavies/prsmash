#!/usr/bin/env bash
#
# End to end through bin/prsmash with real temporary git remotes and stubbed
# gh, pi and curl. Nothing touches GitHub, a model or ntfy.sh.
#
# Covers what decides whether a head gets reviewed:
#   - a conflicting branch gets one conflict notice instead of a review
#     (lleverage#7250 at 638a9f7 conflicted with main in seven files);
#   - once it merges cleanly, the same head is reviewed;
#   - an overlapping run with a stale queue does not review the same head
#     twice (#7250 got two CHANGES_REQUESTED reviews on 3b758135);
#   - a person commenting after a review earns the head another look, capped
#     so an author-side bot cannot loop us.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

fail() { echo "FAIL: $*" >&2; exit 1; }

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/source"
git -C "$TMP/source" config user.email test@example.test
git -C "$TMP/source" config user.name Test
printf 'base\n' > "$TMP/source/widget.txt"
printf 'keep\n' > "$TMP/source/router.ts"
git -C "$TMP/source" add .
git -C "$TMP/source" commit -qm base
BASE=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" remote add origin "$TMP/remote.git"
git -C "$TMP/source" checkout -qb feature
printf 'pr\n' > "$TMP/source/widget.txt"
printf 'pr edit\n' > "$TMP/source/router.ts"
git -C "$TMP/source" commit -qam feature
HEAD=$(git -C "$TMP/source" rev-parse HEAD)
git -C "$TMP/source" checkout -q main
printf 'main\n' > "$TMP/source/widget.txt"
git -C "$TMP/source" rm -q router.ts
git -C "$TMP/source" commit -qam main
git -C "$TMP/source" push -q origin main
git -C "$TMP/source" push -q origin "$HEAD:refs/pull/5938/head"

cat > "$TMP/queue.sh" <<'QUEUE'
#!/usr/bin/env bash
jq -nc --arg head "$TEST_HEAD" --arg activity "$TEST_ACTIVITY" '{repo:"example/widgets",user:"alice",prs:[{
  number:5938,title:"Fix widget",author:{login:"bob"},headRefOid:$head,
  needsRereview:true,myReviewCommit:null,myReviewState:"CHANGES_REQUESTED",
  queueSource:"review-request",repository:{nameWithOwner:"example/widgets"},
  lastActivityAt:(if $activity == "" then null else $activity end)
}]}'
QUEUE
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
state=$TEST_STATE
case "$*" in
  'repo view'*) printf 'example/widgets\n' ;;
  'pr view'*) jq -nc --arg base "$TEST_BASE" --arg head "$TEST_HEAD" \
    '{number:5938,baseRefName:"main",baseRefOid:$base,headRefName:"widget",headRefOid:$head}' ;;
  'pr diff'*) printf 'router.ts\nwidget.txt\n' ;;
  'api repos/example/widgets/pulls/5938')
    jq -nc --arg head "$TEST_HEAD" --arg base "$TEST_BASE" --slurpfile m "$state/mergeable.json" \
      '{head:{sha:$head},base:{ref:"main",sha:$base},user:{login:"bob"},additions:10,deletions:2} + $m[0]' ;;
  'api --paginate repos/example/widgets/issues/5938/comments')
    if compgen -G "$state/comment-*.md" >/dev/null; then
      for f in $(ls "$state"/comment-*.md | sort -V); do
        jq -nc --rawfile body "$f" '{user:{login:"alice"},body:$body}'
      done | jq -sc .
    else
      echo '[]'
    fi ;;
  'api --method POST repos/example/widgets/issues/5938/comments'*)
    for arg in "$@"; do
      if [[ "$arg" == body=@* ]]; then
        cp "${arg#body=@}" "$state/posted.md"
        cp "${arg#body=@}" "$state/comment-$(ls "$state" | grep -c '^comment-').md"
      fi
    done
    echo post >> "$state/posts.log"
    echo 'https://github.com/example/widgets/pull/5938#issuecomment-1' ;;
  'api --paginate --slurp repos/example/widgets/pulls/5938/reviews') echo '[[]]' ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
cat > "$TMP/bin/pi" <<'PI'
#!/usr/bin/env bash
echo run >> "$TEST_STATE/pi.log"
echo '## ✅ Approved'
jq -n --arg head "$PRSMASH_REVIEW_EXPECTED_HEAD" '{repo:"example/widgets",pr:5938,head:$head,
  posting:"github-review",event:"APPROVE",verdict:"APPROVE",manualApprovalRequired:false}' \
  > "$PRSMASH_REVIEW_RESULT_FILE"
PI
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_STATE/curl.log"
CURL
chmod +x "$TMP/queue.sh" "$TMP/bin/gh" "$TMP/bin/pi" "$TMP/bin/curl"
: > "$TMP/state/pi.log"; : > "$TMP/state/posts.log"; : > "$TMP/state/curl.log"

mergeable() { printf '%s\n' "$1" > "$TMP/state/mergeable.json"; }
run_prsmash() {
  env PATH="$TMP/bin:$PATH" HOME="$TMP" TEST_BASE="$BASE" TEST_HEAD="$HEAD" TEST_STATE="$TMP/state" \
    TEST_ACTIVITY="${1:-}" PRSMASH_QUEUE_SCRIPT="$TMP/queue.sh" PRSMASH_SOURCE_REPO="$TMP/source" \
    PRSMASH_LOG_DIR="$TMP/logs" PRSMASH_SLACK_APPROVAL_NOTIFY=false PRSMASH_MERGEABLE_POLL_SECS=0 \
    PRSMASH_NTFY_NOTIFY=true PRSMASH_NTFY_SERVER=https://ntfy.invalid PRSMASH_NTFY_TOPIC=test \
    "$ROOT/bin/prsmash" --all > "$TMP/output" 2>&1 || { cat "$TMP/output" >&2; fail "prsmash failed"; }
}
status() { cut -d'|' -f1-2 "$TMP/logs/latest/pr-5938.status"; }
count() { wc -l < "$TMP/state/$1" | tr -d ' '; }
disposition() { jq -r ".$1" "$TMP/logs/review-dispositions/example_widgets-5938-$HEAD.json" 2>/dev/null || true; }

# 1. Conflicting: no review, one notice naming both files, risky one flagged.
mergeable '{"mergeable":false,"mergeable_state":"dirty"}'
run_prsmash
[[ $(status) == "OK|CONFLICTING" ]] || fail "expected OK|CONFLICTING, got $(status)"
[[ $(count pi.log) == 0 ]] || fail "a conflicting PR was reviewed"
[[ $(count posts.log) == 1 ]] || fail "conflict notice not posted"
[[ $(disposition source) == merge-conflict ]] || fail "conflict head not recorded"
grep -q '^## ⛔ Merge conflicts with `main`, not reviewed$' "$TMP/state/posted.md" || fail "notice heading"
grep -q '| `router.ts` | ⚠️ modify/delete: deleted in `main`, modified in this PR |' "$TMP/state/posted.md" \
  || fail "modify/delete file not flagged: $(cat "$TMP/state/posted.md")"
grep -q '| `widget.txt` | content |' "$TMP/state/posted.md" || fail "content conflict not listed"
grep -q '^- \*\*@bob:\*\*' "$TMP/state/posted.md" || fail "author action missing"
grep -q 'changes requested" review stays in place' "$TMP/state/posted.md" || fail "standing block not explained"
grep -q 'Title: Merge conflicts on #5938' "$TMP/state/curl.log" || fail "no conflict notification"
grep -q '^conflicting=1$' "$TMP/logs/latest/summary.txt" || fail "summary did not count the conflict"
git -C "$TMP/source" for-each-ref 'refs/prsmash/' | grep -q . && fail "temporary refs left behind"

# 2. Still conflicting next tick: skipped, nothing posted or reviewed.
run_prsmash
[[ $(status) == "HANDLED|" ]] || fail "conflicting head not skipped: $(status)"
[[ $(count posts.log) == 1 && $(count pi.log) == 0 ]] || fail "conflicting head acted on twice"

# 3. A lost disposition file cannot double-post: our marker comment is found.
rm "$TMP/logs/review-dispositions/example_widgets-5938-$HEAD.json"
run_prsmash
[[ $(status) == "OK|CONFLICTING" ]] || fail "expected OK|CONFLICTING after state loss, got $(status)"
[[ $(count posts.log) == 1 ]] || fail "notice posted twice for one head"

# 3b. A push that leaves the same files conflicting: no second notice, but the
#     new head is recorded so it is not reviewed while it conflicts.
push_head() {
  git -C "$TMP/source" checkout -q "$HEAD"
  printf '%s\n' "$1" > "$TMP/source/$2"
  git -C "$TMP/source" add "$2"
  git -C "$TMP/source" commit -qm "push $1"
  HEAD=$(git -C "$TMP/source" rev-parse HEAD)
  git -C "$TMP/source" push -q -f origin "$HEAD:refs/pull/5938/head"
  git -C "$TMP/source" checkout -q main
}
FIRST_HEAD=$HEAD
push_head unrelated notes.txt
run_prsmash
[[ $(status) == "OK|CONFLICTING" && $(count posts.log) == 1 ]] || fail "same conflicts re-posted on a new head"
[[ $(disposition source) == merge-conflict ]] || fail "unchanged-conflict head not recorded"

# 3c. A push that changes which files conflict: a fresh notice.
push_head 'pr again' widget2.txt
git -C "$TMP/source" checkout -q main
printf 'main side\n' > "$TMP/source/widget2.txt"
git -C "$TMP/source" add widget2.txt
git -C "$TMP/source" commit -qm 'main adds widget2'
git -C "$TMP/source" push -q origin main
run_prsmash
[[ $(status) == "OK|CONFLICTING" && $(count posts.log) == 2 ]] || fail "changed conflicts not re-posted"
grep -q '| `widget2.txt` | add/add |' "$TMP/state/posted.md" || fail "new conflict missing: $(cat "$TMP/state/posted.md")"

# 4. GitHub still computing mergeability: no review of a known-conflicting head.
mergeable '{"mergeable":null,"mergeable_state":"unknown"}'
run_prsmash
[[ $(status) == "HANDLED|" && $(count pi.log) == 0 ]] || fail "unknown mergeability reviewed a noticed head"
[[ $(count posts.log) == 2 ]] || fail "unknown mergeability posted"

# 5. Conflicts gone on the same head (base moved): reviewed now.
mergeable '{"mergeable":true,"mergeable_state":"clean"}'
run_prsmash
[[ $(status) == "OK|APPROVED" ]] || fail "expected OK|APPROVED, got $(status)"
[[ $(count pi.log) == 1 ]] || fail "resolved head was not reviewed"
[[ $(disposition source) == approved-review ]] || fail "approval not recorded: $(disposition source)"

# 6. An overlapping run whose queue predates that review: no second review.
run_prsmash 2026-01-01T00:00:00Z
[[ $(status) == "HANDLED|" && $(count pi.log) == 1 ]] || fail "same head reviewed twice from a stale queue"

# 7. Someone comments after the review: one more look, counted; capped at two.
later=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)
run_prsmash "$later"
[[ $(status) == "OK|APPROVED" && $(count pi.log) == 2 ]] || fail "new activity did not earn a re-review"
[[ $(disposition activityRereviews) == 1 ]] || fail "activity re-review not counted"
grep -q "^activityRereview=1 lastActivityAt=${later}$" "$TMP/logs/latest/"pr-5938-*.log || fail "log lacks the trigger"
later=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)
run_prsmash "$later"
[[ $(count pi.log) == 3 && $(disposition activityRereviews) == 2 ]] || fail "second activity re-review"
later=$(date -u -d '+15 minutes' +%Y-%m-%dT%H:%M:%SZ)
run_prsmash "$later"
[[ $(status) == "HANDLED|" && $(count pi.log) == 3 ]] || fail "activity re-reviews were not capped"

echo "review trigger tests passed"
