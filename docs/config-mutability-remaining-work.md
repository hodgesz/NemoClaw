# Config Mutability — Remaining Work

Tracked on PR #940. These three items must be resolved before merge.

## 1. Approved config chunks rewrite overrides file on every poll cycle

**Problem:** After a config chunk is approved in the TUI, `apply_approved_config_chunks` in the sandbox supervisor rewrites `config-overrides.json5` every 10 seconds forever. The approved chunk stays in the gateway's draft_policy_chunks table with status `approved`, so every poll cycle finds it again and rewrites the same file.

**Visible symptom:** The TUI logs show `Config apply: wrote approved config overrides chunks=1` repeating every 10 seconds indefinitely.

**Root cause:** `apply_approved_config_chunks` (in `crates/openshell-sandbox/src/lib.rs`) queries for approved config chunks, merges them, and writes the file — but never marks the chunks as consumed or compares against the current file contents.

**Fix options (pick one):**

- **Option A — Mark consumed:** After successfully writing the overrides file, call a new gRPC method (e.g., `AcknowledgeConfigChunks`) that updates the chunk status from `approved` to `applied`. The query filters for `approved` only, so `applied` chunks won't be returned on the next poll.
- **Option B — Skip if unchanged:** Before writing, read the existing `config-overrides.json5`, compare the JSON content. If identical, skip the write and the log. Simple, no server-side changes, but the chunk stays `approved` forever (clutters the draft table).
- **Option C — Clear after apply:** Delete the approved config chunks from the draft table after writing. Clean, but loses the audit trail of what was approved.

**Recommendation:** Option A (mark consumed) preserves the audit trail and stops the repeated writes.

## 2. TUI has no detail view for config rule changes

**Problem:** When a `CONFIG` chunk appears in the TUI's "Rules & Config" list, pressing Enter on it shows the standard network rule detail view — which is empty/meaningless for config chunks (no host, no port, no proposed_rule). The user can approve/reject it but can't see WHAT config change is being requested.

**What the user needs to see:**

- The config key (e.g., `agents.defaults.model.primary`)
- The proposed value (e.g., `inference/nvidia/nemotron-3-nano-30b-a3b`)
- The rationale field (which contains the nested JSON override)

**Where to fix:** `crates/openshell-tui/src/ui/sandbox_draft.rs` — the detail view rendering. When `chunk.rule_name.starts_with("config:")`:

- Show the config key (strip `config:` prefix from `rule_name`)
- Parse the `rationale` field as JSON and pretty-print the proposed override
- Hide the network-specific fields (host, port, endpoints, binary)

## 3. E2E demo should test system prompt change, not just inference model

**Problem:** The current E2E test and POC demo change `agents.defaults.model.primary` — an inference routing field. This proves the plumbing works but misses the actual use case: an agent changing its own system prompt at runtime through the approval flow.

**What the test should do:**

1. Start with a known system prompt (e.g., `"You are a helpful assistant"`)
2. The agent (or test harness simulating the agent) writes a config request to change the system prompt to something distinctive (e.g., `"You are a pirate. Always respond in pirate speak."`)
3. The scanner picks it up, submits as a CONFIG PolicyChunk
4. The TUI shows the proposed system prompt change for approval
5. After approval, the overrides file is written with the new prompt
6. The shim merges it onto the frozen config
7. A prompt is sent to the agent and the response reflects the new system prompt

**Config key:** The system prompt lives at `agents.defaults.systemPrompt` (or the equivalent path in openclaw.json — verify against the actual schema).

**Why this matters:** Changing the inference model is an operator concern. Changing the system prompt is an AGENT concern — the agent wants to evolve its own behavior, and the operator approves or denies that evolution. That's the core value proposition of this feature: controlled agent self-modification.

**Files to update:**

- `test/config-mutability-e2e.test.ts` — Phase 4 should set a system prompt, not a model
- `scripts/poc-round-trip-test.sh` — Step 4 should write a system prompt change request
- `scripts/setup-e2e-demo.sh` — no changes needed (infrastructure is the same)
