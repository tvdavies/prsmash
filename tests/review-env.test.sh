#!/usr/bin/env bash
#
# Dependency install for review worktrees and the review-tool preflight, with
# a fake pnpm on PATH. Nothing is downloaded.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/review-env.sh
source "$ROOT/lib/review-env.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }

worktree="$TMP/worktree"
git init -q "$worktree"
printf 'node_modules\n' > "$worktree/.gitignore"
printf 'lockfileVersion: 9.0\n' > "$worktree/pnpm-lock.yaml"
git -C "$worktree" add .
git -C "$worktree" -c user.email=t@example.test -c user.name=T commit -qm base

# The fake records its arguments and the environment it saw, then installs.
cat > "$TMP/bin/pnpm" <<'PNPM'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_PNPM_LOG"
printf 'CI=%s HUSKY=%s\n' "${CI:-}" "${HUSKY:-}" >> "$FAKE_PNPM_LOG"
printf 'slack=%s ntfy=%s\n' "${SLACK_MCP_XOXC_TOKEN:-}" "${PRSMASH_NTFY_TOKEN:-}" >> "$FAKE_PNPM_LOG"
case "${FAKE_PNPM_MODE:-ok}" in
  fail) exit 3 ;;
  dirty) printf 'oops\n' > stray.txt; printf 'changed\n' >> .gitignore ;;
  dirty-fail) printf 'oops\n' > stray.txt; exit 4 ;;
esac
mkdir -p node_modules/.pnpm
PNPM
chmod +x "$TMP/bin/pnpm"
export FAKE_PNPM_LOG="$TMP/pnpm.log"

run_install() {
  env PATH="$TMP/bin:$PATH" "$@" bash -c \
    "source '$ROOT/lib/review-env.sh'; install_review_dependencies '$worktree' '$TMP/tmp'"
}

# Lockfile picks the command; scripts never run; the worktree stays clean.
[[ $(review_install_command "$worktree") == "pnpm install --frozen-lockfile --prefer-offline --ignore-scripts --ignore-pnpmfile" ]] \
  || fail "pnpm lockfile did not choose pnpm"
out=$(run_install SLACK_MCP_XOXC_TOKEN=secret PRSMASH_NTFY_TOKEN=tk_secret)
grep -qx 'slack= ntfy=' "$FAKE_PNPM_LOG" || fail "service secrets reached the install"
[[ "$out" =~ ^dependencies=installed\ \(pnpm,\ [0-9]+s\)$ ]] || fail "unexpected install line: $out"
grep -q -- '--ignore-scripts --ignore-pnpmfile' "$FAKE_PNPM_LOG" || fail "lifecycle scripts or pnpm hooks were not skipped"
grep -q 'CI=true HUSKY=0' "$FAKE_PNPM_LOG" || fail "install did not run with CI=true HUSKY=0"
[[ -d "$worktree/node_modules/.pnpm" ]] || fail "install did not run in the worktree"
[[ -f "$TMP/tmp/install.log" ]] || fail "install log not written"

# A failure is reported, never fatal.
out=$(run_install FAKE_PNPM_MODE=fail) || fail "a failed install was fatal"
[[ "$out" == "dependencies=failed (pnpm, exit 3 after "*"s; see $TMP/tmp/install.log)" ]] \
  || fail "unexpected failure line: $out"

# An install that leaves files behind is a failure: the reviewer checks the
# checkout is clean.
out=$(run_install FAKE_PNPM_MODE=dirty)
[[ "$out" == "dependencies=failed (pnpm left the worktree dirty, restored: "*"stray.txt"* ]] \
  || fail "dirty install was not reported: $out"
[[ -z $(git -C "$worktree" status --porcelain) ]] || fail "dirty install was not restored"
[[ -d "$worktree/node_modules/.pnpm" ]] || fail "restoring removed ignored node_modules"
out=$(run_install FAKE_PNPM_MODE=dirty-fail)
[[ "$out" == "dependencies=failed (pnpm, exit 4 after "* ]] || fail "dirty failed install: $out"
[[ -z $(git -C "$worktree" status --porcelain) ]] || fail "a failed install left the worktree dirty"

# Disabled, overridden, missing tool, no lockfile.
[[ $(run_install PRSMASH_INSTALL_DEPS=FALSE) == "dependencies=skipped (PRSMASH_INSTALL_DEPS=false)" ]] \
  || fail "PRSMASH_INSTALL_DEPS=false did not skip"
out=$(run_install PRSMASH_INSTALL_CMD='pnpm install --offline && pnpm --filter app exec prisma generate')
[[ "$out" == "dependencies=installed (pnpm, "* ]] || fail "override did not run: $out"
grep -q -- '--filter app exec prisma generate' "$FAKE_PNPM_LOG" || fail "override's second command did not run"
[[ $(run_install PRSMASH_INSTALL_CMD='yarnish install') == "dependencies=unavailable (yarnish not on PATH)" ]] \
  || fail "missing tool was not reported unavailable"
rm "$worktree/pnpm-lock.yaml"
[[ $(review_install_command "$worktree") == "" ]] || fail "no lockfile still chose a command"
[[ $(run_install) == "dependencies=skipped (no lockfile)" ]] || fail "no lockfile did not skip"
printf '{}\n' > "$worktree/package-lock.json"
[[ $(review_install_command "$worktree") == npm\ ci* ]] || fail "package-lock did not choose npm ci"

# Tool preflight lists exactly what is missing.
[[ -z $(PATH="$TMP/bin:$PATH" missing_review_tools pnpm git) ]] || fail "present tools reported missing"
[[ $(missing_review_tools git no-such-tool-x,no-such-tool-y | tr '\n' ' ') == "no-such-tool-x no-such-tool-y " ]] \
  || fail "missing tools not listed"
[[ $(PRSMASH_REQUIRED_TOOLS="git no-such-tool-z" missing_review_tools) == no-such-tool-z ]] \
  || fail "PRSMASH_REQUIRED_TOOLS not honoured"

echo "review-env tests passed"
