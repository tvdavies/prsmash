#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${QUEUE_SCRIPT_UNDER_TEST:-$ROOT/lib/review-queue.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  'repo view') printf 'example/widgets\n' ;;
  'search prs')
    if [[ "$*" == *--review-requested=alice* ]]; then
      printf '%s\n' "$REQUESTED_PRS"
    else
      printf '%s\n' "$REVIEWED_PRS"
    fi ;;
  'api graphql') printf '%s\n' "$GRAPHQL_PR" ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"

pr='{"number":123,"author":{"login":"bob"},"title":"Fix widget","repository":{"nameWithOwner":"example/widgets"}}'
reviewed_head=1111111111111111111111111111111111111111
new_head=2222222222222222222222222222222222222222
base=$(jq -nc --arg head "$new_head" '{data:{repository:{pullRequest:{
  headRefOid:$head, commits:{nodes:[{commit:{committedDate:"2026-09-30T12:00:00Z"}}]},
  reviews:{nodes:[]}, reviewThreads:{nodes:[]}
}}}}')

run_case() {
  local expected=$1 requested=$2 reviewed=$3 graphql=$4 result
  result=$(env PATH="$TMP/bin:$PATH" REQUESTED_PRS="$requested" \
    REVIEWED_PRS="$reviewed" GRAPHQL_PR="$graphql" bash "$SCRIPT" --user alice)
  [[ $(jq '.prs | length' <<<"$result") == "$expected" ]] || {
    echo "Unexpected queue: $result" >&2
    exit 1
  }
  printf '%s\n' "$result"
}

