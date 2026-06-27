# NemoClaw Setup Plan — M4 MacBook Pro

> **Portable guide** — follow this end-to-end to replicate the full NemoClaw setup on a
> fresh Apple Silicon Mac. Written for M4 Pro 48GB but works on any Apple Silicon Mac
> with 32+ GB RAM.

## What you'll end up with

- NemoClaw sandbox ("my-assistant") with full safety features (network policies, filesystem isolation, process sandboxing)
- AWS Bedrock / Claude Sonnet 4.6 inference via LiteLLM proxy (primary)
- NVIDIA Cloud and Ollama as switchable fallback providers
- Telegram bot bridge for mobile access
- Built-in web search via Gemini
- Custom skills (ADHD Planner, Personal CRM)
- Automated recovery after reboot

## Architecture overview

```text
┌─────────────────────────────────────────────────────┐
│  macOS Host                                         │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐                │
│  │ LiteLLM      │  │ Telegram     │                │
│  │ :4000        │  │ Bridge       │                │
│  └──────┬───────┘  └──────┬───────┘                │
│         │                  │ SSH                     │
│  ┌──────┴──────────────────┴───────────────────┐   │
│  │  Docker Desktop (k3s)                        │   │
│  │  ┌────────────────────────────────────────┐ │   │
│  │  │  OpenShell Gateway                      │ │   │
│  │  │  ┌──────────────────────────────────┐  │ │   │
│  │  │  │  Sandbox ("my-assistant")         │  │ │   │
│  │  │  │  - OpenClaw agent                 │  │ │   │
│  │  │  │  - Skills, workspace files        │  │ │   │
│  │  │  │  - Network policy enforcement     │  │ │   │
│  │  │  │  - Filesystem isolation (Landlock) │  │ │   │
│  │  │  └──────────────────────────────────┘  │ │   │
│  │  └────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

Inference flow: Sandbox → `inference.local` → Gateway proxy → LiteLLM (:4000) → AWS Bedrock.
Credentials never enter the sandbox — they stay on the host in the LiteLLM process.

---

## Phase 1: Prerequisites

### 1.1 Xcode Command Line Tools

```bash
xcode-select --install   # skip if already installed
```

### 1.2 Docker Desktop

- Install Docker Desktop for Apple Silicon
- Verify: `docker info` shows `linux/arm64`
- Recommended: allocate at least 8 GB RAM to Docker (Settings > Resources)

### 1.3 Node.js >= 22.16.0

```bash
node --version
# If missing or too old:
nvm install 22
```

### 1.4 Python 3.13

```bash
python3 --version
# LiteLLM needs Python 3.13 (3.14 has uvloop compatibility issues)
# If missing: brew install python@3.13
```

### 1.5 pipx (for LiteLLM)

```bash
brew install pipx
pipx ensurepath
```

### 1.6 Ollama (optional — for local inference fallback)

```bash
brew install ollama
ollama pull qwen3.5:35b-a3b-coding-nvfp4   # ~21 GB, needs 32+ GB free RAM
ollama list
```

> **Memory warning:** Running Ollama + Docker + LiteLLM simultaneously uses ~33 GB.
> On 48 GB that's tight. Pick one inference provider at a time.

---

## Phase 2: Clone and Build NemoClaw

### 2.1 Fork and clone

```bash
# Fork NVIDIA/NemoClaw on GitHub first, then:
git clone git@github.com:<your-username>/NemoClaw.git
cd NemoClaw

