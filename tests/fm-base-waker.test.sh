#!/usr/bin/env bash
# tests/fm-base-waker.test.sh — unit and integration tests for fm-base-waker.sh.
#
# Covers:
#   _is_wake_reason     pure classifier
#   _inject_wake        inject with guards (busy, pending-input)
#   full loop           end-to-end wake delivery via FM_WAKER_MAX_ITERATIONS=1
#
# Mocking strategy: uses the make_supercase fakebin (wake-helpers.sh) which
# provides a fake wezterm.exe whose send-text appends to FM_FAKE_TMUX_SENT and
# whose get-text returns FM_FAKE_TMUX_CAPTURE. WEZTERM_PANE sets both the
# supervisor pane ID reported by the fake and the waker's inject target.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WAKER="$ROOT/bin/fm-base-waker.sh"

# Source the waker's pure functions once. The BASH_SOURCE guard inside the
# script prevents _waker_main from running; only _is_wake_reason, _inject_wake,
# and _resolve_target become available. We set FM_STATE_OVERRIDE to a temp dir
# so fm-wake-lib.sh's mkdir -p STATE side-effect is contained.
TMP_ROOT=$(fm_test_tmproot fm-base-waker-tests)
_source_state="$TMP_ROOT/source-state"
mkdir -p "$_source_state"
if [ -z "${FM_TEST_WAKER_SOURCED:-}" ]; then
  export FM_TEST_WAKER_SOURCED=1
  FM_STATE_OVERRIDE="$_source_state" \
    # shellcheck source=bin/fm-base-waker.sh
    . "$WAKER"
fi

# ---------------------------------------------------------------------------
# Platform proof: nohup & produces an orphan adopted by init (PPID=1)
# This test documents the empirical evidence that the base waker's arm
# mechanism (nohup bin/fm-base-waker.sh >/dev/null 2>&1 &) survives across
# pi tool calls. Each pi tool call is a non-interactive shell; when it exits,
# backgrounded children become orphans adopted by init (PPID=1).
# ---------------------------------------------------------------------------

test_nohup_background_survives_subshell_exit_with_ppid1() {
  # Simulate pi arming the waker: start a process in a subshell (a fresh
  # non-interactive shell, like a pi tool call) using nohup &. The subshell
  # exits immediately. The orphan must still be alive and under init.
  local pid_file waker_pid ppid
  pid_file=$(mktemp)

  # Start a long-lived process inside a subshell that exits right away.
  bash -c "nohup sleep 60 >/dev/null 2>&1 & echo \$! > '$pid_file'"

  # Give the OS a moment to adopt the orphan under init.
  sleep 0.3

  waker_pid=$(cat "$pid_file" 2>/dev/null)
  [ -n "$waker_pid" ] || fail "no PID captured from subshell"
  rm -f "$pid_file"

  # Must be alive after the subshell exited.
  kill -0 "$waker_pid" 2>/dev/null \
    || fail "nohup-backgrounded process died when subshell exited (expected PPID=1 orphan)"

  # Must have been adopted by init (PPID=1). Verified on Git Bash/Cygwin.
  # Note: Cygwin ps does not support -o ppid=; extract from raw output.
  ppid=$(ps -p "$waker_pid" 2>/dev/null | awk 'NR==2 {print $2}')
  [ "$ppid" = "1" ] \
    || fail "process not under init after subshell exit (ppid='$ppid'); orphaning did not occur on this platform"

  kill "$waker_pid" 2>/dev/null || true
  pass "nohup & survives subshell exit: process alive with PPID=1 (adopted by init) — base waker arm mechanism proven"
}



test_is_wake_reason_accepts_all_wake_prefixes() {
  _is_wake_reason "signal: /state/foo.status" \
    || fail "_is_wake_reason rejected 'signal:'"
  _is_wake_reason "stale: sess:fm-task" \
    || fail "_is_wake_reason rejected 'stale:'"
  _is_wake_reason "check: /state/t.check.sh: merged: https://x/pull/1" \
    || fail "_is_wake_reason rejected 'check:'"
  _is_wake_reason "heartbeat" \
    || fail "_is_wake_reason rejected bare 'heartbeat'"
  _is_wake_reason "heartbeat: extra" \
    || fail "_is_wake_reason rejected 'heartbeat: extra'"
  pass "_is_wake_reason accepts all valid wake prefixes"
}

test_is_wake_reason_rejects_status_lines() {
  _is_wake_reason "watcher: already running" \
    && fail "singleton status line misclassified as wake"
  _is_wake_reason "watcher: already running pid 123" \
    && fail "singleton status (pid) misclassified as wake"
  _is_wake_reason "watcher: started pid=42 (beacon fresh)" \
    && fail "watcher started line misclassified as wake"
  _is_wake_reason "" \
    && fail "empty string misclassified as wake"
  _is_wake_reason "some random output" \
    && fail "random line misclassified as wake"
  pass "_is_wake_reason rejects non-wake watcher status lines"
}

# ---------------------------------------------------------------------------
# Unit: _inject_wake — idle pane delivers the reason verbatim
# ---------------------------------------------------------------------------

