#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

command_name="${1:-ensure}"

RUNDIR="${HOME}/.openclaw/run"
LOGDIR="${HOME}/.openclaw/logs"
PIDFILE="${RUNDIR}/gateway.pid"
LOCKFILE="${RUNDIR}/gateway.lock"
LOGFILE="${LOGDIR}/gateway.log"

mkdir -p "$RUNDIR" "$LOGDIR"

info() { printf '%s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1" >&2; }
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

read_pid() {
  if [ -f "$PIDFILE" ]; then
    tr -d '\n' <"$PIDFILE"
  fi
}

pid_running() {
  local pid="${1:-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

gateway_healthy() {
  openclaw gateway status --deep >/dev/null 2>&1
}

clear_stale_pidfile() {
  local pid
  pid="$(read_pid || true)"
  if [ -n "$pid" ] && ! pid_running "$pid"; then
    rm -f "$PIDFILE"
  fi
}

acquire_lock() {
  if ( set -o noclobber; printf '%s\n' "$$" >"$LOCKFILE" ) 2>/dev/null; then
    trap 'rm -f "$LOCKFILE"' EXIT INT TERM
    return 0
  fi

  local lock_pid=""
  if [ -f "$LOCKFILE" ]; then
    lock_pid="$(tr -d '\n' <"$LOCKFILE" 2>/dev/null || true)"
  fi
  if [ -n "$lock_pid" ] && pid_running "$lock_pid"; then
    for _ in 1 2 3 4 5 6 7 8; do
      if gateway_healthy; then
        return 0
      fi
      sleep 1
    done
    fail "gateway bootstrap is already running under PID ${lock_pid}"
  fi

  printf '%s\n' "$$" >"$LOCKFILE"
  trap 'rm -f "$LOCKFILE"' EXIT INT TERM
}

start_gateway() {
  nohup openclaw gateway run >"$LOGFILE" 2>&1 < /dev/null &
  local pid=$!
  printf '%s\n' "$pid" >"$PIDFILE"
  info "started-gateway:${pid}"
}

ensure_gateway() {
  acquire_lock
  clear_stale_pidfile

  if gateway_healthy; then
    local existing_pid
    existing_pid="$(read_pid || true)"
    if [ -n "$existing_pid" ] && pid_running "$existing_pid"; then
      info "gateway-ready:${existing_pid}"
    else
      info "gateway-ready:external"
    fi
    return 0
  fi

  local pid
  pid="$(read_pid || true)"
  if [ -z "$pid" ] || ! pid_running "$pid"; then
    start_gateway
    pid="$(read_pid || true)"
  fi

  for _ in 1 2 3 4 5 6 7 8; do
    if gateway_healthy; then
      info "gateway-ready:${pid:-unknown}"
      return 0
    fi
    if [ -n "$pid" ] && ! pid_running "$pid"; then
      warn "gateway process exited before becoming healthy"
      break
    fi
    sleep 2
  done

  fail "gateway failed to become healthy; see ${LOGFILE}"
}

status_gateway() {
  clear_stale_pidfile
  local pid
  pid="$(read_pid || true)"
  local state="stopped"
  if [ -n "$pid" ] && pid_running "$pid"; then
    state="running"
  fi
  local health="unhealthy"
  if gateway_healthy; then
    health="healthy"
  fi
  printf 'state=%s\n' "$state"
  printf 'health=%s\n' "$health"
  printf 'pid=%s\n' "${pid:-}"
  printf 'log=%s\n' "$LOGFILE"
}

stop_gateway() {
  clear_stale_pidfile
  local pid
  pid="$(read_pid || true)"
  if [ -z "$pid" ]; then
    info "gateway-not-running"
    return 0
  fi
  if pid_running "$pid"; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      if ! pid_running "$pid"; then
        break
      fi
      sleep 1
    done
    if pid_running "$pid"; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$PIDFILE"
  info "gateway-stopped:${pid}"
}

case "$command_name" in
  ensure)
    ensure_gateway
    ;;
  status)
    status_gateway
    ;;
  stop)
    stop_gateway
    ;;
  *)
    fail "usage: nemoclaw-gateway.sh [ensure|status|stop]"
    ;;
esac
