#!/usr/bin/env bash
#
# Unit tests for lib/merge-conflicts.sh against real temporary git repos.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/merge-conflicts.sh
source "$ROOT/lib/merge-conflicts.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$TMP/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.test
git -C "$repo" config user.name Test
printf 'one\n' > "$repo/content.ts"
printf 'router\n' > "$repo/requests.ts"
printf 'admin\n' > "$repo/admin-self-access.ts"
printf 'same\n' > "$repo/clean.ts"
git -C "$repo" add .
git -C "$repo" commit -qm base

# The PR edits content.ts and requests.ts, and deletes admin-self-access.ts.
git -C "$repo" checkout -qb feature
printf 'pr\n' > "$repo/content.ts"
printf 'router changed in the PR\n' > "$repo/requests.ts"
git -C "$repo" rm -q admin-self-access.ts
git -C "$repo" commit -qam feature
head=$(git -C "$repo" rev-parse HEAD)

# Main edits content.ts and admin-self-access.ts, and deletes requests.ts.
git -C "$repo" checkout -q main
printf 'main\n' > "$repo/content.ts"
printf 'admin changed on main\n' > "$repo/admin-self-access.ts"
git -C "$repo" rm -q requests.ts
git -C "$repo" commit -qam main
base=$(git -C "$repo" rev-parse HEAD)

conflicts=$(merge_conflict_files "$repo" "$base" "$head" main)
[[ $(grep -c . <<<"$conflicts") -eq 3 ]] || fail "expected 3 conflicts, got: $conflicts"
grep -qP '^content\tcontent\.ts\t$' <<<"$conflicts" || fail "content conflict missing: $conflicts"
grep -qP '^modify/delete\trequests\.ts\tdeleted in `main`, modified in this PR$' <<<"$conflicts" \
  || fail "main-side delete not described: $conflicts"
grep -qP '^modify/delete\tadmin-self-access\.ts\tdeleted in this PR, modified in `main`$' <<<"$conflicts" \
  || fail "PR-side delete not described: $conflicts"
grep -q clean.ts <<<"$conflicts" && fail "a cleanly merging file was reported"

# A clean merge reports nothing and succeeds; a broken repo is an error.
git -C "$repo" checkout -qb tidy "$base"
printf 'more\n' > "$repo/clean.ts"
git -C "$repo" commit -qam tidy
[[ -z $(merge_conflict_files "$repo" "$base" "$(git -C "$repo" rev-parse HEAD)" main) ]] \
  || fail "clean merge reported conflicts"
rc=0
merge_conflict_files "$TMP/not-a-repo" "$base" "$head" main >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "unavailable trial merge did not return 2 (got $rc)"

# The notice leads with the verdict, names who acts, flags risky files first
# and promises the re-review.
body=$(conflict_notice_body "$head" main "$base" 78 jefftheai CHANGES_REQUESTED "$conflicts")
first_heading=$(grep -m1 '^## ' <<<"$body")
[[ "$first_heading" == '## ⛔ Merge conflicts with `main`, not reviewed' ]] || fail "heading: $first_heading"
fp=$(conflict_fingerprint "$conflicts")
[[ "$fp" =~ ^[0-9a-f]{12}$ ]] || fail "fingerprint: $fp"
[[ $(conflict_fingerprint "$(tac <<<"$conflicts")") == "$fp" ]] || fail "fingerprint depends on order"
[[ $(conflict_fingerprint "") == none ]] || fail "empty fingerprint"
grep -q "^<!-- prsmash:merge-conflict head=${head} files=${fp} -->$" <<<"$body" || fail "dedupe marker missing"
grep -q 'conflicts with `main` in 3 files' <<<"$body" || fail "file count missing"
grep -q '78 commits behind `main`' <<<"$body" || fail "behind count missing"
grep -q '^### To move this forward$' <<<"$body" || fail "action section missing"
grep -q '^- \*\*@jefftheai:\*\* merge or rebase onto `main`' <<<"$body" || fail "author action missing"
grep -q '2 of them are modify/delete-style conflicts' <<<"$body" || fail "risky count missing"
grep -q 're-review automatically once the branch merges cleanly' <<<"$body" || fail "re-review promise missing"
grep -q 'changes requested" review stays in place' <<<"$body" || fail "standing block not explained"
table=$(grep '^| `' <<<"$body")
[[ $(sed -n 1p <<<"$table") == *'⚠️ modify/delete'* && $(sed -n 2p <<<"$table") == *'⚠️ modify/delete'* ]] \
  || fail "risky files are not listed first: $table"
[[ $(sed -n 3p <<<"$table") == '| `content.ts` | content |' ]] || fail "content row: $table"
# Before the action section, nothing but the heading and the one-line verdict.
pre=$(sed -n '/^## /,/^### To move this forward$/p' <<<"$body" | grep -v '^$' | grep -vc '^#')
[[ "$pre" -eq 1 ]] || fail "more than a one-line verdict before the actions"

# Without our own block, no line about it; without a file list, still useful.
body=$(conflict_notice_body "$head" main "$base" "" bob APPROVED "")
grep -q 'review stays' <<<"$body" && fail "mentioned a block we do not hold"
grep -q 'GitHub reports that this branch conflicts with `main`' <<<"$body" || fail "no-file fallback"
grep -q '^| File' <<<"$body" && fail "empty file table rendered"

# Mergeability as GitHub reports it.
[[ $(pr_merge_state '{"mergeable":false,"mergeable_state":"dirty"}') == CONFLICTING ]] || fail dirty
[[ $(pr_merge_state '{"mergeable":true,"mergeable_state":"blocked"}') == MERGEABLE ]] || fail blocked
[[ $(pr_merge_state '{"mergeable":null,"mergeable_state":"unknown"}') == UNKNOWN ]] || fail unknown
[[ $(pr_merge_state 'not json') == UNKNOWN ]] || fail "bad json"

# Already posted: same head, or our latest comment is a notice for the same
# files. A different file set, or a later comment of ours, means post again.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
cat "$TEST_COMMENTS"
GH
chmod +x "$TMP/bin/gh"
other=$(printf '%040d' 1)
posted() {
  printf '%s' "$1" > "$TMP/comments.json"
  PATH="$TMP/bin:$PATH" TEST_COMMENTS="$TMP/comments.json" conflict_notice_already_posted example/widgets 1 "$2" alice "$3"
}
note() { jq -nc --arg u "$1" --arg b "$2" '{user:{login:$u},body:$b}'; }
mark() { printf '<!-- prsmash:merge-conflict head=%s files=%s -->\n## notice' "$1" "$2"; }
legacy="<!-- prsmash:merge-conflict head=${head} -->"
posted "[$(note alice "$(mark "$head" "$fp")")]" "$head" "$fp" || fail "same head not found"
posted "[$(note alice "$legacy")]" "$head" none || fail "legacy marker without files not found"
posted "[$(note alice "$(mark "$other" "$fp")")]" "$head" "$fp" || fail "same files on a new head re-posted"
posted "[$(note alice "$(mark "$other" abcdefabcdef)")]" "$head" "$fp" && fail "changed files not re-posted"
posted "[$(note alice "$(mark "$other" "$fp")"),$(note alice "## ✅ Approved")]" "$head" "$fp" \
  && fail "a newer comment of ours did not trigger a fresh notice"
posted "[$(note bob "$(mark "$head" "$fp")")]" "$head" "$fp" && fail "someone else's marker counted"
posted "[$(note alice "$(mark "$other" none)")]" "$head" none && fail "unknown file sets matched"

echo "merge conflict tests passed"
