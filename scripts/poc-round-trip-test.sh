#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# POC round-trip test for runtime config mutability
# Prerequisites:
#   - Patched openshell binary in PATH
#   - Docker image built: nemoclaw-poc:config-mutability
#   - Docker running
#
# This script walks through the full flow interactively.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${GREEN}▸ $1${NC}"; }
info() { echo -e "  ${CYAN}$1${NC}"; }
wait_enter() {
  echo -e "\n  ${YELLOW}Press Enter to continue...${NC}"
  read -r
}

SANDBOX_NAME="poc-test"

step "1. Verify prerequisites"
echo "  openshell: $(openshell --version 2>&1 | head -1)"
echo "  Docker image: $(docker images nemoclaw-poc:config-mutability --format '{{.Repository}}:{{.Tag}} ({{.Size}})' 2>/dev/null || echo 'NOT FOUND')"

step "2. Run nemoclaw onboard"
info "This will create a sandbox using the patched Docker image."
info "When prompted for model, accept the default."
wait_enter
nemoclaw onboard

step "3. Verify config overrides file exists"
info "Checking for config-overrides.json5 in sandbox..."
openshell exec "$SANDBOX_NAME" -- cat /sandbox/.openclaw-data/config-overrides.json5 2>/dev/null || echo "  (file not found — onboard may not have written it)"
wait_enter

step "4. Verify current model setting"
nemoclaw "$SANDBOX_NAME" config-get
wait_enter

step "5. Submit a config change request FROM INSIDE the sandbox"
info "Writing a config change request file that the sandbox proxy will pick up..."
openshell exec "$SANDBOX_NAME" -- bash -c '
mkdir -p /sandbox/.openclaw-data/config-requests
cat > /sandbox/.openclaw-data/config-requests/test-model-change.json <<EOF
{"key": "agents.defaults.model.primary", "value": "inference/nvidia/nemotron-3-nano-30b-a3b"}
EOF
echo "Request file written."
ls -la /sandbox/.openclaw-data/config-requests/
'
info "The sandbox proxy should pick this up within 5 seconds and submit to gateway."
info "Check the OpenShell TUI — you should see a CONFIG chunk appear."
echo ""
info "Open the TUI in another terminal:"
info "  openshell tui"
info ""
info "Navigate to sandbox → Network Rules tab (press [r])"
info "You should see: CONFIG  agents.defaults.model.primary  [pending]"
info "Press [a] to approve it."
wait_enter

step "6. Verify the change was applied"
info "After approval, the sandbox poll loop should write the overrides file."
info "Waiting 15 seconds for the poll loop to detect and apply..."
sleep 15

info "Current overrides file:"
openshell exec "$SANDBOX_NAME" -- cat /sandbox/.openclaw-data/config-overrides.json5 2>/dev/null || echo "  (not written yet)"
echo ""

info "Config-get:"
nemoclaw "$SANDBOX_NAME" config-get

step "7. Test security: gateway.* should be blocked"
info "Attempting to submit a gateway.auth.token change (should be blocked)..."
openshell exec "$SANDBOX_NAME" -- bash -c '
cat > /sandbox/.openclaw-data/config-requests/evil.json <<EOF
{"key": "gateway.auth.token", "value": "stolen-token"}
EOF
'
sleep 6
info "Check sandbox logs for 'gateway.* blocked' message."

step "8. Test host-side direct set (bypasses approval)"
nemoclaw "$SANDBOX_NAME" config-set --key channels.defaults.configWrites --value false
nemoclaw "$SANDBOX_NAME" config-get

step "Done!"
info "If all steps passed, the round-trip config mutability POC is working."
info "Clean up with: nemoclaw $SANDBOX_NAME destroy --yes"
