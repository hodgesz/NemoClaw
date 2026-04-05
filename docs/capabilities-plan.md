# NemoClaw Capabilities Expansion Plan

> **Tracking doc** — check off items as completed. Future sessions: read this file to see what's done and what's next.

## Context

Expanding the NemoClaw setup on M4 Pro 48GB (sandbox "my-assistant", Bedrock/Sonnet 4.6 via LiteLLM, Telegram bridge active). Customizations live in the `hodgesz/NemoClaw` fork — not pushed upstream to NVIDIA.

**Remotes:**

- `origin` → `hodgesz/NemoClaw` (our fork, push here)
- `upstream` → `NVIDIA/NemoClaw` (pull upstream updates)

## Phase 1: Zero-Risk Skill Installs

> No policy changes, no rebuild. Work entirely inside the sandbox.

- [x] **1A. ADHD Founder Planner** (completed 2026-04-02)
  - Installed at `/sandbox/.openclaw-data/skills/adhd-planner/SKILL.md`
  - Commands: `/adhd-planner plan`, `/adhd-planner migrate`, `/adhd-planner dopamine`
  - No network access, no API keys
  - Note: SSH was broken (handshake verification failure); required full sandbox rebuild to fix

- [x] **1B. Local-First Personal CRM** (completed 2026-04-02)
  - Installed at `/sandbox/.openclaw-data/skills/personal-crm/SKILL.md`
  - Commands: `/crm add`, `/crm search`, `/crm update`, `/crm followups`, `/crm list`
  - Data in `/sandbox/.openclaw-data/crm/` (writable)
  - Optional cron: `openclaw cron add --name "crm:scan" --schedule "0 */6 * * *" --prompt "Scan recent conversations and update CRM contacts"`

**Commit after Phase 1** (if any repo-level changes)

---

## Phase 2: API Integrations with Dynamic Policy

> Dynamic policy additions via `openshell policy set`. No sandbox rebuild.

- [x] **2A. Web Search** (completed 2026-04-02)
  - Pivoted from custom Tavily skill to OpenClaw's built-in web search (Gemini provider)
  - Configured via `docker exec` into sandbox's `openclaw.json` (NemoClaw issue #773 workaround)
  - `GEMINI_API_KEY` stored in `~/.zshrc` (host); injected into `openclaw.json` `tools.web.search.gemini.apiKey`
  - Network policy: `gemini-search.yaml` preset for `generativelanguage.googleapis.com:443`
  - No custom skill needed — agent uses built-in `web_search` tool natively
  - Telegram bridge must use `SANDBOX_NAME=my-assistant` (defaults to "nemoclaw" otherwise)
  - Lesson: OpenClaw skills are description-matched by the model, not slash-command triggered
  - Lesson: After sandbox rebuild, must re-inject Gemini config (step 10 in recovery doc)
  - Lesson: OpenClaw fetch-guard DNS bug requires docker exec patch for web search to work (NemoClaw #1252)
  - Lesson: Gateway device pairing needed after onboard/restart (NemoClaw #1310)

- [x] **2B. Autonomous Morning Briefing** (completed 2026-04-04)
  - **Depends on:** 2A (Gemini web search for news)
  - Policy entry: `wttr.in:443` (GET) added to sandbox network policy
  - Skill installed at `/sandbox/.openclaw-data/skills/morning-briefing/SKILL.md`
  - Uses web_search (Gemini) for news/markets and wttr.in for weather
  - Telegram channel config injected into `openclaw.json` via docker exec
  - Scheduled via macOS launchd (not openclaw cron — gateway pairing issues, NemoClaw #1310)
    - Plist: `~/Library/LaunchAgents/com.nemoclaw.morning-briefing.plist`
    - Script: `scripts/morning-briefing.sh` (host-side, SSHes into sandbox, sends to Telegram)
    - Runs daily at 7:00 AM local time
  - Lesson: OpenClaw gateway channels require `openclaw.json` modification (same #773 workaround)
  - Lesson: openclaw cron needs a stable gateway connection; host-side launchd is more reliable

**Commit after Phase 2** (policy presets, any script changes)

---

## Phase 3: MCP Server Integration

> mcporter setup inside sandbox + per-server policy entries. No rebuild.

- [ ] **MCP infrastructure** (~1 hr)
  - Inside sandbox: `npm i -g mcporter`
  - Config at `/sandbox/config/mcporter.json`

- [ ] **Notion MCP** (~1 hr)
  - Policy: `mcp.notion.so:443`, `api.notion.com:443`
  - Add `notion.yaml` preset

- [ ] **Additional MCP servers** (as needed)
  - Each needs its own policy entry
  - Use `openshell term` TUI to discover blocked requests

**Commit after Phase 3** (policy presets)

---

## Phase 4: Obsidian Vault Integration

> May require rebuild depending on approach chosen.

- [ ] **Investigate `openshell sandbox create --volume`** support
- [ ] **Option A (preferred): Host-side MCP server**
  - Run `npx obsidian-mcp-server --vault ~/path/to/vault --port 4001` on host
  - Add to `start-services.sh`
  - Policy: `host.openshell.internal:4001`
  - Configure mcporter inside sandbox
- [ ] **Option B (if bind-mount available): Direct mount**
  - Requires sandbox rebuild + filesystem_policy change

Commit after Phase 4

---

## Cross-Cutting: Policy Persistence Script

- [x] **Create `scripts/apply-custom-policies.sh`** (completed 2026-04-04)
  - Handles: Gemini config injection, config hash, fetch-guard DNS patch, gateway restart, device pairing, skill reinstall
  - Skills stored in `skills/` directory (morning-briefing, adhd-planner, personal-crm)
  - Idempotent — safe to run multiple times
  - Flags: `--sandbox`, `--skip-skills`, `--dry-run`
- [x] **Hook into `scripts/recover-after-reboot.sh`** (completed 2026-04-04)
  - Called automatically as step 5b after network policy
  - Also documented in `docs/recovery-after-reboot.md` rebuild procedure (step 11)

---

## Memory Budget

| Component | Memory |
|-----------|--------|
| Baseline (Docker + gateway + sandbox + LiteLLM + bridge) | ~5-7 GB |
| All additions (cron, SQLite, mcporter, Obsidian MCP) | ~200 MB |
| **Total** | **~5-8 GB** |

## Verification (after each phase)

1. `nemoclaw my-assistant status` — sandbox healthy
2. `openshell policy get --full my-assistant` — new entries present
3. Test via Telegram
4. For cron: `openclaw cron list` / `openclaw cron runs`
5. For MCP: `mcporter list` / `mcporter call <server>.<tool>`