# Add upstream for pulling NVIDIA updates
git remote add upstream https://github.com/NVIDIA/NemoClaw.git
git fetch upstream
```

**Remotes after setup:**

- `origin` → `<your-username>/NemoClaw` (push your customizations here)
- `upstream` → `NVIDIA/NemoClaw` (pull upstream updates with `git fetch upstream && git merge upstream/main`)

### 2.2 Install dependencies and build

```bash
npm install
cd nemoclaw && npm install && npm run build && cd ..
```

### 2.3 Link the CLI globally

```bash
npm link
nemoclaw --version   # verify
```

---

## Phase 3: Credentials Setup

Collect all credentials before onboarding. Store them all in `~/.zshrc` so every new shell
session has them automatically.

### Required credentials

| Variable | Source | Purpose |
|----------|--------|---------|
| `NVIDIA_API_KEY` | [build.nvidia.com](https://build.nvidia.com/) | Required by NemoClaw even if not using NVIDIA inference |
| `TELEGRAM_BOT_TOKEN` | @BotFather in Telegram | Telegram bridge |
| `AWS_BEARER_TOKEN_BEDROCK` | AWS Console > Bedrock > API keys | Bedrock inference via LiteLLM |
| `GEMINI_API_KEY` | [aistudio.google.com](https://aistudio.google.com/) | Built-in web search |

### Optional credentials

| Variable | Source | Purpose |
|----------|--------|---------|
| `DEVREV_API_KEY` | DevRev dashboard | DevRev integration |
| `SLACK_BOT_TOKEN` | Slack app dashboard | Slack integration |

### Add to ~/.zshrc

```bash
# NemoClaw credentials
export NVIDIA_API_KEY="nvapi-..."
export TELEGRAM_BOT_TOKEN="123456:ABC..."
export AWS_BEARER_TOKEN_BEDROCK="..."
export GEMINI_API_KEY="AIza..."
# Optional:
export DEVREV_API_KEY="..."
export SLACK_BOT_TOKEN="xoxb-..."
```

Then `source ~/.zshrc`.

### Create Telegram bot

1. Open Telegram, search for **@BotFather** (verified, blue checkmark) in the **main search bar** (not Secret Chat search)
2. Send `/newbot`, follow prompts to pick a name and username
3. Copy the bot token — that's your `TELEGRAM_BOT_TOKEN`

---

## Phase 4: Start LiteLLM Proxy (Bedrock)

LiteLLM translates OpenAI-format requests into Bedrock's native API. It runs on the host
and the sandbox reaches it via `host.openshell.internal:4000`.

```bash
# Install LiteLLM (use Python 3.13)
pipx install "litellm[proxy]" --python python3.13

# Start LiteLLM
source ~/.zshrc
nohup litellm --model bedrock/us.anthropic.claude-sonnet-4-6 --port 4000 > /tmp/litellm.log 2>&1 &

# Verify
curl -s -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock/us.anthropic.claude-sonnet-4-6","messages":[{"role":"user","content":"say hi"}],"max_tokens":20}'
```

> **Security:** Your Bedrock bearer token stays on the host in the LiteLLM process.
> The sandbox only sees `inference.local` — credentials never enter the sandbox.

---

## Phase 5: Onboard NemoClaw

### 5.1 Run non-interactive onboard

```bash
source ~/.zshrc

export NEMOCLAW_NON_INTERACTIVE=1
export NEMOCLAW_SANDBOX_NAME="my-assistant"
export NEMOCLAW_PROVIDER=custom
export NEMOCLAW_MODEL="bedrock/us.anthropic.claude-sonnet-4-6"
export NEMOCLAW_ENDPOINT_URL="http://localhost:4000/v1"
export COMPATIBLE_API_KEY="dummy"
export NEMOCLAW_POLICY_PRESETS="telegram,pypi,npm,slack,gemini-search"

nemoclaw onboard --non-interactive
```

This creates:

- An OpenShell gateway container (`openshell-cluster-nemoclaw`)
- A k3s sandbox pod ("my-assistant") with filesystem isolation, network policies, process sandboxing
- A port forward on :18789 for the dashboard

### 5.2 Fix provider endpoint for sandbox access

Onboard validates the endpoint against `localhost`, but the sandbox can't reach localhost —
it needs `host.openshell.internal`. Fix the provider:

```bash
openshell provider delete compatible-endpoint
openshell provider create --name compatible-endpoint --type openai \
  --credential "OPENAI_API_KEY=dummy" \
  --config "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1"
