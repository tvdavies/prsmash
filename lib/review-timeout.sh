#!/usr/bin/env bash

validate_review_timeout_config() {
  local value
  for value in "$@"; do
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
      echo "Review timeout configuration must contain positive integers." >&2
      return 1
    fi
  done
  if [[ "$1" -gt "$2" ]]; then
    echo "PRSMASH_REVIEW_TIMEOUT must not exceed PRSMASH_MAX_REVIEW_TIMEOUT." >&2
    return 1
  fi
}

review_timeout_count() {
  local file=$1
  if [[ -f "$file" ]]; then
    jq -er '.timeouts | select(type == "number" and . >= 0 and floor == .)' "$file" 2>/dev/null || printf '0\n'
  else
    printf '0\n'
  fi
}

review_timeout_seconds() {
  local changed_lines=$1 timeouts=$2 seconds=$3 maximum=$4 large_pr_lines=$5
  if [[ "$changed_lines" -ge "$large_pr_lines" ]]; then
    printf '%s\n' "$maximum"
    return
  fi
  while [[ "$timeouts" -gt 0 && "$seconds" -lt "$maximum" ]]; do
    # Cap before multiplication to avoid overflow even with custom budgets.
    if [[ "$seconds" -gt "$((maximum / 2))" ]]; then
      seconds=$maximum
    else
      seconds=$((seconds * 2))
    fi
    timeouts=$((timeouts - 1))
  done
  printf '%s\n' "$seconds"
}

record_review_timeout() {
  local file=$1 count=$2 tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  if jq -n --argjson count "$count" '{timeouts: $count}' > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}
