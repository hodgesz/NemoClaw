// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { shellQuote } = require("../../dist/lib/runner");

/**
 * Create a spawnClaudeCodeProcess function that executes the Claude Code CLI
 * inside a running NemoClaw sandbox via SSH.
 *
 * @param {string} sshConfigPath - Path to the SSH config file
 * @param {string} sandboxName - The OpenShell sandbox name
 * @param {Array<[string, string]>} authEnv - Auth env var pairs (e.g. [["CLAUDE_CODE_USE_BEDROCK","1"], ["AWS_REGION","us-east-1"]])
 * @returns {(options: import("@anthropic-ai/claude-agent-sdk").SpawnOptions) => import("child_process").ChildProcess}
 */
function createSandboxSpawner(sshConfigPath, sandboxName, authEnv) {
  return (options) => {
    // Build env exports to inject into the remote shell from the resolved auth.
    // Use export+semicolons to avoid quoting issues with SSH remote commands.
    const envExports = authEnv.map(([k, v]) => `export ${k}=${shellQuote(v)}`).join("; ");

    // Use the sandbox's claude binary — may be globally installed or under
    // /sandbox/.local via npm prefix. The SDK passes its bundled cli.js
    // path as the command, but we need the sandbox-local binary instead.
    const remoteArgs = options.args
      .filter((a) => !a.includes("cli.js"))
      .map((a) => shellQuote(a))
      .join(" ");

    const cwd = options.cwd || "/sandbox";
    const claudeBin = "$(command -v claude || echo /sandbox/.local/node_modules/.bin/claude)";
    const remoteCmd = `${envExports}; cd ${shellQuote(cwd)} && ${claudeBin} ${remoteArgs}`;

    const proc = spawn(
      "ssh",
      [
        "-F",
        sshConfigPath,
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        "-o",
        "ServerAliveInterval=30",
        `openshell-${sandboxName}`,
        remoteCmd,
      ],
      { stdio: ["pipe", "pipe", "pipe"] },
    );

    // Wire abort signal
    if (options.signal) {
      options.signal.addEventListener("abort", () => {
        proc.kill("SIGTERM");
      });
    }

    return proc;
  };
}

/**
 * Run a Claude Agent SDK query inside a NemoClaw sandbox.
 *
 * @param {object} params
 * @param {string} params.sandboxName - Sandbox name
 * @param {string} params.sshConfigContent - SSH config file content (from openshell)
 * @param {Array<[string, string]>} params.authEnv - Auth env var pairs from resolveClaudeAuthEnv()
 * @param {string} params.prompt - Prompt to send
 * @param {object} [params.sdkOptions] - Additional SDK query options
 * @returns {AsyncGenerator} Stream of SDK messages
 */
async function* querySandbox({ sandboxName, sshConfigContent, authEnv, prompt, sdkOptions = {} }) {
  // Lazy-load the SDK (it's ESM, so we need dynamic import)
  const { query } = await import("@anthropic-ai/claude-agent-sdk");

  // Write SSH config to a temp file
  const tmpFile = path.join(os.tmpdir(), `nemoclaw-claude-sdk-${process.pid}-${Date.now()}.conf`);
  fs.writeFileSync(tmpFile, sshConfigContent, { mode: 0o600 });

  try {
    const spawner = createSandboxSpawner(tmpFile, sandboxName, authEnv);

    const queryOptions = {
      cwd: sdkOptions.cwd || "/sandbox",
      model: sdkOptions.model || undefined,
      allowedTools: sdkOptions.allowedTools || ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
      permissionMode: sdkOptions.permissionMode || "bypassPermissions",
      allowDangerouslySkipPermissions:
        sdkOptions.permissionMode === "bypassPermissions" || !sdkOptions.permissionMode,
      maxTurns: sdkOptions.maxTurns || undefined,
      systemPrompt: sdkOptions.systemPrompt || undefined,
      persistSession: sdkOptions.persistSession !== false,
      spawnClaudeCodeProcess: spawner,
    };

    // Session resumption
    if (sdkOptions.resume) {
      queryOptions.resume = sdkOptions.resume;
    }
    if (sdkOptions.continue) {
      queryOptions.continue = true;
    }

    // Structured output
    if (sdkOptions.outputFormat) {
      queryOptions.outputFormat = sdkOptions.outputFormat;
    }

    const stream = query({ prompt, options: queryOptions });

    for await (const message of stream) {
      yield message;
    }
  } finally {
    try {
      fs.unlinkSync(tmpFile);
    } catch {
      /* ignore */
    }
  }
}

/**
 * Convenience: run a one-shot prompt and return the final result text.
 *
 * @param {object} params - Same as querySandbox
 * @returns {Promise<{result: string, sessionId: string|null, cost: number|null}>}
 */
async function execSandbox(params) {
  let resultText = "";
  let sessionId = null;
  let cost = null;

  for await (const message of querySandbox(params)) {
    if (message.type === "result") {
      resultText = message.result || "";
      sessionId = message.session_id || null;
      cost = message.total_cost_usd || null;
    }
  }

  return { result: resultText, sessionId, cost };
}

/**
 * List recent Claude Code sessions from the sandbox.
 * Sessions are stored in ~/.claude/projects/ inside the sandbox.
 *
 * @param {string} sandboxName - Sandbox name
 * @param {number} [limit=10] - Max sessions to return
 * @returns {Promise<Array<{sessionId: string, timestamp: number, model: string|null, numMessages: number|null}>>}
 */
async function listSandboxSessions(sandboxName, limit = 10) {
  try {
    const { listSessions } = await import("@anthropic-ai/claude-agent-sdk");
    const sessions = await listSessions({ dir: "/sandbox", limit });
    return sessions.map((s) => ({
      sessionId: s.sessionId,
      timestamp: s.lastModified || Date.now(),
      model: null,
      numMessages: null,
    }));
  } catch {
    // Fallback: list session files from the sandbox via SSH
    return [];
  }
}

module.exports = {
  createSandboxSpawner,
  querySandbox,
  execSandbox,
  listSandboxSessions,
};
