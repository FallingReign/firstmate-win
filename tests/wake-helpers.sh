#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites. The fake terminal surfaces here encode
# watcher/daemon/composer behavior, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/wezterm.exe" <<'SH'
#!/usr/bin/env bash
set -u
shift # cli
[ "${1:-}" = "--prefer-mux" ] && shift
if [ "${1:-}" = "list" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '[{"pane_id":"%s","cursor_y":%s,"tab_title":"%s","title":"%s"}]\n' "$FM_FAKE_TMUX_WINDOW" "${FM_FAKE_TMUX_CURSOR_Y:-0}" "$FM_FAKE_TMUX_WINDOW" "$FM_FAKE_TMUX_WINDOW"
  fi
  exit 0
fi
if [ "${1:-}" = "get-text" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/wezterm.exe"
  printf '%s\n' "$dir"
}

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/wezterm.exe" <<'SH'
#!/usr/bin/env bash
set -u
shift # cli
[ "${1:-}" = "--prefer-mux" ] && shift
case "${1:-}" in
  list)
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || { printf '[]\n'; exit 0; }
    pane="${FM_FAKE_TMUX_WINDOW:-fakepane}"
    sup="${WEZTERM_PANE:-0}"
    printf '[{"pane_id":"%s","cursor_y":%s,"tab_title":"%s","title":"%s"},{"pane_id":"%s","cursor_y":%s,"tab_title":"%s","title":"%s"}]\n' "$pane" "${FM_FAKE_TMUX_CURSOR_Y:-0}" "$pane" "$pane" "$sup" "${FM_FAKE_TMUX_CURSOR_Y:-0}" "$sup" "$sup"
    exit 0 ;;
  get-text)
    # Honor a single-line band capture (-S N -E M, both non-negative) the way the
    # composer reader now bounds its capture to the cursor row; otherwise (e.g.
    # fm_pane_is_busy's "-S -40" tail) return the whole capture. -e is accepted and
    # ignored: this fake emits plain text, which the dim-stripper passes through.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --start-line) _S="${2:-}"; shift 2; continue ;;
        --end-line) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-text)
    input=$(cat)
    case "$input" in
      $'\r')
          # Optionally swallow Enter (file-based flag) to test the retry path.
          if [ -n "${FM_FAKE_TMUX_SWALLOW_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_SWALLOW_FILE" ]; then
            rm -f "$FM_FAKE_TMUX_SWALLOW_FILE"
          else
            printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
            # Enter submits: clear the last line (the typed text) from the
            # capture, simulating the composer being cleared on submit.
            if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$FM_FAKE_TMUX_CAPTURE" ]; then
              _tmp=$(mktemp 2>/dev/null) || _tmp="${FM_FAKE_TMUX_CAPTURE}.tmp"
              sed '$d' "$FM_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$FM_FAKE_TMUX_CAPTURE"
              rm -f "$_tmp" 2>/dev/null
            fi
          fi
          ;;
      *)
          printf '%s\n' "$input" >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
          [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && printf '%s\n' "$input" >> "$FM_FAKE_TMUX_CAPTURE"
          ;;
    esac
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/wezterm.exe"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '│ > │\n' > "$dir/composer"
  cat > "$fakebin/wezterm.exe" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
shift # cli
[ "${1:-}" = "--prefer-mux" ] && shift
case "${1:-}" in
  list)
    sup="${WEZTERM_PANE:-0}"
    printf '[{"pane_id":"win","cursor_y":0,"tab_title":"sess:win","title":"win"},{"pane_id":"%s","cursor_y":0,"tab_title":"%s","title":"%s"}]\n' "$sup" "$sup" "$sup"
    exit 0 ;;
  get-text) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-text)
    text=$(cat)
    if [ "$text" = $'\r' ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        printf '│ > │\n' > "$COMPOSER"
      fi
    else
      [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      printf '│ > %s │\n' "$text" > "$COMPOSER"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/wezterm.exe"
  printf '%s\n' "$dir"
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