# CodeRabbit can be absent, blocking, or have unresolved threads: initial
# reviews still run, but another human reviewer's objection keeps its behaviour.
run_case 1 "[$pr]" '[]' "$base" >/dev/null
for bot in coderabbitai 'coderabbitai[bot]' CodeRabbitAI; do
  blocking=$(jq --arg bot "$bot" '.data.repository.pullRequest.reviews.nodes =
    [{author:{login:$bot},state:"CHANGES_REQUESTED",submittedAt:"2026-09-30T11:00:00Z"}]' <<<"$base")
  run_case 1 "[$pr]" '[]' "$blocking" >/dev/null
done
human=$(jq '.data.repository.pullRequest.reviews.nodes =
  [{author:{login:"carol"},state:"CHANGES_REQUESTED",submittedAt:"2026-09-30T11:00:00Z"}]' <<<"$base")
run_case 0 "[$pr]" '[]' "$human" >/dev/null

mine=$(jq --arg head "$reviewed_head" '.data.repository.pullRequest.reviews.nodes =
  [{author:{login:"alice"},state:"CHANGES_REQUESTED",submittedAt:"2026-09-30T11:00:00Z",commit:{oid:$head}}]' <<<"$base")
bot_thread=$(jq '.data.repository.pullRequest.reviewThreads.nodes = [{
  isResolved:false,origin:{nodes:[{author:{login:"coderabbitai"}}]},
  comments:{nodes:[{author:{login:"bob"},createdAt:"2026-09-30T11:30:00Z"}]}
}]' <<<"$mine")
result=$(run_case 1 '[]' "[$pr]" "$bot_thread")
jq -e '.prs[0].queueSource == "threads-resolved" and .prs[0].threadsUnresolved == 1' <<<"$result" >/dev/null
own_thread=$(jq '.data.repository.pullRequest.reviewThreads.nodes[0].origin.nodes[0].author.login = "alice"' <<<"$bot_thread")
run_case 0 '[]' "[$pr]" "$own_thread" >/dev/null

# An unchanged, already reviewed PR must not get re-reviewed just because
# CodeRabbit is blocking or because it remains review-requested.
unchanged=$(jq '.data.repository.pullRequest.commits.nodes[0].commit.committedDate = "2026-09-30T10:00:00Z"' <<<"$mine")
run_case 0 "[$pr]" '[]' "$unchanged" >/dev/null

# An INCOMPLETE round posts a COMMENTED review on the new head after an earlier
# CHANGES_REQUESTED. That head is now handled: neither a lingering review
# request nor the previously-reviewed path may pick it up again.
incomplete=$(jq --arg old "$reviewed_head" --arg new "$new_head" '.data.repository.pullRequest.reviews.nodes = [
  {author:{login:"alice"},state:"CHANGES_REQUESTED",submittedAt:"2026-09-30T11:00:00Z",commit:{oid:$old}},
  {author:{login:"alice"},state:"COMMENTED",submittedAt:"2026-09-30T13:00:00Z",commit:{oid:$new}}
]' <<<"$base")
run_case 0 "[$pr]" '[]' "$incomplete" >/dev/null
run_case 0 '[]' "[$pr]" "$incomplete" >/dev/null

# The next push re-enters through threads-resolved: the COMMENTED review does
# not hide the standing block, and the incremental base is the incomplete head.
pushed_after=$(jq '.data.repository.pullRequest.commits.nodes[0].commit.committedDate = "2026-09-30T14:00:00Z"' <<<"$incomplete")
result=$(run_case 1 '[]' "[$pr]" "$pushed_after")
jq -e --arg new "$new_head" '.prs[0].queueSource == "threads-resolved"
  and .prs[0].myReviewState == "CHANGES_REQUESTED"
  and .prs[0].myReviewCommit == $new
  and .prs[0].myReviewAt == "2026-09-30T13:00:00Z"' <<<"$result" >/dev/null \
  || { echo "INCOMPLETE head did not re-enter on push: $result" >&2; exit 1; }

# Authors often answer a review in a PR comment, not a thread reply. A person's
# comment after our review counts as a reply (with lastActivityAt exposed for
# prsmash's per-head check); bot comments do not.
answered=$(jq '.data.repository.pullRequest.comments.nodes = [
  {author:{login:"bob",__typename:"User"},createdAt:"2026-09-30T11:45:00Z"}]' <<<"$unchanged")
result=$(run_case 1 "[$pr]" '[]' "$answered")
jq -e '.prs[0].lastActivityAt == "2026-09-30T11:45:00Z"' <<<"$result" >/dev/null \
  || { echo "issue-comment reply was not exposed: $result" >&2; exit 1; }
for bot in '{"login":"coderabbitai","__typename":"Bot"}' '{"login":"linear-code","__typename":"User"}' \
    '{"login":"github-actions[bot]","__typename":"User"}' '{"login":"alice","__typename":"User"}'; do
  botted=$(jq --argjson a "$bot" '.data.repository.pullRequest.comments.nodes = [
    {author:$a,createdAt:"2026-09-30T11:45:00Z"}]' <<<"$unchanged")
  run_case 0 "[$pr]" '[]' "$botted" >/dev/null
done

# A "changes suggested" round is only COMMENTED: once the author pushes or
# answers, it re-enters for a real verdict instead of waiting forever for a
# review request that never comes (lleverage#7325). Its own threads do not
# need resolving first.
suggested=$(jq --arg head "$reviewed_head" '.data.repository.pullRequest.reviews.nodes =
  [{author:{login:"alice"},state:"COMMENTED",submittedAt:"2026-09-30T11:00:00Z",commit:{oid:$head}}]
  | .data.repository.pullRequest.commits.nodes[0].commit.committedDate = "2026-09-30T10:00:00Z"' <<<"$base")
run_case 0 '[]' "[$pr]" "$suggested" >/dev/null
suggested_answered=$(jq '.data.repository.pullRequest.comments.nodes = [
  {author:{login:"bob",__typename:"User"},createdAt:"2026-09-30T12:30:00Z"}]' <<<"$suggested")
result=$(run_case 1 '[]' "[$pr]" "$suggested_answered")
jq -e '.prs[0].queueSource == "suggestions-answered"' <<<"$result" >/dev/null \
  || { echo "answered COMMENTED round did not re-enter: $result" >&2; exit 1; }
suggested_pushed=$(jq '.data.repository.pullRequest.commits.nodes[0].commit.committedDate = "2026-09-30T12:00:00Z"
  | .data.repository.pullRequest.reviewThreads.nodes = [{isResolved:false,
      origin:{nodes:[{author:{login:"alice"}}]},comments:{nodes:[{author:{login:"alice",__typename:"User"},createdAt:"2026-09-30T11:00:00Z"}]}}]' <<<"$suggested")
result=$(run_case 1 '[]' "[$pr]" "$suggested_pushed")
jq -e '.prs[0].queueSource == "suggestions-answered"' <<<"$result" >/dev/null \
  || { echo "pushed COMMENTED round with open suggestion threads did not re-enter: $result" >&2; exit 1; }

echo "review queue tests passed"
