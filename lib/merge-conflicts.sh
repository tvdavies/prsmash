#!/usr/bin/env bash
#
# Merge-conflict handling. A PR that cannot merge into its base is not worth a
# full review: whatever we say about the code changes once the author resolves
# the conflicts, and the conflicts are the thing actually stopping the PR. So
# prsmash checks mergeability first and, when the branch conflicts, posts a
# short notice naming the conflicting files and saying a re-review follows once
# they are resolved. It posts again only for a head whose conflicting files
# differ from the latest notice, so pushes that leave the conflicts alone stay
# quiet.

PRSMASH_CONFLICT_MARKER_PREFIX="<!-- prsmash:merge-conflict"

# pr_merge_state PR_JSON -> CONFLICTING | MERGEABLE | UNKNOWN
#
# PR_JSON is the REST pulls/N object. GitHub computes mergeability lazily:
# `mergeable` is null until a background job finishes, so UNKNOWN is common on
# the first read.
pr_merge_state() {
  jq -r '
    if .mergeable == false and ((.mergeable_state // "") | ascii_downcase) == "dirty" then "CONFLICTING"
    elif .mergeable == true then "MERGEABLE"
    else "UNKNOWN" end' <<<"$1" 2>/dev/null || echo UNKNOWN
}

# refresh_pr_merge_state REPO PR [PR_JSON]
#
# Prints the PR JSON once GitHub has computed mergeability, polling a few times
# when it has not. Gives up quietly and prints the last answer: an unknown
# mergeability never blocks a review.
refresh_pr_merge_state() {
  local repo=$1 pr_number=$2 pr_json=${3:-}
  local attempts=${PRSMASH_MERGEABLE_POLL_ATTEMPTS:-4} delay=${PRSMASH_MERGEABLE_POLL_SECS:-3} i fresh

  for ((i = 0; i < attempts; i++)); do
    if [[ -n "$pr_json" && $(pr_merge_state "$pr_json") != UNKNOWN ]]; then
      break
    fi
    [[ $i -gt 0 || -n "$pr_json" ]] && sleep "$delay"
    fresh=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null) || continue
    pr_json=$fresh
  done
  printf '%s\n' "$pr_json"
}

# merge_conflict_files REPO_DIR BASE_COMMIT HEAD_COMMIT [BASE_LABEL]
#
# Trial-merges HEAD into BASE without touching any worktree or ref
# (`git merge-tree --write-tree`, git 2.38+) and prints one line per
# conflicting path: "KIND<TAB>PATH<TAB>DETAIL". KIND is the git conflict type
# (content, modify/delete, add/add, rename/delete, ...). DETAIL says which side
# deleted or renamed the file, where git reports it. Returns 0 with no output
# for a clean merge, 2 when the trial merge could not run at all.
merge_conflict_files() {
  local repo_dir=$1 base=$2 head=$3 base_label=${4:-base} out rc=0
  out=$(git -C "$repo_dir" merge-tree --write-tree --name-only "$base" "$head" 2>/dev/null) || rc=$?
  [[ $rc -eq 0 ]] && return 0
  [[ $rc -eq 1 ]] || return 2

  python3 - "$base" "$head" "$out" "$base_label" <<'PY'
import re, sys

base, head, out, base_label = sys.argv[1:5]
lines = out.split("\n")
# Line 0 is the merged tree. Conflicted paths follow until the first blank
# line; informational messages come after it.
paths, i = [], 1
while i < len(lines) and lines[i] != "":
    paths.append(lines[i])
    i += 1
messages = [l for l in lines[i + 1:] if l.startswith("CONFLICT (")]

def side(label):
    if label == head:
        return "this PR"
    if label == base:
        return f"`{base_label}`"
    return label

seen = []
for path in dict.fromkeys(paths):
    kind, detail = "content", ""
    for message in messages:
        if path not in message:
            continue
        m = re.match(r"CONFLICT \(([^)]+)\)", message)
        kind = m.group(1) if m else "content"
        d = re.search(r"deleted in (\S+?) and modified in (\S+?)\.", message)
        if d:
            detail = f"deleted in {side(d.group(1))}, modified in {side(d.group(2))}"
        else:
            r = re.search(r"renamed to \S+ in (\S+?)[,.]", message)
            if r:
                detail = f"renamed in {side(r.group(1))}"
        break
    seen.append(f"{kind}\t{path}\t{detail}")
print("\n".join(seen))
PY
}

# conflict_fingerprint CONFLICTS_TSV -> short hash of the sorted conflicting
# paths, or "none" when the file list is unknown.
conflict_fingerprint() {
  local paths
  paths=$(cut -f2 <<<"$1" | sed '/^$/d' | LC_ALL=C sort -u)
  if [[ -z "$paths" ]]; then
    echo none
  else
    printf '%s\n' "$paths" | sha256sum | cut -c1-12
  fi
}

# A conflict where one side deleted, renamed or retyped the file cannot be
# resolved by picking lines: the other side's change has to be ported.
conflict_kind_is_risky() {
  case "$1" in
    content|add/add) return 1 ;;
    *) return 0 ;;
  esac
}

