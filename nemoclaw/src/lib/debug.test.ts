// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { describe, it, expect } from "vitest";
import { redact } from "../../dist/lib/debug.js";

describe("redact", () => {
  it("redacts NVIDIA_API_KEY=value patterns", () => {
    const key = ["NVIDIA", "API", "KEY"].join("_");
    expect(redact(`${key}=some-value`)).toBe(`${key}=<REDACTED>`);
  });

  it("redacts generic KEY/TOKEN/SECRET/PASSWORD env vars", () => {
    expect(redact("API_KEY=secret123")).toBe("API_KEY=<REDACTED>");
    expect(redact("MY_TOKEN=tok_abc")).toBe("MY_TOKEN=<REDACTED>");
    expect(redact("DB_PASSWORD=hunter2")).toBe("DB_PASSWORD=<REDACTED>");
    expect(redact("MY_SECRET=s3cret")).toBe("MY_SECRET=<REDACTED>");
    expect(redact("CREDENTIAL=cred")).toBe("CREDENTIAL=<REDACTED>");
  });

  it("redacts nvapi- prefixed keys", () => {
    expect(redact("using key nvapi-AbCdEfGhIj1234")).toBe("using key <REDACTED>");
  });

  it("redacts GitHub personal access tokens", () => {
    expect(redact("token: ghp_" + "a".repeat(36))).toBe("token: <REDACTED>");
  });

  it("redacts Bearer tokens", () => {
    expect(redact("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")).toBe(
      "Authorization: Bearer <REDACTED>",
    );
  });

  it("handles multiple patterns in one string", () => {
    const input = "API_KEY=secret nvapi-abcdefghijk Bearer tok123";
    const result = redact(input);
    expect(result).not.toContain("secret");
    expect(result).not.toContain("nvapi-abcdefghijk");
    expect(result).not.toContain("tok123");
  });

  it("leaves clean text unchanged", () => {
    const clean = "Hello world, no secrets here";
    expect(redact(clean)).toBe(clean);
  });
});
