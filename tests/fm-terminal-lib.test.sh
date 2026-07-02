#!/usr/bin/env bash
# Focused contract tests for native Windows terminal/path helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-terminal-lib.sh"
# shellcheck source=bin/fm-terminal-lib.sh
. "$LIB"

test_path_contract() {
  local got
  if command -v cygpath >/dev/null 2>&1; then
    got=$(fm_to_bash_path 'C:\Users\jfenech\repo')
    [ "$got" = '/c/Users/jfenech/repo' ] || fail "Windows path conversion failed: $got"
    got=$(fm_to_bash_path 'file:///C:/Users/jfenech/repo')
    [ "$got" = '/c/Users/jfenech/repo' ] || fail "file URI conversion failed: $got"
  fi
  got=$(fm_to_bash_path '/c/Users/jfenech/repo')
  [ "$got" = '/c/Users/jfenech/repo' ] || fail "bash path should pass through unchanged: $got"
  pass "fm_to_bash_path converts Windows/file URI paths and preserves bash paths"
}

test_wezterm_cmd_accepts_exe() {
  local dir fakebin got
  dir=$(fm_test_tmproot fm-terminal-lib)
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" wezterm.exe
  got=$(PATH="$fakebin:/usr/bin:/bin" fm_wezterm_cmd)
  case "$got" in
    */wezterm|*/wezterm.exe) ;;
    *) fail "fm_wezterm_cmd did not accept wezterm.exe: $got" ;;
  esac
  pass "fm_wezterm_cmd accepts wezterm.exe"
}

test_path_contract
test_wezterm_cmd_accepts_exe