# conflict_notice_body HEAD BASE_REF BASE_COMMIT BEHIND_BY AUTHOR MY_REVIEW_STATE CONFLICTS_TSV
#
# The comment prsmash posts on a conflicting PR. It leads with what is wrong,
# then who has to do what, then the files. CONFLICTS_TSV is the output of
# merge_conflict_files (may be empty when the trial merge was unavailable).
conflict_notice_body() {
  local head=$1 base_ref=$2 base_commit=$3 behind_by=$4 author=$5 my_state=$6 conflicts=$7
  local count=0 risky=0 kind path detail rows="" risky_rows="" plain_rows="" behind_text=""

  while IFS=$'\t' read -r kind path detail; do
    [[ -n "$path" ]] || continue
    count=$((count + 1))
    if conflict_kind_is_risky "$kind"; then
      risky=$((risky + 1))
      risky_rows+="| \`${path}\` | ⚠️ ${kind}${detail:+: ${detail}} |"$'\n'
    else
      plain_rows+="| \`${path}\` | ${kind} |"$'\n'
    fi
  done <<<"$conflicts"
  rows="${risky_rows}${plain_rows}"

  if [[ "$behind_by" =~ ^[0-9]+$ && "$behind_by" -gt 0 ]]; then
    behind_text=" It is ${behind_by} commits behind \`${base_ref}\`."
  fi

  printf '%s head=%s files=%s -->\n' "$PRSMASH_CONFLICT_MARKER_PREFIX" "$head" "$(conflict_fingerprint "$conflicts")"
  printf '## ⛔ Merge conflicts with `%s`, not reviewed\n\n' "$base_ref"
  if [[ $count -gt 0 ]]; then
    printf '**This branch conflicts with `%s` in %d file%s, so I have not reviewed `%s`.**%s\n\n' \
      "$base_ref" "$count" "$([[ $count -eq 1 ]] || echo s)" "${head:0:10}" "$behind_text"
  else
    printf '**GitHub reports that this branch conflicts with `%s`, so I have not reviewed `%s`.**%s\n\n' \
      "$base_ref" "${head:0:10}" "$behind_text"
  fi

  printf '### To move this forward\n\n'
  if [[ $risky -gt 0 ]]; then
    printf -- '- **@%s:** merge or rebase onto `%s` and resolve the conflicts below. %d of them %s modify/delete-style conflict%s (marked ⚠️): one side removed or moved the file, so the other side'"'"'s change has to be ported, not just a side picked.\n' \
      "$author" "$base_ref" "$risky" "$([[ $risky -eq 1 ]] && echo is a || echo are)" "$([[ $risky -eq 1 ]] || echo s)"
  else
    printf -- '- **@%s:** merge or rebase onto `%s` and resolve the conflicts below.\n' "$author" "$base_ref"
  fi
  printf -- '- **Reviewer (prsmash):** I re-review automatically once the branch merges cleanly. Nothing else is needed from anyone until then.\n'
  if [[ "$my_state" == CHANGES_REQUESTED ]]; then
    printf '\nMy earlier "changes requested" review stays in place until then; the re-review replaces it with a fresh verdict.\n'
  fi

  if [[ -n "$rows" ]]; then
    printf '\n| File | Conflict |\n|---|---|\n%s' "$rows"
  fi
  printf '\n<sub>Trial merge of `%s` into `%s` at `%s`. I post again only if the conflicting files change.</sub>\n' \
    "${head:0:10}" "$base_ref" "${base_commit:0:10}"
}

# conflict_notice_already_posted REPO PR HEAD LOGIN [FINGERPRINT]
#
# True when one of our issue comments already carries the notice for this
# head, or when our latest notice (for any head) lists the same conflicting
# files and nothing of ours has been posted since. The second case keeps
# pushes that do not touch the conflicts from re-posting the same notice; a
# lost disposition file cannot double-post either way.
conflict_notice_already_posted() {
  local repo=$1 pr_number=$2 head=$3 login=$4 fingerprint=${5:-none} comments
  comments=$(gh api --paginate "repos/${repo}/issues/${pr_number}/comments" 2>/dev/null) || return 1
  printf '%s' "$comments" | jq -s -e --arg me "$login" --arg prefix "$PRSMASH_CONFLICT_MARKER_PREFIX" \
      --arg head "$head" --arg fp "$fingerprint" '
    [.[] | .[] | select(.user.login == $me)] as $mine
    | ($mine | map((.body // "") | capture("^" + $prefix + " head=(?<head>[0-9a-f]+)(?: files=(?<fp>[0-9a-f]+|none))? -->")? )) as $marks
    | ($marks | any(.head == $head))
      or ($fp != "none" and ($mine | length) > 0
          and (($mine | last | .body // "") | capture("^" + $prefix + " head=[0-9a-f]+ files=(?<fp>[0-9a-f]+) -->")? | .fp) == $fp)' \
    >/dev/null 2>&1
}
