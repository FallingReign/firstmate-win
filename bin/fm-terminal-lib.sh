#!/usr/bin/env bash
# Native Windows terminal/path helpers for firstmate's WezTerm + Git Bash path.
set -u

fm_native_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

fm_wezterm_cmd() {
  if command -v wezterm >/dev/null 2>&1; then
    command -v wezterm
  elif command -v wezterm.exe >/dev/null 2>&1; then
    command -v wezterm.exe
  else
    return 1
  fi
}

fm_git_bash_cmd() {
  if [ -n "${FM_GIT_BASH:-}" ]; then
    printf '%s\n' "$FM_GIT_BASH"
  elif [ -x "/c/Program Files/Git/bin/bash.exe" ]; then
    printf '%s\n' "/c/Program Files/Git/bin/bash.exe"
  else
    command -v bash
  fi
}

fm_to_bash_path() {
  case "$1" in
    file:///[A-Za-z]:*) cygpath -u "${1#file:///}" ;;
    [A-Za-z]:*) cygpath -u "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fm_to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

fm_term_cli() {
  "$(fm_wezterm_cmd)" cli --prefer-mux "$@"
}

fm_term_json_field() {
  local pane=$1 field=$2
  fm_term_cli list --format json | node -e '
const panes = JSON.parse(require("fs").readFileSync(0, "utf8"));
const pane = panes.find(p => String(p.pane_id) === String(process.argv[1]));
if (!pane) process.exit(1);
const value = pane[process.argv[2]];
if (value !== undefined && value !== null) console.log(value);
' "$pane" "$field"
}

fm_term_find() {
  local name=$1
  fm_term_cli list --format json | node -e '
const panes = JSON.parse(require("fs").readFileSync(0, "utf8"));
const name = process.argv[1];
const pane = panes.find(p => String(p.pane_id) === name || p.tab_title === name || p.title === name);
if (!pane) process.exit(1);
console.log(pane.pane_id);
' "$name"
}

fm_term_spawn() {
  local title=$1 cwd=$2 pane bash_cmd anchor_window
  bash_cmd=$(fm_to_native_path "$(fm_git_bash_cmd)")
  # `wezterm cli spawn` with no anchor infers the target window from the current
  # pane via $WEZTERM_PANE - which is unset here because firstmate drives wezterm
  # from outside any WezTerm-hosted pane. Anchor explicitly instead: reuse an
  # existing window as a new tab so crewmates collect into one window, or bootstrap
  # the first window with --new-window when none exists yet.
  anchor_window=$(fm_term_cli list --format json | node -e '
const panes = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (panes[0]) console.log(panes[0].window_id);
' 2>/dev/null || true)
  if [ -n "$anchor_window" ]; then
    pane=$(fm_term_cli spawn --window-id "$anchor_window" --cwd "$(fm_to_native_path "$cwd")" -- "$bash_cmd" -l)
  else
    pane=$(fm_term_cli spawn --new-window --cwd "$(fm_to_native_path "$cwd")" -- "$bash_cmd" -l)
  fi
  fm_term_cli set-tab-title --pane-id "$pane" "$title" >/dev/null
  printf '%s\n' "$pane"
}

fm_term_capture() {
  local pane=$1 lines=${2:-40} escapes=${3:-}
  if [ "$escapes" = escapes ]; then
    fm_term_cli get-text --pane-id "$pane" --start-line "-$lines" --escapes
  else
    fm_term_cli get-text --pane-id "$pane" --start-line "-$lines"
  fi
}

fm_term_capture_line() {
  local pane=$1 line=$2
  fm_term_cli get-text --pane-id "$pane" --start-line "$line" --end-line "$line" --escapes
}

fm_term_cwd() {
  fm_to_bash_path "$(fm_term_json_field "$1" cwd)"
}

fm_term_cursor_y() {
  fm_term_json_field "$1" cursor_y
}

fm_term_send_text() {
  local pane=$1 text=$2
  printf '%s' "$text" | fm_term_cli send-text --pane-id "$pane" --no-paste
}

fm_term_send_key() {
  local pane=$1 key=$2 bytes
  case "$key" in
    Enter) bytes='\r' ;;
    Escape|Esc) bytes='\033' ;;
    C-c) bytes='\003' ;;
    *) bytes="$key" ;;
  esac
  printf '%b' "$bytes" | fm_term_cli send-text --pane-id "$pane" --no-paste
}

fm_term_kill() {
  fm_term_cli kill-pane --pane-id "$1" >/dev/null 2>&1
}
