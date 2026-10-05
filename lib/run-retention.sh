#!/usr/bin/env bash

# Delete run directories under $1 older than $2 days.
#
# Reviews sometimes start containers that bind-mount a directory in the run's
# tmp/ (ClickHouse data, for example). Files the container creates belong to
# its user (uid 101 for ClickHouse), so a plain rm -rf as us leaves them, and
# the run directory, behind forever. When that happens, empty the directory
# from inside a throwaway container running as root, then remove it.
#
# PRSMASH_CLEANUP_IMAGE selects that container image (default busybox:stable).
prune_old_runs() {
  local runs_dir=$1 retention_days=$2 dir
  [[ -d "$runs_dir" ]] || return 0
  [[ "$retention_days" =~ ^[0-9]+$ && "$retention_days" -gt 0 ]] || return 0

  while IFS= read -r -d '' dir; do
    rm -rf "$dir" 2>/dev/null || true
    [[ -e "$dir" ]] || continue
    remove_foreign_owned_dir "$dir" || echo "prsmash: could not remove old run directory $dir" >&2
  done < <(find "$runs_dir" -mindepth 1 -maxdepth 1 -type d -mtime "+${retention_days}" -print0 2>/dev/null)
}

remove_foreign_owned_dir() {
  local dir=$1 image="${PRSMASH_CLEANUP_IMAGE:-busybox:stable}"
  command -v docker >/dev/null 2>&1 || return 1
  docker run --rm --network none --user 0:0 -v "$dir:/target" "$image" \
    find /target -mindepth 1 -delete >/dev/null 2>&1 || return 1
  rm -rf "$dir" 2>/dev/null || true
  [[ ! -e "$dir" ]]
}