test_inject_wake_delivers_reason_to_idle_pane() {
  local dir fakebin sent capture state
  dir=$(make_supercase waker-inject-idle)
  fakebin="$dir/fakebin"
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"   # empty = idle (no busy footer, empty composer)

  # Override globals for this test.
  local _save_retries=$BUSY_RETRIES _save_sleep=$BUSY_SLEEP
  local _save_ir=$INJECT_RETRIES _save_is=$INJECT_SLEEP
  BUSY_RETRIES=3; BUSY_SLEEP=0.05; INJECT_RETRIES=3; INJECT_SLEEP=0.05

  PATH="$fakebin:$PATH" \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_STATE_OVERRIDE="$state" \
    WEZTERM_PANE=supervisor-pane \
    _inject_wake "signal: $state/task.status" "supervisor-pane"

  BUSY_RETRIES=$_save_retries; BUSY_SLEEP=$_save_sleep
  INJECT_RETRIES=$_save_ir; INJECT_SLEEP=$_save_is

  grep -qF "signal: $state/task.status" "$sent" \
    || fail "wake reason was not injected into the supervisor pane"
  grep -qF "[ENTER]" "$sent" \
    || fail "Enter was not submitted after the wake reason"
  pass "_inject_wake delivers the wake reason verbatim to an idle pane"
}

# ---------------------------------------------------------------------------
# Unit: _inject_wake — busy guard defers injection
# ---------------------------------------------------------------------------

test_inject_wake_defers_when_supervisor_busy() {
  local dir fakebin sent capture state
  dir=$(make_supercase waker-inject-busy)
  fakebin="$dir/fakebin"
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  # Pane shows pi's busy footer — fm_pane_is_busy must fire.
  capture="$dir/pane.txt"
  printf 'Working...\n' > "$capture"

  local _save_retries=$BUSY_RETRIES _save_sleep=$BUSY_SLEEP
  BUSY_RETRIES=0; BUSY_SLEEP=0.01   # exhaust retries immediately

  PATH="$fakebin:$PATH" \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_STATE_OVERRIDE="$state" \
    WEZTERM_PANE=supervisor-pane \
    _inject_wake "heartbeat" "supervisor-pane"

  BUSY_RETRIES=$_save_retries; BUSY_SLEEP=$_save_sleep

  [ -s "$sent" ] && fail "inject was not deferred when supervisor pane was busy"
  pass "_inject_wake defers when the supervisor pane shows a busy footer"
}

# ---------------------------------------------------------------------------
# Unit: _inject_wake — pending-input guard defers injection
# ---------------------------------------------------------------------------

test_inject_wake_defers_when_pending_input() {
  local dir fakebin sent capture state
  dir=$(make_supercase waker-inject-pending)
  fakebin="$dir/fakebin"
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  # cursor line (y=0) has real unsubmitted text — fm_pane_input_pending fires.
  capture="$dir/pane.txt"
  printf 'human draft text\n' > "$capture"

  local _save_retries=$BUSY_RETRIES _save_sleep=$BUSY_SLEEP
  local _save_ir=$INJECT_RETRIES _save_is=$INJECT_SLEEP
  BUSY_RETRIES=0; BUSY_SLEEP=0.01; INJECT_RETRIES=1; INJECT_SLEEP=0.05

  PATH="$fakebin:$PATH" \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_STATE_OVERRIDE="$state" \
    WEZTERM_PANE=supervisor-pane \
    _inject_wake "stale: sess:fm-foo" "supervisor-pane"

  BUSY_RETRIES=$_save_retries; BUSY_SLEEP=$_save_sleep
  INJECT_RETRIES=$_save_ir; INJECT_SLEEP=$_save_is

  [ -s "$sent" ] && fail "inject was not deferred when composer had pending input"
  pass "_inject_wake defers when the supervisor pane has pending input"
}

# ---------------------------------------------------------------------------
# Integration: full loop delivers a real wake reason end-to-end
# ---------------------------------------------------------------------------

test_waker_loop_injects_signal_wake() {
  local dir fakebin sent capture watch_script state
  dir=$(make_supercase waker-loop-signal)
  fakebin="$dir/fakebin"
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"   # idle pane

  # Fake fm-watch.sh: emit a signal reason and exit immediately.
  watch_script="$dir/fake-watch.sh"
  cat > "$watch_script" <<SH
#!/usr/bin/env bash
printf 'signal: $state/task.status\n'
SH
  chmod +x "$watch_script"

  PATH="$fakebin:$PATH" \
    FM_SUPERVISOR_TARGET=supervisor-pane \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_STATE_OVERRIDE="$state" \
    WEZTERM_PANE=supervisor-pane \
    FM_WAKER_WATCH="$watch_script" \
    FM_WAKER_MAX_ITERATIONS=1 \
    FM_WAKER_INJECT_SLEEP=0.05 \
    FM_WAKER_BUSY_SLEEP=0.05 \
    "$WAKER" \
    || fail "fm-base-waker.sh exited non-zero"

  grep -qF "signal: $state/task.status" "$sent" \
    || fail "signal wake reason was not injected into the supervisor pane"
  grep -qF "[ENTER]" "$sent" \
    || fail "Enter was not submitted after the signal reason"
  pass "waker loop delivers a signal wake reason verbatim to the supervisor pane"
}

