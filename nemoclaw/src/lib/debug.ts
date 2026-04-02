// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { existsSync, mkdtempSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { platform, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { execa } from "execa";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface DebugOptions {
  /** Target sandbox name (auto-detected if omitted). */
  sandboxName?: string;
  /** Only collect minimal diagnostics. */
  quick?: boolean;
  /** Write a tarball to this path. */
  output?: string;
}

// ---------------------------------------------------------------------------
// Colour helpers — respect NO_COLOR
// ---------------------------------------------------------------------------

const useColor = !process.env.NO_COLOR && process.stdout.isTTY;
const GREEN = useColor ? "\x1b[0;32m" : "";
const YELLOW = useColor ? "\x1b[1;33m" : "";
const CYAN = useColor ? "\x1b[0;36m" : "";
const NC = useColor ? "\x1b[0m" : "";

function info(msg: string): void {
  console.log(`${GREEN}[debug]${NC} ${msg}`);
}

function warn(msg: string): void {
  console.log(`${YELLOW}[debug]${NC} ${msg}`);
}

function section(title: string): void {
  console.log(`\n${CYAN}═══ ${title} ═══${NC}\n`);
}

// ---------------------------------------------------------------------------
// Secret redaction
// ---------------------------------------------------------------------------

const REDACT_PATTERNS: [RegExp, string][] = [
  [/(NVIDIA_API_KEY|API_KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|_KEY)=\S+/gi, "$1=<REDACTED>"],
  [/nvapi-[A-Za-z0-9_-]{10,}/g, "<REDACTED>"],
  [/ghp_[A-Za-z0-9]{30,}/g, "<REDACTED>"],
  [/(Bearer )\S+/gi, "$1<REDACTED>"],
];

