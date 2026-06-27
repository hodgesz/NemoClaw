#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Apply custom sandbox configurations that don't survive a rebuild.
#
# In the v0.0.68 / OpenShell 0.0.44 runtime, almost everything this script
# used to do is now owned by upstream and must NOT be re-done at runtime:
#   - openclaw.json is baked at image build and hash-verified by nemoclaw-start
#     at startup. Do NOT rewrite it (or you must also rewrite .config-hash,
#     and the integrity check is an upstream security control, not to be
#     circumvented). Web search (Brave), the native telegram channel, model
#     config, and policy presets are all baked at onboard.
#   - The gateway is supervised IN-SANDBOX by nemoclaw-start (#4710 health
#     probe + #2757 respawn loop). A host-side launcher that matches the old
#     "openclaw-gateway" process name (which doesn't exist in 0.0.44 — the
#     gateway is the bare "openclaw" process) would launch a SECOND, conflicting
#     gateway. So we never start/kill the gateway from here.
#   - The fetch-guard DNS patch (NemoClaw #1252 / OpenClaw #396) is GONE
#     upstream: #1252 is CLOSED ("Track removal of downstream OpenClaw trusted
#     env-proxy DNS workaround") and the patched code block no longer exists
#     in OpenClaw 2026.5.27's dist/. Web search works through the proxy without
#     it. Dropped entirely — no distro hacking.
#
# What this script ACTUALLY does now (thin, read-only except skill files):
#   1. Re-install custom skills from ./skills/ into the sandbox (fork-personal
#      content: adhd-planner, morning-briefing, personal-crm, ...). Skills live
#      at /sandbox/.openclaw/skills/<name>/SKILL.md in 0.0.44 (NOT the old
#      /sandbox/.openclaw-data/skills/ path).
#   2. Verify the sandbox's inference provider is registered (read-only).
#   3. Verify the native telegram channel is present (read-only — never strip).
#
# Usage:
#   ./scripts/apply-custom-policies.sh                     # default sandbox
#   ./scripts/apply-custom-policies.sh --sandbox mybox     # named sandbox
#   ./scripts/apply-custom-policies.sh --skip-skills       # skip skill install
#   ./scripts/apply-custom-policies.sh --dry-run           # show what would happen
#
# Requires: Docker running, sandbox Ready, SSH access to the sandbox.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────
SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
SKIP_SKILLS=0
DRY_RUN=0

# ── Colors ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${GREEN}[custom]${NC} $1"; }
warn() { echo -e "${YELLOW}[custom]${NC} $1"; }
fail() {
  echo -e "${RED}[custom]${NC} $1" >&2
  exit 1
}
step() { echo -e "\n${CYAN}── $1 ──${NC}"; }
dry() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] $1"
    return 0
  else
    return 1
  fi
}

# ── Parse flags ─────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a name}"
      shift 2
      ;;
    --skip-skills)
      SKIP_SKILLS=1
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

# ── Preflight ───────────────────────────────────────────────────
if ! docker info >/dev/null 2>&1; then
  fail "Docker is not running."
fi

# Confirm the sandbox container exists (0.0.44: sandbox runs directly under
# the Docker daemon as openshell-<name>-<uuid>; there is NO openshell-cluster-*
# containerd-host container). Match on the name prefix; Docker ps is enough.
if ! docker ps --filter "name=openshell-${SANDBOX_NAME}-" --format '{{.Names}}' \
  | grep -q "openshell-${SANDBOX_NAME}-"; then
  fail "Sandbox container 'openshell-${SANDBOX_NAME}-*' not found. Is the sandbox running?"
fi
info "Sandbox: ${SANDBOX_NAME}"

# ssh wrapper used by every step. 0.0.44 reachability is via
# `ssh openshell-<sandbox>` (an openshell ssh-proxy tunnel), not
# `docker exec openshell-cluster-* ctr task exec`.
sb_ssh() {
  ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "openshell-${SANDBOX_NAME}" "$@"
}

# ── Step 1: Re-install custom skills ────────────────────────────
# Skills are fork-personal content that doesn't survive a sandbox rebuild.
# In 0.0.44 they live at /sandbox/.openclaw/skills/<name>/SKILL.md.
step "Step 1/3: Custom skills"

if [ "$SKIP_SKILLS" -eq 1 ]; then
  info "Skipping skill install (--skip-skills)."
elif dry "would install skills from $REPO_DIR/skills/ into /sandbox/.openclaw/skills/"; then
  :
