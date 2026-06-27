#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Auto-start NemoClaw after a macOS reboot.
#
# Waits for Docker Desktop to be ready, recovers the OpenShell gateway and
# sandbox, then starts auxiliary services (Telegram bridge, cloudflared).
#
# Designed to run as a macOS LaunchAgent (RunAtLoad + KeepAlive on crash).
#
# Usage:
#   ./scripts/auto-start.sh                     # auto-detect sandbox
#   ./scripts/auto-start.sh --sandbox mybox     # explicit sandbox name
#   ./scripts/auto-start.sh --timeout 300       # custom Docker wait (seconds)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_PREFIX="[nemoclaw-autostart]"

# ── Defaults ────────────────────────────────────────────────────────
DOCKER_TIMEOUT=180 # seconds to wait for Docker daemon
SANDBOX_NAME=""    # auto-detect from registry if empty

# ── Parse flags ─────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a name}"
      shift 2
      ;;
    --timeout)
      DOCKER_TIMEOUT="${2:?--timeout requires seconds}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# ── Logging ─────────────────────────────────────────────────────────
info() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX $1"; }
warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX [WARN] $1"; }
fail() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX [ERROR] $1" >&2
  exit 1
}

# ── Load env vars from shell profiles (tokens, API keys) ───────────
# LaunchAgents don't run in a login shell, so TELEGRAM_BOT_TOKEN,
# NVIDIA_API_KEY, etc. won't be set. We extract export lines from the
# user's dotfiles instead of sourcing them (which can hang on
# interactive-only setup like nvm, oh-my-zsh, etc.).
_load_exports_from() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    # Match: export VAR="value" or export VAR='value' or export VAR=value
    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([A-Z_][A-Z0-9_]*)= ]]; then
      eval "$line" 2>/dev/null || true
    fi
  done <"$file"
}

for rc in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bashrc"; do
  _load_exports_from "$rc"
done

# Ensure nvm-managed node, openshell, and Homebrew are on PATH.
# The LaunchAgent plist sets these, but manual runs need them too.
for p in \
  "$HOME/.nvm/versions/node/"*/bin \
  "$HOME/.local/bin" \
  /opt/homebrew/bin \
  /usr/local/bin; do
  case ":$PATH:" in
    *":$p:"*) ;; # already present
    *) [ -d "$p" ] && PATH="$p:$PATH" ;;
  esac
done
export PATH

# ── Step 1: Wait for Docker ────────────────────────────────────────
info "Waiting for Docker daemon (timeout: ${DOCKER_TIMEOUT}s)..."

elapsed=0
while ! docker info >/dev/null 2>&1; do
  if [ "$elapsed" -ge "$DOCKER_TIMEOUT" ]; then
    fail "Docker daemon did not start within ${DOCKER_TIMEOUT}s. Aborting."
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

info "Docker is ready (waited ${elapsed}s)."

# ── Step 2: Resolve sandbox name ───────────────────────────────────
if [ -z "$SANDBOX_NAME" ]; then
  if [ -f "$HOME/.nemoclaw/sandboxes.json" ] && command -v node >/dev/null 2>&1; then
    SANDBOX_NAME="$(node -e "
      const s = require('$HOME/.nemoclaw/sandboxes.json');
      console.log(s.defaultSandbox || Object.keys(s.sandboxes || {})[0] || '');
    " 2>/dev/null || true)"
  fi
fi

if [ -z "$SANDBOX_NAME" ]; then
  fail "No sandbox name provided and none found in ~/.nemoclaw/sandboxes.json."
fi

info "Target sandbox: $SANDBOX_NAME"

# ── Step 3: Recover OpenShell gateway ──────────────────────────────
info "Recovering OpenShell gateway..."

if ! command -v openshell >/dev/null 2>&1; then
  fail "openshell not found on PATH."
fi

# Select the nemoclaw gateway; start it if not running
openshell gateway select nemoclaw 2>/dev/null || true

