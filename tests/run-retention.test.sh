#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/run-retention.sh"
TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A read-only directory stands in for files owned by a container's user: rm -rf
# as us cannot delete its contents. Root can, so the foreign-owned cases only
# mean something for an unprivileged user.
make_runs() {
  chmod -R u+w "$TMP/runs" 2>/dev/null || true
  rm -rf "$TMP/runs"
  mkdir -p "$TMP/runs/old-plain/tmp" "$TMP/runs/old-foreign/tmp/pr-1/chdata" "$TMP/runs/recent/tmp"
  touch "$TMP/runs/old-plain/tmp/file" "$TMP/runs/old-foreign/tmp/pr-1/chdata/part" "$TMP/runs/recent/tmp/file"
  chmod 555 "$TMP/runs/old-foreign/tmp/pr-1/chdata"
  touch -d '10 days ago' "$TMP/runs/old-plain" "$TMP/runs/old-foreign"
}

# Stub docker: record the call, then do what the root container would do.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -v ]]; then host=${2%%:*}; shift 2; else shift; fi
done
chmod -R u+w "$host" && find "$host" -mindepth 1 -delete
DOCKER
chmod +x "$TMP/bin/docker"
export DOCKER_LOG="$TMP/docker.log"

# Old directories go, recent ones stay, and docker empties the foreign-owned one.
make_runs
PATH="$TMP/bin:$PATH" prune_old_runs "$TMP/runs" 7
[[ ! -e "$TMP/runs/old-plain" ]] || fail "old run directory was kept"
[[ -d "$TMP/runs/recent" ]] || fail "recent run directory was removed"
if [[ "$EUID" -ne 0 ]]; then
  [[ ! -e "$TMP/runs/old-foreign" ]] || fail "foreign-owned run directory was kept"
  grep -q -- "--user 0:0 -v $TMP/runs/old-foreign:/target busybox:stable find /target -mindepth 1 -delete" "$DOCKER_LOG" \
    || fail "docker was not used to empty the foreign-owned directory: $(cat "$DOCKER_LOG")"
  [[ $(wc -l < "$DOCKER_LOG") -eq 1 ]] || fail "docker ran for directories rm -rf could delete"
fi

# Without docker the foreign-owned directory is reported and left in place.
if [[ "$EUID" -ne 0 ]]; then
  make_runs
  mkdir -p "$TMP/nodocker"
  for tool in find rm; do ln -sf "$(command -v "$tool")" "$TMP/nodocker/$tool"; done
  err=$(PATH="$TMP/nodocker" prune_old_runs "$TMP/runs" 7 2>&1 >/dev/null)
  [[ -d "$TMP/runs/old-foreign" ]] || fail "foreign-owned directory vanished without docker"
  [[ "$err" == *"could not remove old run directory $TMP/runs/old-foreign"* ]] || fail "missing warning: $err"
fi

# Invalid or disabled retention never deletes anything.
make_runs
for days in 0 abc ''; do
  PATH="$TMP/bin:$PATH" prune_old_runs "$TMP/runs" "$days"
  [[ -d "$TMP/runs/old-plain" ]] || fail "retention '$days' deleted a run directory"
done

echo "run-retention tests passed"