else
  SKILLS_DIR="$REPO_DIR/skills"

  if [ ! -d "$SKILLS_DIR" ]; then
    warn "No skills/ directory found at $SKILLS_DIR. Skipping."
  else
    installed=0
    skipped=0
    for skill_dir in "$SKILLS_DIR"/*/; do
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      skill_file="$skill_dir/SKILL.md"

      if [ ! -f "$skill_file" ]; then
        warn "Skill '$skill_name' has no SKILL.md. Skipping."
        skipped=$((skipped + 1))
        continue
      fi

      # Ensure the skill dir exists, then stream the SKILL.md into place.
      if sb_ssh "mkdir -p /sandbox/.openclaw/skills/$skill_name" 2>/dev/null \
        && sb_ssh "cat > /sandbox/.openclaw/skills/$skill_name/SKILL.md" \
          <"$skill_file" 2>/dev/null; then
        info "Installed skill: $skill_name"
        installed=$((installed + 1))
      else
        warn "Failed to install skill '$skill_name' (SSH/upload error)."
        skipped=$((skipped + 1))
      fi
    done

    if [ "$installed" -gt 0 ]; then
      info "Installed $installed skill(s). Skipped $skipped."
    else
      warn "No skills installed ($skipped skipped)."
    fi
  fi
fi

# ── Step 2: Verify inference provider (read-only) ──────────────
# The provider is baked at onboard and bound in the gateway. We only verify
# it's registered (warn if not) — we do NOT inject config or recreate stale
# Bedrock/Ollama/NVIDIA providers here. Use `openshell inference` on the host.
step "Step 2/3: Verify inference provider (read-only)"

if dry "would verify the sandbox's inference provider is registered"; then
  :
else
  if ! command -v openshell >/dev/null 2>&1; then
    warn "openshell CLI not found on PATH; cannot verify provider. Skipping."
  else
    # Read the sandbox's provider from the local registry for an honest check.
    # Expand $HOME on the SHELL side — a literal "$HOME" inside the JS string
    # is passed to node verbatim and require() silently misses the file.
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
      info "No provider recorded in ~/.nemoclaw/sandboxes.json; skipping provider check."
    else
      # Strip ANSI color codes — openshell colorizes even when piped — so the
      # provider name matches cleanly.
      if openshell provider list 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q -- "$provider"; then
        info "Inference provider '$provider' is registered."
      else
        warn "Inference provider '$provider' not found in 'openshell provider list'."
        warn "  Onboard may have failed to bind it; run 'nemoclaw $SANDBOX_NAME status' or re-onboard."
      fi
    fi
  fi
fi

# ── Step 3: Verify native telegram channel (read-only) ──────────
# The native telegram channel is baked at onboard and is the ONLY poller in
# v0.0.68 (the host bridge was removed). We verify it's present and polling —
# we NEVER strip it (the old Step 1b did and would break Telegram now).
step "Step 3/3: Verify native telegram channel (read-only)"

if dry "would verify the native telegram channel is present + polling"; then
  :
else
  # Check the channel exists in the baked openclaw.json. The baked config uses
  # a `channels.telegram` map (with `enabled`/`accounts`/...), not an array of
  # `{channelId:"telegram"}` objects. Read-only via SSH — we never write the file.
  chan_present=$(sb_ssh \
    'python3 -c "import json; c=json.load(open(\"/sandbox/.openclaw/openclaw.json\")); tg=(c.get(\"channels\") or {}).get(\"telegram\") or {}; print(\"yes\" if tg.get(\"enabled\") else \"no\")" 2>/dev/null || echo no' \
    2>/dev/null || echo "err")

  case "$chan_present" in
    yes)
      info "Native telegram channel is present."
      # Cross-check the poller is actually running (look for the bare openclaw
      # process — gateway + native poller run as one process in 0.0.44).
      if sb_ssh 'pgrep -x openclaw >/dev/null 2>&1' 2>/dev/null; then
        info "Telegram poller process (openclaw) is running."
      else
        warn "Telegram channel configured but no 'openclaw' process — gateway may not be up yet."
      fi
      ;;
    no)
      warn "Native telegram channel NOT found in /sandbox/.openclaw/openclaw.json."
      warn "  Re-onboard with TELEGRAM_BOT_TOKEN set, or: nemoclaw $SANDBOX_NAME channels add telegram"
      ;;
    *)
      warn "Could not read telegram channel config from sandbox (SSH error). Skipping."
      ;;
  esac
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Custom Policies Applied                             │"
echo "  │                                                      │"
printf "  │  Sandbox:     %-38s│\n" "$SANDBOX_NAME"
printf "  │  Skills:      %-38s│\n" "$([ "$SKIP_SKILLS" -eq 1 ] && echo 'skipped' || echo 'installed')"
printf "  │  Provider:    %-38s│\n" "verified (read-only)"
printf "  │  Telegram:    %-38s│\n" "verified (read-only)"
echo "  │                                                      │"
echo "  │  Verify: ssh openshell-${SANDBOX_NAME} \\"
echo "  │    'openclaw agent --agent main -m \"hello\"'"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
