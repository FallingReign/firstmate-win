#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Skips local-only/no-origin projects, dirty clones, non-default checkouts,
# diverged branches, and fetch/fast-forward failures without forcing or stashing.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# The no-arg sweep covers two sources, unioned and de-duplicated by resolved
# path: every directory directly under $PROJECTS, and every project registered
# in data/projects.md via an explicit `path:` field (for clones a captain keeps
# outside $PROJECTS - see AGENTS.md section 2/6). Registry lines with no `path:`
# field are assumed to live under $PROJECTS/<name> as before, so they only come
# from the directory sweep.
# Usage: fm-fleet-sync.sh [<project-dir>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/projects.md"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-fleet-sync.sh [<project-dir>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -le 1 ] || { usage; exit 1; }

project_label() {
  case "$PROJ" in
    "$PROJECTS"/*) basename "$PROJ" ;;
    projects/*) basename "$PROJ" ;;
    *) printf '%s\n' "$PROJ" ;;
  esac
}

# canon_path <path>: print a resolved absolute path for de-duplication (falls
# back to the raw input if the path isn't a directory yet, e.g. a stale
# registry entry - sync_project reports that as "skipped: not a directory").
canon_path() {
  if [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd)
  else
    printf '%s\n' "$1"
  fi
}

# registry_entries: print "<name><TAB><path>" for every data/projects.md entry
# that carries an explicit `(path: ...; ...)` field - the registered name, not
# a basename guess, so fm-project-mode.sh still resolves the right mode/yolo
# for a project whose directory name differs from its registry name. Entries
# without a `path:` field are skipped here; they're covered by the
# $PROJECTS/* sweep instead.
registry_entries() {
  [ -f "$REGISTRY" ] || return 0
  awk '
    /^- / {
      name = $2
      if (match($0, /\(path: *[^;)]*/)) {
        p = substr($0, RSTART + 6, RLENGTH - 6)
        gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (p != "") print name "\t" p
      }
    }
  ' "$REGISTRY"
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

prune_gone_branches() {
  # Delete local branches whose upstream tracking branch is gone - the remote
  # branch was deleted, which in this fleet means its PR merged - as long as
  # nothing still needs them. Never the checked-out branch, and never a branch
  # that still has a worktree (a live or not-yet-torn-down task). "Gone" plus
  # "no worktree" already proves the work landed: teardown removes a branch's
  # worktree only after confirming the work reached the remote. We deliberately
  # do NOT also require the branch to be an ancestor of origin/<default> - PRs in
  # this fleet are squash-merged, so a merged branch is never an ancestor and
  # such a check would prune nothing. The no-worktree guard is the real safety
  # net. Set FM_FLEET_PRUNE=0 to skip pruning entirely.
  [ "${FM_FLEET_PRUNE:-1}" != "0" ] || return 0

  local worktree_branches current refline branch track
  worktree_branches=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p')
  current=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  while IFS= read -r refline; do
    branch=${refline%% *}
    track=${refline#* }
    [ "$track" = "[gone]" ] || continue
    [ -n "$branch" ] || continue
    [ "$branch" != "$current" ] || continue
    if printf '%s\n' "$worktree_branches" | grep -Fxq -- "$branch"; then
      continue
    fi
    if git -C "$PROJ" branch -D -- "$branch" >/dev/null 2>&1; then
      echo "$label: pruned $branch"
    fi
  done < <(git -C "$PROJ" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null)
}

sync_project() {
  PROJ=$1
  label=${2:-$(project_label)}

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$label" 2>/dev/null || echo "no-mistakes off")
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  if ! git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    echo "$label: skipped: no origin remote"
    return 0
  fi

  if ! fetch_output=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); then
    reason="fetch failed"
    if [ -n "$fetch_output" ]; then
      reason="$reason: $(first_line "$fetch_output")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi

  prune_gone_branches || true

  DEFAULT=$(default_branch) || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }
  BASE="origin/$DEFAULT"
  if ! git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "$label: skipped: $BASE does not exist"
    return 0
  fi

  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ "$cur" != "$DEFAULT" ]; then
    [ -n "$cur" ] || cur="detached HEAD"
    echo "$label: skipped: on $cur, expected $DEFAULT"
    return 0
  fi
  if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null; then
    echo "$label: skipped: local $DEFAULT does not exist"
    return 0
  fi

  local_rev=$(git -C "$PROJ" rev-parse "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE") || {
    echo "$label: skipped: cannot read $BASE"
    return 0
  }
  if [ "$local_rev" = "$remote_rev" ]; then
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
    echo "$label: skipped: local $DEFAULT has diverged from $BASE"
    return 0
  fi

  before=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  if ! merge_output=$(git -C "$PROJ" merge --ff-only "$BASE" 2>&1); then
    reason="fast-forward failed"
    if [ -n "$merge_output" ]; then
      reason="$reason: $(first_line "$merge_output")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: fast-forward completed but cannot read local $DEFAULT"
    return 0
  }
  echo "$label: synced $before..$after"
  return 0
}

if [ $# -eq 1 ]; then
  sync_project "$1"
  exit 0
fi

declare -A synced_paths=()

if [ -d "$PROJECTS" ]; then
  for proj in "$PROJECTS"/*; do
    [ -e "$proj" ] || continue
    [ -d "$proj" ] || continue
    synced_paths["$(canon_path "$proj")"]=1
    sync_project "$proj"
  done
fi

while IFS=$'\t' read -r regname regpath; do
  [ -n "$regpath" ] || continue
  key=$(canon_path "$regpath")
  [ -z "${synced_paths[$key]:-}" ] || continue
  synced_paths["$key"]=1
  sync_project "$regpath" "$regname"
done < <(registry_entries)
