#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Supervised Telegram bridge for launchd.
#
# Waits for the sandbox to be ready, writes a PID file for the health
# check, then execs the bridge in the foreground. When the bridge dies,
# launchd restarts it via KeepAlive.
#
# Usage (manual):
#   ./scripts/telegram-bridge-wrapper.sh
#   SANDBOX_NAME=mybox ./scripts/telegram-bridge-wrapper.sh

set -euo pipefail

SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
READY_TIMEOUT=300
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PIDDIR="/tmp/nemoclaw-services-${SANDBOX_NAME}"

info() { echo "$(date '+%Y-%m-%d %H:%M:%S') [telegram-bridge] $1"; }

# ── Preflight: require tokens ─────────────────────────────────────
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  info "TELEGRAM_BOT_TOKEN not set. Exiting."
  exit 1
fi
if [ -z "${NVIDIA_API_KEY:-}" ]; then
  info "NVIDIA_API_KEY not set. Exiting."
  exit 1
fi

# ── Wait for sandbox to be ready ──────────────────────────────────
info "Waiting for sandbox '$SANDBOX_NAME' to be ready (timeout: ${READY_TIMEOUT}s)..."

elapsed=0
while true; do
  if openshell sandbox get "$SANDBOX_NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -qiw "ready"; then
    break
  fi
  if [ "$elapsed" -ge "$READY_TIMEOUT" ]; then
    info "Sandbox not ready after ${READY_TIMEOUT}s. Exiting (launchd will retry)."
    exit 1
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

info "Sandbox ready (waited ${elapsed}s). Starting Telegram bridge."

# ── Write PID file for health check ──────────────────────────────
mkdir -p "$PIDDIR"

cleanup() {
  rm -f "$PIDDIR/telegram-bridge.pid"
}
trap cleanup EXIT

# ── Run bridge in foreground ─────────────────────────────────────
# Use exec so launchd tracks the node process directly.
# Write PID file first (exec replaces this process, keeping the same PID).
echo $$ > "$PIDDIR/telegram-bridge.pid"
exec node "$SCRIPT_DIR/telegram-bridge.js"
