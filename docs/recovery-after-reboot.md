# Recovery After Reboot

When your Mac reboots (or Docker Desktop restarts), the NemoClaw gateway container stops but its data volumes survive. The sandbox, workspace files, and providers can all be recovered **without a full re-onboard** if you follow the right sequence.

## TL;DR

**If using Claude Code:** just say "recover after reboot per `docs/recovery-after-reboot.md`" — Claude has the context in memory to handle it.

**If running manually:** open Docker Desktop, wait for it to be ready, then:

```bash
cd /Users/hodgesz/VsCodeProjects/nvidia/NemoClaw

# Credentials are already in ~/.zshrc — just source to pick up latest values
source ~/.zshrc

# Recover with no arguments: keep the baked-onboard inference provider, start
# the in-sandbox services. The script never destroys the gateway or sandbox.
./scripts/recover-after-reboot.sh
```

Under v0.0.68 / OpenShell 0.0.44 the script is intentionally read-only about the
sandbox internals: it waits for Docker, restarts the gateway non-destructively,
verifies the sandbox survived, **verifies** (rather than re-creates) the recorded
inference provider, reinstalls custom skills via `apply-custom-policies.sh`,
re-creates the port forward, and (with `--services`) starts the host-side
services. It no longer rewrites `openclaw.json`, re-applies the fetch-guard DNS
patch, or kills/restarts the gateway process — those are owned by upstream
`nemoclaw-start` and baked at onboard. Pass `--provider` only to **switch**
providers; without it the baked provider is left untouched.

## Credential sources

All credentials are exported in `~/.zshrc` and available in every new shell session:

