#!/usr/bin/env node
// fm-crew-monitor.js — live crew-panel renderer for the right-side WezTerm pane.
//
// Self-contained: node:fs / node:path / node:readline / node:process only, no
// npm dependencies, no build step. Meant to be launched by
// .pi/extensions/crew-panel.ts via `wezterm cli split-pane`, but also runs
// standalone: `FM_HOME=/path/to/home node bin/fm-crew-monitor.js`.
//
// Reads FM_HOME from the environment; default is the directory containing
// this script's bin/ (i.e. the firstmate repo root), matching the FM_HOME
// convention documented in AGENTS.md section 2.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

const FM_HOME = process.env.FM_HOME || path.dirname(__dirname);
const STATE_DIR = path.join(FM_HOME, "state");
const DATA_DIR = path.join(FM_HOME, "data");
const REFRESH_MS = 2000;

// Marks this pane's terminal title so the pi extension can recognize an
// already-running monitor on session_start and avoid spawning a duplicate.
const PANE_TITLE = "fm-crew-monitor";

function setPaneTitle() {
  process.stdout.write(`\x1b]0;${PANE_TITLE}\x07`);
}

function readLines(file) {
  try {
    return fs.readFileSync(file, "utf8").split(/\r?\n/);
  } catch {
    return [];
  }
}

function lastStatusLine(id) {
  const lines = readLines(path.join(STATE_DIR, `${id}.status`)).filter((l) => l.trim() !== "");
  return lines.length ? lines[lines.length - 1].trim() : "";
}

function lastStatusLines(id, n) {
  const lines = readLines(path.join(STATE_DIR, `${id}.status`)).filter((l) => l.trim() !== "");
  return lines.slice(-n);
}

function parseMeta(id) {
  const lines = readLines(path.join(STATE_DIR, `${id}.meta`));
  const meta = {};
  for (const line of lines) {
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    meta[line.slice(0, eq)] = line.slice(eq + 1);
  }
  return meta;
}

function projectName(meta) {
  const raw = meta.project || meta.home || "";
  if (!raw) return "?";
  return path.basename(raw.replace(/[\\/]+$/, "")) || raw;
}

function briefDescription(id) {
  const lines = readLines(path.join(DATA_DIR, id, "brief.md"));
  for (const line of lines) {
    const t = line.trim();
    if (t === "" || t.startsWith("#")) continue;
    return t;
  }
  return "(no brief)";
}

function scanTasks() {
  let entries;
  try {
    entries = fs.readdirSync(STATE_DIR);
  } catch {
    return [];
  }
  const ids = entries
    .filter((f) => f.endsWith(".meta"))
    .map((f) => f.slice(0, -".meta".length))
    .sort();
  return ids.map((id) => {
    const meta = parseMeta(id);
    return {
      id,
      project: projectName(meta),
      status: lastStatusLine(id),
    };
  });
}

// --- rendering ---------------------------------------------------------

function cols() {
  return Math.max(process.stdout.columns || 30, 20);
}

function truncate(s, width) {
  if (s.length <= width) return s;
  if (width <= 1) return s.slice(0, width);
  return s.slice(0, width - 1) + "…";
}

function padRow(text, width) {
  const t = truncate(text, width);
  return t + " ".repeat(Math.max(0, width - t.length));
}

function boxLine(text, width) {
  return `│ ${padRow(text, width - 4)} │`;
}

function boxTop(title, width) {
  const label = ` ${title} `;
  const dashes = Math.max(0, width - 2 - label.length);
  return `┌${label}${"─".repeat(dashes)}┐`;
}

function boxBottom(width) {
  return `└${"─".repeat(Math.max(0, width - 2))}┘`;
}

function boxDivider(width) {
  return `├${"─".repeat(Math.max(0, width - 2))}┤`;
}

function clearScreen() {
  process.stdout.write("\x1b[2J\x1b[H");
}

function renderList(tasks, selected) {
  const width = cols();
  const out = [];
  out.push(boxTop(`Crew (${tasks.length} active)`, width));
  if (tasks.length === 0) {
    out.push(boxLine("no crew in flight", width));
  } else {
    tasks.forEach((task, i) => {
      const marker = i === selected ? "▶ " : "  ";
      out.push(boxLine(`${marker}${task.id}`, width));
      out.push(boxLine(`    ${task.project}`, width));
      out.push(boxLine(`    ${task.status || "(no status yet)"}`, width));
    });
  }
  out.push(boxDivider(width));
  out.push(boxLine("↑↓ select  ⏎ detail  ^C quit", width));
  out.push(boxBottom(width));
  return out.join("\n");
}

function renderDetail(task) {
  const width = cols();
  const out = [];
  out.push(boxTop(task.id, width));
  out.push(boxLine(`project: ${task.project}`, width));
  out.push(boxLine(`task: ${briefDescription(task.id)}`, width));
  out.push(boxDivider(width));
  const lines = lastStatusLines(task.id, 10);
  if (lines.length === 0) {
    out.push(boxLine("(no status yet)", width));
  } else {
    for (const line of lines) out.push(boxLine(line, width));
  }
  out.push(boxDivider(width));
  out.push(boxLine("q/Esc back  ^C quit", width));
  out.push(boxBottom(width));
  return out.join("\n");
}

// --- main loop -----------------------------------------------------------

let tasks = [];
let selected = 0;
let detailId = null; // task id currently shown in detail view, or null for list

function render() {
  clearScreen();
  if (detailId !== null) {
    const task = tasks.find((t) => t.id === detailId);
    if (!task) {
      detailId = null;
      process.stdout.write(renderList(tasks, selected));
      return;
    }
    process.stdout.write(renderDetail(task));
  } else {
    process.stdout.write(renderList(tasks, selected));
  }
}

function refresh() {
  tasks = scanTasks();
  if (selected >= tasks.length) selected = Math.max(0, tasks.length - 1);
  render();
}

function cleanExit() {
  process.stdout.write("\x1b[?25h"); // show cursor
  clearScreen();
  if (process.stdin.isTTY) process.stdin.setRawMode(false);
  process.exit(0);
}

function main() {
  setPaneTitle();
  process.stdout.write("\x1b[?25l"); // hide cursor
  refresh();
  setInterval(refresh, REFRESH_MS);

  if (process.stdin.isTTY) {
    readline.emitKeypressEvents(process.stdin);
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.on("keypress", (_str, key) => {
      if (!key) return;
      if (key.ctrl && key.name === "c") {
        cleanExit();
        return;
      }
      if (detailId !== null) {
        if (key.name === "escape" || key.name === "q") {
          detailId = null;
          render();
        }
        return;
      }
      if (key.name === "up") {
        if (tasks.length) selected = (selected - 1 + tasks.length) % tasks.length;
        render();
      } else if (key.name === "down") {
        if (tasks.length) selected = (selected + 1) % tasks.length;
        render();
      } else if (key.name === "return") {
        if (tasks.length) {
          detailId = tasks[selected].id;
          render();
        }
      }
    });
  }

  process.stdout.on("resize", render);
  process.on("SIGINT", cleanExit);
  process.on("SIGTERM", cleanExit);
}

main();
