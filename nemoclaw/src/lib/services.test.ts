// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";
import { showStatus, stopAll, getServiceStatuses } from "../../dist/lib/services.js";

// ---------------------------------------------------------------------------
// Mock node:fs — in-memory filesystem for PID files & logs
// ---------------------------------------------------------------------------

const store = new Map<string, string>();
const dirs = new Set<string>();

vi.mock("node:fs", async (importOriginal) => {
  const original = await importOriginal();
  return {
    ...original,
    existsSync: (p: string) => store.has(p) || dirs.has(p),
    mkdirSync: (_p: string) => {
      dirs.add(_p);
    },
    readFileSync: (p: string) => {
      const content = store.get(p);
      if (content === undefined) throw new Error(`ENOENT: ${p}`);
      return content;
    },
    writeFileSync: (p: string, data: string) => {
      store.set(p, data);
    },
    unlinkSync: (p: string) => {
      store.delete(p);
    },
  };
});

// ---------------------------------------------------------------------------
// Mock process.kill for PID checks (default: process not found)
// ---------------------------------------------------------------------------

const originalKill = process.kill.bind(process);
let killMock: (pid: number, signal?: string | number) => boolean;

beforeEach(() => {
  store.clear();
  dirs.clear();
  // Default: all processes are dead
  killMock = (_pid: number, _signal?: string | number) => {
    const err = new Error("ESRCH") as NodeJS.ErrnoException;
    err.code = "ESRCH";
    throw err;
  };
  process.kill = killMock as typeof process.kill;
});

afterEach(() => {
  process.kill = originalKill;
});

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("lib/services", () => {
  describe("getServiceStatuses", () => {
    it("reports all services as stopped when no PID files exist", () => {
      const statuses = getServiceStatuses({ pidDir: "/tmp/test-svc" });
      expect(statuses).toEqual([
        { name: "telegram-bridge", running: false, pid: null },
        { name: "cloudflared", running: false, pid: null },
      ]);
    });

    it("reports a service as running when PID file exists and process is alive", () => {
      store.set("/tmp/test-svc/telegram-bridge.pid", "12345");
      // Make process.kill(12345, 0) succeed
      killMock = (pid: number, signal?: string | number) => {
        if (pid === 12345 && (signal === 0 || signal === undefined)) return true;
        const err = new Error("ESRCH") as NodeJS.ErrnoException;
        err.code = "ESRCH";
        throw err;
      };
      process.kill = killMock as typeof process.kill;

      const statuses = getServiceStatuses({ pidDir: "/tmp/test-svc" });
      expect(statuses[0]).toEqual({ name: "telegram-bridge", running: true, pid: 12345 });
      expect(statuses[1]).toEqual({ name: "cloudflared", running: false, pid: null });
    });

    it("reports a service as not running when PID file exists but process is dead", () => {
      store.set("/tmp/test-svc/cloudflared.pid", "99999");
      const statuses = getServiceStatuses({ pidDir: "/tmp/test-svc" });
      expect(statuses[1]).toEqual({ name: "cloudflared", running: false, pid: 99999 });
    });

    it("handles malformed PID file", () => {
      store.set("/tmp/test-svc/telegram-bridge.pid", "not-a-number");
      const statuses = getServiceStatuses({ pidDir: "/tmp/test-svc" });
      expect(statuses[0]).toEqual({ name: "telegram-bridge", running: false, pid: null });
    });
  });

  describe("showStatus", () => {
    it("prints status without crashing", () => {
      const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      showStatus({ pidDir: "/tmp/test-svc" });
      expect(logSpy).toHaveBeenCalled();
      logSpy.mockRestore();
    });

    it("prints cloudflared URL from log file", () => {
      store.set(
        "/tmp/test-svc/cloudflared.log",
        "some output\nhttps://abc-123.trycloudflare.com\nmore output",
      );
      const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      showStatus({ pidDir: "/tmp/test-svc" });
      const output = logSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("https://abc-123.trycloudflare.com");
      logSpy.mockRestore();
    });
  });

  describe("stopAll", () => {
    it("removes PID files and reports stopped", () => {
      store.set("/tmp/test-svc/telegram-bridge.pid", "111");
      store.set("/tmp/test-svc/cloudflared.pid", "222");

      const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      stopAll({ pidDir: "/tmp/test-svc" });

      expect(store.has("/tmp/test-svc/telegram-bridge.pid")).toBe(false);
      expect(store.has("/tmp/test-svc/cloudflared.pid")).toBe(false);

      const output = logSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("All services stopped");
      logSpy.mockRestore();
    });

    it("handles already-stopped services gracefully", () => {
      const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      expect(() => {
        stopAll({ pidDir: "/tmp/test-svc" });
      }).not.toThrow();
      logSpy.mockRestore();
    });
  });
});
