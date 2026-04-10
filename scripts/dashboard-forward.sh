#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Supervised dashboard port forward for launchd.
#
# Waits for the sandbox to be ready, then execs `openshell forward start`
# in the foreground. When the forward dies (gateway hiccup, sandbox restart),
# the process exits and launchd restarts it via KeepAlive.
#
# Usage (manual):
#   ./scripts/dashboard-forward.sh                       # auto-detect sandbox
#   ./scripts/dashboard-forward.sh --sandbox mybox       # explicit sandbox
#   ./scripts/dashboard-forward.sh --port 18789          # explicit port

set -euo pipefail

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
DASHBOARD_PORT="${DASHBOARD_PORT:-18789}"
READY_TIMEOUT=300 # seconds to wait for sandbox before giving up

# ── Parse flags ────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a name}"
      shift 2
      ;;
    --port)
      DASHBOARD_PORT="${2:?--port requires a number}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

info() { echo "$(date '+%Y-%m-%d %H:%M:%S') [dashboard-forward] $1"; }

# ── Wait for sandbox to be ready ──────────────────────────────────
# On boot the sandbox may take a few minutes to come up. Poll rather
# than fail immediately so launchd doesn't enter a rapid-restart loop.
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

info "Sandbox ready (waited ${elapsed}s). Starting port forward on ${DASHBOARD_PORT}."

# ── Clean up any stale background forward ─────────────────────────
openshell forward stop "$DASHBOARD_PORT" 2>/dev/null || true

# ── Exec the forward in the foreground ────────────────────────────
# No --background flag: the process stays in the foreground so launchd
# can track it and restart when it exits.
exec openshell forward start "$DASHBOARD_PORT" "$SANDBOX_NAME"