export function redact(text: string): string {
  let result = text;
  for (const [pattern, replacement] of REDACT_PATTERNS) {
    result = result.replace(pattern, replacement);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Command runner
// ---------------------------------------------------------------------------

const isMacOS = platform() === "darwin";

async function commandExists(cmd: string): Promise<boolean> {
  try {
    await execa("command", ["-v", cmd], { shell: true, stdout: "ignore", stderr: "ignore" });
    return true;
  } catch {
    return false;
  }
}

async function collect(
  collectDir: string,
  label: string,
  command: string,
  args: string[],
): Promise<void> {
  const filename = label.replace(/[ /]/g, (c) => (c === " " ? "_" : "-"));
  const outfile = join(collectDir, `${filename}.txt`);

  if (!(await commandExists(command))) {
    const msg = `  (${command} not found, skipping)`;
    console.log(msg);
    writeFileSync(outfile, msg + "\n");
    return;
  }

  const result = await execa(command, args, {
    reject: false,
    timeout: 30_000,
    stdout: "pipe",
    stderr: "pipe",
    shell: command === "sh",
  });

  const raw = result.stdout + "\n" + result.stderr;
  const redacted = redact(raw);
  writeFileSync(outfile, redacted);
  console.log(redacted.trimEnd());

  if (result.exitCode !== 0) {
    console.log("  (command exited with non-zero status)");
  }
}

/** Run a shell one-liner via `sh -c`. */
async function collectShell(collectDir: string, label: string, shellCmd: string): Promise<void> {
  const filename = label.replace(/[ /]/g, (c) => (c === " " ? "_" : "-"));
  const outfile = join(collectDir, `${filename}.txt`);

  const result = await execa("sh", ["-c", shellCmd], {
    reject: false,
    timeout: 30_000,
    stdout: "pipe",
    stderr: "pipe",
  });

  const raw = result.stdout + "\n" + result.stderr;
  const redacted = redact(raw);
  writeFileSync(outfile, redacted);
  console.log(redacted.trimEnd());

  if (result.exitCode !== 0) {
    console.log("  (command exited with non-zero status)");
  }
}

// ---------------------------------------------------------------------------
// Auto-detect sandbox name
// ---------------------------------------------------------------------------

async function detectSandboxName(): Promise<string> {
  if (!(await commandExists("openshell"))) return "default";
  try {
    const result = await execa("openshell", ["sandbox", "list"], {
      reject: false,
      timeout: 10_000,
      stdout: "pipe",
      stderr: "ignore",
    });
    const lines = result.stdout.split("\n").filter((l) => l.trim().length > 0);
    for (const line of lines) {
      const first = line.trim().split(/\s+/)[0];
      if (first && first.toLowerCase() !== "name") return first;
    }
  } catch {
    /* ignore */
  }
  return "default";
}

// ---------------------------------------------------------------------------
// Diagnostic sections
// ---------------------------------------------------------------------------

async function collectSystem(collectDir: string, quick: boolean): Promise<void> {
  section("System");
  await collect(collectDir, "date", "date", []);
  await collect(collectDir, "uname", "uname", ["-a"]);
  await collect(collectDir, "uptime", "uptime", []);

  if (isMacOS) {
    await collectShell(
      collectDir,
      "memory",
      'echo "Physical: $(($(sysctl -n hw.memsize) / 1048576)) MB"; vm_stat',
    );
  } else {
    await collect(collectDir, "free", "free", ["-m"]);
  }

  if (!quick) {
    await collect(collectDir, "df", "df", ["-h"]);
  }
}

async function collectProcesses(collectDir: string, quick: boolean): Promise<void> {
  section("Processes");
  if (isMacOS) {
    await collectShell(
      collectDir,
      "ps-cpu",
      "ps -eo pid,ppid,comm,%mem,%cpu | sort -k5 -rn | head -30",
    );
  } else {
    await collectShell(
      collectDir,
      "ps-cpu",
      "ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -30",
    );
  }

  if (!quick) {
    if (isMacOS) {
      await collectShell(
        collectDir,
        "ps-mem",
        "ps -eo pid,ppid,comm,%mem,%cpu | sort -k4 -rn | head -30",
      );
      await collectShell(collectDir, "top", "top -l 1 | head -50");
    } else {
      await collectShell(
        collectDir,
        "ps-mem",
        "ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -30",
      );
      await collectShell(collectDir, "top", "top -b -n 1 | head -50");
    }
  }
}

async function collectGpu(collectDir: string, quick: boolean): Promise<void> {
  section("GPU");
  await collect(collectDir, "nvidia-smi", "nvidia-smi", []);

  if (!quick) {
    await collect(collectDir, "nvidia-smi-dmon", "nvidia-smi", [
      "dmon",
      "-s",
      "pucvmet",
      "-c",
      "10",
    ]);
    await collect(collectDir, "nvidia-smi-query", "nvidia-smi", [
      "--query-gpu=name,utilization.gpu,utilization.memory,memory.total,memory.used,temperature.gpu,power.draw",
      "--format=csv",
    ]);
  }
}

async function collectDocker(collectDir: string, quick: boolean): Promise<void> {
  section("Docker");
  await collect(collectDir, "docker-ps", "docker", ["ps", "-a"]);
  await collect(collectDir, "docker-stats", "docker", ["stats", "--no-stream"]);

  if (!quick) {
    await collect(collectDir, "docker-info", "docker", ["info"]);
    await collect(collectDir, "docker-df", "docker", ["system", "df"]);
  }

  // NemoClaw-labelled containers
  if (await commandExists("docker")) {
    try {
      const result = await execa(
        "docker",
        ["ps", "-a", "--filter", "label=com.nvidia.nemoclaw", "--format", "{{.Names}}"],
        { reject: false, stdout: "pipe", stderr: "ignore" },
      );
      const containers = result.stdout.split("\n").filter((c) => c.trim().length > 0);
      for (const cid of containers) {
        await collect(collectDir, `docker-logs-${cid}`, "docker", ["logs", "--tail", "200", cid]);
        if (!quick) {
          await collect(collectDir, `docker-inspect-${cid}`, "docker", ["inspect", cid]);
        }
      }
    } catch {
      /* docker not available */
    }
  }
}

async function collectOpenshell(
  collectDir: string,
  sandboxName: string,
  quick: boolean,
): Promise<void> {
  section("OpenShell");
  await collect(collectDir, "openshell-status", "openshell", ["status"]);
  await collect(collectDir, "openshell-sandbox-list", "openshell", ["sandbox", "list"]);
  await collect(collectDir, "openshell-sandbox-get", "openshell", ["sandbox", "get", sandboxName]);
  await collect(collectDir, "openshell-logs", "openshell", ["logs", sandboxName]);

  if (!quick) {
    await collect(collectDir, "openshell-gateway-info", "openshell", ["gateway", "info"]);
  }
}

async function collectSandboxInternals(
  collectDir: string,
  sandboxName: string,
  quick: boolean,
): Promise<void> {
  if (!(await commandExists("openshell"))) return;

  // Check if sandbox exists
  try {
    const result = await execa("openshell", ["sandbox", "list"], {
      reject: false,
      timeout: 10_000,
      stdout: "pipe",
      stderr: "ignore",
    });
    const names = result.stdout
      .split("\n")
      .map((l) => l.trim().split(/\s+/)[0])
      .filter((n) => n && n.toLowerCase() !== "name");
    if (!names.includes(sandboxName)) return;
  } catch {
    return;
  }

  section("Sandbox Internals");

  // Generate temporary SSH config
  const sshConfigPath = join(tmpdir(), `nemoclaw-ssh-${String(Date.now())}`);
  try {
    const sshResult = await execa("openshell", ["sandbox", "ssh-config", sandboxName], {
      reject: false,
      stdout: "pipe",
      stderr: "ignore",
    });
    if (sshResult.exitCode !== 0) {
      warn(`Could not generate SSH config for sandbox '${sandboxName}', skipping internals`);
      return;
    }
    writeFileSync(sshConfigPath, sshResult.stdout);

    const sshHost = `openshell-${sandboxName}`;
    const sshBase = [
      "-F",
      sshConfigPath,
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "ConnectTimeout=10",
      sshHost,
    ];

    await collect(collectDir, "sandbox-ps", "ssh", [...sshBase, "ps", "-ef"]);
    await collect(collectDir, "sandbox-free", "ssh", [...sshBase, "free", "-m"]);
    if (!quick) {
      await collectShell(
        collectDir,
        "sandbox-top",
        `ssh ${sshBase.map((a) => `'${a}'`).join(" ")} 'top -b -n 1 | head -50'`,
      );
      await collect(collectDir, "sandbox-gateway-log", "ssh", [
        ...sshBase,
        "tail",
        "-200",
        "/tmp/gateway.log",
      ]);
    }
  } finally {
    if (existsSync(sshConfigPath)) {
      unlinkSync(sshConfigPath);
    }
  }
}

async function collectNetwork(collectDir: string): Promise<void> {
  section("Network");
  if (isMacOS) {
    await collectShell(collectDir, "listening", "netstat -anp tcp | grep LISTEN");
    await collect(collectDir, "ifconfig", "ifconfig", []);
    await collect(collectDir, "routes", "netstat", ["-rn"]);
    await collect(collectDir, "dns-config", "scutil", ["--dns"]);
  } else {
    await collect(collectDir, "ss", "ss", ["-ltnp"]);
    await collect(collectDir, "ip-addr", "ip", ["addr"]);
    await collect(collectDir, "ip-route", "ip", ["route"]);
    await collectShell(collectDir, "resolv-conf", "cat /etc/resolv.conf");
  }
  await collect(collectDir, "nslookup", "nslookup", ["integrate.api.nvidia.com"]);
  await collectShell(
    collectDir,
    "curl-models",
    'code=$(curl -s -o /dev/null -w "%{http_code}" https://integrate.api.nvidia.com/v1/models); echo "HTTP $code"; if [ "$code" -ge 200 ] && [ "$code" -lt 500 ]; then echo "NIM API reachable"; else echo "NIM API unreachable"; exit 1; fi',
  );
  await collectShell(collectDir, "lsof-net", "lsof -i -P -n 2>/dev/null | head -50");
  await collect(collectDir, "lsof-18789", "lsof", ["-i", ":18789"]);
}

async function collectKernel(collectDir: string): Promise<void> {
  section("Kernel / IO");
  if (isMacOS) {
    await collect(collectDir, "vmstat", "vm_stat", []);
    await collect(collectDir, "iostat", "iostat", ["-c", "5", "-w", "1"]);
  } else {
    await collect(collectDir, "vmstat", "vmstat", ["1", "5"]);
    await collect(collectDir, "iostat", "iostat", ["-xz", "1", "5"]);
  }
}

async function collectKernelMessages(collectDir: string): Promise<void> {
  section("Kernel Messages");
  if (isMacOS) {
    await collectShell(
      collectDir,
      "system-log",
      'log show --last 5m --predicate "eventType == logEvent" --style compact 2>/dev/null | tail -100',
    );
  } else {
    await collectShell(collectDir, "dmesg", "dmesg | tail -100");
  }
}

// ---------------------------------------------------------------------------
// Tarball
// ---------------------------------------------------------------------------

async function createTarball(collectDir: string, output: string): Promise<void> {
  await execa("tar", ["czf", output, "-C", dirname(collectDir), basename(collectDir)]);
  info(`Tarball written to ${output}`);
  warn(
    "Known secrets are auto-redacted, but please review for any remaining sensitive data before sharing.",
  );
  info("Attach this file to your GitHub issue.");
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

export async function runDebug(opts: DebugOptions = {}): Promise<void> {
  const quick = opts.quick ?? false;
  const output = opts.output ?? "";

  // Resolve sandbox name
  let sandboxName =
    opts.sandboxName ?? process.env.NEMOCLAW_SANDBOX ?? process.env.SANDBOX_NAME ?? "";
  if (!sandboxName) {
    sandboxName = await detectSandboxName();
  }

  // Create temp collection directory
  const collectDir = mkdtempSync(join(tmpdir(), "nemoclaw-debug-"));

  try {
    info(`Collecting diagnostics for sandbox '${sandboxName}'...`);
    info(`Quick mode: ${String(quick)}`);
    if (output) info(`Tarball output: ${output}`);
    console.log("");

    await collectSystem(collectDir, quick);
    await collectProcesses(collectDir, quick);
    await collectGpu(collectDir, quick);
    await collectDocker(collectDir, quick);
    await collectOpenshell(collectDir, sandboxName, quick);
    await collectSandboxInternals(collectDir, sandboxName, quick);

    if (!quick) {
      await collectNetwork(collectDir);
      await collectKernel(collectDir);
    }

    await collectKernelMessages(collectDir);

    if (output) {
      await createTarball(collectDir, output);
    }

    console.log("");
    info("Done. If filing a bug, run with --output and attach the tarball to your issue:");
    info("  nemoclaw debug --output /tmp/nemoclaw-debug.tar.gz");
  } finally {
    rmSync(collectDir, { recursive: true, force: true });
  }
}