| Variable | Source | Notes |
|----------|--------|-------|
| `AWS_BEARER_TOKEN_BEDROCK` | `~/.zshrc` | Bedrock bearer token for LiteLLM proxy |
| `NVIDIA_API_KEY` | `~/.zshrc` | From [build.nvidia.com](https://build.nvidia.com/) (Google hodgesz account) |
| `TELEGRAM_BOT_TOKEN` | `~/.zshrc` | @hodgesz_claw_bot bot token |
| `DEVREV_API_KEY` | `~/.zshrc` | DevRev PAT |
| `SLACK_BOT_TOKEN` | `~/.zshrc` | Slack bot token |
| `GEMINI_API_KEY` | `~/.zshrc` | Google Gemini API key for built-in web search |

## Claude Code recovery steps

When the user says "recover after reboot", Claude should follow these steps exactly:

1. **Source credentials:** run `source ~/.zshrc` to load all tokens into the current shell
2. **Wait for Docker:** run `docker info` in a loop — Docker Desktop can briefly respond then go away during startup, so verify it stays ready with two checks 5 seconds apart before proceeding
3. **Run the recovery script:** `./scripts/recover-after-reboot.sh` (no `--provider` — keep the baked-onboard provider; add `--services` only if the user wants the host-side services started). Do **not** pass `--provider bedrock` unless the user explicitly asks to *switch* to Bedrock/LiteLLM.
4. **Verify:** run `nemoclaw my-assistant status` only AFTER the script completes successfully

## What survives a reboot

| Component | Survives? | Notes |
|-----------|-----------|-------|
| Docker volumes (k3s state, sandbox PVC) | Yes | Persist unless explicitly removed |
| Sandbox pod + workspace files | Usually | k3s recovers the pod from its etcd state on the volume |
| Gateway container | No | Must be restarted — but restarting reattaches to the existing volume |
| Inference providers (gateway-level) | Yes | Stateless config inside the gateway; recovery **verifies** the recorded provider (read-only). Only re-created if you pass `--provider` to switch. |
| Network policy presets | Yes | Baked at onboard; persist on the sandbox |
| Port forwards | No | Ephemeral; re-created by the script |
| Native Telegram channel | Yes | Baked at onboard; the in-sandbox `openclaw` process polls it. No host bridge in v0.0.68. |
| Custom skills (fork-personal) | No | Reinstalled by `apply-custom-policies.sh` from `./skills/` |
| SSH tunnel (gateway <-> sandbox) | Sometimes | Can break after reboot; if broken, requires full sandbox rebuild (see below) |
| `openclaw.json` (model, web search, native telegram channel) | Yes (if sandbox survived) | Baked at image build and hash-verified by `nemoclaw-start`. Not rewritten at runtime in v0.0.68. |
| Web search (Brave) | Yes | Baked at onboard; works through the proxy without any runtime patch (the old fetch-guard DNS workaround is gone upstream). |

## What can go wrong

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

> Under v0.0.68 the rebuild is a **straight backup → destroy → onboard → restore**. Onboard now bakes the inference provider, native telegram channel, web search (Brave), and policy presets into the image, and `nemoclaw-start` hash-verifies `openclaw.json` at startup — so the old post-rebuild `docker exec` hacks (re-injecting Gemini web search, applying the fetch-guard DNS patch, rewriting `.config-hash`, killing the gateway process, approving the device) are obsolete and must NOT be re-applied. `apply-custom-policies.sh` only reinstalls custom skills and verifies the provider/channel read-only.

```bash
# 1. Back up workspace (if SSH still worked recently, use existing backup)
ls ~/.nemoclaw/backups/
# If no recent backup and SSH is broken, you cannot back up — use the last good backup

# 2. Destroy the sandbox
echo "y" | nemoclaw my-assistant destroy

# 3. Re-onboard (Bedrock-via-LiteLLM example).
#    Everything below is baked at onboard by nemoclaw itself — no post-build hacks.
source ~/.zshrc
export NEMOCLAW_NON_INTERACTIVE=1
export NEMOCLAW_SANDBOX_NAME="my-assistant"
export NEMOCLAW_PROVIDER=custom
export NEMOCLAW_MODEL="bedrock/us.anthropic.claude-sonnet-4-6"
export NEMOCLAW_ENDPOINT_URL="http://localhost:4000/v1"
export COMPATIBLE_API_KEY="dummy"
export NEMOCLAW_POLICY_PRESETS="telegram,pypi,npm,slack,gemini-search"
nemoclaw onboard --non-interactive

# 4. Refresh SSH config (replace the openshell-my-assistant block, don't blindly append)
openshell sandbox ssh-config my-assistant   # then edit ~/.ssh/config by hand

# 5. Verify SSH works
ssh -o ConnectTimeout=10 openshell-my-assistant 'echo "SSH works!"'

# 6. Restore workspace via SSH (scp won't work — no sftp-server in sandbox)
for f in SOUL.md USER.md IDENTITY.md AGENTS.md; do
  ssh openshell-my-assistant "cat > /sandbox/.openclaw/workspace/$f" \
    < ~/.nemoclaw/backups/<timestamp>/$f
done

# 7. Reinstall custom skills + verify provider/channel (read-only)
./scripts/apply-custom-policies.sh --sandbox my-assistant

# 8. Start host-side services (if used)
./scripts/recover-after-reboot.sh --services
```

> Note: there is no standalone Telegram bridge process to kill in v0.0.68 (the host bridge was removed in the native-channels migration), so no `pkill -f telegram-bridge.js` step is needed before destroy. Inbound Telegram is the sandbox's native telegram channel, polled by the in-sandbox `openclaw` process.

**Prevention:** The recovery script (`recover-after-reboot.sh`) checks SSH health after gateway restart (step 3). If SSH is broken, it warns early instead of continuing with a broken tunnel. Always back up workspace regularly — a broken SSH tunnel means you can't make a fresh backup.

### SSH config corruption (github.com routed through sandbox)

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

### Duplicate Telegram responses after rebuild

> **v0.0.68:** This failure mode no longer exists. There is no host-side Telegram bridge — `start-services.sh` only manages the `cloudflared` public tunnel, and inbound Telegram is the sandbox's single native telegram channel owned by the in-sandbox `openclaw` process. A destroy-and-re-onboard replaces that process wholesale, so there is no old bridge to orphan and no double polling. If you ever do see doubled responses, treat it as a separate bug (two `openclaw` processes in the same sandbox) rather than the old bridge-orphan story, and collect `nemoclaw my-assistant logs` before taking action.

## Usage

```bash
# Basic recovery (keeps current inference provider)
./scripts/recover-after-reboot.sh

# Recovery + switch to Ollama for local inference
./scripts/recover-after-reboot.sh --provider ollama

# Recovery + switch to Bedrock via LiteLLM
./scripts/recover-after-reboot.sh --provider bedrock

# Recovery + start host-side services (cloudflared public tunnel)
./scripts/recover-after-reboot.sh --services

# Recovery for a different sandbox
./scripts/recover-after-reboot.sh --sandbox other-box

# See what it would do without doing it
./scripts/recover-after-reboot.sh --dry-run

# Combine flags
./scripts/recover-after-reboot.sh --provider ollama --services
```

## Provider options

| Flag | Provider | Memory cost | Requires |
|------|----------|-------------|----------|
| `--provider bedrock` | Bedrock/Sonnet 4.6 via LiteLLM | ~0.5 GB | `AWS_BEARER_TOKEN_BEDROCK` (script starts LiteLLM automatically) |
| `--provider nvidia` | NVIDIA cloud endpoints | None | `NVIDIA_API_KEY` |
| `--provider ollama` | Ollama (local Qwen 3.5) | ~21 GB | Ollama running on port 11434 |
| *(omitted)* | Keep pre-reboot setting | -- | -- |

## If the sandbox was lost

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

## Switching inference models (full rebuild required)

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

### What gets reset on rebuild

| Component | Reset? | Action needed |
|-----------|--------|---------------|
| `openclaw.json` (model identity) | Yes (rebuilt) | This is the point of the rebuild |
| Workspace files (SOUL.md, etc.) | Yes (lost) | Restore from backup |
| Session history | Yes (lost) | Fresh start |
| Providers | No (gateway-level) | Re-point with `openshell inference set`, or `recover-after-reboot.sh --provider` (step 4) |
| Network policy | Yes (reset to presets) | Re-add custom endpoints (step 5) |
| Port forward | Yes (recreated) | Onboard restarts it |
| Custom skills (fork-personal) | Yes (lost) | Reinstall via `apply-custom-policies.sh` |
| Native Telegram channel | Yes (rebaked) | Baked at onboard; no manual re-inject |

### Files containing model identity (audit)

| File | Path | Writable? | Behavior |
|------|------|-----------|----------|
| `openclaw.json` | `/sandbox/.openclaw/` | No (root, 444, Landlock) | Source of truth — rebuilt with sandbox |
| `models.json` | `/sandbox/.openclaw-data/agents/main/agent/` | Writable but regenerated | Derived from openclaw.json on startup |
| `sessions.json` | `/sandbox/.openclaw-data/agents/main/sessions/` | Writable | Caches model name per session |

## Memory management (M4 Pro 48 GB)

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
