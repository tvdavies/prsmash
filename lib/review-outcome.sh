#!/usr/bin/env bash
#
# What did this run do? Answered from this run's own evidence: the posting
# helper's result file, or a review GitHub holds for the exact reviewed head
# that was submitted during this run. GitHub's effective review state is never
# used on its own: it can be an older review of an older head, which once made
# an unposted INCOMPLETE re-review report (and notify) "changes requested".
#
# States written to the status file after a successful review run:
#   APPROVED                  an approval was posted on this head
#   CHANGES_REQUESTED         a blocking review was posted on this head
#   COMMENTED                 a non-blocking comment or review was posted
#   MANUAL_APPROVAL_REQUIRED  approval held back for a human (comment posted)
#   INCOMPLETE                a COMMENTED "review incomplete" review was posted
#   NOT_POSTED                the reviewer finished but published nothing
#   SUPERSEDED                abandoned because the head moved in a way the
#                             review could not follow; nothing recorded
#                             (written by prsmash itself, not by this function)
#   CONFLICTING               not reviewed: the branch conflicts with its base
#                             and a conflict notice was posted instead
#                             (written by prsmash itself, not by this function)

# review_run_outcome RESULT_FILE REPO PR HEAD REVIEWS_JSON LOGIN STARTED_AT [ISSUE_COMMENTS_JSON]
#
# Prints "STATE<TAB>DISPOSITION_SOURCE". A non-empty disposition source means
# the head must be recorded as handled, so later runs skip it until a new
# commit arrives. REVIEWS_JSON is the reviews listing (flat, or the page array
# from `gh api --paginate --slurp`); STARTED_AT is an ISO-8601 UTC timestamp
# (YYYY-MM-DDTHH:MM:SSZ) from before the review began. ISSUE_COMMENTS_JSON, when
# given, is the PR's issue-comment listing in the same shapes.
review_run_outcome() {
  local result_file=$1 repo=$2 pr_number=$3 head_oid=$4 reviews_json=$5 login=$6 started_at=$7
  local issue_comments_json=${8:-[]}
  local posting event verdict manual github_state commented

  if [[ -n "$result_file" && -f "$result_file" ]] \
      && [[ "$pr_number" =~ ^[0-9]+$ ]] \
      && jq -e --arg repo "$repo" --argjson pr "$pr_number" --arg head "$head_oid" \
          '.repo == $repo and .pr == $pr and .head == $head' "$result_file" >/dev/null 2>&1; then
    posting=$(jq -r '.posting // empty' "$result_file")
    event=$(jq -r '.event // empty' "$result_file")
    verdict=$(jq -r '.verdict // empty' "$result_file")
    manual=$(jq -r '.manualApprovalRequired // false' "$result_file")

    if [[ "$manual" == "true" ]]; then
      printf 'MANUAL_APPROVAL_REQUIRED\tmanual-approval-required\n'
    elif [[ "$verdict" == "INCOMPLETE" ]]; then
      printf 'INCOMPLETE\tincomplete-review\n'
    elif [[ "$posting" == "issue-comment" ]]; then
      # Issue comments are invisible to GitHub review state, so only the
      # disposition record keeps this head from being reviewed again.
      printf 'COMMENTED\tissue-comment-review\n'
    else
      case "$event" in
        APPROVE) printf 'APPROVED\t\n' ;;
        REQUEST_CHANGES) printf 'CHANGES_REQUESTED\t\n' ;;
        COMMENT) printf 'COMMENTED\tcommented-review\n' ;;
        *) printf 'NOT_POSTED\tnot-posted\n' ;;
      esac
    fi
    return 0
  fi

  # No result file: an older helper, or a posting that did not record one.
  # Accept only a review of ours on this exact head submitted during this run.
  github_state=$(jq -r --arg me "$login" --arg head "$head_oid" --arg since "$started_at" '
      (if length > 0 and (.[0] | type) == "array" then add else . end)
      | [.[] | select(.user.login == $me and .commit_id == $head
                      and (.submitted_at // "") >= $since)]
      | last | .state // empty' <<<"${reviews_json:-[]}" 2>/dev/null || true)

  case "$github_state" in
    APPROVED) printf 'APPROVED\t\n' ;;
    CHANGES_REQUESTED) printf 'CHANGES_REQUESTED\t\n' ;;
    COMMENTED) printf 'COMMENTED\tcommented-review\n' ;;
    *)
      # Non-blocking verdicts are posted as an issue comment, which has no
      # review state (lleverage#7734 was reported unposted after posting one).
      # Only a comment of ours from this run carrying the posting helper's
      # marker for this exact head counts; any other comment proves nothing.
      commented=$(jq -r --arg me "$login" --arg since "$started_at" \
          --arg marker "<!-- pr-review reviewed-head=${head_oid} -->" '
          (if length > 0 and (.[0] | type) == "array" then add else . end)
          | [.[] | select(.user.login == $me and (.created_at // "") >= $since
                          and ((.body // "") | contains($marker)))]
          | length' <<<"${issue_comments_json:-[]}" 2>/dev/null || echo 0)
      if [[ "$commented" =~ ^[0-9]+$ && "$commented" -gt 0 ]]; then
        printf 'COMMENTED\tissue-comment-review\n'
        return 0
      fi
      # Nothing was published for this head. Re-running the same review on the
      # same commit would only repeat that outcome every few minutes, so the
      # head is recorded as handled and the notification says what happened.
      printf 'NOT_POSTED\tnot-posted\n' ;;
  esac
}

# ntfy_kind_for_state STATE -> notification kind, or nothing for no push.
ntfy_kind_for_state() {
  case "$1" in
    APPROVED) echo approved ;;
    CHANGES_REQUESTED) echo changes-requested ;;
    COMMENTED) echo commented ;;
    MANUAL_APPROVAL_REQUIRED) echo awaiting-approval ;;
    INCOMPLETE) echo incomplete ;;
    NOT_POSTED) echo not-posted ;;
    CONFLICTING) echo conflicting ;;
    *) echo commented ;;
  esac
}