if ! openshell status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -qiw "healthy\|connected"; then
  info "Gateway not healthy — starting gateway..."
  openshell gateway start --name nemoclaw 2>&1 || true

  # Wait for the gateway to become healthy
  gw_elapsed=0
  gw_timeout=120
  while ! openshell status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -qiw "healthy\|connected"; do
    if [ "$gw_elapsed" -ge "$gw_timeout" ]; then
      warn "Gateway did not become healthy within ${gw_timeout}s. Continuing anyway."
      break
    fi
    sleep 5
    gw_elapsed=$((gw_elapsed + 5))
  done
fi

info "Gateway state: $(openshell status 2>&1 | head -3 | tr '\n' ' ')"

# ── Step 3b: Verify LiteLLM proxy (Bedrock inference) ─────────────
# LiteLLM is managed by com.nemoclaw.litellm LaunchAgent (KeepAlive).
# We just wait for it to be ready rather than starting it ourselves.
litellm_ready=0
for _ in $(seq 1 15); do
  if curl -sf --max-time 2 http://127.0.0.1:4000/health >/dev/null 2>&1; then
    litellm_ready=1
    break
  fi
  sleep 2
done
if [ "$litellm_ready" -eq 1 ]; then
  info "LiteLLM proxy is healthy on port 4000."
else
  warn "LiteLLM not responding on port 4000 after 30s. Check: launchctl list | grep litellm"
fi

# ── Step 3c: Verify inference provider (read-only) ────────────────
# Providers are baked at onboard and bound in the gateway (stateless config
# that DOES survive gateway restarts). The old code hardcoded stale
# Bedrock/Ollama/NVIDIA providers regardless of which provider the sandbox
# actually uses — wrong for a gemini-api sandbox. We now read the sandbox's
# recorded provider and only verify it's registered (warn if not). We never
# recreate stale providers here.
info "Verifying inference provider..."

provider=""
SANDBOXES_JSON="$HOME/.nemoclaw/sandboxes.json"
if [ -f "$SANDBOXES_JSON" ] && command -v node >/dev/null 2>&1; then
  provider="$(SB="$SANDBOX_NAME" SB_JSON="$SANDBOXES_JSON" node -e "
    try {
      const s = require(process.env.SB_JSON);
      const sb = (s.sandboxes || {})[process.env.SB] || {};
      process.stdout.write(sb.provider || '');
    } catch {}
  " 2>/dev/null || true)"
fi

if [ -z "$provider" ]; then
  warn "No provider recorded in ~/.nemoclaw/sandboxes.json for '$SANDBOX_NAME'. Skipping provider check."
elif command -v openshell >/dev/null 2>&1; then
  # Strip ANSI — openshell colorizes even when piped.
  if openshell provider list 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q -- "$provider"; then
    info "Inference provider '$provider' is registered."
  else
    warn "Inference provider '$provider' not registered. Re-onboard or set via 'openshell inference set'."
  fi
else
  warn "openshell CLI not found; cannot verify provider '$provider'."
fi

# ── Step 4: Recover sandbox (triggers OpenClaw process recovery) ───
info "Checking sandbox '$SANDBOX_NAME'..."

if command -v nemoclaw >/dev/null 2>&1; then
  nemoclaw "$SANDBOX_NAME" status 2>&1 || warn "Sandbox status check returned non-zero."
else
  # Fall back to direct node invocation
  node "$REPO_DIR/bin/nemoclaw.js" "$SANDBOX_NAME" status 2>&1 || warn "Sandbox status check returned non-zero."
fi

# ── Step 4a: Verify SSH tunnel ────────────────────────────────────
info "Verifying SSH tunnel to sandbox..."
ssh_test=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" 'echo ok' 2>&1 || true)
if [ "$ssh_test" = "ok" ]; then
  info "SSH tunnel to sandbox is healthy."
