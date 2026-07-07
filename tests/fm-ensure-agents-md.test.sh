#!/usr/bin/env bash
# tests/fm-ensure-agents-md.test.sh — fm-ensure-agents-md.sh behavior matrix.
#
# Covers every branch of the script:
#   - both real files: default to AGENTS.md (Fix 2) — primary new behavior
#   - AGENTS.md alone with no CLAUDE.md: script creates CLAUDE.md
#   - AGENTS.md with a correct CLAUDE.md symlink: no-op (symlink-capable only)
#   - AGENTS.md with a wrong CLAUDE.md symlink: error  (symlink-capable only)
#   - CLAUDE.md real file alone: promote to AGENTS.md
#   - neither file: create skeleton
#   - AGENTS.md is a symlink: error  (symlink-capable only)
#
# Symlink assertions are guarded: Windows (Git Bash without Developer Mode) does
# not support real symlinks via `ln -s`, so tests that require genuine symlink
# support are skipped on such platforms.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-ensure-agents-md.sh"
TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md-tests)

make_dir() {
  local name=$1
  local d="$TMP_ROOT/$name"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# Detect whether this platform supports real symlinks.
# ln -s on Windows (Git Bash without Developer Mode) creates a file copy.
_has_real_symlinks() {
  local probe_dir probe_target rc
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-symprobe.XXXXXX") || return 1
  printf 'x\n' > "$probe_dir/target"
  ln -s target "$probe_dir/link" 2>/dev/null
  rc=1
  [ -L "$probe_dir/link" ] && rc=0
  rm -rf "$probe_dir"
  return $rc
}

HAVE_REAL_SYMLINKS=0
_has_real_symlinks && HAVE_REAL_SYMLINKS=1

# ---------------------------------------------------------------------------
# Fix 2 (primary new behavior): both AGENTS.md and CLAUDE.md are real files
# ---------------------------------------------------------------------------

test_both_real_files_defaults_to_agents_canonical() {
  local dir out rc
  dir=$(make_dir both-real)
  printf '# Agents knowledge\n' > "$dir/AGENTS.md"
  printf '# Claude pointer\n'  > "$dir/CLAUDE.md"

  out=$("$SCRIPT" "$dir" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] \
    || fail "both real files: expected exit 0, got $rc (output: $out)"
  case "$out" in
    *"unchanged: AGENTS.md canonical; CLAUDE.md kept as a real file"*) ;;
    *) fail "both real files: unexpected output: $out" ;;
  esac

  # Files must be byte-unchanged.
  [ "$(cat "$dir/AGENTS.md")" = "# Agents knowledge" ] \
    || fail "both real files: AGENTS.md was modified"
  [ "$(cat "$dir/CLAUDE.md")" = "# Claude pointer" ] \
    || fail "both real files: CLAUDE.md was modified"
  # CLAUDE.md must still be a regular file (not a symlink, not gone).
  [ -f "$dir/CLAUDE.md" ] \
    || fail "both real files: CLAUDE.md is no longer a regular file"
  if [ "$HAVE_REAL_SYMLINKS" -eq 1 ]; then
    [ ! -L "$dir/CLAUDE.md" ] \
      || fail "both real files: CLAUDE.md was unexpectedly converted to a symlink"
  fi

  pass "both-real-files: exits 0, leaves both files byte-unchanged, reports canonical"
}

test_both_real_files_idempotent() {
  # Running twice on the same dir must give the same result.
  local dir out1 out2
  dir=$(make_dir both-real-idempotent)
  printf 'agents content\n' > "$dir/AGENTS.md"
  printf 'claude content\n' > "$dir/CLAUDE.md"

  out1=$("$SCRIPT" "$dir" 2>&1)
  out2=$("$SCRIPT" "$dir" 2>&1)
  [ "$out1" = "$out2" ] \
    || fail "both real files: output changed between runs ('$out1' vs '$out2')"
  [ "$(cat "$dir/AGENTS.md")" = "agents content" ] \
    || fail "both real files: AGENTS.md modified on second run"
  [ "$(cat "$dir/CLAUDE.md")" = "claude content" ] \
    || fail "both real files: CLAUDE.md modified on second run"

  pass "both-real-files: idempotent across repeated runs"
}

test_both_real_files_agents_canonical_not_stderr() {
  # The success message must go to stdout, not stderr. An exit-0 branch that
  # emits to stderr could look like an error to a caller.
  local dir stdout_out stderr_out rc
  dir=$(make_dir both-real-stdout)
  printf '# A\n' > "$dir/AGENTS.md"
  printf '# C\n' > "$dir/CLAUDE.md"

  stdout_out=$("$SCRIPT" "$dir" 2>/dev/null)
  rc=$?

  [ "$rc" -eq 0 ] || fail "both real files: expected exit 0, got $rc"
  case "$stdout_out" in
    *"unchanged: AGENTS.md canonical"*) ;;
    *) fail "both real files: success message not on stdout (got: '$stdout_out')" ;;
  esac

  pass "both-real-files: success message goes to stdout (not stderr)"
}

# ---------------------------------------------------------------------------
# Pre-existing branches (must be unaffected by Fix 2)
# ---------------------------------------------------------------------------

