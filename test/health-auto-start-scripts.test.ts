// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(import.meta.dirname, "..");

function writeExecutable(file: string, body: string): void {
  writeFileSync(file, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(file, 0o755);
}

describe("host health and auto-start scripts", () => {
  it("emits JSON when openclaw doctor does not return an exit marker", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "nemoclaw-health-check-"));
    const bin = path.join(dir, "bin");
    mkdirSync(bin);
    writeExecutable(path.join(bin, "ssh"), 'printf "%s\\n" "transport unavailable"; exit 255');

    const result = spawnSync(
      "bash",
      [
        path.join(ROOT, "scripts/health-check.sh"),
        "--json",
        "--skip",
        "docker,gateway,sandbox,ssh,inference,inference_live,dashboard,bridge,rules,briefing",
      ],
      {
        encoding: "utf8",
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
      },
    );

    expect(result.status).toBe(1);
    const output = JSON.parse(result.stdout);
    expect(output.checks).toContainEqual({
      name: "agent",
      status: "fail",
      detail: "openclaw doctor: exited with code unknown",
    });
  });

  it("recovers a ready sandbox when its gateway health endpoint is down", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "nemoclaw-auto-start-"));
    const scripts = path.join(dir, "scripts");
    const bin = path.join(dir, "bin");
    const home = path.join(dir, "home");
    const calls = path.join(dir, "calls.log");
    mkdirSync(scripts);
    mkdirSync(bin);
    mkdirSync(path.join(home, ".nemoclaw"), { recursive: true });
    cpSync(path.join(ROOT, "scripts/auto-start.sh"), path.join(scripts, "auto-start.sh"));
    writeFileSync(
      path.join(home, ".nemoclaw/sandboxes.json"),
      JSON.stringify({
        defaultSandbox: "my-assistant",
        sandboxes: { "my-assistant": { provider: "openrouter" } },
      }),
    );

    writeExecutable(path.join(bin, "docker"), "exit 0");
    writeExecutable(
      path.join(bin, "openshell"),
      'case "$1 $2" in "sandbox get") echo Ready ;; "provider list") echo openrouter ;; *) echo connected ;; esac',
    );
    writeExecutable(
      path.join(bin, "nemoclaw"),
      `printf '%s\\n' "$*" >> ${JSON.stringify(calls)}; exit 0`,
    );
    writeExecutable(
      path.join(bin, "curl"),
      'case "$*" in *127.0.0.1:4000*) exit 0 ;; *) exit 1 ;; esac',
    );
    writeExecutable(
      path.join(bin, "ssh"),
      'case "$*" in *"echo ok"*) echo ok; exit 0 ;; *"curl -sf"*) exit 1 ;; *) exit 0 ;; esac',
    );
    writeExecutable(path.join(bin, "sleep"), "exit 0");

    const result = spawnSync("bash", [path.join(scripts, "auto-start.sh")], {
      encoding: "utf8",
      env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}` },
    });

    expect(result.status).toBe(0);
    expect(result.stdout).toContain("running supported recovery");
    expect(readFileSync(calls, "utf8")).toContain("my-assistant recover");
  });
});
