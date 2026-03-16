# NemoClaw — OpenClaw Plugin for OpenShell

Run OpenClaw inside an OpenShell sandbox with NVIDIA inference (Nemotron 3 Super 120B via [build.nvidia.com](https://build.nvidia.com), or local vLLM).

## Quick Start

```bash
# After npm publish (coming soon):
# npm install -g nemoclaw

# Pre-publish: install from git
git clone git@github.com:NVIDIA/openshell-openclaw-plugin.git
cd openshell-openclaw-plugin
./install.sh
```

First run prompts for your NVIDIA API Key (get one from [build.nvidia.com](https://build.nvidia.com)) and saves it to `~/.nemoclaw/credentials.json`.

### Prerequisites

- Node.js 20+
- Docker
- [OpenShell CLI](https://github.com/NVIDIA/OpenShell/releases) (binary download)

The repo-owned sandbox image stays simple and non-root at rest.
Headless bootstrap runs `openclaw setup`, then `nemoclaw-gateway.sh ensure`
inside the sandbox. That helper uses `~/.openclaw/run/gateway.pid` and
`~/.openclaw/run/gateway.lock` to keep exactly one direct
`openclaw gateway run --force` process alive without requiring systemd or
root-only service installation.

### Ubuntu 24.04 (fresh install)

> **Minimum 8GB RAM** — the sandbox image is ~1.5 GiB and will OOM-kill on 4GB VMs.

#### Prerequisites (one-time, interactive steps)

```bash
# Docker
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker
```
You must run the above first before continuing.

```
# Node.js 22 LTS
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# gh CLI (needed while OpenShell repo is private)
sudo apt-get install -y gh
gh auth login          # interactive — follow the prompts

# OpenShell CLI (binary from GitHub releases)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
esac
gh release download --repo NVIDIA/OpenShell \
  --pattern "openshell-${ARCH}-unknown-linux-musl.tar.gz" --dir /tmp
tar xzf /tmp/openshell-${ARCH}-unknown-linux-musl.tar.gz -C /tmp
sudo install -m 755 /tmp/openshell /usr/local/bin/openshell
rm -f /tmp/openshell /tmp/openshell-${ARCH}-unknown-linux-musl.tar.gz
```

#### NVIDIA Container Toolkit (optional — only if you have a GPU)

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

#### NemoClaw

```bash
git clone https://github.com/NVIDIA/openshell-openclaw-plugin.git
cd openshell-openclaw-plugin
sudo npm install -g .
nemoclaw onboard
```

### macOS

```bash
brew install colima docker node
colima start

# OpenShell CLI (binary from GitHub releases)
curl -fsSL https://github.com/NVIDIA/OpenShell/releases/latest/download/openshell-aarch64-apple-darwin.tar.gz | tar xz
sudo install -m 755 openshell /usr/local/bin/openshell
rm -f openshell

# NemoClaw (pre-publish: install from git)
git clone https://github.com/NVIDIA/openshell-openclaw-plugin.git
cd openshell-openclaw-plugin
sudo npm install -g .
nemoclaw setup
```

### Windows (via WSL2)

NemoClaw does not support native Windows. All scripts, binaries, and tooling target Linux and macOS only. To run on Windows, use **WSL2 with Ubuntu 24.04**:

```bash
# 1. Install WSL2 with Ubuntu 24.04 (from PowerShell as Administrator)
wsl --install -d Ubuntu-24.04

# 2. Launch Ubuntu and follow the Ubuntu 24.04 instructions above
```

Once inside WSL2, the full Ubuntu 24.04 setup applies as-is — Docker Desktop integrates with WSL2 backends, and Linux binaries (OpenShell) work natively.

### Deploy to a cloud VM

```bash
nemoclaw deploy my-gpu-box
```

Requires the [Brev CLI](https://github.com/brevdev/brev-cli) and [Brev account](https://brev.nvidia.com). The deploy script installs Docker, NVIDIA Container Toolkit (if GPU present), and OpenShell on the VM automatically.

## Usage

### Connect to the sandbox

```bash
nemoclaw <sandbox-name> connect          # local
nemoclaw deploy my-gpu-box               # remote Brev instance
```

### Run OpenClaw (inside the sandbox)

```bash
openclaw agent --agent main --local -m "your prompt" --session-id s1
```

### Switch inference providers

```bash
# NVIDIA cloud (Nemotron 3 Super 120B)
openshell inference set --provider nvidia-nim --model nvidia/nemotron-3-super-120b-a12b

# Local vLLM
openshell inference set --provider vllm-local --model nvidia/nemotron-3-nano-30b-a3b
```

### Monitor

```bash
openshell term
```

### Network egress approval flow

NemoClaw runs with a strict network policy — the sandbox can only reach
explicitly allowed endpoints. When the agent tries to access something new
(a web API, a package registry, etc.), OpenShell intercepts the request and
the TUI prompts the operator to approve or deny it in real time.

To see this in action, run the walkthrough:

```bash
./scripts/walkthrough.sh
```

This opens a split tmux session — TUI on the left, agent on the right.
Try asking the agent something that requires external access:

- *"Write a Python script that fetches the current NVIDIA stock price"*
- *"Install the requests library and get the top story from Hacker News"*

The TUI will show the blocked request and ask you to approve it. Once
approved, the agent completes the task.

Without tmux, run these in two terminals:

```bash
# Terminal 1 — monitor + approve
openshell term

# Terminal 2 — agent
openshell sandbox connect nemoclaw -- nemoclaw-shell
export NVIDIA_API_KEY=nvapi-...
nemoclaw-start
openclaw agent --agent main --local --session-id live
```

## Architecture

```
nemoclaw/                           Thin TypeScript plugin (in-process with OpenClaw gateway)
├── src/
│   ├── index.ts                    Plugin entry — registers all nemoclaw commands
│   ├── commands/
│   │   ├── launch.ts               Fresh install (prefers OpenShell-native for net-new)
│   │   ├── migrate.ts              Migrate host OpenClaw into sandbox
│   │   ├── connect.ts              Interactive shell into sandbox
│   │   ├── status.ts               Blueprint run state + sandbox health
│   │   └── eject.ts                Rollback to host install from snapshot
│   └── blueprint/
│       ├── resolve.ts              Version resolution, cache management
│       ├── verify.ts               Digest verification, compatibility checks
│       ├── exec.ts                 Subprocess execution of blueprint runner
│       └── state.ts                Persistent state (run IDs, snapshots)
├── openclaw.plugin.json            Plugin manifest
└── package.json                    Commands declared under openclaw.extensions

nemoclaw-blueprint/                 Versioned blueprint artifact (separate release stream)
├── blueprint.yaml                  Manifest — version, profiles, compatibility
├── orchestrator/
│   └── runner.py                   CLI runner — plan / apply / status / rollback
├── policies/
│   └── openclaw-sandbox.yaml       Strict baseline network + filesystem policy
├── migrations/
│   └── snapshot.py                 Snapshot / restore / cutover / rollback logic
└── iac/                            (future) Declarative infrastructure modules
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup.sh` | Host-side setup — gateway, providers, inference route, sandbox |
| `scripts/brev-setup.sh` | Brev bootstrap — installs prerequisites, then runs `setup.sh` |
| `scripts/nemoclaw-shell.sh` | Thin shell wrapper — runs commands inside the sandbox as the current user |
| `scripts/nemoclaw-gateway.sh` | Gateway process manager — `ensure`, `status`, `stop` using PID + lock files |
| `scripts/nemoclaw-start.sh` | Sandbox startup helper — configures OpenClaw, installs plugin |
| `scripts/walkthrough.sh` | Split-screen walkthrough — agent + TUI approval flow |
| `scripts/fix-coredns.sh` | CoreDNS patch for Colima environments |

## Commands

| Command | Description |
|---------|-------------|
| `nemoclaw onboard` | Interactive setup wizard (recommended) |
| `nemoclaw list` | List all sandboxes |
| `nemoclaw <name> connect` | Interactive shell into the sandbox |
| `nemoclaw <name> status` | Sandbox health, inference config, NIM status |
| `nemoclaw <name> policy-add` | Add a network policy preset |
| `nemoclaw <name> policy-list` | List presets (● = applied) |
| `nemoclaw <name> destroy` | Stop NIM + delete sandbox |
| `nemoclaw deploy <instance>` | Deploy to a Brev VM |
| `nemoclaw start` / `stop` / `status` | Manage services (Telegram, tunnel) |
| `nemoclaw setup` | Legacy setup (deprecated) |

## Inference Profiles

| Profile | Provider | Model | Use Case |
|---------|----------|-------|----------|
| `default` | NVIDIA cloud | nemotron-3-super-120b-a12b | Production, requires API key |
| `nim-local` | Local NIM service | nemotron-3-super-120b-a12b | On-prem, NIM deployed as pod |
| `vllm` | vLLM | nemotron-3-nano-30b-a3b | Local inference, vLLM on localhost:8000 |

## Design Principles

1. **Thin plugin, versioned blueprint** — Plugin stays small and stable; orchestration logic evolves independently
2. **Respect CLI boundaries** — Plugin commands live under `nemoclaw` namespace, never override built-in OpenClaw commands
3. **Supply chain safety** — Immutable versioned artifacts with digest verification
4. **OpenShell-native for net-new** — Don't force double-install; prefer `openshell sandbox create`
5. **Snapshot everything** — Every migration creates a restorable backup
