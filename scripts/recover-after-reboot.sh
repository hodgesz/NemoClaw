#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Safely recover a NemoClaw sandbox after a host reboot or Docker Desktop restart.
#
# Unlike `nemoclaw onboard`, this script never destroys the gateway or sandbox.
# It waits for Docker, restarts the gateway, checks if the sandbox survived,
# re-applies providers and network policy, restarts the port forward, and
# optionally starts services (Telegram bridge, etc.).
#
# Usage:
#   ./scripts/recover-after-reboot.sh                        # recover "my-assistant"
#   ./scripts/recover-after-reboot.sh --sandbox mybox        # recover a named sandbox
#   ./scripts/recover-after-reboot.sh --provider ollama      # also switch inference provider
#   ./scripts/recover-after-reboot.sh --services             # also start Telegram bridge
#   ./scripts/recover-after-reboot.sh --dry-run              # show what would happen

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────
SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
GATEWAY_NAME="nemoclaw"
DASHBOARD_PORT="${DASHBOARD_PORT:-18789}"
PROVIDER="" # empty = keep whatever was set before reboot
START_SERVICES=0
DRY_RUN=0
DOCKER_WAIT_SECS=60

# ── Colors ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${GREEN}[recover]${NC} $1"; }
warn() { echo -e "${YELLOW}[recover]${NC} $1"; }
fail() {
  echo -e "${RED}[recover]${NC} $1" >&2
  exit 1
}
step() { echo -e "\n${CYAN}── $1 ──${NC}"; }
dry() { if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] $1"
  return 0
else return 1; fi; }

# ── Parse flags ─────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a name}"
      shift 2
      ;;
    --provider)
      PROVIDER="${2:?--provider requires: nvidia|ollama|bedrock}"
      shift 2
      ;;
    --services)
      START_SERVICES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help | -h)
      sed -n '2,/^$/s/^# *//p' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

# ── Step 1: Wait for Docker ─────────────────────────────────────
step "Step 1/6: Waiting for Docker daemon"

if dry "would wait for Docker daemon"; then
  :
else
  elapsed=0
  while ! docker info >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$DOCKER_WAIT_SECS" ]; then
      fail "Docker not ready after ${DOCKER_WAIT_SECS}s. Start Docker Desktop and re-run."
    fi
    printf "  waiting... (%ds)\r" "$elapsed"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  info "Docker is ready."
fi

# ── Step 2: Restart gateway (non-destructive) ───────────────────
step "Step 2/6: Restarting gateway (non-destructive)"

if dry "would run: openshell gateway start --name $GATEWAY_NAME"; then
  :
else
  # Select first — if the gateway container survived the reboot this is enough.
  if openshell gateway select "$GATEWAY_NAME" >/dev/null 2>&1 \
    && openshell status 2>&1 | grep -q "healthy"; then
    info "Gateway '$GATEWAY_NAME' already healthy (container survived reboot)."
  else
    info "Starting gateway '$GATEWAY_NAME'..."
    openshell gateway start --name "$GATEWAY_NAME" 2>&1 \
      | grep -v "^  I0" \
      || fail "Gateway failed to start. You may need a full re-onboard: nemoclaw onboard"
    info "Gateway started."
  fi
fi

# ── Step 3: Check sandbox ───────────────────────────────────────
step "Step 3/6: Checking sandbox '$SANDBOX_NAME'"

if dry "would run: openshell sandbox get $SANDBOX_NAME"; then
  :
else
  sandbox_state="$(openshell sandbox get "$SANDBOX_NAME" 2>&1 || true)"
  if echo "$sandbox_state" | grep -qi "ready"; then
    info "Sandbox '$SANDBOX_NAME' is Ready. Workspace files preserved."
    # Verify SSH tunnel health — a broken handshake silently breaks upload/download/backup
    ssh_test=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "openshell-${SANDBOX_NAME}" 'echo ok' 2>&1 || true)
    if [ "$ssh_test" = "ok" ]; then
      info "SSH tunnel to sandbox is healthy."
    else
      warn "SSH tunnel to sandbox is BROKEN (handshake verification failure)."
      warn "File uploads, downloads, backups, and scp will silently fail."
      warn "To fix: destroy and re-onboard the sandbox. See docs/recovery-after-reboot.md"
      warn "  echo 'y' | nemoclaw $SANDBOX_NAME destroy"
      warn "  nemoclaw onboard"
    fi
  elif echo "$sandbox_state" | grep -qi "not found\|does not exist\|no sandbox"; then
    fail "Sandbox '$SANDBOX_NAME' was lost. Run: nemoclaw onboard --non-interactive"
  else
    warn "Sandbox state unclear. Waiting 15s for pod to stabilize..."
    sleep 15
    sandbox_state="$(openshell sandbox get "$SANDBOX_NAME" 2>&1 || true)"
    if echo "$sandbox_state" | grep -qi "ready"; then
      info "Sandbox '$SANDBOX_NAME' is Ready after wait."
    else
      warn "Sandbox may not be healthy. State:"
      echo "$sandbox_state"
      warn "If problems persist, back up workspace then re-onboard:"
      warn "  ./scripts/backup-workspace.sh backup $SANDBOX_NAME"
      warn "  nemoclaw onboard --non-interactive"
      # Continue anyway — providers and port forward are still useful
    fi
  fi
