#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Gateway watchdog: ensures openclaw-gateway is running inside the sandbox.
#
# Background:
#   OpenClaw's in-sandbox gateway has no supervisor. When anything kills
#   it (notably: `openclaw doctor` triggers a self-SIGTERM ~6s later with
#   close code 1012 "service restart"), nothing respawns it. The dashboard
#   forward on port 18789 then returns empty replies and the health check
#   goes red.
#
#   The health-check LaunchAgent runs `openclaw doctor` every 10 minutes,
#   which reliably kills the gateway in embedded-mode (unpaired) sandboxes.
#   This watchdog closes the loop.
#
# Behavior:
#   1. Check if openclaw-gateway is running inside the sandbox via
#      containerd task exec (NOT SSH — SSH+openclaw CLI calls are what
#      trigger the kill in the first place).
#   2. If alive → exit 0 silently.
#   3. If dead → relaunch via SSH with setsid+nohup so the new process
#      fully detaches from the SSH session.
#
# Usage (manual):
#   ./scripts/gateway-watchdog.sh                    # default sandbox
#   ./scripts/gateway-watchdog.sh --sandbox mybox    # named sandbox
#   ./scripts/gateway-watchdog.sh --verbose          # log on healthy too
#
# Designed for launchd StartInterval=60.

set -euo pipefail

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
CLUSTER_CONTAINER="${NEMOCLAW_CLUSTER_CONTAINER:-openshell-cluster-nemoclaw}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
VERBOSE=0

# ── Parse flags ────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a name}"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [gateway-watchdog] $1"; }
log_verbose() {
  [ "$VERBOSE" -eq 1 ] && log "$1"
  return 0
}

# ── Find the running sandbox container ────────────────────────────
# Same logic as apply-custom-policies.sh — after reboot there can be
# stale `sandbox-from` entries, so intersect against tasks list.
find_container() {
  local running_tasks candidates
  running_tasks="$(docker exec "$CLUSTER_CONTAINER" ctr -n k8s.io tasks list 2>/dev/null \
    | awk 'NR>1 && $3=="RUNNING" {print $1}')"
  candidates="$(docker exec "$CLUSTER_CONTAINER" ctr -n k8s.io containers list 2>/dev/null \
    | grep 'sandbox-from' | awk '{print $1}')"
  for cid in $candidates; do
    if printf '%s\n' "$running_tasks" | grep -qx "$cid"; then
      echo "$cid"
      return 0
    fi
  done
  return 1
}

# ── Preflight ──────────────────────────────────────────────────────
if ! docker info >/dev/null 2>&1; then
  log "Docker is not running. Skipping check."
  exit 0
fi

CONTAINER_ID="$(find_container || true)"
if [ -z "$CONTAINER_ID" ]; then
  log "Sandbox container not found. Is the sandbox running? Skipping check."
  exit 0
fi

# Find the openclaw-gateway PID inside the sandbox. Empty if not running.
#
# Matches argv[0] exactly — a substring grep would match the ctr task exec
# wrapper process itself (whose cmdline contains "openclaw-gateway" as a
# search pattern), producing a false positive.
#
# We can't use netstat/ss/ip here: `ctr task exec` enters the container's
# pid+mount namespace but a *different* network namespace than the pod's
# actual one (empirically verified — ip addr shows only loopback), so a
# port-binding check would always come back negative even when the gateway
# is serving 18789 correctly.
find_gateway_pid() {
  # shellcheck disable=SC2016 # single quotes intentional — runs inside sandbox
  docker exec -i "$CLUSTER_CONTAINER" ctr -n k8s.io task exec \
    --exec-id "watchdog-pid-$$-$RANDOM" --user 0 "$CONTAINER_ID" sh -c '
    for f in /proc/[0-9]*/cmdline; do
      first=$(tr "\0" "\n" < "$f" 2>/dev/null | head -1)
      if [ "$first" = "openclaw-gateway" ]; then
        pid=${f#/proc/}
        echo "${pid%/cmdline}"
        return 0
      fi
    done
  ' 2>/dev/null || true
}

GW_PID=$(find_gateway_pid)
if [ -n "$GW_PID" ]; then
  log_verbose "Gateway healthy (PID $GW_PID)."
  exit 0
fi

# ── Gateway is dead — relaunch it ─────────────────────────────────
log "Gateway not running. Relaunching on port ${GATEWAY_PORT}..."

ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" \
  "setsid sh -c \"nohup openclaw gateway run --port ${GATEWAY_PORT} --auth token --bind loopback >/tmp/gateway.log 2>&1 </dev/null &\"" \
  2>/dev/null || true

# ── Wait for the gateway process to appear (up to 45s) ────────────
# Cold-start is slow: node spawn + config load + channel setup take
# 15-20s before the openclaw-gateway process even forks. Keep polling
# so we don't report false success on a transient pre-fork process.
elapsed=0
while [ "$elapsed" -lt 45 ]; do
  sleep 3
  elapsed=$((elapsed + 3))
  NEW_PID=$(find_gateway_pid)
  if [ -n "$NEW_PID" ]; then
    log "Gateway relaunched (PID $NEW_PID, took ${elapsed}s)."
    exit 0
  fi
done

log "ERROR: Gateway failed to start within 45s. See /tmp/gateway.log inside sandbox."
exit 1
