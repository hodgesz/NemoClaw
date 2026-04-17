#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Check the health of all NemoClaw services and optionally alert on failures.
#
# Probes Docker, the OpenShell gateway, sandbox readiness, SSH tunnel,
# inference endpoint, port forward, Telegram bridge, and (optionally)
# the in-sandbox OpenClaw agent via `openclaw doctor`.
#
# Designed to run interactively or on a timer (cron / launchd).
# When --alert is set, only sends a notification on failure — silent on success.
#
# Usage:
#   ./scripts/health-check.sh                            # check all, print status
#   ./scripts/health-check.sh --sandbox mybox            # check a named sandbox
#   ./scripts/health-check.sh --alert telegram           # alert via Telegram on failure
#   ./scripts/health-check.sh --json                     # output JSON (for scripting)
#   ./scripts/health-check.sh --quiet                    # exit code only (0=healthy)
#   ./scripts/health-check.sh --skip docker,ssh          # skip specific checks
#   ./scripts/health-check.sh --auto-fix                 # attempt to fix failures before alerting
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Script error (bad arguments, missing dependencies)
#
# Related upstream issues:
#   - NemoClaw #233  (observability / metrics proposal)
#   - NemoClaw #1430 (Docker HEALTHCHECK missing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────
SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
GATEWAY_NAME="${NEMOCLAW_GATEWAY_NAME:-nemoclaw}"
DASHBOARD_PORT="${DASHBOARD_PORT:-18789}"
ALERT_METHOD=""      # empty = no alerting
OUTPUT_MODE="pretty" # pretty | json | quiet
SKIP_CHECKS=""       # comma-separated list of checks to skip
AUTO_FIX=0           # when set, attempt to fix failures before alerting

# ── Colors (disabled when not a terminal or in json/quiet mode) ─
if [ -t 1 ] && [ "$OUTPUT_MODE" = "pretty" ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' CYAN='' NC=''
fi

# ── Parse flags ─────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a name}"
      shift 2
      ;;
    --gateway)
      GATEWAY_NAME="${2:?--gateway requires a name}"
      shift 2
      ;;
    --port)
      DASHBOARD_PORT="${2:?--port requires a number}"
      shift 2
      ;;
    --alert)
      ALERT_METHOD="${2:?--alert requires a method (telegram)}"
      shift 2
      ;;
    --json)
      OUTPUT_MODE="json"
      GREEN='' RED='' YELLOW='' CYAN='' NC=''
      shift
      ;;
    --quiet | -q)
      OUTPUT_MODE="quiet"
      GREEN='' RED='' YELLOW='' CYAN='' NC=''
      shift
      ;;
    --skip)
      SKIP_CHECKS="${2:?--skip requires a comma-separated list}"
      shift 2
      ;;
    --auto-fix)
      AUTO_FIX=1
      shift
      ;;
    --help | -h)
      sed -n '2,/^$/s/^# *//p' "$0"
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
RESULTS=()

should_skip() {
  echo ",$SKIP_CHECKS," | grep -qi ",$1,"
}

# Escape special characters for JSON string values.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

record() {
  local name="$1" status="$2" detail="$3"
  RESULTS+=("${name}|${status}|${detail}")
  case "$status" in
    pass) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
    fail) CHECKS_FAILED=$((CHECKS_FAILED + 1)) ;;
    skip) CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)) ;;
  esac

  if [ "$OUTPUT_MODE" = "pretty" ]; then
    case "$status" in
      pass) echo -e "  ${GREEN}✓${NC} ${name}: ${detail}" ;;
      fail) echo -e "  ${RED}✗${NC} ${name}: ${detail}" ;;
      skip) echo -e "  ${YELLOW}–${NC} ${name}: skipped" ;;
    esac
  fi
}

# ── Individual checks ──────────────────────────────────────────

check_docker() {
  if should_skip "docker"; then
    record "docker" "skip" ""
    return
  fi
  if docker info >/dev/null 2>&1; then
    record "docker" "pass" "Docker daemon running"
  else
    record "docker" "fail" "Docker daemon not responding"
  fi
}