fi

# ── Step 3b: Start LiteLLM if needed for Bedrock ────────────────
if [ "$PROVIDER" = "bedrock" ] || [ -z "$PROVIDER" ]; then
  # Start LiteLLM if not already running (needed for Bedrock inference)
  if ! curl -s --max-time 2 http://localhost:4000/health >/dev/null 2>&1; then
    if [ "$PROVIDER" = "bedrock" ] || [ -z "$PROVIDER" ]; then
      if [ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then
        if ! dry "would start LiteLLM for Bedrock"; then
          info "Starting LiteLLM for Bedrock..."
          nohup litellm --model bedrock/us.anthropic.claude-sonnet-4-6 --port 4000 \
            >/tmp/litellm.log 2>&1 &
          echo $! >/tmp/litellm.pid
          # Wait for it to be ready
          for _ in $(seq 1 15); do
            if curl -s --max-time 2 http://localhost:4000/health >/dev/null 2>&1; then
              break
            fi
            sleep 1
          done
          if curl -s --max-time 2 http://localhost:4000/health >/dev/null 2>&1; then
            info "LiteLLM ready (PID $(cat /tmp/litellm.pid))."
          else
            warn "LiteLLM may still be starting. Check /tmp/litellm.log if inference fails."
          fi
        fi
      else
        warn "AWS_BEARER_TOKEN_BEDROCK not set. LiteLLM not started."
        warn "Set it and re-run, or switch to a different provider."
      fi
    fi
  else
    info "LiteLLM already running on port 4000."
  fi
fi

# ── Step 4: Re-create providers ──────────────────────────────────
step "Step 4/6: Ensuring inference providers exist"

ensure_provider() {
  local name="$1" type="$2" cred="$3" config="$4"
  if dry "would create provider $name"; then return; fi
  # Delete-and-recreate is safe — providers are stateless config.
  openshell provider delete "$name" 2>/dev/null || true
  if openshell provider create --name "$name" --type "$type" \
    --credential "$cred" --config "$config" 2>&1 | grep -q "Created"; then
    info "Provider '$name' ready."
  else
    warn "Provider '$name' may already exist (OK)."
  fi
}

ensure_provider "ollama-local" "openai" \
  "OPENAI_API_KEY=ollama" \
  "OPENAI_BASE_URL=http://host.openshell.internal:11434/v1"

ensure_provider "bedrock-litellm" "openai" \
  "OPENAI_API_KEY=dummy" \
  "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1"

# compatible-endpoint is created by onboard when using custom provider (Bedrock)
ensure_provider "compatible-endpoint" "openai" \
  "OPENAI_API_KEY=dummy" \
  "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1"

# nvidia-prod is created by onboard and persists in the gateway — check it
if ! dry "would check nvidia-prod" && ! openshell provider list 2>&1 | grep -q "nvidia-prod"; then
  if [ -n "${NVIDIA_API_KEY:-}" ]; then
    ensure_provider "nvidia-prod" "nvidia" \
      "NVIDIA_API_KEY=${NVIDIA_API_KEY}" \
      "NVIDIA_BASE_URL=https://integrate.api.nvidia.com/v1"
  else
    warn "nvidia-prod provider missing and NVIDIA_API_KEY not set. Skipping."
  fi
fi

# ── Step 4b: Switch provider if requested ────────────────────────
if [ -n "$PROVIDER" ]; then
  case "$PROVIDER" in
    nvidia)
      if ! dry "would set inference to nvidia-prod"; then
        openshell inference set --provider nvidia-prod \
          --model nvidia/nemotron-3-super-120b-a12b --no-verify 2>&1
        info "Inference set to NVIDIA cloud."
      fi
      ;;
    ollama)
      if ! dry "would set inference to ollama-local"; then
        openshell inference set --provider ollama-local \
          --model qwen3.5:35b-a3b-coding-nvfp4 --no-verify 2>&1
        info "Inference set to Ollama (local). Make sure Ollama is running."
      fi
      ;;
    bedrock)
      if ! dry "would set inference to compatible-endpoint (Bedrock)"; then
        openshell inference set --provider compatible-endpoint \
          --model bedrock/us.anthropic.claude-sonnet-4-6 --no-verify 2>&1
        info "Inference set to Bedrock/Sonnet 4.6 via LiteLLM."
      fi
      ;;
    *)
      warn "Unknown provider '$PROVIDER'. Skipping inference switch."
      ;;
  esac
