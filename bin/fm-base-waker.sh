#!/usr/bin/env bash
# fm-base-waker.sh — base-mode (non-afk) watcher wake delivery loop.
#
# For harnesses without a tracked-background-and-notify facility (e.g. pi),
# this script runs as a long-lived background process. On each watcher wake it
# injects the reason line verbatim into the supervisor pane so firstmate's next
# turn receives it, then loops to catch the next wake automatically.
#
# Design: thin loop around EXISTING fm-watch.sh + EXISTING fm-tmux-lib.sh inject
# primitive. No sentinel marker, no AFK gating, no classification, no batching —
# those belong to the /afk daemon only. The base waker is deliberately dumb:
# watcher fires → inject the reason verbatim → re-arm.
#
# Losslessness: fm-watch.sh enqueues every wake to state/.wake-queue BEFORE
# advancing its suppression markers, so a failed inject is not a lost wake;
# firstmate drains the queue on its next turn or on recovery.
#
# Usage: fm-base-waker.sh
#   Run as a long-lived background process on pi or any harness without
#   run_in_background. Start it from the firstmate session with `&` so it
#   becomes an orphaned child that survives the tool call:
#     bin/fm-base-waker.sh &
#   On claude/codex/opencode, fm-watch-arm.sh (exit-and-notify via tracked
#   background) is the correct mechanism; this script is additive and does not
#   replace it on those harnesses.
#
# Environment:
#   FM_SUPERVISOR_TARGET     pane to inject into; falls back to $WEZTERM_PANE,
#                            then pane 0 (same resolution as the afk daemon)
#   FM_WAKER_WATCH           override the watcher script path (testing only;
#                            default: bin/fm-watch.sh alongside this script)
#   FM_WAKER_BUSY_RETRIES    retries when pane is busy or has pending input
#                            (default 20); each retry sleeps FM_WAKER_BUSY_SLEEP
#   FM_WAKER_BUSY_SLEEP      seconds between busy/pending retries (default 5)
#   FM_WAKER_INJECT_RETRIES  Enter-retry attempts on a swallowed Enter (default 3)
#                            text is typed once, only Enter is retried — the same
#                            shared submit contract as fm-send.sh
#   FM_WAKER_INJECT_SLEEP    seconds between Enter retries and settle pause
#                            (default 0.5)
#   FM_WAKER_RETRY_SLEEP     seconds to wait before restarting when the watcher
#                            emits non-wake output (default 1)
#   FM_WAKER_MAX_ITERATIONS  exit after N successful injects; 0 = run forever
#                            (default 0; set to 1 in tests to limit the loop)
#   FM_STATE_OVERRIDE        alternate state dir (testing)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Watcher script — overridable for testing.
WATCH="${FM_WAKER_WATCH:-$SCRIPT_DIR/fm-watch.sh}"

# Tunables (set once at startup; tests can override the shell globals directly).
BUSY_RETRIES=${FM_WAKER_BUSY_RETRIES:-20}
BUSY_SLEEP=${FM_WAKER_BUSY_SLEEP:-5}
INJECT_RETRIES=${FM_WAKER_INJECT_RETRIES:-3}
INJECT_SLEEP=${FM_WAKER_INJECT_SLEEP:-0.5}
RETRY_SLEEP=${FM_WAKER_RETRY_SLEEP:-1}
MAX_ITERATIONS=${FM_WAKER_MAX_ITERATIONS:-0}

# ---------------------------------------------------------------------------
# _resolve_target: supervisor pane resolution.
# Priority: FM_SUPERVISOR_TARGET > $WEZTERM_PANE > pane 0 fallback.
# Mirrors the /afk daemon's discover_supervisor_target.
# ---------------------------------------------------------------------------
_resolve_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
  elif [ -n "${WEZTERM_PANE:-}" ]; then
    printf '%s' "$WEZTERM_PANE"
  else
    printf '0'
  fi
}

# ---------------------------------------------------------------------------
# _is_wake_reason: 0 if <reason> is a genuine watcher wake line.
# Anything else (e.g. "watcher: already running" on a singleton-lock collision)
# is a STATUS line that must not be injected into the supervisor pane.
# Mirrors is_wake_reason in fm-supervise-daemon.sh.
# ---------------------------------------------------------------------------
_is_wake_reason() {
  local reason=$1
  case "$reason" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# _inject_wake: inject <reason> into <target> with busy/pending guards.
# Retries up to BUSY_RETRIES times when the pane is busy or has pending input.
# Uses the shared fm-tmux-lib.sh submit primitive (type-once, Enter-retry).
# A failed inject after all retries is not an error: the reason is already in
# state/.wake-queue so firstmate will drain it on recovery.
# ---------------------------------------------------------------------------
_inject_wake() {
  local reason=$1 target=$2 retry=0
  while [ "$retry" -le "$BUSY_RETRIES" ]; do
    # Pane-alive check: if the supervisor pane is gone, backoff and retry.
    if ! fm_term_capture "$target" 1 >/dev/null 2>&1; then
      sleep "$BUSY_SLEEP"
      retry=$((retry + 1))
      continue
    fi
    # Busy guard: never inject while the supervisor agent is mid-turn.
    if fm_pane_is_busy "$target"; then
      sleep "$BUSY_SLEEP"
      retry=$((retry + 1))
      continue
    fi
    # Pending-input guard: never merge with a human's half-typed line.
    if fm_pane_input_pending "$target"; then
      sleep "$BUSY_SLEEP"
      retry=$((retry + 1))
      continue
    fi
    # Inject: type once, retry Enter only (shared submit contract).
    # Discard the verdict — the wake is already in the queue regardless.
    fm_tmux_submit_core "$target" "$reason" "$INJECT_RETRIES" "$INJECT_SLEEP" "$INJECT_SLEEP" >/dev/null
    return 0
  done
  return 0  # gave up after retries; wake is preserved in state/.wake-queue
}

# ---------------------------------------------------------------------------
# _waker_main: the loop. Guarded by BASH_SOURCE so the pure functions above
# remain testable when this file is sourced.
# ---------------------------------------------------------------------------
_waker_main() {
  local target reason iter=0
  target=$(_resolve_target)
  while :; do
    # Run the watcher: blocks until a wake is due, exits printing one reason.
    # stderr redirected so singleton-lock "already running" lines don't clutter.
    reason=$("$WATCH" 2>/dev/null) || true

    # Ignore empty output and non-wake status lines (e.g. singleton collisions).
    if [ -z "$reason" ] || ! _is_wake_reason "$reason"; then
      sleep "$RETRY_SLEEP"
      continue
    fi

    _inject_wake "$reason" "$target"

    # FM_WAKER_MAX_ITERATIONS: exit after N injected wakes (testing only).
    if [ "${MAX_ITERATIONS}" -gt 0 ] 2>/dev/null; then
      iter=$((iter + 1))
      [ "$iter" -ge "$MAX_ITERATIONS" ] && return 0
    fi
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _waker_main "$@"
fi
