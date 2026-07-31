// crew-panel.ts — live crew-panel extension for firstmate's pi chat.
//
// Opens a narrow WezTerm split (bin/fm-crew-monitor.js) alongside the main
// pi chat pane so the captain can see every active crewmate at a glance, and
// keeps a footer status indicator in sync. Auto-discovered from
// .pi/extensions/ when pi runs from the firstmate-win repo root (see
// AGENTS.md section 2 for the FM_HOME convention this and the monitor script
// share).
//
// No-ops entirely when there is no UI (RPC/print mode) or wezterm is not on
// PATH, and reuses an already-running monitor pane instead of spawning a
// second one.
//
// Reuse detection is keyed primarily off a persisted pane id
// (state/.crew-monitor-pane), verified for liveness against
// `wezterm cli list --format json` on every session_start; matching by the
// pane title bin/fm-crew-monitor.js sets on itself ("fm-crew-monitor") is
// tried first as a lighter-weight check but is a best-effort fallback only —
// empirically, OSC-title updates from a freshly `split-pane`-spawned process
// do not reliably show up in `wezterm cli list` output within any bounded
// wait, at least on wezterm 20240203-110809-5046fc22, so the persisted id is
// the mechanism this actually depends on.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// This file lives at <repo>/.pi/extensions/crew-panel.ts, so the repo root
// (where bin/ lives) is two levels up.
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const FM_HOME = process.env.FM_HOME || REPO_ROOT;
const STATE_DIR = path.join(FM_HOME, "state");
const MONITOR_SCRIPT = path.join(REPO_ROOT, "bin", "fm-crew-monitor.js");
const PANE_TITLE = "fm-crew-monitor";
const PANE_MARKER_FILE = path.join(STATE_DIR, ".crew-monitor-pane");

interface WeztermPane {
  window_id: number;
  tab_id: number;
  pane_id: number;
  title: string;
  cwd?: string;
}

let weztermCmd: string | undefined | null = null; // null = not probed yet

async function findWeztermCmd(): Promise<string | undefined> {
  if (weztermCmd !== null) return weztermCmd;
  for (const candidate of ["wezterm", "wezterm.exe"]) {
    try {
      await execFileAsync(candidate, ["--version"]);
      weztermCmd = candidate;
      return weztermCmd;
    } catch {
      // try next candidate
    }
  }
  weztermCmd = undefined;
  return weztermCmd;
}

async function weztermCli(cmd: string, args: string[]): Promise<string> {
  const { stdout } = await execFileAsync(cmd, ["cli", "--prefer-mux", ...args]);
  return stdout.trim();
}

async function listPanes(cmd: string): Promise<WeztermPane[]> {
  const out = await weztermCli(cmd, ["list", "--format", "json"]);
  return out ? (JSON.parse(out) as WeztermPane[]) : [];
}

function countActiveTasks(): number {
  if (!existsSync(STATE_DIR)) return 0;
  try {
    return readdirSync(STATE_DIR).filter((f) => f.endsWith(".meta")).length;
  } catch {
    return 0;
  }
}

function readMarkedPaneId(): string | undefined {
  try {
    const id = readFileSync(PANE_MARKER_FILE, "utf8").trim();
    return id || undefined;
  } catch {
    return undefined;
  }
}

function writeMarkedPaneId(paneId: string): void {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    writeFileSync(PANE_MARKER_FILE, `${paneId}\n`);
  } catch {
    // best-effort only; worst case is a duplicate spawn next session
  }
}

async function findOrSpawnMonitorPane(cmd: string): Promise<string | undefined> {
  const currentPaneId = process.env.WEZTERM_PANE;
  if (!currentPaneId) return undefined; // pi is not running inside a wezterm pane

  const panes = await listPanes(cmd);
  const current = panes.find((p) => String(p.pane_id) === currentPaneId);
  if (!current) return undefined;

  const sameTab = (p: WeztermPane) => p.tab_id === current.tab_id && p.pane_id !== current.pane_id;

  const markedId = readMarkedPaneId();
  const marked = markedId && panes.find((p) => String(p.pane_id) === markedId && sameTab(p));
  if (marked) return markedId;

  const byTitle = panes.find((p) => sameTab(p) && p.title === PANE_TITLE);
  if (byTitle) {
    const id = String(byTitle.pane_id);
    writeMarkedPaneId(id);
    return id;
  }

  // Launch the monitor via `node -e` so FM_HOME can be set for the child
  // process without depending on a shell being available on PATH.
  const inline = `process.env.FM_HOME=${JSON.stringify(FM_HOME)};require(${JSON.stringify(MONITOR_SCRIPT)});`;
  const newPaneId = await weztermCli(cmd, [
    "split-pane",
    "--pane-id",
    currentPaneId,
    "--right",
    "--percent",
    "25",
    "--",
    "node",
    "-e",
    inline,
  ]);
  if (!newPaneId) return undefined;
  writeMarkedPaneId(newPaneId);
  return newPaneId;
}

async function killPaneIfOpen(cmd: string, paneId: string): Promise<void> {
  try {
    const panes = await listPanes(cmd);
    if (panes.some((p) => String(p.pane_id) === paneId)) {
      await weztermCli(cmd, ["kill-pane", "--pane-id", paneId]);
    }
  } catch {
    // best-effort cleanup only
  } finally {
    try {
      rmSync(PANE_MARKER_FILE, { force: true });
    } catch {
      // ignore
    }
  }
}

export default function (pi: ExtensionAPI) {
  let monitorPaneId: string | undefined;

  pi.on("session_start", async (_event, ctx) => {
    if (!ctx.hasUI) return;
    const cmd = await findWeztermCmd();
    if (!cmd) return;
    try {
      monitorPaneId = await findOrSpawnMonitorPane(cmd);
    } catch {
      // wezterm not usable (no mux, not inside a pane, etc.) — no-op
    }
  });

  pi.on("turn_end", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const n = countActiveTasks();
    ctx.ui.setStatus("crew", n > 0 ? `🚢 ${n} active` : "🚢 idle");
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    if (!ctx.hasUI || !monitorPaneId) return;
    const cmd = await findWeztermCmd();
    if (!cmd) return;
    await killPaneIfOpen(cmd, monitorPaneId);
  });
}
