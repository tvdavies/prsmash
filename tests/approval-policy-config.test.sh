#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "FAIL: unexpected gh call: $*" >&2
exit 1
GH
chmod +x "$TMP/bin/gh"

cat > "$TMP/queue.sh" <<'QUEUE'
#!/usr/bin/env bash
printf '%s\n' '{"repo":null,"user":"tvdavies","prs":[]}'
QUEUE
chmod +x "$TMP/queue.sh"

stdout_file="$TMP/stdout.log"
stderr_file="$TMP/stderr.log"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_prsmash() {
  local env_args=() cli_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == *=* && ${#cli_args[@]} -eq 0 ]]; then
      env_args+=("$1")
    else
      cli_args+=("$1")
    fi
    shift
  done

  rm -f "$stdout_file" "$stderr_file"
  env \
    -u PRSMASH_TRUSTED_AUTHORS \
    -u PRSMASH_APPROVAL_LINE_LIMIT \
    -u PRSMASH_APPROVAL_MAX_LINES \
    -u PRSMASH_AUTO_APPROVE_ALL \
    PATH="$TMP/bin:$PATH" \
    PRSMASH_QUEUE_SCRIPT="$TMP/queue.sh" \
    PRSMASH_SOURCE_REPO="$ROOT" \
    PRSMASH_LOG_DIR="$TMP/logs" \
    "${env_args[@]}" \
    "$ROOT/bin/prsmash" --dry-run "${cli_args[@]}" \
    >"$stdout_file" 2>"$stderr_file"
}

run_prsmash
rg -q 'Human approval: untrusted authors with 1001\+ changed lines' "$stdout_file" \
  || fail "default 1001-line policy was not displayed"

run_prsmash PRSMASH_APPROVAL_MAX_LINES=1501
rg -q 'Human approval: untrusted authors with 1501\+ changed lines' "$stdout_file" \
  || fail "legacy line-limit alias was not applied"

run_prsmash --approval-line-limit 2001
rg -q 'Human approval: untrusted authors with 2001\+ changed lines' "$stdout_file" \
  || fail "CLI line-limit override was not applied"

run_prsmash PRSMASH_TRUSTED_AUTHORS=
rg -q 'no trusted-author list — every eligible PR will be approved' "$stdout_file" \
  || fail "empty trusted-author list did not disable the gate"

run_prsmash PRSMASH_AUTO_APPROVE_ALL=TrUe PRSMASH_APPROVAL_LINE_LIMIT=invalid
rg -q 'Approval policy: override enabled' "$stdout_file" \
  || fail "global auto-approval override was not enabled"

if run_prsmash PRSMASH_AUTO_APPROVE_ALL=yes; then
  fail "invalid auto-approval override was accepted"
fi
rg -q 'PRSMASH_AUTO_APPROVE_ALL must be true or false' "$stderr_file" \
  || fail "invalid override did not report a configuration error"

for invalid_limit in 0 abc; do
  if run_prsmash PRSMASH_APPROVAL_LINE_LIMIT="$invalid_limit"; then
    fail "invalid approval line limit '$invalid_limit' was accepted"
  fi
  rg -q 'PRSMASH_APPROVAL_LINE_LIMIT must be a positive integer' "$stderr_file" \
    || fail "invalid line limit '$invalid_limit' did not report a configuration error"
done

if run_prsmash --approval-line-limit; then
  fail "missing CLI line-limit value was accepted"
fi
rg -q -- '--approval-line-limit requires a value' "$stderr_file" \
  || fail "missing CLI line-limit value did not report an error"

echo "approval policy configuration tests passed"