check_gateway() {
  if should_skip "gateway"; then
    record "gateway" "skip" ""
    return
  fi
  if ! command -v openshell >/dev/null 2>&1; then
    record "gateway" "fail" "openshell CLI not found"
    return
  fi
  local status_out
  # Strip ANSI escape codes — openshell embeds colors that break word-boundary matching.
  status_out="$(openshell status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
  # Use word-boundary matching to avoid "unhealthy" matching "healthy"
  # and "disconnected" matching "connected".
  if echo "$status_out" | grep -qiw "healthy"; then
    record "gateway" "pass" "Gateway '$GATEWAY_NAME' healthy"
  elif echo "$status_out" | grep -qiw "connected"; then
    record "gateway" "pass" "Gateway '$GATEWAY_NAME' connected"
  else
    record "gateway" "fail" "Gateway not healthy"
  fi
}

check_sandbox() {
  if should_skip "sandbox"; then
    record "sandbox" "skip" ""
    return
  fi
  if ! command -v openshell >/dev/null 2>&1; then
    record "sandbox" "fail" "openshell CLI not found"
    return
  fi
  local sandbox_out
  sandbox_out="$(openshell sandbox get "$SANDBOX_NAME" 2>&1 || true)"
  # Check failure cases first — "not ready" contains "ready" so order matters.
  if echo "$sandbox_out" | grep -qi "not found\|does not exist"; then
    record "sandbox" "fail" "Sandbox '$SANDBOX_NAME' not found"
  elif echo "$sandbox_out" | grep -qi "not ready"; then
    record "sandbox" "fail" "Sandbox '$SANDBOX_NAME' not ready"
  elif echo "$sandbox_out" | grep -qiw "ready"; then
    record "sandbox" "pass" "Sandbox '$SANDBOX_NAME' ready"
  else
    record "sandbox" "fail" "Sandbox '$SANDBOX_NAME' state unknown"
  fi
}

check_ssh() {
  if should_skip "ssh"; then
    record "ssh" "skip" ""
    return
  fi
  local ssh_out
  ssh_out=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "openshell-${SANDBOX_NAME}" 'echo ok' 2>&1 || true)
  if [ "$ssh_out" = "ok" ]; then
    record "ssh" "pass" "SSH tunnel to sandbox healthy"
  else
    record "ssh" "fail" "SSH tunnel broken (${ssh_out:0:80})"
  fi
}

check_inference() {
  if should_skip "inference"; then
    record "inference" "skip" ""
    return
  fi
  # Check common inference endpoints; at least one should respond
  local found=0 detail=""

  # LiteLLM (Bedrock proxy)
  if curl -sf --max-time 3 http://localhost:4000/health >/dev/null 2>&1; then
    found=1
    detail="LiteLLM (port 4000)"
  fi

  # Ollama
  if curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    found=1
    detail="${detail:+$detail, }Ollama (port 11434)"
  fi

  # vLLM / NIM
  if curl -sf --max-time 3 http://localhost:8000/v1/models >/dev/null 2>&1; then
    found=1
    detail="${detail:+$detail, }vLLM/NIM (port 8000)"
  fi

  # NVIDIA cloud (check via provider list if available)
  if command -v openshell >/dev/null 2>&1; then
    if openshell provider list 2>&1 | grep -q "nvidia-prod"; then
      found=1
      detail="${detail:+$detail, }NVIDIA cloud provider"
    fi
  fi

  if [ "$found" -eq 1 ]; then
    record "inference" "pass" "$detail"
  else
    record "inference" "fail" "No inference endpoint responding"
  fi
}

check_dashboard() {
  if should_skip "dashboard"; then
    record "dashboard" "skip" ""
    return
  fi
  # Use -o /dev/null -w to get HTTP status; accept any response (even errors)
  # as proof the port forward is alive. curl exit 7 = connection refused (down),
  # exit 52 = empty reply (gateway restarting). Only 7 is a hard failure.
  local http_code curl_exit
  http_code=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:${DASHBOARD_PORT}/" 2>/dev/null) && curl_exit=0 || curl_exit=$?
  if [ "$http_code" != "000" ]; then
    record "dashboard" "pass" "Dashboard on port $DASHBOARD_PORT (HTTP $http_code)"
  elif [ "$curl_exit" -eq 7 ]; then
    record "dashboard" "fail" "Port forward not running on $DASHBOARD_PORT"
  else
    record "dashboard" "fail" "Dashboard not responding on port $DASHBOARD_PORT"
  fi
}

