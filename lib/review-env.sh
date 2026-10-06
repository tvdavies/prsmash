#!/usr/bin/env bash
#
# The review environment: tools the reviewer needs on PATH, and a review
# worktree's dependencies installed before the reviewer starts, so it
# can run the changed tests instead of reporting them unverifiable
# (lleverage#7821 got two "Review Incomplete" rounds because the worktree had
# no node_modules).
#
# Lifecycle scripts and pnpm hooks (.pnpmfile.cjs) are skipped by default: they
# are PR-controlled code that runs before anyone has read it, and in lleverage
# they reach outside the worktree (a preinstall that pip-installs into the
# user's Python, husky writing the git config every worktree shares). A repo
# that needs a generate step names it in PRSMASH_INSTALL_CMD. The install also
# runs without the service's secrets (Slack, ntfy, model keys) in its
# environment. It is not a sandbox: the reviewer runs the PR's tests anyway.
#
#   PRSMASH_INSTALL_DEPS     false to skip installing (default true)
#   PRSMASH_INSTALL_CMD      shell command run in the worktree instead of the
#                            lockfile default
#   PRSMASH_INSTALL_TIMEOUT  seconds before the install is killed (default 900)

# review_install_command WORKTREE -> the default install command for the
# worktree's lockfile, or nothing when there is no lockfile we know.
review_install_command() {
  local worktree=$1
  if [[ -f "$worktree/pnpm-lock.yaml" ]]; then
    echo "pnpm install --frozen-lockfile --prefer-offline --ignore-scripts --ignore-pnpmfile"
  elif [[ -f "$worktree/bun.lock" || -f "$worktree/bun.lockb" ]]; then
    echo "bun install --frozen-lockfile --ignore-scripts"
  elif [[ -f "$worktree/package-lock.json" ]]; then
    echo "npm ci --prefer-offline --ignore-scripts --no-audit --no-fund"
  elif [[ -f "$worktree/yarn.lock" ]]; then
    echo "yarn install --frozen-lockfile --ignore-scripts"
  fi
}

# install_review_dependencies WORKTREE TMP_DIR
#
# Prints one "dependencies=..." line: installed, failed, unavailable or
# skipped, with the reason. Always returns 0: a failed install leaves the
# reviewer less to run, it does not stop the review.
install_review_dependencies() {
  local worktree=$1 tmp_dir=$2
  local enabled cmd tool timeout_secs log start rc=0 elapsed dirty

  enabled=$(printf '%s' "${PRSMASH_INSTALL_DEPS:-true}" | tr '[:upper:]' '[:lower:]')
  if [[ "$enabled" == false ]]; then
    echo "dependencies=skipped (PRSMASH_INSTALL_DEPS=false)"
    return 0
  fi

  cmd=${PRSMASH_INSTALL_CMD:-$(review_install_command "$worktree")}
  if [[ -z "$cmd" ]]; then
    echo "dependencies=skipped (no lockfile)"
    return 0
  fi
  tool=${cmd%% *}
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "dependencies=unavailable (${tool} not on PATH)"
    return 0
  fi

  timeout_secs=${PRSMASH_INSTALL_TIMEOUT:-900}
  [[ "$timeout_secs" =~ ^[0-9]+$ && "$timeout_secs" -gt 0 ]] || timeout_secs=900
  mkdir -p "$tmp_dir"
  log="$tmp_dir/install.log"
  start=$(date +%s)
  (
    cd "$worktree" || exit 1
    local runner=(timeout --kill-after=30 "$timeout_secs" bash -c "$cmd")
    command -v ionice >/dev/null 2>&1 && runner=(ionice -c3 "${runner[@]}")
    command -v nice >/dev/null 2>&1 && runner=(nice -n 10 "${runner[@]}")
    env -u SLACK_MCP_XOXC_TOKEN -u SLACK_MCP_XOXD_TOKEN -u PRSMASH_NTFY_TOKEN \
      -u PI_CLAUDE_CODE_API_KEY_FILE -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
      CI=true HUSKY=0 "${runner[@]}"
  ) > "$log" 2>&1 || rc=$?
  elapsed=$(( $(date +%s) - start ))

  # The reviewer checks that its checkout is clean, so an install that leaves
  # tracked or unignored files behind is undone (ignored files such as
  # node_modules stay) and reported as failed.
  dirty=$(git -C "$worktree" status --porcelain 2>/dev/null | head -5)
  if [[ -n "$dirty" ]]; then
    git -C "$worktree" reset -q --hard >/dev/null 2>&1 || true
    git -C "$worktree" clean -qfd >/dev/null 2>&1 || true
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "dependencies=failed (${tool}, exit ${rc} after ${elapsed}s; see ${log})"
    return 0
  fi
  if [[ -n "$dirty" ]]; then
    echo "dependencies=failed (${tool} left the worktree dirty, restored: $(tr '\n' ' ' <<<"$dirty"))"
    return 0
  fi
  echo "dependencies=installed (${tool}, ${elapsed}s)"
}

# missing_review_tools [TOOL...] -> the tools not on PATH, one per line.
#
# The reviewer treats a tool missing from PATH as unavailable and works around
# it, which has cost whole reviews: lleverage#7664 could not read its Linear
# ticket because linear-cli was not on the service PATH. Checking at the start
# of every run turns a silent PATH regression into a visible one.
#   PRSMASH_REQUIRED_TOOLS  space or comma separated (default:
#                           gh git jq pi linear-cli pnpm)
missing_review_tools() {
  local tools tool
  if [[ $# -gt 0 ]]; then
    tools="$*"
  else
    tools=${PRSMASH_REQUIRED_TOOLS:-gh git jq pi linear-cli pnpm}
  fi
  for tool in ${tools//,/ }; do
    command -v "$tool" >/dev/null 2>&1 || echo "$tool"
  done
}
