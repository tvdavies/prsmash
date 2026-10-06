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
#                             (only with PRSMASH_HOLD_INCOMPLETE=false)
#   INCOMPLETE_HELD           the review could not finish; nothing was posted
#                             and the head will be retried
#   INCOMPLETE_GAVE_UP        held on every allowed attempt; nothing posted,
#                             the operator is told privately
#                             (both written by prsmash from INCOMPLETE_HELD)
#   NOT_POSTED                the reviewer finished but published nothing
#   SUPERSEDED                nothing was posted because the PR moved to a
#                             new head during the review; the new head is
#                             reviewed on the next tick (written by prsmash
#                             via superseded_state, not by this function)
#   CONFLICTING               not reviewed: the branch conflicts with its base
#                             and a conflict notice was posted instead
#                             (written by prsmash itself, not by this function)

# review_run_outcome RESULT_FILE REPO PR HEAD REVIEWS_JSON LOGIN STARTED_AT
#
# Prints "STATE<TAB>DISPOSITION_SOURCE". A non-empty disposition source means
# the head must be recorded as handled, so later runs skip it until a new
# commit arrives. REVIEWS_JSON is the reviews listing (flat, or the page array
# from `gh api --paginate --slurp`); STARTED_AT is an ISO-8601 UTC timestamp
# (YYYY-MM-DDTHH:MM:SSZ) from before the review began.
review_run_outcome() {
  local result_file=$1 repo=$2 pr_number=$3 head_oid=$4 reviews_json=$5 login=$6 started_at=$7
  local posting event verdict manual github_state

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
    elif [[ "$posting" == "held" ]]; then
      printf 'INCOMPLETE_HELD\tincomplete-held\n'
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
    INCOMPLETE_HELD) ;; # retried quietly; only giving up is worth a push
    INCOMPLETE_GAVE_UP) echo held-gave-up ;;
    NOT_POSTED) echo not-posted ;;
    SUPERSEDED) ;; # routine: the new head is reviewed next tick
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
    held-gave-up) printf 'Review stuck on #%s\thigh\tpause_button\n' "$pr_number" ;;
    not-posted) printf 'Review not posted for #%s\thigh\tgrey_question\n' "$pr_number" ;;
    conflicting) printf 'Merge conflicts on #%s\tdefault\tconstruction\n' "$pr_number" ;;
    failed) printf 'Review FAILED for #%s\turgent\trotating_light\n' "$pr_number" ;;
    *) return 1 ;;
  esac
}

# ntfy_message_body KIND TITLE AUTHOR TIME [DETAIL] -> the push body for one PR.
ntfy_message_body() {
  local kind=$1 pr_title=$2 pr_author=$3 time_str=$4 detail=${5:-}
  case "$kind" in
    held-gave-up) printf '%s (%s) — review could not finish after every retry; nothing was posted on the PR. %s' "$pr_title" "$pr_author" "$detail" ;;
    failed) printf '%s (%s) — review errored after %s' "$pr_title" "$pr_author" "$time_str" ;;
    incomplete) printf '%s (%s) — commented, not approved: required coverage still missing (%s)' "$pr_title" "$pr_author" "$time_str" ;;
    not-posted) printf '%s (%s) — review finished but published nothing; this head will not be retried (%s)' "$pr_title" "$pr_author" "$time_str" ;;
    conflicting) printf '%s (%s) — conflicts with its base; posted the files, will re-review once resolved' "$pr_title" "$pr_author" ;;
    *) printf '%s (%s) — %s' "$pr_title" "$pr_author" "$time_str" ;;
  esac
}

# held_review_reason BODY_FILE -> one line saying why a held review could not
# finish: the body's first prose line (after the verdict heading), cut to 240
# characters. Nothing when the file is missing.
held_review_reason() {
  local file=$1
  [[ -n "$file" && -f "$file" ]] || return 0
  awk '
    /^[[:space:]]*$/ || /^#/ || /^<!--/ || /^>/ || /^---/ { next }
    { print; exit }
  ' "$file" | cut -c1-240
}

# superseded_state STATE ANALYZED_HEAD CURRENT_HEAD -> the state to report.
#
# A review that published nothing because the author pushed mid-review is not
# a stuck head: the posting helper refuses a stale head by design, and the new
# head has no disposition, so the next tick reviews it. lleverage#7824 raised a
# high-priority "will not be retried" alert for exactly this. Any other state,
# or an unknown current head, is returned unchanged.
superseded_state() {
  local state=$1 analyzed_head=$2 current_head=$3
  if [[ "$state" == NOT_POSTED && -n "$current_head" && -n "$analyzed_head" \
        && "$current_head" != "$analyzed_head" ]]; then
    echo SUPERSEDED
  else
    echo "$state"
  fi
}