check_bridge() {
  if should_skip "bridge"; then
    record "bridge" "skip" ""
    return
  fi
  local piddir="/tmp/nemoclaw-services-${SANDBOX_NAME}"
  local pidfile="$piddir/telegram-bridge.pid"
  local pid
  if [ -f "$pidfile" ] && pid=$(cat "$pidfile") && kill -0 "$pid" 2>/dev/null; then
    record "bridge" "pass" "Telegram bridge running (PID $pid)"
  else
    # Bridge requires both TELEGRAM_BOT_TOKEN and NVIDIA_API_KEY (same as start-services.sh).
    # Only report failure if both are set but the bridge is not running.
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${NVIDIA_API_KEY:-}" ]; then
      record "bridge" "fail" "Telegram bridge not running (tokens are set)"
    else
      record "bridge" "skip" "Bridge prerequisites not set"
    fi
  fi
}

check_agent() {
  if should_skip "agent"; then
    record "agent" "skip" ""
    return
  fi
  # Run openclaw doctor inside the sandbox via SSH.
  # The command outputs a banner, warnings, and diagnostic lines.
  # We check the exit code first, then look for explicit error indicators.
  local doctor_out doctor_exit
  doctor_out=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "openshell-${SANDBOX_NAME}" 'openclaw doctor 2>&1; echo "EXIT:$?"' 2>&1 || true)
  doctor_exit=$(echo "$doctor_out" | grep -o 'EXIT:[0-9]*' | tail -1 | cut -d: -f2)
  if [ "${doctor_exit:-1}" = "0" ]; then
    record "agent" "pass" "openclaw doctor: passed (exit 0)"
  else
    # Non-zero exit or missing exit code — treat as failure
    local err_line
    err_line=$(echo "$doctor_out" | grep -i "error\|fail\|unhealthy" | head -1 || true)
    if [ -n "$err_line" ]; then
      record "agent" "fail" "openclaw doctor: ${err_line:0:80}"
    else
      record "agent" "fail" "openclaw doctor: exited with code ${doctor_exit:-unknown}"
    fi
  fi
}

check_rules() {
  if should_skip "rules"; then
    record "rules" "skip" ""
    return
  fi
  if ! command -v openshell >/dev/null 2>&1; then
    record "rules" "skip" "openshell CLI not found"
    return
  fi
  local rules_out pending_count
  rules_out="$(openshell rule get "$SANDBOX_NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
  pending_count="$(echo "$rules_out" | grep -ci "proposed" || true)"
  if [ "$pending_count" -eq 0 ]; then
    record "rules" "pass" "No pending network rules"
  else
    record "rules" "fail" "$pending_count pending rule(s) awaiting approval"
  fi
}

check_briefing() {
  if should_skip "briefing"; then
    record "briefing" "skip" ""
    return
  fi
  local status_file="/tmp/nemoclaw-briefing-status.json"
  if [ ! -f "$status_file" ]; then
    record "briefing" "skip" "No briefing status file (never ran?)"
    return
  fi
  # Parse the status file
  local status timestamp age_hours
  status="$(grep -o '"status":"[^"]*"' "$status_file" | head -1 | cut -d'"' -f4)"
  timestamp="$(grep -o '"timestamp":"[^"]*"' "$status_file" | head -1 | cut -d'"' -f4)"

  # Check staleness — briefing should run daily, so >25h is stale
  if [ -n "$timestamp" ]; then
    local file_epoch now_epoch
    file_epoch="$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s' 2>/dev/null || stat -f '%m' "$status_file")"
    now_epoch="$(date '+%s')"
    age_hours=$(((now_epoch - file_epoch) / 3600))
    if [ "$age_hours" -gt 25 ]; then
      record "briefing" "fail" "Last briefing is ${age_hours}h old (stale)"
      return
    fi
  fi

  case "$status" in
    ok)
      record "briefing" "pass" "Last briefing succeeded ($timestamp)"
      ;;
    error:*)
      local err_type="${status#error:}"
      record "briefing" "fail" "Last briefing failed: $err_type ($timestamp)"
      ;;
    *)
      record "briefing" "fail" "Unknown briefing status: $status"
      ;;
  esac
}

