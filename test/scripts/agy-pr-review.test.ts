// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const REPO_ROOT = path.resolve(import.meta.dirname, "../..");
const SCRIPT_PATH = path.join(REPO_ROOT, "scripts", "agy-pr-review.sh");

function runScript(args: string[], extraEnv: NodeJS.ProcessEnv = {}) {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    CI: undefined,
    GEMINI_API_KEY: undefined,
    ANTIGRAVITY_API_KEY: undefined,
    GITHUB_TOKEN: undefined,
    GH_TOKEN: undefined,
    ...extraEnv,
  };
  return spawnSync("bash", [SCRIPT_PATH, ...args], {
    cwd: REPO_ROOT,
    encoding: "utf8",
    env,
  });
}

function writeExecutable(filePath: string, source: string): void {
  fs.writeFileSync(filePath, source, { mode: 0o755 });
}

describe("agy-pr-review.sh CLI options", () => {
  it("prints usage and exits 0 on --help", () => {
    const res = runScript(["--help"]);
    expect(res.status).toBe(0);
    expect(res.stdout).toContain("Usage: agy-pr-review.sh");
    expect(res.stdout).toContain("--local-only");
    expect(res.stdout).toContain("--model MODEL");
  });

  it("prints usage and exits 0 on -h", () => {
    const res = runScript(["-h"]);
    expect(res.status).toBe(0);
    expect(res.stdout).toContain("Usage: agy-pr-review.sh");
  });

  it("exits 2 when --model is missing a value", () => {
    const res = runScript(["--model"]);
    expect(res.status).toBe(2);
    expect(res.stderr).toContain("error: --model requires a non-empty value");
  });

  it("exits 2 when --model is given an empty string", () => {
    const res = runScript(["--model", ""]);
    expect(res.status).toBe(2);
    expect(res.stderr).toContain("error: --model requires a non-empty value");
  });

  it("exits 2 on unknown options", () => {
    const res = runScript(["--unknown-option"]);
    expect(res.status).toBe(2);
    expect(res.stderr).toContain("Unknown option: --unknown-option");
    expect(res.stderr).toContain("Usage: agy-pr-review.sh");
  });

  it("exits 2 on unexpected extra positional arguments", () => {
    const res = runScript(["123", "456"]);
    expect(res.status).toBe(2);
    expect(res.stderr).toContain("error: unexpected extra argument: 456");
  });

  it("exits 2 when positional PR is non-numeric", () => {
    const res = runScript(["invalid-pr"]);
    expect(res.status).toBe(2);
    expect(res.stderr).toContain("error: invalid PR number: invalid-pr");
  });

  it("exits 0 with a notice in CI when GEMINI_API_KEY is not configured", () => {
    const res = runScript(["123"], {
      CI: "true",
      GEMINI_API_KEY: "",
    });
    expect(res.status).toBe(0);
    expect(res.stderr).toContain(
      "notice: GEMINI_API_KEY is not configured in repository secrets; skipping PR review.",
    );
  });
});

describe("agy-pr-review.sh prerequisite and environment checks", () => {
  let tempDir: string;
  let binDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "nemoclaw-agy-review-test-"));
    binDir = path.join(tempDir, "bin");
    fs.mkdirSync(binDir);
    writeExecutable(path.join(binDir, "git"), "#!/usr/bin/env bash\nexit 0\n");
    writeExecutable(path.join(binDir, "perl"), "#!/usr/bin/env bash\nexit 0\n");
  });

  afterEach(() => {
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  it("exits 1 when a required binary is missing from PATH", () => {
    writeExecutable(path.join(binDir, "gh"), "#!/usr/bin/env bash\nexit 0\n");

    const res = runScript(["123"], {
      PATH: `${binDir}:/usr/bin:/bin`,
    });
    expect(res.status).toBe(1);
    expect(res.stderr).toContain("error: agy not found in PATH");
  });

  it("exits 1 when gh auth status fails", () => {
    writeExecutable(path.join(binDir, "agy"), "#!/usr/bin/env bash\nexit 0\n");
    writeExecutable(
      path.join(binDir, "gh"),
      `#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  echo "Logged out" >&2
  exit 1
fi
exit 0
`,
    );

    const res = runScript(["123"], {
      PATH: `${binDir}:/usr/bin:/bin`,
    });
    expect(res.status).toBe(1);
    expect(res.stderr).toContain("error: gh is not authenticated (run: gh auth login)");
  });

  it("exits 1 when no PR number is given and no open PR exists for current branch", () => {
    writeExecutable(path.join(binDir, "agy"), "#!/usr/bin/env bash\nexit 0\n");
    writeExecutable(
      path.join(binDir, "gh"),
      `#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  exit 0
fi
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo "NVIDIA/NemoClaw"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  exit 1
fi
exit 0
`,
    );

    const res = runScript([], {
      PATH: `${binDir}:/usr/bin:/bin`,
    });
    expect(res.status).toBe(1);
    expect(res.stderr).toContain("error: no PR number given and no open PR for the current branch");
  });

  it("configures modelProvider gemini in settings.json when GEMINI_API_KEY is set", () => {
    const configDir = path.join(tempDir, "config-new");
    runScript(["123"], {
      AGY_CONFIG_DIR: configDir,
      GEMINI_API_KEY: "fake-key-for-test",
      PATH: `${binDir}:/usr/bin:/bin`,
    });
    const settingsPath = path.join(configDir, "settings.json");
    expect(fs.existsSync(settingsPath)).toBe(true);
    const content = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    expect(content.modelProvider).toBe("gemini");
  });

  it("preserves existing settings while adding modelProvider gemini", () => {
    const configDir = path.join(tempDir, "config-existing");
    fs.mkdirSync(configDir, { recursive: true });
    const settingsPath = path.join(configDir, "settings.json");
    fs.writeFileSync(settingsPath, JSON.stringify({ existingOption: "value" }));
    runScript(["123"], {
      AGY_CONFIG_DIR: configDir,
      GEMINI_API_KEY: "fake-key-for-test",
      PATH: `${binDir}:/usr/bin:/bin`,
    });
    const content = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    expect(content.modelProvider).toBe("gemini");
    expect(content.existingOption).toBe("value");
  });
});