openshell inference set --provider compatible-endpoint \
  --model "bedrock/us.anthropic.claude-sonnet-4-6" --no-verify
```

### 5.3 Create additional providers (for switching later)

```bash
# Ollama (local inference fallback)
openshell provider create --name ollama-local --type openai \
  --credential "OPENAI_API_KEY=ollama" \
  --config "OPENAI_BASE_URL=http://host.openshell.internal:11434/v1"

# Bedrock via LiteLLM (alias)
openshell provider create --name bedrock-litellm --type openai \
  --credential "OPENAI_API_KEY=dummy" \
  --config "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1"
```

### 5.4 Add network policy for local inference endpoints

The sandbox needs to reach LiteLLM (:4000) and optionally Ollama (:11434). The recovery
script handles this automatically, but for first-time setup:

```bash
# Get current policy
openshell policy get --full my-assistant > /tmp/current-policy.yaml

# Add local endpoints (append to network_policies section):
#   ollama_local:
#     name: ollama_local
#     endpoints:
#     - host: host.openshell.internal
#       port: 11434
#       ...
#   litellm:
#     name: litellm
#     endpoints:
#     - host: host.openshell.internal
#       port: 4000
#       ...

# Or just run the recovery script which adds them automatically:
./scripts/recover-after-reboot.sh --provider bedrock
```

### 5.5 Set up SSH config for sandbox access

```bash
# Check if openshell-my-assistant already exists in SSH config
grep -q "openshell-my-assistant" ~/.ssh/config 2>/dev/null && echo "Already exists" || \
  openshell sandbox ssh-config my-assistant >> ~/.ssh/config
```

> **Warning:** Never blindly run `openshell sandbox ssh-config >> ~/.ssh/config` multiple
> times. It appends without checking, and the ProxyCommand settings can bleed into
> preceding Host blocks (e.g., `Host github.com`), routing all your GitHub SSH traffic
> through the sandbox proxy. Always check the file first and replace the block if it exists.

### 5.6 Verify sandbox

```bash
nemoclaw my-assistant status
# Should show Phase: Ready

# Quick SSH test
ssh -o ConnectTimeout=10 openshell-my-assistant 'echo hello'
# Should print: hello
```

### 5.7 Switch between providers at runtime

No rebuild needed — just change the inference route:

```bash
# Bedrock (primary)
openshell inference set --provider compatible-endpoint \
  --model bedrock/us.anthropic.claude-sonnet-4-6 --no-verify

# Ollama (local)
openshell inference set --provider ollama-local \
  --model qwen3.5:35b-a3b-coding-nvfp4 --no-verify

# NVIDIA Cloud
openshell inference set --provider nvidia-prod \
  --model nvidia/nemotron-3-super-120b-a12b
```

> **Note:** Switching providers changes the gateway route only. The agent's model identity
> in `openclaw.json` stays the same. To change the model identity (what the agent thinks
> it is), you must rebuild the sandbox. See `docs/recovery-after-reboot.md` "Switching
> inference models" section.

---

## Phase 6: Configure Web Search (Gemini)

OpenClaw has a built-in `$web_search` tool that supports Brave, Gemini, Grok, Kimi, and
Perplexity. We use Gemini because it has a generous free tier.

### 6.1 The problem

NemoClaw issue [#773](https://github.com/NVIDIA/NemoClaw/issues/773): there's no supported
way to configure web search — `openclaw configure --section web` fails because
`openclaw.json` is read-only (root, 444, Landlock). The community workaround is to modify
the config via `docker exec` into the k3s container.

### 6.2 Apply the gemini-search network policy

This was already included in `NEMOCLAW_POLICY_PRESETS` during onboard (Phase 5.1). The
preset is defined in `nemoclaw-blueprint/policies/presets/gemini-search.yaml` and allows
traffic to `generativelanguage.googleapis.com:443`.

Verify it's applied:

```bash
nemoclaw my-assistant status | grep gemini
# Should show: gemini-search in the Policies line
```

### 6.3 Inject Gemini config into openclaw.json

This is the docker exec workaround for issue #773. You need to do this after every sandbox
rebuild (it's automated in step 10 of the recovery doc's rebuild procedure).

```bash
# Find the sandbox container ID
CONTAINER_ID=$(docker exec openshell-cluster-nemoclaw ctr -n k8s.io containers list 2>/dev/null \
  | grep 'sandbox-from' | awk '{print $1}')