fi

# ── Step 5: Re-apply network policy for local endpoints ──────────
step "Step 5/6: Checking network policy for local endpoints"

if dry "would check/update network policy"; then
  :
else
  policy="$(openshell policy get --full "$SANDBOX_NAME" 2>&1 || true)"
  needs_update=0

  if ! echo "$policy" | grep -q "ollama_local"; then
    needs_update=1
    info "ollama_local endpoint missing from policy."
  fi
  if ! echo "$policy" | grep -q "litellm"; then
    needs_update=1
    info "litellm endpoint missing from policy."
  fi

  if [ "$needs_update" -eq 1 ]; then
    # Extract the YAML portion (everything after the --- line)
    policy_yaml="$(echo "$policy" | sed -n '/^---$/,$ p' | tail -n +2)"

    if [ -z "$policy_yaml" ]; then
      warn "Could not parse current policy. Skipping policy update."
      warn "You may need to manually add ollama_local and litellm endpoints."
    else
      # Append the local endpoint blocks
      cat >/tmp/nemoclaw-recovery-policy.yaml <<PEOF
${policy_yaml}
  ollama_local:
    name: ollama_local
    endpoints:
    - host: host.openshell.internal
      port: 11434
      protocol: rest
      enforcement: enforce
      rules:
      - allow:
          method: '*'
          path: /**
    binaries:
    - path: /usr/local/bin/claude
    - path: /usr/local/bin/openclaw
  litellm:
    name: litellm
    endpoints:
    - host: host.openshell.internal
      port: 4000
      protocol: rest
      enforcement: enforce
      rules:
      - allow:
          method: '*'
          path: /**
    binaries:
    - path: /usr/local/bin/claude
    - path: /usr/local/bin/openclaw
PEOF
      openshell policy set --policy /tmp/nemoclaw-recovery-policy.yaml --wait "$SANDBOX_NAME" 2>&1
      info "Network policy updated with local endpoints."
      rm -f /tmp/nemoclaw-recovery-policy.yaml
    fi
  else
    info "Network policy already includes local endpoints."
  fi
fi

# ── Step 5b: Apply custom sandbox configurations ────────────────
step "Step 5b/6: Custom sandbox configurations (Gemini, fetch-guard, skills)"

if dry "would run apply-custom-policies.sh"; then
  :
else
  if [ -x "$SCRIPT_DIR/apply-custom-policies.sh" ]; then
    "$SCRIPT_DIR/apply-custom-policies.sh" --sandbox "$SANDBOX_NAME"
  else
    warn "apply-custom-policies.sh not found or not executable. Skipping."
  fi
fi

# ── Step 6: Port forward + services ─────────────────────────────
step "Step 6/6: Port forward and services"

if dry "would start port forward on $DASHBOARD_PORT"; then
  :
else
  openshell forward stop "$DASHBOARD_PORT" "$SANDBOX_NAME" 2>/dev/null || true
  openshell forward start --background "$DASHBOARD_PORT" "$SANDBOX_NAME" 2>&1
  info "Dashboard forwarded on port $DASHBOARD_PORT."
fi

if [ "$START_SERVICES" -eq 1 ]; then
  if dry "would start services via start-services.sh"; then
    :
  else
    info "Starting services (Telegram bridge, etc.)..."
    export SANDBOX_NAME
    "$SCRIPT_DIR/start-services.sh" --sandbox "$SANDBOX_NAME"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Recovery Complete                                   │"
echo "  │                                                      │"
printf "  │  Sandbox:   %-40s│\n" "$SANDBOX_NAME"
if [ -n "$PROVIDER" ]; then
  printf "  │  Provider:  %-40s│\n" "$PROVIDER"
else
  echo "  │  Provider:  (unchanged from before reboot)          │"
fi
printf "  │  Dashboard: http://127.0.0.1:%-24s│\n" "$DASHBOARD_PORT/"
echo "  │                                                      │"
echo "  │  Verify: nemoclaw $SANDBOX_NAME status"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