check_inference_live() {
  if should_skip "inference_live"; then
    record "inference_live" "skip" ""
    return
  fi
  # End-to-end inference probe: send a minimal prompt through the sandbox agent
  # and verify we get a non-error response. Timeout after 30s to avoid blocking
  # the health check for minutes on a hung provider.
  local probe_out probe_exit
  probe_out=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "openshell-${SANDBOX_NAME}" \
    'timeout 30 openclaw agent --agent main -m "Reply with only the word: OK" 2>&1 | tail -5' \
    2>&1) && probe_exit=0 || probe_exit=$?

  if [ "$probe_exit" -ne 0 ]; then
    record "inference_live" "fail" "Inference probe SSH/timeout (exit $probe_exit)"
    return
  fi

  # Strip stderr noise (Node.js warnings, setup lines) before checking for errors
  local clean_out
  clean_out="$(echo "$probe_out" | grep -vE 'UNDICI-EHPA|EnvHttpProxyAgent|trace-warnings|\(node:|\(Use .node')"

  # Check for error patterns in the response
  if echo "$clean_out" | grep -qiE "timed? out|timeout|ETIMEDOUT|connection refused|ECONNREFUSED|502|503|rate.limit|LLM.*error"; then
    local err_snippet
    err_snippet="$(echo "$clean_out" | grep -iE "timed? out|timeout|error|refused|502|503|rate" | head -1)"
    record "inference_live" "fail" "Inference error: ${err_snippet:0:60}"
  elif [ -z "$probe_out" ]; then
    record "inference_live" "fail" "Inference probe returned empty response"
  else
    record "inference_live" "pass" "Inference probe OK"
  fi
}

# ── Auto-fix functions ─────────────────────────────────────────
# Each returns 0 if remediation was attempted (re-check warranted).
# These are invoked indirectly via get_fix_func().

fix_docker() {
  if [ "$(uname -s)" = "Darwin" ]; then
    open -a Docker 2>/dev/null || true
  fi
  # Give the daemon time to start
  local elapsed=0
  while [ "$elapsed" -lt 15 ]; do
    docker info >/dev/null 2>&1 && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 0
}

fix_gateway() {
  openshell gateway select "$GATEWAY_NAME" 2>/dev/null || true
  openshell gateway start --name "$GATEWAY_NAME" 2>&1 || true
  local elapsed=0
  while [ "$elapsed" -lt 30 ]; do
    local out
    out="$(openshell status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
    if echo "$out" | grep -qiw "healthy\|connected"; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 0
}

fix_inference() {
  # Restart LiteLLM via its LaunchAgent if not responding on port 4000.
  if ! curl -sf --max-time 2 http://localhost:4000/health >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.nemoclaw.litellm" 2>/dev/null || true
    sleep 8
  fi
  # Re-create the compatible-endpoint provider
  if command -v openshell >/dev/null 2>&1; then
    openshell provider delete "compatible-endpoint" 2>/dev/null || true
    openshell provider create --name "compatible-endpoint" --type "openai" \
      --credential "OPENAI_API_KEY=dummy" \
      --config "OPENAI_BASE_URL=http://host.openshell.internal:4000/v1" 2>/dev/null || true
  fi
  return 0
}

fix_inference_live() {
  # inference_live failure usually means LiteLLM is down — restart it
  fix_inference
}

fix_dashboard() {
  openshell forward stop "$DASHBOARD_PORT" 2>/dev/null || true
  openshell forward start --background "$DASHBOARD_PORT" "$SANDBOX_NAME" 2>&1 || true
  sleep 2
  return 0
}

fix_bridge() {
  "$SCRIPT_DIR/start-services.sh" --sandbox "$SANDBOX_NAME" 2>/dev/null || true
  sleep 3
  return 0
}

fix_agent() {
  if [ -x "$SCRIPT_DIR/apply-custom-policies.sh" ]; then
    "$SCRIPT_DIR/apply-custom-policies.sh" --sandbox "$SANDBOX_NAME" 2>/dev/null || true
  fi
  return 0
}

