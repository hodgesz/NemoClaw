// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import type { PluginLogger } from "../index.js";
import { tmpdir } from "node:os";
import { join } from "node:path";

export interface EnsureSandboxOpenClawBootstrapOptions {
  sandboxName: string;
  logger: PluginLogger;
}

type SandboxOpenClawCommandResult = {
  ok: boolean;
  stdout: string;
  stderr: string;
  detail: string;
};

type GatewayInstallJson = {
  ok?: boolean;
  message?: string;
  warnings?: string[];
};

function isSystemdUnavailableDetail(detail: string): boolean {
  const normalized = detail.toLowerCase();
  return (
    normalized.includes("systemctl --user unavailable") ||
    normalized.includes("systemctl not available") ||
    normalized.includes("systemd user services are required") ||
    normalized.includes("failed to connect to bus") ||
    normalized.includes("dbus_session_bus_address") ||
    normalized.includes("xdg_runtime_dir")
  );
}

function readExecStream(value: unknown): string {
  if (typeof value === "string") {
    return value.trim();
  }
  if (value instanceof Buffer) {
    return value.toString("utf-8").trim();
  }
  return "";
}

function runSandboxSshCommand(
  sandboxName: string,
  remoteArgs: string[],
): SandboxOpenClawCommandResult {
  const tmpDir = mkdtempSync(join(tmpdir(), "nemoclaw-ssh-"));
  const configPath = join(tmpDir, "config");

  try {
    const sshConfig = execFileSync("openshell", ["sandbox", "ssh-config", sandboxName], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    writeFileSync(configPath, sshConfig, { mode: 0o600 });

    const host =
      sshConfig
        .split("\n")
        .map((line) => line.trim())
        .find((line) => line.startsWith("Host "))
        ?.split(/\s+/)[1] || `openshell-${sandboxName}`;

    const remoteCommand = remoteArgs
      .map((arg) => `'${arg.replaceAll("'", `'\\''`)}'`)
      .join(" ");

    const stdout = execFileSync("ssh", ["-F", configPath, host, remoteCommand], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return {
      ok: true,
      stdout: stdout.trim(),
      stderr: "",
      detail: stdout.trim(),
    };
  } catch (err: unknown) {
    const stderr =
      err && typeof err === "object" && "stderr" in err
        ? readExecStream((err as { stderr?: unknown }).stderr)
        : "";
    const stdout =
      err && typeof err === "object" && "stdout" in err
        ? readExecStream((err as { stdout?: unknown }).stdout)
        : "";
    const detail = stderr || stdout || String(err);
    return {
      ok: false,
      stdout,
      stderr,
      detail,
    };
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}

function runSandboxOpenClawCommand(
  sandboxName: string,
  args: string[],
): SandboxOpenClawCommandResult {
  return runSandboxSshCommand(sandboxName, ["nemoclaw-shell", "openclaw", ...args]);
}

function parseGatewayInstallJson(stdout: string): GatewayInstallJson | null {
  if (!stdout) {
    return null;
  }
  try {
    return JSON.parse(stdout) as GatewayInstallJson;
  } catch {
    return null;
  }
}

function runSandboxShellCommand(sandboxName: string, script: string): SandboxOpenClawCommandResult {
  return runSandboxSshCommand(sandboxName, ["nemoclaw-shell", "sh", "-lc", script]);
}

function manualSandboxCommandHint(sandboxName: string, command: string): string {
  return `openshell sandbox ssh-config ${sandboxName} > /tmp/${sandboxName}.ssh && ssh -F /tmp/${sandboxName}.ssh openshell-${sandboxName} nemoclaw-shell ${command}`;
}

function startSandboxGatewayWithoutSystemd(
  sandboxName: string,
  logger: PluginLogger,
): SandboxOpenClawCommandResult {
  logger.warn(
    "Sandbox user-systemd is unavailable, likely because the sandbox was not booted with systemd. Falling back to a direct background Gateway process.",
  );
  return runSandboxShellCommand(
    sandboxName,
    [
      'mkdir -p "$HOME/.openclaw/logs"',
      'if ! openclaw gateway status --deep >/dev/null 2>&1; then',
      '  nohup openclaw gateway run >"$HOME/.openclaw/logs/gateway.log" 2>&1 < /dev/null &',
      "fi",
      "for i in 1 2 3 4 5 6 7 8; do",
      "  if openclaw gateway status --deep >/dev/null 2>&1; then",
      '    echo "gateway-ready"',
      "    exit 0",
      "  fi",
      "  sleep 2",
      "done",
      'echo "gateway-not-ready" >&2',
      "exit 1",
    ].join("\n"),
  );
}

export function ensureSandboxOpenClawBootstrap(
  opts: EnsureSandboxOpenClawBootstrapOptions,
): boolean {
  const { sandboxName, logger } = opts;

  const setup = runSandboxOpenClawCommand(sandboxName, ["setup"]);
  if (!setup.ok) {
    logger.error(`Failed to initialize OpenClaw inside the sandbox: ${setup.detail}`);
    logger.info(`After resolving the issue, run '${manualSandboxCommandHint(sandboxName, "openclaw setup")}'.`);
    return false;
  }

  // Keep bootstrap headless. `gateway install` auto-generates and persists a
  // gateway token when one is missing, then installs the managed service.
  const install = runSandboxOpenClawCommand(sandboxName, ["gateway", "install", "--json"]);
  const parsed = parseGatewayInstallJson(install.stdout);
  const installFailure = !install.ok || parsed?.ok === false;
  const installFailureDetail = parsed?.message || install.detail || "Sandbox Gateway install failed.";

  if (installFailure && isSystemdUnavailableDetail(installFailureDetail)) {
    const fallback = startSandboxGatewayWithoutSystemd(sandboxName, logger);
    if (!fallback.ok) {
      logger.error(`Failed to start the sandbox Gateway without systemd: ${fallback.detail}`);
      logger.info(
        `After resolving the issue, run '${manualSandboxCommandHint(sandboxName, "openclaw gateway run")}'.`,
      );
      return false;
    }
    for (const warning of parsed?.warnings ?? []) {
      logger.warn(warning);
    }
    logger.info("Initialized OpenClaw config and started the Gateway directly inside the sandbox.");
    return true;
  }

  if (installFailure) {
    logger.error(`Failed to install the sandbox Gateway service: ${installFailureDetail}`);
    logger.info(
      `After resolving the issue, run '${manualSandboxCommandHint(sandboxName, "openclaw gateway install")}'.`,
    );
    return false;
  }
  for (const warning of parsed?.warnings ?? []) {
    logger.warn(warning);
  }

  logger.info("Initialized OpenClaw config and installed the Gateway service inside the sandbox.");
  return true;
}