echo "Sandbox container: $CONTAINER_ID"

# Read current config
docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id read-cfg --user 0 "$CONTAINER_ID" \
  cat /sandbox/.openclaw/openclaw.json > /tmp/oc-cfg.json

# Inject Gemini web search config
python3 -c "
import json, os
cfg = json.load(open('/tmp/oc-cfg.json'))
cfg.setdefault('tools', {})['web'] = {
    'search': {
        'enabled': True,
        'provider': 'gemini',
        'gemini': {'apiKey': os.environ['GEMINI_API_KEY']}
    },
    'fetch': {'enabled': True}
}
json.dump(cfg, open('/tmp/oc-cfg.json', 'w'), indent=2)
"

# Write config back into the sandbox
docker exec -i openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id write-cfg --user 0 "$CONTAINER_ID" \
  sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/oc-cfg.json
rm /tmp/oc-cfg.json
```

> **Note:** This produces a "Config integrity check failed" warning on agent startup.
> To suppress it, update the config hash (see step 6.4).

### 6.4 Update config hash and patch fetch-guard DNS

After modifying `openclaw.json`, update the stored hash so `nemoclaw-start` doesn't
refuse to start with "integrity check FAILED":

```bash
docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id fix-hash --user 0 "$CONTAINER_ID" \
  sh -c 'sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash && chmod 444 /sandbox/.openclaw/.config-hash'
```

Then patch OpenClaw's fetch-guard to fix web search DNS resolution. OpenClaw's SSRF guard
does a local DNS lookup before checking if it should use the environment proxy — this fails
in the sandbox because k3s CoreDNS can't resolve external hostnames. The fix reorders the
code so `TRUSTED_ENV_PROXY` mode skips DNS pinning entirely.

See [NemoClaw #1252](https://github.com/NVIDIA/NemoClaw/issues/1252) and
[upstream OpenClaw #59005](https://github.com/openclaw/openclaw/issues/59005).

```bash
# Patch all fetch-guard files in the sandbox container
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
"
  docker exec -i openshell-cluster-nemoclaw ctr -n k8s.io task exec \
    --exec-id "write-fg-$RANDOM" --user 0 "$CONTAINER_ID" \
    sh -c "cat > $FILE" < /tmp/fg-patch.js 2>&1
done
rm /tmp/fg-patch.js 2>/dev/null
```

After patching, restart the gateway process inside the container so it loads the patched
files. The container's init system respawns it automatically:

```bash
# Kill the gateway (it respawns with patched code)
docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id find-gw --user 0 "$CONTAINER_ID" \
  sh -c 'ls /proc/*/cmdline 2>/dev/null | while read f; do
    pid=$(echo "$f" | cut -d/ -f3)
    tr "\0" " " < "$f" 2>/dev/null | grep -q "openclaw-gateway" && echo "$pid"
  done' | head -1 | xargs -I{} docker exec openshell-cluster-nemoclaw ctr -n k8s.io task exec \
  --exec-id kill-gw --user 0 "$CONTAINER_ID" kill {}
