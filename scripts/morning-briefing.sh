#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Morning Briefing — sends a daily briefing to Telegram via the sandbox agent.
# Designed to be called by cron or launchd on the host.
#
# Usage: ./scripts/morning-briefing.sh [--chat-id <id>]
#
# Requires: TELEGRAM_BOT_TOKEN in environment, SSH access to sandbox.

set -euo pipefail

# Source credentials (launchd doesn't load shell profiles).
# Extract only export lines from ~/.zshrc since bash can't run zsh-specific syntax.
# shellcheck disable=SC1090
if [[ -f "$HOME/.zshrc" ]]; then
  eval "$(grep '^export [A-Za-z_]' "$HOME/.zshrc" 2>/dev/null)" || true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
CHAT_ID="${1:---chat-id}"

# If first arg is --chat-id, take the next arg
if [[ "$CHAT_ID" == "--chat-id" ]]; then
  CHAT_ID="${2:-${TELEGRAM_CHAT_ID:-}}"
fi

# Use the same session ID as the Telegram bridge (tg-{chatId}) so that
# replies to the briefing in Telegram carry full conversation context.
SESSION_ID="tg-${CHAT_ID}"

if [[ -z "$CHAT_ID" || -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "Error: TELEGRAM_CHAT_ID and TELEGRAM_BOT_TOKEN must be set" >&2
  exit 1
fi

# Run agent in sandbox
RESPONSE=$(ssh -o ConnectTimeout=10 "openshell-${SANDBOX_NAME}" \
  "export NVIDIA_API_KEY=unused && nemoclaw-start openclaw agent --agent main \
   -m 'Give me my morning briefing' --session-id ${SESSION_ID}" 2>&1 \
  | grep -v -e '\[SECURITY\]' -e 'Setting up NemoClaw' -e '\[gateway\]' -e 'UNDICI' \
           -e '(node:' -e 'Use .node' -e 'pairing required' -e 'CAP_SET' \
           -e 'privilege separation' -e 'Gateway target:' -e 'Source: local loopback' \
           -e 'Config: /sandbox' -e 'Bind: loopback' -e 'getaddrinfo' \
           -e 'tools websearch' -e 'Gateway agent failed' \
           -e 'GatewayClientRequestError' -e 'abnormal closure' \
           -e 'tools cron failed' || true)

# ── Detect error responses ───────────────────────────────────────
# The agent may return an error message instead of a real briefing.
# Detect known failure patterns and flag them so the health check can
# distinguish success from failure, and the user gets a clear alert.
BRIEFING_STATUS="ok"

if [[ -z "$RESPONSE" ]]; then
  RESPONSE="⚠️ Morning briefing failed — agent returned empty response."
  BRIEFING_STATUS="error:empty"
elif echo "$RESPONSE" | grep -qiE "timed? out|timeout|ETIMEDOUT|request.*(fail|error)|LLM.*(fail|error|timed)|inference.*(fail|error|unavailable)|connection refused|ECONNREFUSED|502|503|rate.limit"; then
  # Wrap the error so the user knows this isn't a real briefing
  RESPONSE="⚠️ Morning briefing failed — agent error:

${RESPONSE}"
  BRIEFING_STATUS="error:llm"
fi

# Write status for health-check.sh to read
STATUS_FILE="/tmp/nemoclaw-briefing-status.json"
printf '{"timestamp":"%s","status":"%s","chat_id":"%s"}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$BRIEFING_STATUS" "$CHAT_ID" \
  > "$STATUS_FILE"

# Send to Telegram (try Markdown first, fall back to plain text)
RESULT=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  --data-urlencode "text=${RESPONSE}" 2>&1)

if echo "$RESULT" | grep -q '"ok":false'; then
  # Markdown failed (unbalanced formatting) — retry plain text
  RESULT=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode "text=${RESPONSE}" 2>&1)
fi

if echo "$RESULT" | grep -q '"ok":true'; then
  echo "[$(date)] Morning briefing sent to chat $CHAT_ID (status: $BRIEFING_STATUS)"
else
  echo "[$(date)] Failed to send briefing: $RESULT" >&2
  # Update status file with send failure too
  printf '{"timestamp":"%s","status":"error:send","chat_id":"%s"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CHAT_ID" \
    > "$STATUS_FILE"
  exit 1
fi