fix_rules() {
  openshell rule approve-all "$SANDBOX_NAME" 2>/dev/null || true
  return 0
}

# Map check name → fix function (bash 3.2 compatible, no associative arrays)
get_fix_func() {
  case "$1" in
    docker) echo "fix_docker" ;;
    gateway) echo "fix_gateway" ;;
    inference) echo "fix_inference" ;;
    dashboard) echo "fix_dashboard" ;;
    bridge) echo "fix_bridge" ;;
    agent) echo "fix_agent" ;;
    rules) echo "fix_rules" ;;
    inference_live) echo "fix_inference_live" ;;
    *) echo "" ;; # sandbox, ssh: not auto-fixable
  esac
}

REMEDIATION_ORDER=(docker gateway sandbox ssh inference inference_live dashboard bridge agent rules briefing)

get_result_status() {
  local target="$1"
  local entry
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r rname rstatus rdetail <<<"$entry"
    if [ "$rname" = "$target" ]; then
      echo "$rstatus"
      return
    fi
  done
  echo "skip"
}

replace_result() {
  local target="$1" new_status="$2" new_detail="$3"
  local i
  for i in "${!RESULTS[@]}"; do
    IFS='|' read -r rname _ _ <<<"${RESULTS[$i]}"
    if [ "$rname" = "$target" ]; then
      RESULTS[i]="${target}|${new_status}|${new_detail}"
      return
    fi
  done
}

remediate_and_recheck() {
  [ "$OUTPUT_MODE" = "pretty" ] && echo -e "\n${CYAN}Auto-fix: attempting remediation...${NC}\n"

  local name
  for name in "${REMEDIATION_ORDER[@]}"; do
    local status
    status="$(get_result_status "$name")"
    [ "$status" = "fail" ] || continue

    local func
    func="$(get_fix_func "$name")"
    if [ -n "$func" ]; then
      [ "$OUTPUT_MODE" = "pretty" ] && echo -e "  ${YELLOW}⟳${NC} Fixing $name..."
      $func 2>/dev/null || true
    else
      [ "$OUTPUT_MODE" = "pretty" ] && echo -e "  ${YELLOW}–${NC} $name: no auto-fix available (retry only)"
    fi
  done

  [ "$OUTPUT_MODE" = "pretty" ] && echo -e "\n${CYAN}Auto-fix: re-checking...${NC}\n"

  # Re-run only the checks that failed. Capture new result without polluting RESULTS.
  for name in "${REMEDIATION_ORDER[@]}"; do
    local status
    status="$(get_result_status "$name")"
    [ "$status" = "fail" ] || continue

    # Save state
    local saved_passed=$CHECKS_PASSED saved_failed=$CHECKS_FAILED saved_skipped=$CHECKS_SKIPPED
    local saved_len=${#RESULTS[@]}

    # Re-run the check (it appends to RESULTS)
    "check_${name}"

    # Extract the new entry
    local new_entry="${RESULTS[$saved_len]}"
    IFS='|' read -r _ new_status new_detail <<<"$new_entry"

    # Restore RESULTS to saved state, then update the original entry
    unset "RESULTS[$saved_len]"
    RESULTS=("${RESULTS[@]}")
    CHECKS_PASSED=$saved_passed
    CHECKS_FAILED=$saved_failed
    CHECKS_SKIPPED=$saved_skipped

    replace_result "$name" "$new_status" "$new_detail"
  done

  # Recalculate counters
  CHECKS_PASSED=0
  CHECKS_FAILED=0
  CHECKS_SKIPPED=0
  local entry
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r _ rstatus _ <<<"$entry"
    case "$rstatus" in
      pass) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
      fail) CHECKS_FAILED=$((CHECKS_FAILED + 1)) ;;
      skip) CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)) ;;
    esac
  done

  # Print post-remediation results in pretty mode
  if [ "$OUTPUT_MODE" = "pretty" ]; then
    for entry in "${RESULTS[@]}"; do
      IFS='|' read -r rname rstatus rdetail <<<"$entry"
      case "$rstatus" in
        pass) echo -e "  ${GREEN}✓${NC} ${rname}: ${rdetail}" ;;
        fail) echo -e "  ${RED}✗${NC} ${rname}: ${rdetail}" ;;
        skip) echo -e "  ${YELLOW}–${NC} ${rname}: skipped" ;;
      esac
    done
  fi
}

