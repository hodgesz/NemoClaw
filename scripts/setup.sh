#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw setup — run this on the HOST to set up everything.
#
# Prerequisites:
#   - Docker running (Colima, Docker Desktop, or native)
#   - openshell CLI installed (pip install openshell @ git+https://github.com/NVIDIA/OpenShell.git)
#   - NVIDIA_API_KEY set in environment (from build.nvidia.com)
#
# Usage:
#   export NVIDIA_API_KEY=nvapi-...
#   ./scripts/setup.sh
#
# What it does:
#   1. Starts an OpenShell gateway (or reuses existing)
#   2. Fixes CoreDNS for Colima environments
#   3. Creates nvidia-nim provider (build.nvidia.com)
#   4. Creates vllm-local provider (if vLLM is running)
#   5. Sets inference route to nvidia-nim by default
#   6. Builds and creates the NemoClaw sandbox
#   7. Prints next steps

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}>>>${NC} $1"; }
warn() { echo -e "${YELLOW}>>>${NC} $1"; }
fail() { echo -e "${RED}>>>${NC} $1"; exit 1; }

# Resolve DOCKER_HOST for Colima if needed
if [ -z "${DOCKER_HOST:-}" ]; then
  if [ -S "$HOME/.colima/default/docker.sock" ]; then
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
    warn "Using Colima Docker socket"
  fi
fi

# Check prerequisites
command -v openshell > /dev/null || fail "openshell CLI not found. Install: pip install 'openshell @ git+https://github.com/NVIDIA/OpenShell.git'"
command -v docker > /dev/null || fail "docker not found"
[ -n "${NVIDIA_API_KEY:-}" ] || fail "NVIDIA_API_KEY not set. Get one from build.nvidia.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Gateway — always start fresh to avoid stale state
info "Starting OpenShell gateway..."
openshell gateway destroy -g nemoclaw > /dev/null 2>&1 || true
GATEWAY_ARGS=(--name nemoclaw)
command -v nvidia-smi > /dev/null 2>&1 && GATEWAY_ARGS+=(--gpu)
openshell gateway start "${GATEWAY_ARGS[@]}" 2>&1 | tail -10

# Verify gateway is actually healthy
if ! openshell status 2>&1 | grep -q "Connected"; then
  fail "Gateway failed to start. Check 'openshell gateway info' and Docker logs."
fi
info "Gateway is healthy"

# 2. CoreDNS fix (Colima only)
if [ -S "$HOME/.colima/default/docker.sock" ]; then
  info "Patching CoreDNS for Colima..."
  bash "$SCRIPT_DIR/fix-coredns.sh" 2>&1 || warn "CoreDNS patch failed (may not be needed)"
fi

# 3. Providers
info "Setting up inference providers..."

# nvidia-nim (build.nvidia.com)
if openshell provider create --name nvidia-nim --type openai \
  --credential "NVIDIA_API_KEY=$NVIDIA_API_KEY" \
  --config "OPENAI_BASE_URL=https://integrate.api.nvidia.com/v1" 2>&1 | grep -q "AlreadyExists"; then
  info "nvidia-nim provider already exists"
else
  info "Created nvidia-nim provider"
fi

# vllm-local (if running)
if curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
  if openshell provider create --name vllm-local --type openai \
    --credential "OPENAI_API_KEY=dummy" \
    --config "OPENAI_BASE_URL=http://host.docker.internal:8000/v1" 2>&1 | grep -q "AlreadyExists"; then
    info "vllm-local provider already exists"
  else
    info "Created vllm-local provider (vLLM detected on localhost:8000)"
  fi
fi

# 4. Inference route — default to nvidia-nim
info "Setting inference route to nvidia-nim / Nemotron 3 Super..."
openshell inference set --provider nvidia-nim --model nvidia/nemotron-3-super-120b-a12b > /dev/null 2>&1

# 5. Build and create sandbox
info "Deleting old nemoclaw sandbox (if any)..."
openshell sandbox delete nemoclaw > /dev/null 2>&1 || true

info "Building and creating NemoClaw sandbox (this takes a few minutes on first run)..."

# Stage a clean build context (openshell doesn't honor .dockerignore)
BUILD_CTX="$(mktemp -d)"
cp "$REPO_DIR/Dockerfile" "$BUILD_CTX/"
cp -r "$REPO_DIR/nemoclaw" "$BUILD_CTX/nemoclaw"
cp -r "$REPO_DIR/nemoclaw-blueprint" "$BUILD_CTX/nemoclaw-blueprint"
cp -r "$REPO_DIR/scripts" "$BUILD_CTX/scripts"
rm -rf "$BUILD_CTX/nemoclaw/node_modules" "$BUILD_CTX/nemoclaw/src"

openshell sandbox create --from "$BUILD_CTX/Dockerfile" --name nemoclaw \
  --provider nvidia-nim \
  -- env NVIDIA_API_KEY="$NVIDIA_API_KEY"
rm -rf "$BUILD_CTX"

# 6. Done
echo ""
info "Setup complete!"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  NemoClaw installed                                 │"
echo "  │                                                     │"
echo "  │  Provider:  nvidia-nim (build.nvidia.com)           │"
echo "  │  Model:     nvidia/nemotron-3-super-120b-a12b       │"
echo "  │             Nemotron 3 Super 120B                   │"
echo "  │  Routing:   inference.local -> NVIDIA cloud         │"
echo "  │  Sandbox:   nemoclaw                                │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  Connect to the sandbox:"
echo "    openshell sandbox connect nemoclaw"
echo ""
echo "  Run OpenClaw:"
echo "    openclaw agent --agent main --local -m 'your prompt' --session-id s1"
echo ""
echo "  Switch to local vLLM:"
echo "    openshell inference set --provider vllm-local --model nvidia/nemotron-3-nano-30b-a3b"
echo ""
echo "  Start Telegram bridge + JensenClaw + public tunnel:"
echo "    TELEGRAM_BOT_TOKEN=... ./scripts/start-services.sh"
echo ""
echo "  Monitor + approve network egress in TUI:"
echo "    openshell term"
