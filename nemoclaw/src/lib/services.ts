// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { execa } from "execa";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface ServiceOptions {
  /** Sandbox name (default: "default"). */
  sandboxName?: string;
  /** Dashboard port for cloudflared (default: 18789). */
  dashboardPort?: number;
  /** Repo root directory — used to locate scripts/. */
  repoDir?: string;
  /** Override PID directory (default: /tmp/nemoclaw-services-{sandbox}). */
  pidDir?: string;
}

export interface ServiceStatus {
  name: string;
  running: boolean;
  pid: number | null;
}

// ---------------------------------------------------------------------------
// Colour helpers — respect NO_COLOR
// ---------------------------------------------------------------------------

const useColor = !process.env.NO_COLOR && process.stdout.isTTY;
const GREEN = useColor ? "\x1b[0;32m" : "";
const RED = useColor ? "\x1b[0;31m" : "";
const YELLOW = useColor ? "\x1b[1;33m" : "";
const NC = useColor ? "\x1b[0m" : "";

function info(msg: string): void {
  console.log(`${GREEN}[services]${NC} ${msg}`);
}

function warn(msg: string): void {
  console.log(`${YELLOW}[services]${NC} ${msg}`);
}

// ---------------------------------------------------------------------------
// PID helpers
// ---------------------------------------------------------------------------

function ensurePidDir(pidDir: string): void {
  if (!existsSync(pidDir)) {
    mkdirSync(pidDir, { recursive: true });
  }
}

function readPid(pidDir: string, name: string): number | null {
  const pidFile = join(pidDir, `${name}.pid`);
  if (!existsSync(pidFile)) return null;
  const raw = readFileSync(pidFile, "utf-8").trim();
  const pid = Number(raw);
  return Number.isFinite(pid) && pid > 0 ? pid : null;
}

