---
name: pr-review
description: "Review a pull request against architecture, security, correctness, performance, and test coverage standards."
user_invocable: true
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# PR Review: NemoClaw

Review the pull request whose number is given in the prompt (`<PR_NUMBER>`). If the prompt specifies **local-only** mode, print the review to stdout and do NOT post anything to GitHub.

## Workflow

1. **Fetch the PR.**
   - `gh pr view <PR_NUMBER> --json title,body,baseRefName,headRefName,files`
   - `gh pr diff <PR_NUMBER>`
2. **Read context.** Open modified files beyond the diff hunks. Trace callers and callees across the codebase (search for changed symbols) to catch broken contracts, schema changes, or missed sibling call paths. Inspect context and dependencies using repository search tools (`rg` or `grep`) and file inspection.
3. **Verify behavior.** If the prompt already contains test results from the harness, use them and do not re-run tests. Otherwise, run the relevant local tests for modified modules using Vitest (`npx vitest run <changed_test_files>`). Check out the PR with `gh pr checkout <PR_NUMBER>` only if needed; never push.
4. **Evaluate on 5 axes.**
   - **Correctness & Edge Cases**: Parameter validation, null/undefined safety, error handling, unhandled promise rejections, race conditions, signal traps, and resource leakages (event listeners, file handles, subprocesses).
   - **Architecture & Contracts**: Conformance to NemoClaw CLI patterns (oclif), OpenShell sandboxing boundaries, package structure, and decoupled agent integrations adhering to existing abstractions.
   - **Security & Trust Boundaries**: Sandbox isolation, host path traversal prevention, network egress policy compliance, token/secret protection (credentials, tokens, and keys are never logged, serialized, or leaked), and CLI/blueprint input sanitization.
   - **Performance & Scalability**: Async I/O patterns, subprocess execution overhead, memory usage, and container lifecycle efficiency.
   - **Test Coverage**: Confirmation that all new and modified code paths are accompanied by unit or integration tests in Vitest, and verification of harness test results provided by the host runner.
5. **Format findings.** Tag each finding with a severity: `[CRITICAL]`, `[HIGH]`, or `[NIT]`. Give the exact `file:line` reference. For actionable fixes, include a GitHub suggestion block:

   ````markdown
   ```suggestion
   corrected line(s)
   ```
   ````

   End with a short summary: tests run and their result, plus an overall verdict in prose.
6. **Post the review** (unless local-only):
   Post via `gh pr review <PR_NUMBER> --comment -F <review_file>`. Never approve or merge.

## Headless Behavior

When running non-interactively in headless mode (`agy -p`), execution concludes when tool calls finish. Never end a turn with "waiting for tests" or similar pending states. Run tests synchronously in the foreground, scoped to the modified test files only, and inspect the result. Your final message MUST be the complete review (or, in local-only mode, the review text printed to stdout), even if tests could not be run; in that case document the constraint in the summary.

## Guardrails

- Never use `--approve` or `--request-changes`, and never run `gh pr merge` or `git push`.
- Do not modify repository files; this is a read-and-verify task.
- Only produce findings for genuine bugs, regressions, security risks, or standard violations.
- Only report issues verified against the code; clearly state when an observation is uncertain.