# ── Run all checks ─────────────────────────────────────────────
if [ "$OUTPUT_MODE" = "pretty" ]; then
  echo -e "\n${CYAN}NemoClaw Health Check${NC}  ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo -e "${CYAN}Sandbox:${NC} $SANDBOX_NAME  ${CYAN}Gateway:${NC} $GATEWAY_NAME\n"
fi

check_docker
check_gateway
check_sandbox
check_ssh
check_inference
check_inference_live
check_dashboard
check_bridge
check_agent
check_rules
check_briefing

# ── Auto-fix pass ─────────────────────────────────────────────
if [ "$AUTO_FIX" -eq 1 ] && [ "$CHECKS_FAILED" -gt 0 ]; then
  remediate_and_recheck
fi

# ── Output ─────────────────────────────────────────────────────
TOTAL=$((CHECKS_PASSED + CHECKS_FAILED + CHECKS_SKIPPED))

if [ "$OUTPUT_MODE" = "pretty" ]; then
  echo ""
  if [ "$CHECKS_FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}All $CHECKS_PASSED checks passed${NC} ($CHECKS_SKIPPED skipped)"
  else
    echo -e "  ${RED}$CHECKS_FAILED/$TOTAL checks failed${NC} ($CHECKS_PASSED passed, $CHECKS_SKIPPED skipped)"
  fi
  echo ""
fi

if [ "$OUTPUT_MODE" = "json" ]; then
  safe_sandbox=$(json_escape "$SANDBOX_NAME")
  safe_gateway=$(json_escape "$GATEWAY_NAME")
  echo "{"
  echo "  \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\","
  echo "  \"sandbox\": \"$safe_sandbox\","
  echo "  \"gateway\": \"$safe_gateway\","
  echo "  \"summary\": { \"passed\": $CHECKS_PASSED, \"failed\": $CHECKS_FAILED, \"skipped\": $CHECKS_SKIPPED },"
  echo "  \"checks\": ["
  first=1
  for result in "${RESULTS[@]}"; do
    IFS='|' read -r name status detail <<<"$result"
    safe_detail=$(json_escape "$detail")
    [ "$first" -eq 1 ] && first=0 || echo ","
    printf '    { "name": "%s", "status": "%s", "detail": "%s" }' "$name" "$status" "$safe_detail"
  done
  echo ""
  echo "  ]"
  echo "}"
fi

# ── Alerting ───────────────────────────────────────────────────
if [ "$CHECKS_FAILED" -gt 0 ] && [ -n "$ALERT_METHOD" ]; then
  # Build failure summary
  FAILURE_LINES=""
  for result in "${RESULTS[@]}"; do
    IFS='|' read -r name status detail <<<"$result"
    if [ "$status" = "fail" ]; then
      FAILURE_LINES="${FAILURE_LINES}✗ ${name}: ${detail}\n"
    fi
  done

  case "$ALERT_METHOD" in
    telegram)
      if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "Warning: --alert telegram requires TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID" >&2
      else
        ALERT_TEXT="⚠️ NemoClaw Health Alert

${CHECKS_FAILED}/${TOTAL} checks failed (sandbox: ${SANDBOX_NAME})

$(echo -e "$FAILURE_LINES")
Run: ./scripts/health-check.sh --sandbox '$SANDBOX_NAME'"

        RESULT=$(curl -s -X POST \
          "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
          -d chat_id="$TELEGRAM_CHAT_ID" \
          --data-urlencode "text=${ALERT_TEXT}" 2>&1)

        if echo "$RESULT" | grep -q '"ok":true'; then
          [ "$OUTPUT_MODE" = "pretty" ] && echo -e "  ${YELLOW}Alert sent to Telegram${NC}"
        else
          echo "Warning: Failed to send Telegram alert" >&2
        fi
      fi
      ;;
    *)
      echo "Warning: Unknown alert method '$ALERT_METHOD'. Supported: telegram" >&2
      ;;
  esac
fi

# ── Exit code ──────────────────────────────────────────────────
if [ "$CHECKS_FAILED" -gt 0 ]; then
  exit 1
else
  exit 0
fi
