---
name: "nemoclaw-user-overview"
description: "Documentation-derived skill for nemoclaw user overview."
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# NemoClaw User Overview

> **Tracking doc** — check off items as completed. Future sessions: read this file to see what's done and what's next.

## Step 1: Context

Expanding the NemoClaw setup on M4 Pro 48GB (sandbox "my-assistant", Bedrock/Sonnet 4.6 via LiteLLM, Telegram bridge active). Customizations live in the `hodgesz/NemoClaw` fork — not pushed upstream to NVIDIA.

**Remotes:**

- `origin` → `hodgesz/NemoClaw` (our fork, push here)
- `upstream` → `NVIDIA/NemoClaw` (pull upstream updates)

## Step 2: Phase 1: Zero-Risk Skill Installs

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

## Step 3: Phase 2: API Integrations with Dynamic Policy

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

## Step 4: Phase 2C: Browser/Web Automation via CDP (completed 2026-04-05)

> Host-side Chrome + two-script tunnel. No sandbox rebuild needed.

- [x] **Architecture**: Host-side headless Chrome (port 9222) → CDP proxy (port 9223, rewrites Host header) → in-sandbox CONNECT tunnel (localhost:9222)
- [x] **`scripts/chrome-cdp-proxy.js`** — Runs on host, rewrites `Host: host.openshell.internal` to `Host: localhost` for Chrome's security check. Handles HTTP discovery and WebSocket upgrade.
- [x] **`scripts/cdp-tunnel.js`** — Runs inside sandbox, listens on `localhost:9222` and creates HTTP CONNECT tunnels through the egress proxy (`10.200.0.1:3128`) to the host-side proxy. Needed because Node.js `ws` library doesn't use `HTTP_PROXY` env vars.
- [x] **Network policy**: `browser_cdp` entry with `access: full` for `host.openshell.internal:9223`
- [x] **openclaw.json**: `browser.profiles.remote.cdpUrl = "http://127.0.0.1:9222"`
- **Known limitation**: DNS pre-check in OpenClaw's browser tool fails because UDP 53 is blocked in sandbox (OpenShell #387). Browser open with IP addresses works; domain names require upstream DNS fix.
- **Known limitation**: Screenshots require media directory symlink (`/sandbox/.openclaw/media → /sandbox/.openclaw-data/media`)
- Lesson: OpenShell egress proxy strips WebSocket upgrade headers for HTTP traffic; must use CONNECT tunnel
- Lesson: `tls: skip` in policy gives TCP passthrough but doesn't help when Node.js bypasses the proxy
- Lesson: Same CONNECT-tunnel pattern as Discord's proxy workaround (NemoClaw #409)
- Lesson: OpenShell v0.0.21+ fixed WebSocket relay in proxy (PR #718), but only helps traffic that goes through the proxy

**Commit after Phase 2C** (scripts, policy changes)

---

## Step 5: Phase 3: MCP Server Integration

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

## Step 6: Phase 4: Obsidian Vault Integration

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

## Step 7: Cross-Cutting: Policy Persistence Script

- [x] **Create `scripts/apply-custom-policies.sh`** (completed 2026-04-04)
  - Handles: Gemini config injection, config hash, fetch-guard DNS patch, gateway restart, device pairing, skill reinstall
  - Skills stored in `skills/` directory (morning-briefing, adhd-planner, personal-crm)
  - Idempotent — safe to run multiple times
  - Flags: `--sandbox`, `--skip-skills`, `--dry-run`
- [x] **Hook into `scripts/recover-after-reboot.sh`** (completed 2026-04-04)
  - Called automatically as step 5b after network policy
  - Also documented in `docs/recovery-after-reboot.md` rebuild procedure (step 11)

---

## Step 8: Memory Budget

| Component | Memory |
|-----------|--------|
| Baseline (Docker + gateway + sandbox + LiteLLM + bridge) | ~5-7 GB |
| All additions (cron, SQLite, mcporter, Obsidian MCP) | ~200 MB |
| **Total** | **~5-8 GB** |

## Step 9: Verification (after each phase)

1. `nemoclaw my-assistant status` — sandbox healthy
2. `openshell policy get --full my-assistant` — new entries present
3. Test via Telegram
4. For cron: `openclaw cron list` / `openclaw cron runs`
5. For MCP: `mcporter list` / `mcporter call <server>.<tool>`

When your Mac reboots (or Docker Desktop restarts), the NemoClaw gateway container stops but its data volumes survive. The sandbox, workspace files, and providers can all be recovered **without a full re-onboard** if you follow the right sequence.

## Step 10: TL;DR

**If using Claude Code:** just say "recover after reboot per `docs/recovery-after-reboot.md`" — Claude has the context in memory to handle it.

**If running manually:** open Docker Desktop, wait for it to be ready, then:

```bash
cd /Users/jonathanhodges/VsCodeProjects/nvidia/NemoClaw

# Credentials are already in ~/.zshrc — just source to pick up latest values
source ~/.zshrc

# Recover everything (starts LiteLLM, gateway, providers, policy, bridge)
./scripts/recover-after-reboot.sh --provider bedrock --services
```

The script waits for Docker, starts LiteLLM for Bedrock, restarts the gateway non-destructively, verifies the sandbox, re-creates providers, patches the network policy, restarts the port forward, and launches the Telegram bridge.

## Step 11: Credential sources

All credentials are exported in `~/.zshrc` and available in every new shell session:

| Variable | Source | Notes |
|----------|--------|-------|
| `AWS_BEARER_TOKEN_BEDROCK` | `~/.zshrc` | Bedrock bearer token for LiteLLM proxy |
| `NVIDIA_API_KEY` | `~/.zshrc` | From [build.nvidia.com](https://build.nvidia.com/) (Google hodgesz account) |
| `TELEGRAM_BOT_TOKEN` | `~/.zshrc` | @hodgesz_claw_bot bot token |
| `DEVREV_API_KEY` | `~/.zshrc` | DevRev PAT |
| `SLACK_BOT_TOKEN` | `~/.zshrc` | Slack bot token |
| `GEMINI_API_KEY` | `~/.zshrc` | Google Gemini API key for built-in web search |

## Step 12: Claude Code recovery steps

When the user says "recover after reboot", Claude should follow these steps exactly:

1. **Source credentials:** run `source ~/.zshrc` to load all tokens into the current shell
2. **Wait for Docker:** run `docker info` in a loop — Docker Desktop can briefly respond then go away during startup, so verify it stays ready with two checks 5 seconds apart before proceeding
3. **Run the recovery script:** `./scripts/recover-after-reboot.sh --provider bedrock --services`
4. **Verify:** run `nemoclaw my-assistant status` only AFTER the script completes successfully

## Step 13: What survives a reboot

| Component | Survives? | Notes |
|-----------|-----------|-------|
| Docker volumes (k3s state, sandbox PVC) | Yes | Persist unless explicitly removed |
| Sandbox pod + workspace files | Usually | k3s recovers the pod from its etcd state on the volume |
| Gateway container | No | Must be restarted — but restarting reattaches to the existing volume |
| Providers (ollama-local, bedrock-litellm) | No | Stateless config inside the gateway; re-created by the script |
| Network policy customizations | Sometimes | If the sandbox pod survived, policy stays; script checks and patches if needed |
| Port forwards | No | Ephemeral; re-created by the script |
| Telegram bridge / services | No | Host processes; re-created with `--services` |
| SSH tunnel (gateway <-> sandbox) | Sometimes | Can break after reboot; if broken, requires full sandbox rebuild (see below) |
| Gemini web search config in openclaw.json | Yes (if sandbox survived) | Lost on sandbox rebuild — must re-inject via docker exec (step 10 in rebuild procedure) |
| OpenClaw fetch-guard DNS patch | No (lost on rebuild) | Must re-apply via docker exec after every rebuild (step 11) — see [NemoClaw #1252](https://github.com/NVIDIA/NemoClaw/issues/1252) |
| Gateway device pairing | No (lost on rebuild) | Must re-approve device after rebuild or gateway restart (step 12) — see [NemoClaw #1310](https://github.com/NVIDIA/NemoClaw/issues/1310) |

## Step 14: What can go wrong

The **one thing to avoid** is running `nemoclaw <name> status` before Docker is ready. That command tries to recover the gateway and, if Docker isn't responding yet, it will **destroy and recreate the gateway** — which wipes the k3s volume and loses the sandbox.

The recovery script avoids this by:

1. Waiting for `docker info` to succeed before touching the gateway
2. Using `openshell gateway start` (non-destructive) instead of the nemoclaw wrapper

### SSH handshake verification failure

After a reboot (or sometimes after the gateway restarts), the SSH tunnel between the gateway and sandbox can break with this error in the logs:

```text
[sandbox] [WARN] SSH connection: handshake verification failed peer=10.42.0.18:XXXXX
```

**Symptoms:** `openshell sandbox upload/download` silently fail (report success but no files transfer), `ssh openshell-<name>` times out during banner exchange, `scp` fails, and `scripts/backup-workspace.sh` produces empty backups.

**Root cause:** The gateway and sandbox SSH keys get out of sync. The gateway's SSH proxy connects to the sandbox but the sandbox rejects the handshake because the key material doesn't match what it expects.

**Diagnosis:**

```bash
# Check for the handshake failure
nemoclaw my-assistant logs 2>&1 | grep -i "handshake verification failed"

# Quick SSH test (should print "hello" — if it times out, SSH is broken)
ssh -o ConnectTimeout=10 openshell-my-assistant 'echo hello'
```

**Fix — full sandbox rebuild required:**

```bash
# 0. Kill any running Telegram bridge FIRST (prevents duplicate responses after rebuild)
pkill -f telegram-bridge.js || true

# 1. Back up workspace (if SSH still worked recently, use existing backup)
ls ~/.nemoclaw/backups/
# If no recent backup and SSH is broken, you cannot back up — use the last good backup

# 2. Destroy the sandbox
echo "y" | nemoclaw my-assistant destroy

# 3. Re-onboard (Bedrock example)
source ~/.zshrc
export NEMOCLAW_NON_INTERACTIVE=1
export NEMOCLAW_SANDBOX_NAME="my-assistant"
export NEMOCLAW_PROVIDER=custom
export NEMOCLAW_MODEL="bedrock/us.anthropic.claude-sonnet-4-6"
export NEMOCLAW_ENDPOINT_URL="http://localhost:4000/v1"
export COMPATIBLE_API_KEY="dummy"
export NEMOCLAW_POLICY_PRESETS="telegram,pypi,npm,slack,gemini-search"
nemoclaw onboard --non-interactive

# 4. Fix provider endpoint for sandbox access
openshell provider delete compatible-endpoint
openshell provider create --name compatible-endpoint --type openai \
  --credential "OPENAI_API_KEY=dummy" \
  --config "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1"
openshell inference set --provider compatible-endpoint \
  --model "bedrock/us.anthropic.claude-sonnet-4-6" --no-verify

# 5. Refresh SSH config
openshell sandbox ssh-config my-assistant >> ~/.ssh/config

# 6. Verify SSH works
ssh -o ConnectTimeout=10 openshell-my-assistant 'echo "SSH works!"'

# 7. Restore workspace via SSH (scp won't work — no sftp-server in sandbox)
for f in SOUL.md USER.md IDENTITY.md AGENTS.md; do
  ssh openshell-my-assistant "cat > /sandbox/.openclaw/workspace/$f" \
    < ~/.nemoclaw/backups/<timestamp>/$f
done

# 8. Re-apply local policy + start services
./scripts/recover-after-reboot.sh --provider bedrock --services

# 9. Re-install any custom skills
# Skills live at /sandbox/.openclaw-data/skills/<skill-id>/SKILL.md
# Upload via: ssh openshell-my-assistant "cat > /path/SKILL.md" < local-file

# 10. Re-apply Gemini web search config (NemoClaw issue #773 workaround)
# The openclaw.json is rebuilt on sandbox creation, losing the web search config.
# Find the sandbox container ID, then inject the config via docker exec.
CONTAINER_ID=$(docker exec openshell-cluster-nemoclaw ctr -n k8s.io containers list 2>/dev/null \
  | grep 'sandbox-from' | awk '{print $1}')
docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id gemini-cfg --user 0 "$CONTAINER_ID" \
  sh -c 'cat /sandbox/.openclaw/openclaw.json' > /tmp/oc-cfg.json
python3 -c "
import json
cfg = json.load(open('/tmp/oc-cfg.json'))
cfg.setdefault('tools', {})['web'] = {
    'search': {'enabled': True, 'provider': 'gemini',
               'gemini': {'apiKey': '$(echo $GEMINI_API_KEY)'}},
    'fetch': {'enabled': True}
}
json.dump(cfg, open('/tmp/oc-cfg.json', 'w'), indent=2)
"
docker exec -i openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id gemini-write --user 0 "$CONTAINER_ID" \
  sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/oc-cfg.json
rm /tmp/oc-cfg.json

# 11. Apply all custom sandbox configurations (automated)
# This single script handles steps 10-12 plus skill reinstalls.
# Run it instead of the manual steps below.
./scripts/apply-custom-policies.sh --sandbox my-assistant

# --- Manual steps (for reference, handled by apply-custom-policies.sh) ---

# 11-manual. Patch OpenClaw fetch-guard for web search DNS (NemoClaw #1252 / OpenClaw #59005)
# OpenClaw's fetch-guard does local DNS resolution before using the proxy, which fails
# in the sandbox (k3s CoreDNS can't resolve external hostnames). This patch reorders
# the code so TRUSTED_ENV_PROXY mode uses EnvHttpProxyAgent without DNS pinning.
# Must re-apply after every sandbox rebuild.
CONTAINER_ID=$(docker exec openshell-cluster-nemoclaw ctr -n k8s.io containers list 2>/dev/null \
  | grep 'sandbox-from' | awk '{print $1}' | head -1)
for FILE in $(docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id find-guards --user 0 "$CONTAINER_ID" \
  sh -c 'grep -rl "resolvePinnedHostname" /usr/local/lib/node_modules/openclaw/dist/' 2>/dev/null); do
  docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
    --exec-id "read-fg-$RANDOM" --user 0 "$CONTAINER_ID" cat "$FILE" > /tmp/fg-patch.js 2>&1
  python3 -c "
content = open('/tmp/fg-patch.js').read()
old = '''let dispatcher = null;
\t\ttry {
\t\t\tconst pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {
\t\t\t\tlookupFn: params.lookupFn,
\t\t\t\tpolicy: params.policy
\t\t\t});
\t\t\tif (mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured()) dispatcher = new EnvHttpProxyAgent();
\t\t\telse if (params.pinDns !== false) dispatcher = createPinnedDispatcher(pinned);'''
new = '''let dispatcher = null;
\t\ttry {
\t\t\tconst useTrustedEnvProxy = mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured();
\t\t\tif (useTrustedEnvProxy) {
\t\t\t\tdispatcher = new EnvHttpProxyAgent();
\t\t\t} else {
\t\t\t\tconst pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {
\t\t\t\t\tlookupFn: params.lookupFn,
\t\t\t\t\tpolicy: params.policy
\t\t\t\t});
\t\t\t\tif (params.pinDns !== false) dispatcher = createPinnedDispatcher(pinned);
\t\t\t}'''
if old in content:
    open('/tmp/fg-patch.js', 'w').write(content.replace(old, new))
    print(f'PATCHED: {\"$FILE\"!r}')
else:
    print(f'SKIPPED: {\"$FILE\"!r}')
"
  docker exec -i openshell-cluster-nemoclaw ctr -n k8s.io task exec \
    --exec-id "write-fg-$RANDOM" --user 0 "$CONTAINER_ID" \
    sh -c "cat > $FILE" < /tmp/fg-patch.js 2>&1
done
rm /tmp/fg-patch.js 2>/dev/null

# 11b. Update config hash (prevents "integrity check FAILED" from nemoclaw-start)
docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id fix-hash --user 0 "$CONTAINER_ID" \
  sh -c 'sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash && chmod 444 /sandbox/.openclaw/.config-hash'

# 11c. Restart the gateway process so it loads the patched fetch-guard files.
# The container's init system respawns it automatically after kill.
docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id find-gw-pid --user 0 "$CONTAINER_ID" \
  sh -c 'ls /proc/*/cmdline 2>/dev/null | while read f; do
    pid=$(echo "$f" | cut -d/ -f3)
    tr "\0" " " < "$f" 2>/dev/null | grep -q "openclaw-gateway" && echo "$pid"
  done' | head -1 | xargs -I{} docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id kill-gw --user 0 "$CONTAINER_ID" kill {}
sleep 5  # wait for gateway respawn

# 12. Approve device pairing (NemoClaw #1310)
# After onboard or gateway restart, the CLI agent needs device approval to connect
# to the gateway. Without this, the agent falls back to embedded mode (which works
# but loses access to some gateway-only features).
ssh openshell-my-assistant 'openclaw devices list 2>&1' | grep -oP '[0-9a-f-]{36}' | head -1 | \
  xargs -I{} ssh openshell-my-assistant "openclaw devices approve {} 2>&1"
```

**Prevention:** The recovery script (`recover-after-reboot.sh`) now checks SSH health after gateway restart (step 3). If SSH is broken, it warns early instead of continuing with a broken tunnel. Always back up workspace regularly — a broken SSH tunnel means you can't make a fresh backup.

## SSH config corruption (github.com routed through sandbox)

**Symptom:** `ssh -T git@github.com` hangs indefinitely. `git push origin` also hangs.

**Root cause:** Running `openshell sandbox ssh-config my-assistant >> ~/.ssh/config` multiple times appends OpenShell proxy settings without a `Host` header boundary. The ProxyCommand bleeds into the preceding `Host github.com` block, routing all GitHub SSH traffic through the NemoClaw sandbox proxy.

**Diagnosis:**

```bash
# Check if github.com block has a ProxyCommand (it should NOT)
grep -A 10 "Host github.com" ~/.ssh/config
```

**Fix:** Edit `~/.ssh/config` so the blocks are cleanly separated:

```text
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519

Host openshell-my-assistant
    User sandbox
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /dev/null
    LogLevel ERROR
    ProxyCommand /Users/jonathanhodges/.local/bin/openshell ssh-proxy --gateway-name nemoclaw --name my-assistant
```

**Prevention:** Never blindly append `openshell sandbox ssh-config >> ~/.ssh/config`. Instead, check the file first and replace the `openshell-my-assistant` block if it already exists.

## Duplicate Telegram responses after rebuild

**Symptom:** The agent sends every response twice in Telegram, but the dashboard only shows one.

**Root cause:** The old Telegram bridge process (from before the rebuild) is still alive. `start-services.sh` tracks PIDs in `/tmp/nemoclaw-services/`, but a sandbox destroy + re-onboard can orphan the old process if the PID file was lost or the bridge was started in a different session. Both the old and new bridge poll the same Telegram bot, so every message gets processed twice.

**Diagnosis:**

```bash
# Should show exactly ONE process — if you see two, that's the problem
ps aux | grep telegram-bridge | grep -v grep
```

**Fix:**

```bash
pkill -f telegram-bridge.js
# Then restart cleanly
nemoclaw start
# or: ./scripts/start-services.sh --sandbox my-assistant
```

**Prevention:** Always kill the bridge before destroying a sandbox:

```bash
pkill -f telegram-bridge.js || true
nemoclaw my-assistant destroy
```

## Step 15: Usage

```bash
# Basic recovery (keeps current inference provider)
./scripts/recover-after-reboot.sh

# Recovery + switch to Ollama for local inference
./scripts/recover-after-reboot.sh --provider ollama

# Recovery + switch to Bedrock via LiteLLM
./scripts/recover-after-reboot.sh --provider bedrock

# Recovery + start Telegram bridge and cloudflared
./scripts/recover-after-reboot.sh --services

# Recovery for a different sandbox
./scripts/recover-after-reboot.sh --sandbox other-box

# See what it would do without doing it
./scripts/recover-after-reboot.sh --dry-run

# Combine flags
./scripts/recover-after-reboot.sh --provider ollama --services
```

## Step 16: Provider options

| Flag | Provider | Memory cost | Requires |
|------|----------|-------------|----------|
| `--provider bedrock` | Bedrock/Sonnet 4.6 via LiteLLM | ~0.5 GB | `AWS_BEARER_TOKEN_BEDROCK` (script starts LiteLLM automatically) |
| `--provider nvidia` | NVIDIA cloud endpoints | None | `NVIDIA_API_KEY` |
| `--provider ollama` | Ollama (local Qwen 3.5) | ~21 GB | Ollama running on port 11434 |
| *(omitted)* | Keep pre-reboot setting | -- | -- |

## Step 17: If the sandbox was lost

If the script reports "Sandbox was lost", the k3s state didn't survive. This is rare but can happen if:

- `nemoclaw status` ran before Docker was ready (destroyed the gateway volume)
- Docker Desktop "Reset to factory defaults" was used
- The Docker volume was manually removed

In that case, back up what you can and do a full re-onboard:

```bash
# If the sandbox is partially alive, try to save workspace first
./scripts/backup-workspace.sh backup my-assistant

# Full re-onboard
export NVIDIA_API_KEY="..."
export TELEGRAM_BOT_TOKEN="..."
export NEMOCLAW_NON_INTERACTIVE=1
export NEMOCLAW_SANDBOX_NAME="my-assistant"
export NEMOCLAW_POLICY_PRESETS="telegram,pypi,npm,slack,gemini-search"
nemoclaw onboard --non-interactive

# Restore workspace into the new sandbox
./scripts/backup-workspace.sh restore my-assistant
```

## Step 18: Switching inference models (full rebuild required)

Changing the inference model requires **rebuilding the sandbox**. The agent's model identity is baked into `/sandbox/.openclaw/openclaw.json` at build time (root-owned, 444, Landlock read-only). Running `openshell inference set` only changes the gateway route — the agent still identifies as the old model. See [NVIDIA/NemoClaw#759](https://github.com/NVIDIA/NemoClaw/issues/759).

### Step-by-step model switch

```bash
# 1. Back up workspace
./scripts/backup-workspace.sh backup my-assistant

# 2. Stop services
./scripts/start-services.sh --sandbox my-assistant --stop

# 3. Rebuild sandbox with new model
#    Set NEMOCLAW_RECREATE_SANDBOX=1 to force rebuild.
#    Set NEMOCLAW_PROVIDER and NEMOCLAW_MODEL for the target.

# Example: Bedrock/Claude Sonnet 4.6 via LiteLLM
export NEMOCLAW_RECREATE_SANDBOX=1
export NEMOCLAW_PROVIDER=custom
export NEMOCLAW_MODEL="bedrock/us.anthropic.claude-sonnet-4-6"
export NEMOCLAW_ENDPOINT_URL="http://localhost:4000/v1"   # host URL for validation
export COMPATIBLE_API_KEY="dummy"
nemoclaw onboard --non-interactive

# Example: Ollama/Qwen local
export NEMOCLAW_RECREATE_SANDBOX=1
export NEMOCLAW_PROVIDER=ollama
export NEMOCLAW_MODEL="qwen3.5:35b-a3b-coding-nvfp4"
nemoclaw onboard --non-interactive

# Example: NVIDIA cloud (default)
export NEMOCLAW_RECREATE_SANDBOX=1
nemoclaw onboard --non-interactive

# 4. Fix provider endpoint for sandbox access (LiteLLM/Ollama only)
#    Onboard validates against localhost, but the sandbox needs host.openshell.internal
openshell provider delete compatible-endpoint
openshell provider create --name compatible-endpoint --type openai \
  --credential "OPENAI_API_KEY=dummy" \
  --config "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1"
openshell inference set --provider compatible-endpoint \
  --model "bedrock/us.anthropic.claude-sonnet-4-6" --no-verify

# 5. Re-add local network policy endpoints (litellm, ollama)
#    The recovery script handles this, or add manually to the policy YAML.

# 6. Restore workspace
./scripts/backup-workspace.sh restore my-assistant

# 7. Restart services
./scripts/start-services.sh --sandbox my-assistant
```

## What gets reset on rebuild

| Component | Reset? | Action needed |
|-----------|--------|---------------|
| `openclaw.json` (model identity) | Yes (rebuilt) | This is the point of the rebuild |
| Workspace files (SOUL.md, etc.) | Yes (lost) | Restore from backup |
| Session history | Yes (lost) | Fresh start |
| Providers | No (gateway-level) | But may need re-pointing (step 4) |
| Network policy | Yes (reset to presets) | Re-add custom endpoints (step 5) |
| Port forward | Yes (recreated) | Onboard restarts it |
| Fetch-guard DNS patch | Yes (lost) | Re-apply via docker exec (step 11) |
| Gateway device pairing | Yes (lost) | Re-approve device (step 12) |

### Files containing model identity (audit)

| File | Path | Writable? | Behavior |
|------|------|-----------|----------|
| `openclaw.json` | `/sandbox/.openclaw/` | No (root, 444, Landlock) | Source of truth — rebuilt with sandbox |
| `models.json` | `/sandbox/.openclaw-data/agents/main/agent/` | Writable but regenerated | Derived from openclaw.json on startup |
| `sessions.json` | `/sandbox/.openclaw-data/agents/main/sessions/` | Writable | Caches model name per session |

## Step 19: Memory management (M4 Pro 48 GB)

Avoid running Ollama + LiteLLM + Docker simultaneously. Pick one inference path:

| Setup | Approx. memory |
|-------|---------------|
| Docker + gateway + sandbox | ~4-6 GB |
| + NVIDIA cloud inference | +0 GB |
| + LiteLLM (Bedrock) | +0.5 GB |
| + Ollama (Qwen 3.5 35B) | +21 GB |
| macOS + apps + Claude Code | ~8-10 GB |

Safe combinations:

- Docker + NVIDIA cloud: ~14 GB total
- Docker + Bedrock/LiteLLM: ~15 GB total
- Docker + Ollama: ~33 GB total (tight but workable if you close other apps)
