#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# OpenRouter usage monitor — detects when the free-tier RPD budget is
# exhausted and inference falls back to paid models (GLM 5.2).
#
# OpenRouter's /v1/key endpoint exposes paid credit usage (usage_monthly,
# limit_remaining) but NOT the free-model RPD counter (that's only surfaced
# via X-RateLimit-* headers on 429s). So we detect free-tier exhaustion
# indirectly: when the 1,000 RPD free budget is hit, calls 429 and fall back
# to the paid GLM 5.2 fallback, which shows up as usage_monthly increasing.
#
# An increase in usage_monthly between runs = free tier exhausted + paid
# fallback active. That's the single signal we alert on.
#
# Usage:
#   ./scripts/openrouter-usage-monitor.sh                 # check + alert on increase
#   ./scripts/openrouter-usage-monitor.sh --alert telegram # alert via Telegram on increase
#   ./scripts/openrouter-usage-monitor.sh --status         # print current state, no alert
#
# Requires: OPENROUTER_API_KEY in environment, optionally TELEGRAM_BOT_TOKEN
# and TELEGRAM_CHAT_ID for --alert telegram.

set -euo pipefail

ALERT_METHOD=""
STATUS_ONLY=0
STATE_FILE="${HOME}/.nemoclaw/openrouter-usage.state"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alert)
      ALERT_METHOD="${2:?--alert requires a method (telegram)}"
      shift 2
      ;;
    --status)
      STATUS_ONLY=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "Error: OPENROUTER_API_KEY must be set" >&2
  exit 1
fi

# Fetch current key state.
RESPONSE=$(curl -s --max-time 15 https://openrouter.ai/api/v1/key \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" 2>&1) || {
  echo "Error: failed to query OpenRouter /v1/key: ${RESPONSE}" >&2
  exit 1
}

# Parse fields with node (jq may not be installed).
read -r USAGE_MONTHLY LIMIT LIMIT_REMAINING IS_FREE_TIER <<< "$(printf '%s' "$RESPONSE" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
    try {
      const j=JSON.parse(d).data;
      process.stdout.write([j.usage_monthly||0, j.limit||0, j.limit_remaining||0, j.is_free_tier].join(' '));
    } catch(e) { process.stdout.write('0 0 0 false'); }
  });
")"

# Load previous baseline.
PREV_USAGE=0
if [[ -f "$STATE_FILE" ]]; then
  PREV_USAGE=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

# Save current as the new baseline.
mkdir -p "$(dirname "$STATE_FILE")"
echo "$USAGE_MONTHLY" > "$STATE_FILE"

# Compute delta (paid spend since last check).
DELTA=$(( USAGE_MONTHLY - PREV_USAGE ))

# Print status.
echo "OpenRouter usage:"
echo "  Free tier:     ${IS_FREE_TIER}"
echo "  Paid usage:    \$${USAGE_MONTHLY} / \$${LIMIT} (monthly cap, resets monthly)"
echo "  Remaining:     \$${LIMIT_REMAINING}"
echo "  Since last:    \$${DELTA} paid spend"
if [[ "$DELTA" -gt 0 ]]; then
  echo "  ⚠ Free-tier RPD exhausted — paid fallback (GLM 5.2) is active."
elif [[ "$USAGE_MONTHLY" -gt 0 ]]; then
  echo "  Paid fallback was used earlier today; no new paid spend this check."
else
  echo "  ✓ All inference on free tier; no paid fallback usage."
fi

# Status-only mode: exit here.
if [[ "$STATUS_ONLY" -eq 1 ]]; then
  exit 0
fi

# Alert only when paid usage increased (free tier exhausted → fallback active).
if [[ "$DELTA" -gt 0 ]] && [[ "$ALERT_METHOD" == "telegram" ]]; then
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "Warning: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not set; cannot alert" >&2
    exit 0
  fi
  ALERT_TEXT="⚠ OpenRouter: free-tier RPD exhausted, paid fallback active.
Paid usage: \$${USAGE_MONTHLY} / \$${LIMIT} (+\$${DELTA} since last check).
Remaining monthly credit: \$${LIMIT_REMAINING}.
Inference is now billing against your paid cap until the free RPD window resets."
  RESULT=$(curl -s -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=${ALERT_TEXT}" 2>&1)
  if echo "$RESULT" | grep -q '"ok":true'; then
    echo "Alert sent to Telegram"
  else
    echo "Warning: Failed to send Telegram alert" >&2
  fi
fi