test_agents_alone_creates_claude() {
  # AGENTS.md exists, CLAUDE.md does not — script must create CLAUDE.md.
  local dir out rc
  dir=$(make_dir agents-alone)
  printf '# agents\n' > "$dir/AGENTS.md"

  out=$("$SCRIPT" "$dir" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "agents-alone: expected exit 0, got $rc (output: $out)"
  [ -e "$dir/CLAUDE.md" ] \
    || fail "agents-alone: CLAUDE.md was not created"
  if [ "$HAVE_REAL_SYMLINKS" -eq 1 ]; then
    [ -L "$dir/CLAUDE.md" ] \
      || fail "agents-alone: CLAUDE.md is not a symlink (platform supports real symlinks)"
    [ "$(readlink "$dir/CLAUDE.md")" = "AGENTS.md" ] \
      || fail "agents-alone: CLAUDE.md does not point to AGENTS.md"
  fi

  pass "agents-alone: creates CLAUDE.md linked to AGENTS.md"
}

test_correct_symlink_is_noop() {
  if [ "$HAVE_REAL_SYMLINKS" -ne 1 ]; then
    pass "correct-symlink: SKIPPED (platform does not support real symlinks)"
    return 0
  fi
  local dir out rc
  dir=$(make_dir correct-symlink)
  printf '# agents\n' > "$dir/AGENTS.md"
  ln -s AGENTS.md "$dir/CLAUDE.md"

  out=$("$SCRIPT" "$dir" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "correct-symlink: expected exit 0, got $rc"
  case "$out" in
    *unchanged*) ;;
    *) fail "correct-symlink: unexpected output: $out" ;;
  esac
  [ -L "$dir/CLAUDE.md" ] || fail "correct-symlink: CLAUDE.md is no longer a symlink"

  pass "correct-symlink: no-op when CLAUDE.md -> AGENTS.md already correct"
}

test_wrong_symlink_errors() {
  if [ "$HAVE_REAL_SYMLINKS" -ne 1 ]; then
    pass "wrong-symlink: SKIPPED (platform does not support real symlinks)"
    return 0
  fi
  local dir out rc
  dir=$(make_dir wrong-symlink)
  printf '# agents\n' > "$dir/AGENTS.md"
  ln -s SOMETHING_ELSE.md "$dir/CLAUDE.md"

  out=$("$SCRIPT" "$dir" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] \
    || fail "wrong-symlink: expected non-zero exit, got 0 (output: $out)"
  case "$out" in
    *conflict*) ;;
    *) fail "wrong-symlink: expected 'conflict' in output, got: $out" ;;
  esac

  pass "wrong-symlink: errors when CLAUDE.md is a symlink pointing elsewhere"
}

test_claude_alone_is_promoted() {
  local dir out rc
  dir=$(make_dir claude-alone)
  printf '# claude content\n' > "$dir/CLAUDE.md"

  out=$("$SCRIPT" "$dir" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "claude-alone: expected exit 0, got $rc (output: $out)"
  [ -f "$dir/AGENTS.md" ] || fail "claude-alone: AGENTS.md was not created"
  [ "$(cat "$dir/AGENTS.md")" = "# claude content" ] \
    || fail "claude-alone: AGENTS.md content differs from original CLAUDE.md"
  if [ "$HAVE_REAL_SYMLINKS" -eq 1 ]; then
    [ -L "$dir/CLAUDE.md" ] \
      || fail "claude-alone: CLAUDE.md was not converted to a symlink"
  fi

  pass "claude-alone: CLAUDE.md promoted to AGENTS.md"
}

test_neither_file_creates_skeleton() {
  local dir out rc
  dir=$(make_dir neither)

  out=$("$SCRIPT" "$dir" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "neither: expected exit 0, got $rc (output: $out)"
  [ -f "$dir/AGENTS.md" ] || fail "neither: AGENTS.md skeleton not created"
  grep -F "Project agent memory" "$dir/AGENTS.md" >/dev/null \
    || fail "neither: skeleton does not contain expected header"
  [ -e "$dir/CLAUDE.md" ] || fail "neither: CLAUDE.md not created"

  pass "neither: creates AGENTS.md skeleton and CLAUDE.md"
}

test_agents_is_symlink_errors() {
  if [ "$HAVE_REAL_SYMLINKS" -ne 1 ]; then
    pass "agents-is-symlink: SKIPPED (platform does not support real symlinks)"
    return 0
  fi
  local dir out rc
  dir=$(make_dir agents-symlink)
  printf '# real\n' > "$dir/REAL.md"
  ln -s REAL.md "$dir/AGENTS.md"

  out=$("$SCRIPT" "$dir" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] \
    || fail "agents-is-symlink: expected non-zero exit, got 0 (output: $out)"
  case "$out" in
    *conflict*) ;;
    *) fail "agents-is-symlink: expected 'conflict' in output, got: $out" ;;
  esac

  pass "agents-is-symlink: errors when AGENTS.md is itself a symlink"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
test_both_real_files_defaults_to_agents_canonical
test_both_real_files_idempotent
test_both_real_files_agents_canonical_not_stderr
test_agents_alone_creates_claude
test_correct_symlink_is_noop
test_wrong_symlink_errors
test_claude_alone_is_promoted
test_neither_file_creates_skeleton
test_agents_is_symlink_errors
