#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

BUILTIN_DEFAULT="anthropic-claude-code/claude-opus-4-8"

cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "FAIL: unexpected gh call: $*" >&2
exit 1
GH
chmod +x "$TMP/bin/gh"

# Stubbed pi registry so prsmash-model validation is deterministic and does not
# depend on the host's pi install.
cat > "$TMP/bin/pi" <<'PI'
#!/usr/bin/env bash
if [[ "$1" == "--list-models" ]]; then
  cat <<'TABLE'
provider               model                context  max-out  thinking  images
anthropic-claude-code  claude-opus-4-8      1M       128K     yes       yes
openai-codex           gpt-5.6-sol          400K     128K     yes       yes
TABLE
  exit 0
fi
echo "FAIL: unexpected pi call: $*" >&2
exit 1
PI
chmod +x "$TMP/bin/pi"

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
    -u PI_PRSMASH_MODEL \
    -u PRSMASH_MODEL_FILE \
    PATH="$TMP/bin:$PATH" \
    PRSMASH_QUEUE_SCRIPT="$TMP/queue.sh" \
    PRSMASH_SOURCE_REPO="$ROOT" \
    PRSMASH_LOG_DIR="$TMP/logs" \
    "${env_args[@]}" \
    "$ROOT/bin/prsmash" --dry-run "${cli_args[@]}" \
    >"$stdout_file" 2>"$stderr_file"
}

run_model_tool() {
  rm -f "$stdout_file" "$stderr_file"
  env \
    -u PI_PRSMASH_MODEL \
    -u PRSMASH_MODEL_FILE \
    PATH="$TMP/bin:$PATH" \
    PRSMASH_LOG_DIR="$TMP/logs" \
    "$ROOT/bin/prsmash-model" "$@" \
    >"$stdout_file" 2>"$stderr_file"
}

# --- prsmash default resolution ---

run_prsmash
rg -qF "Model: $BUILTIN_DEFAULT" "$stdout_file" \
  || fail "built-in default model was not used"

mkdir -p "$TMP/logs"
echo "openai-codex/gpt-5.6-sol" > "$TMP/logs/model"
run_prsmash
rg -qF "Model: openai-codex/gpt-5.6-sol" "$stdout_file" \
  || fail "model file was not read"

run_prsmash PI_PRSMASH_MODEL=env/override
rg -qF "Model: env/override" "$stdout_file" \
  || fail "environment did not override the model file"

run_prsmash --model flag/override
rg -qF "Model: flag/override" "$stdout_file" \
  || fail "--model flag did not override the model file"

echo "alt/model" > "$TMP/alt-model"
run_prsmash PRSMASH_MODEL_FILE="$TMP/alt-model"
rg -qF "Model: alt/model" "$stdout_file" \
  || fail "PRSMASH_MODEL_FILE override was not honoured"

# An empty or whitespace-only file must fall back to the built-in default.
printf '  \n' > "$TMP/logs/model"
run_prsmash
rg -qF "Model: $BUILTIN_DEFAULT" "$stdout_file" \
  || fail "empty model file did not fall back to the built-in default"
rm -f "$TMP/logs/model"

# --- prsmash-model utility ---

run_model_tool --show
rg -qF "Effective default: $BUILTIN_DEFAULT (built-in" "$stdout_file" \
  || fail "--show did not report the built-in default"

run_model_tool --list
rg -qF "openai-codex/gpt-5.6-sol" "$stdout_file" \
  || fail "--list did not include the stubbed model"

run_model_tool openai-codex/gpt-5.6-sol
[[ "$(cat "$TMP/logs/model")" == "openai-codex/gpt-5.6-sol" ]] \
  || fail "setting a valid model did not write the model file"

run_model_tool --show
rg -qF "Effective default: openai-codex/gpt-5.6-sol (from $TMP/logs/model)" "$stdout_file" \
  || fail "--show did not report the saved model"

if run_model_tool not-a/real-model; then
  fail "an invalid model was accepted"
fi
rg -qF "Not a valid pi model: not-a/real-model" "$stderr_file" \
  || fail "invalid model did not produce a validation error"
[[ "$(cat "$TMP/logs/model")" == "openai-codex/gpt-5.6-sol" ]] \
  || fail "invalid model overwrote the saved model file"

run_model_tool --clear
[[ ! -f "$TMP/logs/model" ]] \
  || fail "--clear did not remove the model file"

run_prsmash
rg -qF "Model: $BUILTIN_DEFAULT" "$stdout_file" \
  || fail "prsmash did not fall back to the built-in default after --clear"

echo "PASS: model configuration"
