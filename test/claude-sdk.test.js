// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { describe, it, expect } from "vitest";
import { createSandboxSpawner } from "../bin/lib/claude-sdk.js";

describe("claude-sdk", () => {
  describe("createSandboxSpawner", () => {
    it("returns a function", () => {
      const spawner = createSandboxSpawner(
        "/tmp/test.conf",
        "test-sandbox",
        [["ANTHROPIC_API_KEY", "sk-ant-test"]],
      );
      expect(typeof spawner).toBe("function");
    });

    it("spawns an SSH process with direct API key auth", () => {
      const spawner = createSandboxSpawner(
        "/tmp/test.conf",
        "test-sandbox",
        [["ANTHROPIC_API_KEY", "sk-ant-test"]],
      );
      const mockAbort = new AbortController();

      const proc = spawner({
        command: "/path/to/cli.js",
        args: ["--json", "--input-format", "stream"],
        cwd: "/sandbox",
        env: { ANTHROPIC_API_KEY: "sk-ant-test" },
        signal: mockAbort.signal,
      });

      expect(proc).toBeDefined();
      expect(proc.stdin).toBeDefined();
      expect(proc.stdout).toBeDefined();
      expect(typeof proc.kill).toBe("function");
      proc.kill("SIGTERM");
    });

    it("spawns with Bedrock auth env vars", () => {
      const spawner = createSandboxSpawner(
        "/tmp/test.conf",
        "test-sandbox",
        [
          ["CLAUDE_CODE_USE_BEDROCK", "1"],
          ["AWS_REGION", "us-east-1"],
          ["AWS_PROFILE", "dev"],
        ],
      );
      const mockAbort = new AbortController();

      const proc = spawner({
        command: "/path/to/cli.js",
        args: ["--json", "--input-format", "stream"],
        cwd: "/sandbox",
        env: {},
        signal: mockAbort.signal,
      });

      expect(proc).toBeDefined();
      proc.kill("SIGTERM");
    });

    it("filters out cli.js from args", () => {
      const spawner = createSandboxSpawner(
        "/tmp/test.conf",
        "test-sandbox",
        [["ANTHROPIC_API_KEY", "sk-ant-test"]],
      );
      const mockAbort = new AbortController();

      const proc = spawner({
        command: "/node_modules/@anthropic-ai/claude-agent-sdk/vendor/cli.js",
        args: ["--json", "/node_modules/.../cli.js", "--input-format", "stream"],
        cwd: "/workspace",
        env: {},
        signal: mockAbort.signal,
      });

      expect(proc).toBeDefined();
      proc.kill("SIGTERM");
    });
  });
});