test_waker_loop_injects_heartbeat() {
  local dir fakebin sent capture watch_script state
  dir=$(make_supercase waker-loop-heartbeat)
  fakebin="$dir/fakebin"
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"

  watch_script="$dir/fake-watch.sh"
  cat > "$watch_script" <<'SH'
#!/usr/bin/env bash
printf 'heartbeat\n'
SH
  chmod +x "$watch_script"

  PATH="$fakebin:$PATH" \
    FM_SUPERVISOR_TARGET=supervisor-pane \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_STATE_OVERRIDE="$state" \
    WEZTERM_PANE=supervisor-pane \
    FM_WAKER_WATCH="$watch_script" \
    FM_WAKER_MAX_ITERATIONS=1 \
    FM_WAKER_INJECT_SLEEP=0.05 \
    FM_WAKER_BUSY_SLEEP=0.05 \
    "$WAKER" \
    || fail "fm-base-waker.sh exited non-zero for heartbeat"

  grep -qF "heartbeat" "$sent" \
    || fail "heartbeat wake reason was not injected"
  pass "waker loop delivers a heartbeat wake reason"
}

# ---------------------------------------------------------------------------
# Integration: non-wake watcher output is NOT injected
# ---------------------------------------------------------------------------

test_waker_loop_skips_non_wake_output_then_injects() {
  # First call returns "watcher: already running" (a status line, not a wake).
  # Second call returns the real wake reason.
  # Only the wake reason must appear in sent.log.
  local dir fakebin sent capture watch_script count_file state
  dir=$(make_supercase waker-loop-skip)
  fakebin="$dir/fakebin"
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  count_file="$dir/.call-count"

  watch_script="$dir/fake-watch.sh"
  cat > "$watch_script" <<SH
#!/usr/bin/env bash
count_file='$count_file'
if [ ! -f "\$count_file" ]; then
  touch "\$count_file"
  printf 'watcher: already running\n'
else
  printf 'signal: $state/second.status\n'
fi
SH
  chmod +x "$watch_script"

  PATH="$fakebin:$PATH" \
    FM_SUPERVISOR_TARGET=supervisor-pane \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_STATE_OVERRIDE="$state" \
    WEZTERM_PANE=supervisor-pane \
    FM_WAKER_WATCH="$watch_script" \
    FM_WAKER_MAX_ITERATIONS=1 \
    FM_WAKER_INJECT_SLEEP=0.05 \
    FM_WAKER_BUSY_SLEEP=0.05 \
    FM_WAKER_RETRY_SLEEP=0.05 \
    "$WAKER" \
    || fail "fm-base-waker.sh exited non-zero"

  grep -qF "watcher: already running" "$sent" \
    && fail "non-wake status line was injected into the supervisor pane"
  grep -qF "signal: $state/second.status" "$sent" \
    || fail "subsequent wake reason was not injected after skipping non-wake output"
  pass "waker loop skips non-wake watcher output and injects the next real wake"
}

# ---------------------------------------------------------------------------
# Unit: _resolve_target priority
# ---------------------------------------------------------------------------

test_resolve_target_priority() {
  local out
  # FM_SUPERVISOR_TARGET wins over everything
  out=$(FM_SUPERVISOR_TARGET=explicit WEZTERM_PANE=inherited _resolve_target)
  [ "$out" = "explicit" ] || fail "_resolve_target: FM_SUPERVISOR_TARGET not honored (got: $out)"

  # WEZTERM_PANE wins when FM_SUPERVISOR_TARGET is unset
  out=$(env -u FM_SUPERVISOR_TARGET WEZTERM_PANE=inherited _resolve_target 2>/dev/null \
        || FM_SUPERVISOR_TARGET= WEZTERM_PANE=inherited _resolve_target)
  [ "$out" = "inherited" ] || fail "_resolve_target: WEZTERM_PANE not honored (got: $out)"

  # Fallback to 0
  out=$(FM_SUPERVISOR_TARGET= WEZTERM_PANE= _resolve_target)
  [ "$out" = "0" ] || fail "_resolve_target: did not fall back to 0 (got: $out)"

  pass "_resolve_target respects FM_SUPERVISOR_TARGET > WEZTERM_PANE > 0"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
test_nohup_background_survives_subshell_exit_with_ppid1
test_is_wake_reason_accepts_all_wake_prefixes
test_is_wake_reason_rejects_status_lines
test_inject_wake_delivers_reason_to_idle_pane
test_inject_wake_defers_when_supervisor_busy
test_inject_wake_defers_when_pending_input
test_waker_loop_injects_signal_wake
test_waker_loop_injects_heartbeat
test_waker_loop_skips_non_wake_output_then_injects
test_resolve_target_priority
