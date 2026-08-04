#!/usr/bin/env bash
# tests/fm-fleet-sync.test.sh - no-arg sweep scope coverage for fm-fleet-sync.sh.
#
# Covers the fix for a real incident: a project registered in data/projects.md
# by an explicit `path:` field outside $PROJECTS was never reached by the
# no-arg sweep (bin/fm-bootstrap.sh always calls fm-fleet-sync.sh with no
# argument), so it silently drifted behind origin forever. The no-arg sweep
# must now also cover data/projects.md entries that carry a `path:` field, in
# addition to (not instead of) the existing $PROJECTS/* directory sweep.
#
# Matrix:
#   (a) project under $PROJECTS/*, no path: field       -> synced (no regression)
#   (b) project registered by path: outside $PROJECTS   -> synced (the fix)
#   (c) $PROJECTS/* project re-registered with a path:
#       field pointing at itself                        -> synced exactly once (dedupe)
#   (d) local-only project registered by path: outside
#       $PROJECTS                                        -> still skipped (safety
#                                                            preserved; proves mode
#                                                            lookup uses the registry
#                                                            name, not a path basename)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET_SYNC="$ROOT/bin/fm-fleet-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-sync-tests)
fm_git_identity

# make_clone <dir>: bare origin plus a clone checked out on main, two commits
# ahead on origin so a sync has something to fast-forward. Echoes nothing;
# the clone ends up behind by one commit.
make_clone() {
  local clone_dir=$1 origin_dir="$1.origin.git" seed_dir="$1.seed"
  git init -q --bare "$origin_dir"
  git -C "$origin_dir" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin_dir" "$seed_dir" 2>/dev/null
  git -C "$seed_dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git -C "$seed_dir" push -q origin main
  git clone -q "$origin_dir" "$clone_dir" 2>/dev/null
  git -C "$clone_dir" remote set-head origin main 2>/dev/null || true
  git -C "$seed_dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
  git -C "$seed_dir" push -q origin main
  rm -rf "$seed_dir"
}

test_registry_path_outside_projects_is_synced() {
  local home ext out
  home="$TMP_ROOT/home-outside"
  ext="$TMP_ROOT/ext-outside"
  mkdir -p "$home/projects" "$home/data" "$ext"

  make_clone "$home/projects/proj-a"
  make_clone "$ext/proj-b"
  cat > "$home/data/projects.md" <<EOF
- proj-a [no-mistakes] - lives under projects/ (added 2026-01-01)
- proj-b [no-mistakes] - lives outside projects/ (path: $ext/proj-b; remote: file://dummy) (added 2026-01-01)
EOF

  out=$(FM_HOME="$home" "$FLEET_SYNC") || fail "fleet sync failed: $out"
  assert_contains "$out" "proj-a: synced" "project under \$PROJECTS should still sync"
  assert_contains "$out" "proj-b: synced" \
    "path:-registered project outside \$PROJECTS should now sync too"
  pass "no-arg sweep reaches a project registered by absolute path outside \$PROJECTS"
}

test_dedupe_path_pointing_back_into_projects() {
  local home out count
  home="$TMP_ROOT/home-dedupe"
  mkdir -p "$home/projects" "$home/data"

  make_clone "$home/projects/proj-a"
  cat > "$home/data/projects.md" <<EOF
- proj-a [no-mistakes] - registered with a path: back into \$PROJECTS (path: $home/projects/proj-a; remote: file://dummy) (added 2026-01-01)
EOF

  out=$(FM_HOME="$home" "$FLEET_SYNC") || fail "fleet sync failed: $out"
  count=$(printf '%s\n' "$out" | grep -c '^proj-a:') || true
  [ "$count" -eq 1 ] || fail "expected proj-a synced exactly once, got $count lines: $out"
  pass "a project under \$PROJECTS re-registered via a matching path: is synced only once"
}

test_local_only_registered_by_path_is_still_skipped() {
  local home ext out
  home="$TMP_ROOT/home-localonly"
  ext="$TMP_ROOT/ext-localonly"
  mkdir -p "$home/projects" "$home/data" "$ext"

  make_clone "$ext/proj-c"
  cat > "$home/data/projects.md" <<EOF
- proj-c [local-only] - outside \$PROJECTS and local-only (path: $ext/proj-c; remote: file://dummy) (added 2026-01-01)
EOF

  out=$(FM_HOME="$home" "$FLEET_SYNC") || fail "fleet sync failed: $out"
  assert_contains "$out" "proj-c: skipped: local-only project" \
    "local-only mode must resolve via the registry name even when path: points outside \$PROJECTS"
  assert_not_contains "$out" "proj-c: synced" \
    "a local-only registered project must never be synced regardless of where its clone lives"
  pass "local-only safety still applies to a project registered by an outside path:"
}

test_registry_path_outside_projects_is_synced
test_dedupe_path_pointing_back_into_projects
test_local_only_registered_by_path_is_still_skipped