function isRunning(pidDir: string, name: string): boolean {
  const pid = readPid(pidDir, name);
  if (pid === null) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function writePid(pidDir: string, name: string, pid: number): void {
  writeFileSync(join(pidDir, `${name}.pid`), String(pid));
}

function removePid(pidDir: string, name: string): void {
  const pidFile = join(pidDir, `${name}.pid`);
  if (existsSync(pidFile)) {
    unlinkSync(pidFile);
  }
}

// ---------------------------------------------------------------------------
// Service lifecycle
// ---------------------------------------------------------------------------

const SERVICE_NAMES = ["telegram-bridge", "cloudflared"] as const;
type ServiceName = (typeof SERVICE_NAMES)[number];

function startService(
  pidDir: string,
  name: ServiceName,
  command: string,
  args: string[],
  env?: Record<string, string>,
): void {
  if (isRunning(pidDir, name)) {
    const pid = readPid(pidDir, name);
    info(`${name} already running (PID ${String(pid)})`);
    return;
  }

  const logFile = join(pidDir, `${name}.log`);
  const subprocess = execa(command, args, {
    detached: true,
    stdout: { file: logFile },
    stderr: { file: logFile },
    stdin: "ignore",
    env: { ...process.env, ...env },
    cleanup: false,
  });

  const pid = subprocess.pid;
  if (pid === undefined) {
    warn(`${name} failed to start`);
    return;
  }

  subprocess.unref();
  writePid(pidDir, name, pid);
  info(`${name} started (PID ${String(pid)})`);
}

function stopService(pidDir: string, name: ServiceName): void {
  const pid = readPid(pidDir, name);
  if (pid !== null) {
    try {
      process.kill(pid, 0); // check alive
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        try {
          process.kill(pid, "SIGKILL");
        } catch {
          /* already dead */
        }
      }
      info(`${name} stopped (PID ${String(pid)})`);
    } catch {
      info(`${name} was not running`);
    }
    removePid(pidDir, name);
  } else {
    info(`${name} was not running`);
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

function resolvePidDir(opts: ServiceOptions): string {
  const sandbox =
    opts.sandboxName ?? process.env.NEMOCLAW_SANDBOX ?? process.env.SANDBOX_NAME ?? "default";
  return opts.pidDir ?? `/tmp/nemoclaw-services-${sandbox}`;
}

export function showStatus(opts: ServiceOptions = {}): void {
  const pidDir = resolvePidDir(opts);
  ensurePidDir(pidDir);

  console.log("");
  for (const svc of SERVICE_NAMES) {
    if (isRunning(pidDir, svc)) {
      const pid = readPid(pidDir, svc);
      console.log(`  ${GREEN}●${NC} ${svc}  (PID ${String(pid)})`);
    } else {
      console.log(`  ${RED}●${NC} ${svc}  (stopped)`);
    }
  }
  console.log("");

  const logFile = join(pidDir, "cloudflared.log");
  if (existsSync(logFile)) {
    const log = readFileSync(logFile, "utf-8");
    const match = /https:\/\/[a-z0-9-]*\.trycloudflare\.com/.exec(log);
    if (match) {
      info(`Public URL: ${match[0]}`);
    }
  }
}

export function stopAll(opts: ServiceOptions = {}): void {
  const pidDir = resolvePidDir(opts);
  ensurePidDir(pidDir);
  stopService(pidDir, "cloudflared");
  stopService(pidDir, "telegram-bridge");
  info("All services stopped.");
}

export async function startAll(opts: ServiceOptions = {}): Promise<void> {
  const pidDir = resolvePidDir(opts);
  const dashboardPort = opts.dashboardPort ?? (Number(process.env.DASHBOARD_PORT) || 18789);
  const repoDir = opts.repoDir ?? join(import.meta.dirname, "..", "..", "..");

  if (!process.env.NVIDIA_API_KEY) {
    console.error(`${RED}[services]${NC} NVIDIA_API_KEY required`);
    process.exit(1);
  }

  if (!process.env.TELEGRAM_BOT_TOKEN) {
    warn("TELEGRAM_BOT_TOKEN not set \u2014 Telegram bridge will not start.");
    warn("Create a bot via @BotFather on Telegram and set the token.");
  }

  // Verify node is available (should always be true since we're running in Node)
  try {
    await execa("node", ["--version"], { reject: true, stdout: "ignore", stderr: "ignore" });
  } catch {
    console.error(`${RED}[services]${NC} node not found. Install Node.js first.`);
    process.exit(1);
  }

  // Warn if no sandbox is ready
  try {
    const result = await execa("openshell", ["sandbox", "list"], {
      reject: false,
      stdout: "pipe",
      stderr: "pipe",
    });
    const output = result.stdout + result.stderr;
    if (!output.includes("Ready")) {
      warn("No sandbox in Ready state. Telegram bridge may not work until sandbox is running.");
    }
  } catch {
    /* openshell not installed — skip check */
  }

  ensurePidDir(pidDir);

  // Telegram bridge
  if (process.env.TELEGRAM_BOT_TOKEN) {
    const sandboxName =
      opts.sandboxName ?? process.env.NEMOCLAW_SANDBOX ?? process.env.SANDBOX_NAME ?? "default";
    startService(
      pidDir,
      "telegram-bridge",
      "node",
      [join(repoDir, "scripts", "telegram-bridge.js")],
      { SANDBOX_NAME: sandboxName },
    );
  }

  // cloudflared tunnel
  try {
    await execa("command", ["-v", "cloudflared"], {
      reject: true,
      shell: true,
      stdout: "ignore",
      stderr: "ignore",
    });
    startService(pidDir, "cloudflared", "cloudflared", [
      "tunnel",
      "--url",
      `http://localhost:${String(dashboardPort)}`,
    ]);
  } catch {
    warn("cloudflared not found \u2014 no public URL. Install: brev-setup.sh or manually.");
  }

  // Wait for cloudflared URL
  if (isRunning(pidDir, "cloudflared")) {
    info("Waiting for tunnel URL...");
    const logFile = join(pidDir, "cloudflared.log");
    for (let i = 0; i < 15; i++) {
      if (existsSync(logFile)) {
        const log = readFileSync(logFile, "utf-8");
        if (/https:\/\/[a-z0-9-]*\.trycloudflare\.com/.test(log)) {
          break;
        }
      }
      await new Promise((resolve) => {
        setTimeout(resolve, 1000);
      });
    }
  }

  // Banner
  console.log("");
  console.log(
    "  \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510",
  );
  console.log("  \u2502  NemoClaw Services                                  \u2502");
  console.log("  \u2502                                                     \u2502");

  let tunnelUrl = "";
  const cfLogFile = join(pidDir, "cloudflared.log");
  if (existsSync(cfLogFile)) {
    const log = readFileSync(cfLogFile, "utf-8");
    const match = /https:\/\/[a-z0-9-]*\.trycloudflare\.com/.exec(log);
    if (match) {
      tunnelUrl = match[0];
    }
  }

  if (tunnelUrl) {
    console.log(`  \u2502  Public URL:  ${tunnelUrl.padEnd(40)}\u2502`);
  }

  if (isRunning(pidDir, "telegram-bridge")) {
    console.log("  \u2502  Telegram:    bridge running                        \u2502");
  } else {
    console.log("  \u2502  Telegram:    not started (no token)                \u2502");
  }

  console.log("  \u2502                                                     \u2502");
  console.log("  \u2502  Run 'openshell term' to monitor egress approvals   \u2502");
  console.log(
    "  \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518",
  );
  console.log("");
}

// ---------------------------------------------------------------------------
// Exported status helper (useful for programmatic access)
// ---------------------------------------------------------------------------

export function getServiceStatuses(opts: ServiceOptions = {}): ServiceStatus[] {
  const pidDir = resolvePidDir(opts);
  ensurePidDir(pidDir);
  return SERVICE_NAMES.map((name) => ({
    name,
    running: isRunning(pidDir, name),
    pid: readPid(pidDir, name),
  }));
}