sleep 5  # wait for respawn
```

> **Important:** This patch must be re-applied after every sandbox rebuild. The files
> live under `/usr` in the container image and are overwritten on rebuild. Add this step
> to your rebuild checklist alongside the Gemini config injection.

### 6.5 Approve device pairing

After onboard (or gateway restart), the CLI agent needs device approval to connect to
the gateway. Without this, the agent falls back to embedded mode. See
[NemoClaw #1310](https://github.com/NVIDIA/NemoClaw/issues/1310).

```bash
# List pending devices and approve
ssh openshell-my-assistant 'openclaw devices list'
# Copy the Request UUID from the Pending table, then:
ssh openshell-my-assistant 'openclaw devices approve <request-uuid>'
```

### 6.6 Test web search

Via the dashboard chat or Telegram: ask "What's the weather in Denver today?"
The agent should use the built-in `web_search` tool and return live results.

---

## Phase 7: Telegram Bridge

### 7.1 Start the bridge

```bash
source ~/.zshrc
SANDBOX_NAME=my-assistant ./scripts/start-services.sh --sandbox my-assistant
```

Or start manually:

```bash
source ~/.zshrc
SANDBOX_NAME=my-assistant nohup node scripts/telegram-bridge.js > /tmp/telegram-bridge.log 2>&1 &
```

> **Critical:** Always set `SANDBOX_NAME=my-assistant`. The bridge defaults to "nemoclaw"
> which will give "sandbox not found" errors if your sandbox is named differently.

### 7.2 Verify

```bash
cat /tmp/telegram-bridge.log
# Should show the startup banner with correct Bot, Sandbox, and Model

# Or use the service manager:
./scripts/start-services.sh --sandbox my-assistant --status
```

Send a message to your bot in Telegram. You should get a response within ~15 seconds.

### 7.3 How the bridge works

- Bridge runs on the **host** (not inside the sandbox)
- It polls Telegram for new messages via HTTPS
- For each message, it SSHes into the sandbox and runs `openclaw agent -m "<message>"`
- Agent runs through the Gateway (not `--local`), which gives it access to `web_search` and other Gateway-only tools
- Response is sent back to Telegram, with setup noise filtered out

### 7.4 Noise filtering

The bridge filters out stderr noise (security warnings, setup lines, box-drawing characters)
before sending responses to Telegram. The filter patterns are in `scripts/telegram-bridge.js`
lines 48-64. If you see unwanted lines in Telegram responses, add the pattern to the
`NOISE_PATTERNS` array.

### 7.5 Restrict access (optional)

```bash
export ALLOWED_CHAT_IDS="123456789,987654321"
```

Get your chat ID by sending a message to the bot and checking the bridge log, or use
`@userinfobot` in Telegram.

### 7.6 Stop the bridge

```bash
./scripts/start-services.sh --sandbox my-assistant --stop
# Or: pkill -f telegram-bridge.js
```

---

## Phase 8: Install Custom Skills

Skills live inside the sandbox at `/sandbox/.openclaw-data/skills/<skill-id>/SKILL.md`.
They require no policy changes and no rebuild. Upload via SSH.

### 8.1 ADHD Founder Planner

```bash
# Create the skill directory and upload
ssh openshell-my-assistant 'mkdir -p /sandbox/.openclaw-data/skills/adhd-planner'
ssh openshell-my-assistant 'cat > /sandbox/.openclaw-data/skills/adhd-planner/SKILL.md' << 'SKILL_EOF'
# ... paste your SKILL.md content here ...
SKILL_EOF
```

### 8.2 Personal CRM

```bash
ssh openshell-my-assistant 'mkdir -p /sandbox/.openclaw-data/skills/personal-crm'
ssh openshell-my-assistant 'mkdir -p /sandbox/.openclaw-data/crm'
ssh openshell-my-assistant 'cat > /sandbox/.openclaw-data/skills/personal-crm/SKILL.md' << 'SKILL_EOF'
# ... paste your SKILL.md content here ...
SKILL_EOF
```

> **How skills work:** OpenClaw skills are description-matched by the model, not
> slash-command triggered. The agent reads the skill description and decides when to use
> it based on the user's message. Native tools (like `$web_search`) take priority over
> custom skills with similar descriptions.

### 8.3 Back up skills

Skills are lost on sandbox rebuild. Keep local copies:

```bash
# Download current skills
mkdir -p ~/.nemoclaw/skills
ssh openshell-my-assistant 'tar -cf - /sandbox/.openclaw-data/skills/' > ~/.nemoclaw/skills/backup.tar
```

---

## Phase 9: Workspace Customization

The agent's personality and behavior are defined in workspace files at
`/sandbox/.openclaw-data/workspace/`. Key files:

| File | Purpose |
|------|---------|
| `SOUL.md` | Agent personality, voice, behavioral guidelines |
| `USER.md` | Information about you (the user) |
| `IDENTITY.md` | Agent name, role, mission statement |
| `AGENTS.md` | Instructions for using tools and skills |

### 9.1 Edit workspace files

```bash
# Read current file
ssh openshell-my-assistant 'cat /sandbox/.openclaw-data/workspace/SOUL.md'