# ntfy_message_spec KIND PR_NUMBER -> "TITLE<TAB>PRIORITY<TAB>TAGS". Returns 1
# for an unknown kind, which callers treat as "send nothing".
ntfy_message_spec() {
  local kind=$1 pr_number=$2
  case "$kind" in
    approved) printf 'Approved #%s\tdefault\twhite_check_mark\n' "$pr_number" ;;
    changes-requested) printf 'Changes requested on #%s\thigh\twarning\n' "$pr_number" ;;
    commented) printf 'Commented on #%s\tdefault\tspeech_balloon\n' "$pr_number" ;;
    awaiting-approval) printf 'Needs your approval: #%s\thigh\teyes\n' "$pr_number" ;;
    incomplete) printf 'Review incomplete on #%s\tdefault\thourglass\n' "$pr_number" ;;
    not-posted) printf 'Review not posted for #%s\thigh\tgrey_question\n' "$pr_number" ;;
    conflicting) printf 'Merge conflicts on #%s\tdefault\tconstruction\n' "$pr_number" ;;
    failed) printf 'Review FAILED for #%s\turgent\trotating_light\n' "$pr_number" ;;
    *) return 1 ;;
  esac
}

# ntfy_message_body KIND TITLE AUTHOR TIME -> the push body for one PR.
ntfy_message_body() {
  local kind=$1 pr_title=$2 pr_author=$3 time_str=$4
  case "$kind" in
    failed) printf '%s (%s) — review errored after %s' "$pr_title" "$pr_author" "$time_str" ;;
    incomplete) printf '%s (%s) — commented, not approved: required coverage still missing (%s)' "$pr_title" "$pr_author" "$time_str" ;;
    not-posted) printf '%s (%s) — review finished but published nothing; this head will not be retried (%s)' "$pr_title" "$pr_author" "$time_str" ;;
    conflicting) printf '%s (%s) — conflicts with its base; posted the files, will re-review once resolved' "$pr_title" "$pr_author" ;;
    *) printf '%s (%s) — %s' "$pr_title" "$pr_author" "$time_str" ;;
  esac
}
