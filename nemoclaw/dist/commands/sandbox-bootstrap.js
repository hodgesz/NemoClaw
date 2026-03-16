"use strict";
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
exports.ensureSandboxOpenClawBootstrap = ensureSandboxOpenClawBootstrap;
const node_child_process_1 = require("node:child_process");
const node_fs_1 = require("node:fs");
const node_os_1 = require("node:os");
const node_path_1 = require("node:path");
function isSystemdUnavailableDetail(detail) {
    const normalized = detail.toLowerCase();
    return (normalized.includes("systemctl --user unavailable") ||
        normalized.includes("systemctl not available") ||
        normalized.includes("systemd user services are required") ||
        normalized.includes("failed to connect to bus") ||
        normalized.includes("dbus_session_bus_address") ||
        normalized.includes("xdg_runtime_dir"));
}
function readExecStream(value) {
    if (typeof value === "string") {
        return value.trim();
    }
    if (value instanceof Buffer) {
        return value.toString("utf-8").trim();
    }
    return "";
}
function runSandboxSshCommand(sandboxName, remoteArgs) {
    const tmpDir = (0, node_fs_1.mkdtempSync)((0, node_path_1.join)((0, node_os_1.tmpdir)(), "nemoclaw-ssh-"));
    const configPath = (0, node_path_1.join)(tmpDir, "config");
    try {
        const sshConfig = (0, node_child_process_1.execFileSync)("openshell", ["sandbox", "ssh-config", sandboxName], {
            encoding: "utf-8",
            stdio: ["ignore", "pipe", "pipe"],
        });
        (0, node_fs_1.writeFileSync)(configPath, sshConfig, { mode: 0o600 });
        const host = sshConfig
            .split("\n")
            .map((line) => line.trim())
            .find((line) => line.startsWith("Host "))
            ?.split(/\s+/)[1] || `openshell-${sandboxName}`;
        const remoteCommand = remoteArgs
            .map((arg) => `'${arg.replaceAll("'", `'\\''`)}'`)
            .join(" ");
        const stdout = (0, node_child_process_1.execFileSync)("ssh", ["-F", configPath, host, remoteCommand], {
            encoding: "utf-8",
            stdio: ["ignore", "pipe", "pipe"],
        });
        return {
            ok: true,
            stdout: stdout.trim(),
            stderr: "",
            detail: stdout.trim(),
        };
    }
    catch (err) {
        const stderr = err && typeof err === "object" && "stderr" in err
            ? readExecStream(err.stderr)
            : "";
        const stdout = err && typeof err === "object" && "stdout" in err
            ? readExecStream(err.stdout)
            : "";
        const detail = stderr || stdout || String(err);
        return {
            ok: false,
            stdout,
            stderr,
            detail,
        };
    }
    finally {
        (0, node_fs_1.rmSync)(tmpDir, { recursive: true, force: true });
    }
}
function runSandboxOpenClawCommand(sandboxName, args) {
    return runSandboxSshCommand(sandboxName, ["nemoclaw-shell", "openclaw", ...args]);
}
function parseGatewayInstallJson(stdout) {
    if (!stdout) {
        return null;
    }
    try {
        return JSON.parse(stdout);
    }
    catch {
        return null;
    }
}
function runSandboxShellCommand(sandboxName, script) {
    return runSandboxSshCommand(sandboxName, ["nemoclaw-shell", "sh", "-lc", script]);
}
function manualSandboxCommandHint(sandboxName, command) {
    return `openshell sandbox ssh-config ${sandboxName} > /tmp/${sandboxName}.ssh && ssh -F /tmp/${sandboxName}.ssh openshell-${sandboxName} nemoclaw-shell ${command}`;
}
function startSandboxGatewayWithoutSystemd(sandboxName, logger) {
    logger.warn("Sandbox user-systemd is unavailable, likely because the sandbox was not booted with systemd. Falling back to a direct background Gateway process.");
    return runSandboxShellCommand(sandboxName, [
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
    ].join("\n"));
}
function ensureSandboxOpenClawBootstrap(opts) {
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
            logger.info(`After resolving the issue, run '${manualSandboxCommandHint(sandboxName, "openclaw gateway run")}'.`);
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
        logger.info(`After resolving the issue, run '${manualSandboxCommandHint(sandboxName, "openclaw gateway install")}'.`);
        return false;
    }
    for (const warning of parsed?.warnings ?? []) {
        logger.warn(warning);
    }
    logger.info("Initialized OpenClaw config and installed the Gateway service inside the sandbox.");
    return true;
}
//# sourceMappingURL=sandbox-bootstrap.js.map