# Upload updated file
ssh openshell-my-assistant 'cat > /sandbox/.openclaw-data/workspace/SOUL.md' < ~/path/to/SOUL.md
```

### 9.2 Back up workspace

```bash
./scripts/backup-workspace.sh backup my-assistant
# Saved to ~/.nemoclaw/backups/<timestamp>/
ls ~/.nemoclaw/backups/
```

### 9.3 Restore workspace

```bash
./scripts/backup-workspace.sh restore my-assistant <timestamp>
```

> **Important:** Back up regularly. A broken SSH tunnel means you can't make a fresh
> backup — you'll need the last good one. The recovery script checks SSH health and
> warns if it's broken.

---

## Phase 10: Dashboard Access

The OpenClaw dashboard runs at `http://127.0.0.1:18789/` but requires an auth token.

### 10.1 Get the dashboard URL with token

```bash
# The token is in openclaw.json inside the sandbox
ssh openshell-my-assistant 'cat /sandbox/.openclaw/openclaw.json' 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('http://127.0.0.1:18789/#token=' + d['gateway']['auth']['token'])"
```

### 10.2 Fix port forwarding

If the dashboard is unreachable:

```bash
openshell forward stop 18789 my-assistant 2>/dev/null || true
openshell forward start --background 18789 my-assistant
```

> **Note:** The token changes on sandbox rebuild. Old bookmarked URLs will show
> "unauthorized: gateway token mismatch".

---

## Phase 11: Recovery and Day-2 Operations

See **`docs/recovery-after-reboot.md`** for the full recovery guide. Quick reference:

### After a reboot

```bash
cd /path/to/NemoClaw
source ~/.zshrc
./scripts/recover-after-reboot.sh --provider bedrock --services
```

The script: waits for Docker → restarts gateway → checks sandbox → starts LiteLLM →
re-creates providers → patches network policy → restarts port forward → starts Telegram bridge.

### After a sandbox rebuild

If SSH breaks or the sandbox is lost, you need a full rebuild. The recovery doc has a
10-step procedure including re-injecting the Gemini web search config (step 10) and
restoring workspace + skills.

### Pulling upstream NemoClaw updates

```bash
git fetch upstream
git merge upstream/main
# Resolve any conflicts in your local customizations
# Rebuild NemoClaw: cd nemoclaw && npm install && npm run build && cd ..
# Re-link: npm link
```

Local customizations (telegram-bridge.js noise filter, gemini-search.yaml preset) are in
your fork, not upstream. Merge conflicts will be rare and limited to these files.

---

## Phase 12: Test Safety Features

### Network policy

```bash
# Connect to sandbox
ssh openshell-my-assistant

# From inside, try an unauthorized request:
curl https://example.com   # BLOCKED
# Open openshell term in another terminal to see the blocked request
```

### Filesystem isolation

```bash
ssh openshell-my-assistant 'touch /usr/test'      # FAIL (read-only)
ssh openshell-my-assistant 'touch /sandbox/test'   # SUCCEED
ssh openshell-my-assistant 'ls -la /sandbox/.openclaw/openclaw.json'  # root, 444
```