else
  warn "SSH tunnel to sandbox is BROKEN (${ssh_test:0:80})."
  warn "File uploads, downloads, backups, and agent SSH will fail."
  warn "To fix: echo 'y' | nemoclaw $SANDBOX_NAME destroy && nemoclaw onboard"
fi

# ── Step 4b: Re-apply network policy ─────────────────────────────
info "Applying network policy..."
POLICY_FILE="$REPO_DIR/nemoclaw-blueprint/policies/my-assistant-policy.yaml"
if [ -f "$POLICY_FILE" ]; then
  openshell policy set --policy "$POLICY_FILE" --wait "$SANDBOX_NAME" 2>&1 || warn "Policy set failed."
  openshell rule approve-all "$SANDBOX_NAME" 2>&1 || true
  info "Network policy applied and pending rules approved."
else
  warn "Policy file not found: $POLICY_FILE. Skipping."
fi

# ── Step 4c: Apply custom sandbox configurations ─────────────────
# apply-custom-policies.sh is now a thin skill-installer + read-only verifier
# (it no longer mutates openclaw.json, applies a fetch-guard patch, or restarts
# the gateway — all owned upstream now). It only re-installs custom skills and
# verifies provider + telegram channel.
if [ -x "$SCRIPT_DIR/apply-custom-policies.sh" ]; then
  info "Applying custom sandbox configurations (skills, verify provider/channel)..."
  "$SCRIPT_DIR/apply-custom-policies.sh" --sandbox "$SANDBOX_NAME" 2>&1 || warn "Custom policies failed."
else
  warn "apply-custom-policies.sh not found or not executable. Skipping."
fi

# Read-only gateway health probe (no restart loop: there's no patch to reload,
# and the in-sandbox nemoclaw-start supervisor (#4710 + #2757) owns gateway
# health). One soft probe for the summary log only.
info "Probing in-sandbox gateway health..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" \
  'curl -sf --max-time 2 http://127.0.0.1:18789/health >/dev/null 2>&1' 2>/dev/null; then
  info "In-sandbox gateway is responding on :18789."
else
  warn "In-sandbox gateway not responding on :18789 yet (may still be booting; supervisor will recover)."
fi

# ── Step 4d: Setup DNS proxy ─────────────────────────────────────
# The sandbox DNS proxy doesn't survive pod restarts. Re-setup every boot.
if [ -x "$SCRIPT_DIR/setup-dns-proxy.sh" ]; then
  info "Setting up DNS proxy in sandbox..."
  "$SCRIPT_DIR/setup-dns-proxy.sh" nemoclaw "$SANDBOX_NAME" 2>&1 || warn "DNS proxy setup failed."
else
  warn "setup-dns-proxy.sh not found or not executable. Skipping."
fi

# ── Step 4e: Dashboard port forward ───────────────────────────────
# Managed by the com.nemoclaw.dashboard-forward LaunchAgent (KeepAlive).
# No action needed here — launchd supervises the foreground forward.

# ── Step 5: Start auxiliary services ───────────────────────────────
info "Starting auxiliary services..."

if command -v nemoclaw >/dev/null 2>&1; then
  nemoclaw start 2>&1 || warn "Service start returned non-zero."
else
  node "$REPO_DIR/bin/nemoclaw.js" start 2>&1 || warn "Service start returned non-zero."
fi

# ── Step 6: Final rule approval pass ──────────────────────────────
# Services starting up (bridge, agent, etc.) may trigger new egress
# connections that generate proposed rules. Give them a moment, then
# approve anything pending so web_search/web_fetch work immediately.
sleep 10
pending="$(openshell rule get "$SANDBOX_NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -ci "proposed" || true)"
if [ "$pending" -gt 0 ]; then
  info "Approving $pending pending network rule(s)..."
  openshell rule approve-all "$SANDBOX_NAME" 2>&1 || warn "Rule approval failed."
else
  info "No pending network rules."
fi

info "Auto-start complete."