### Inference routing (credentials never in sandbox)

```bash
ssh openshell-my-assistant 'cat /sandbox/.openclaw/openclaw.json' | grep -A2 endpoint
# Should show inference.local, NOT the real Bedrock/NVIDIA URL
# No API keys visible
```

### Process sandboxing

```bash
ssh openshell-my-assistant 'whoami'     # sandbox
ssh openshell-my-assistant 'ulimit -u'  # 512
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `bin/nemoclaw.js` | CLI entry point |
| `bin/lib/onboard.js` | Onboarding wizard logic |
| `nemoclaw-blueprint/blueprint.yaml` | Sandbox + inference configuration |
| `nemoclaw-blueprint/policies/openclaw-sandbox.yaml` | Default network/filesystem policy |
| `nemoclaw-blueprint/policies/presets/` | Policy presets (telegram, gemini-search, etc.) |
| `scripts/telegram-bridge.js` | Telegram bridge (host-side, **local customization**) |
| `scripts/start-services.sh` | Service lifecycle (start/stop/status) |
| `scripts/recover-after-reboot.sh` | Post-reboot recovery (**local customization**) |
| `scripts/backup-workspace.sh` | Workspace backup/restore |
| `docs/recovery-after-reboot.md` | Full recovery guide |
| `docs/capabilities-plan.md` | Capabilities expansion tracking |
| `~/.nemoclaw/backups/` | Workspace backups |

### Files we customize in the fork (not upstream)

| File | What changed | Why |
|------|-------------|-----|
| `scripts/telegram-bridge.js` | Noise filter patterns, removed `--local` flag | Clean Telegram output, enable web_search via Gateway |
| `nemoclaw-blueprint/policies/presets/gemini-search.yaml` | New file | Network policy for Gemini web search |
| `scripts/recover-after-reboot.sh` | New file | Automated recovery after reboot |
| `scripts/start-services.sh` | New file | Service lifecycle management |
| `scripts/backup-workspace.sh` | New file | Workspace backup/restore |
| `docs/recovery-after-reboot.md` | New file | Recovery documentation |
| `docs/capabilities-plan.md` | New file | Expansion tracking |

---

## Memory Budget (M4 Pro 48 GB)

| Component | Memory |
|-----------|--------|
| macOS + apps + Claude Code | ~8-10 GB |
| Docker Desktop (k3s) | ~2-3 GB |
| Gateway + sandbox | ~2-3 GB |
| LiteLLM (Bedrock proxy) | ~0.5 GB |
| Telegram bridge (Node.js) | ~50 MB |
| **Total (Bedrock setup)** | **~13-17 GB** |
| + Ollama (Qwen 3.5 35B) | +21 GB |
| **Total (Ollama setup)** | **~33-37 GB** |

Safe combinations:

- Docker + Bedrock/LiteLLM: ~15 GB total (30+ GB free)
- Docker + NVIDIA cloud: ~14 GB total (no LiteLLM needed)
- Docker + Ollama: ~35 GB total (tight — close other apps, stop LiteLLM first)

> **Tip:** Stop Ollama when not using it (`pkill ollama`) — it holds GPU memory even when idle.

---

## Verification Checklist

- [ ] Docker Desktop running on Apple Silicon
- [ ] `nemoclaw --version` works
- [ ] LiteLLM running on :4000 (`curl http://localhost:4000/health`)
- [ ] Sandbox created and ready (`nemoclaw my-assistant status` shows Phase: Ready)
- [ ] SSH works (`ssh openshell-my-assistant 'echo hello'`)
- [ ] Inference works end-to-end (send a prompt via dashboard or Telegram)
- [ ] Network policy blocks unauthorized requests
- [ ] Filesystem isolation: can't write to /usr, can write to /sandbox
- [ ] No API keys visible inside sandbox
- [ ] Fetch-guard DNS patch applied (all `fetch-guard-*.js` files patched)
- [ ] Config hash updated (no "integrity check FAILED" on agent start)
- [ ] Gateway device pairing approved (`openclaw devices list` shows Paired)
- [ ] Gemini web search works ("what's the weather in Denver?")
- [ ] Telegram bridge running with correct sandbox name
- [ ] Telegram bot responds to messages
- [ ] Dashboard accessible with token URL
- [ ] Workspace files customized and backed up
- [ ] Custom skills installed (ADHD Planner, Personal CRM)
- [ ] Recovery script works (`./scripts/recover-after-reboot.sh --dry-run`)
- [ ] Fork remotes configured (`origin` = your fork, `upstream` = NVIDIA)

---

## Known Issues and Workarounds

| Issue | Workaround | Reference |
|-------|-----------|-----------|
| Web search config not configurable at runtime | `docker exec` into k3s container to modify `openclaw.json` | [NemoClaw #773](https://github.com/NVIDIA/NemoClaw/issues/773) |
| Config hash warning after modifying openclaw.json | Cosmetic in non-root mode — agent proceeds | Expected after Phase 6.3 |
| Provider OPENAI_BASE_URL ignored by gateway | Delete and recreate provider after onboard | [NemoClaw #893](https://github.com/NVIDIA/NemoClaw/issues/893) |
| Model identity baked into openclaw.json | Must rebuild sandbox to change model identity | [NemoClaw #759](https://github.com/NVIDIA/NemoClaw/issues/759) |
| SSH handshake failure after reboot | Full sandbox rebuild required | See recovery doc |
| Telegram bridge defaults to "nemoclaw" sandbox | Always set `SANDBOX_NAME=my-assistant` | Bridge code line 32 |
| Markdown tables don't render in Telegram | Telegram only supports basic Markdown — tables appear as pipe-delimited text | Telegram API limitation |
| `nemoclaw status` before Docker ready destroys gateway | Always wait for Docker first | Recovery script handles this |
| Web search DNS fails in sandbox (`EAI_AGAIN`) | Patch fetch-guard files via `docker exec` to skip DNS pinning in proxy mode | [NemoClaw #1252](https://github.com/NVIDIA/NemoClaw/issues/1252), [OpenClaw #59005](https://github.com/openclaw/openclaw/issues/59005) |
| Gateway "pairing required" after onboard | Run `openclaw devices list` + `approve` inside sandbox | [NemoClaw #1310](https://github.com/NVIDIA/NemoClaw/issues/1310) |

---

## Lessons Learned (the hard way)

1. **Never destroy the sandbox to fix a config problem.** Each destroy wipes SSH keys, workspace, skills, everything. Find another way or accept the limitation.

2. **Never modify upstream NemoClaw files** (nemoclaw-start.sh, onboard.js, Dockerfiles). Work within extension points: policy presets, skills, recovery scripts, start-services scripts.

3. **Never restart the outer OpenShell gateway** (`openshell gateway stop/start`). It can rename the gateway and lose the sandbox entirely.

4. **Always back up before risky operations.** A broken SSH tunnel means you can't make a new backup — you need the last good one.

5. **OpenClaw skills are description-matched**, not slash-command triggered. Native tools (like `$web_search`) take priority over custom skills.

6. **The Telegram bridge needs `SANDBOX_NAME`** set to match your sandbox name. The default ("nemoclaw") causes "sandbox not found" errors.

7. **Gemini web search config must be re-injected** after every sandbox rebuild (step 10 in recovery doc's rebuild procedure).

8. **Never blindly append `openshell sandbox ssh-config >> ~/.ssh/config`.** It can corrupt other Host blocks (like `github.com`) by bleeding ProxyCommand settings into them. Always check the file first.

9. **The fetch-guard DNS patch must be re-applied after every sandbox rebuild.** The patched files live under `/usr` in the container image and are overwritten. Same for the config hash and device pairing approval.

10. **After killing the gateway process, it respawns but needs re-pairing.** Device approval (`openclaw devices approve`) is required each time the gateway restarts.
