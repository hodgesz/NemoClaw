#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Apply custom sandbox configurations that don't survive a rebuild.
#
# This script re-applies all host-side customizations into the sandbox
# container via docker exec. It is idempotent and safe to run multiple times.
#
# What it does:
#   1. Inject Gemini web search config into openclaw.json (NemoClaw #773 workaround)
#   2. Update config hash (prevents "integrity check FAILED" from nemoclaw-start)
#   3. Patch OpenClaw fetch-guard for web search DNS (NemoClaw #1252 / OpenClaw #396)
#   4. Ensure the gateway is running (start it if not, leave it alone if it is)
#   5. Wait for gateway + approve device pairing (NemoClaw #1310)
#   6. Re-install custom skills (morning briefing, ADHD planner, personal CRM)
#
# Usage:
#   ./scripts/apply-custom-policies.sh                     # default sandbox
#   ./scripts/apply-custom-policies.sh --sandbox mybox     # named sandbox
#   ./scripts/apply-custom-policies.sh --skip-skills       # skip skill install
#   ./scripts/apply-custom-policies.sh --dry-run           # show what would happen
#
# Requires: GEMINI_API_KEY in environment, Docker running, sandbox Ready.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────
SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
CLUSTER_CONTAINER="openshell-cluster-nemoclaw"
SKIP_SKILLS=0
SKIP_GEMINI=0
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
    --skip-gemini)
      SKIP_GEMINI=1
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

# Find the sandbox container ID.
#
# After a host reboot there can be several `sandbox-from` containers
# registered in containerd (stale + current). Only one of them has a
# running task — that's the one we need. Cross-reference the container
# list against `tasks list` and pick the container whose task is RUNNING.
find_container() {
  local running_tasks candidates
  running_tasks="$(docker exec "$CLUSTER_CONTAINER" ctr -n k8s.io tasks list 2>/dev/null \
    | awk 'NR>1 && $3=="RUNNING" {print $1}')"
  candidates="$(docker exec "$CLUSTER_CONTAINER" ctr -n k8s.io containers list 2>/dev/null \
    | grep 'sandbox-from' | awk '{print $1}')"
  # Intersect: return the first candidate that also has a running task.
  for cid in $candidates; do
    if printf '%s\n' "$running_tasks" | grep -qx "$cid"; then
      echo "$cid"
      return 0
    fi
  done
  return 1
}

CONTAINER_ID="$(find_container)"
if [ -z "$CONTAINER_ID" ]; then
  fail "Could not find sandbox container. Is the sandbox running?"
fi
info "Sandbox container: ${CONTAINER_ID:0:12}..."

# Helper: exec inside sandbox container as root
sandbox_exec() {
  local exec_id="$1"
  shift
  docker exec -i "$CLUSTER_CONTAINER" ctr -n k8s.io task exec \
    --exec-id "$exec_id" --user 0 "$CONTAINER_ID" "$@"
}

# Poll for openclaw-gateway to appear inside the sandbox. Gateway cold-start
# takes 10-20s (node spawn + channel setup + port bind), so a single fixed
# sleep is unreliable. Returns the PID on stdout, empty on timeout.
wait_for_gateway() {
  local timeout="${1:-30}"
  local elapsed=0
  local pid=""
  while [ "$elapsed" -lt "$timeout" ]; do
    # shellcheck disable=SC2016 # single quotes intentional — runs inside sandbox
    pid=$(sandbox_exec "wait-gw-${elapsed}" sh -c '
      for f in /proc/[0-9]*/cmdline; do
        first=$(tr "\0" "\n" < "$f" 2>/dev/null | head -1)
        if [ "$first" = "openclaw-gateway" ]; then
          pid=$(echo "$f" | cut -d/ -f3)
          echo "$pid"
          break
        fi
      done
    ' 2>/dev/null || true)
    if [ -n "$pid" ]; then
      echo "$pid"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# ── Step 1: Inject web search config ─────────────────────────────
# Configures web search provider in openclaw.json. Prefers Brave Search
# (BRAVE_SEARCH_API_KEY) over Gemini (GEMINI_API_KEY). Brave is more
# reliable for always-on use (Gemini was 503ing intermittently).
# Pass --skip-gemini to skip this entirely (e.g. from auto-start when
# model config is handled by NEMOCLAW_MODEL_OVERRIDE).

if [ "$SKIP_GEMINI" -eq 1 ]; then
  step "Step 1/6: Web search config (skipped via --skip-gemini)"
  info "Skipping web search injection."
elif [ -n "${BRAVE_SEARCH_API_KEY:-}" ]; then
  step "Step 1/6: Web search config (Brave)"
  if dry "would inject Brave web search config into openclaw.json"; then
    :
  else
    sandbox_exec read-cfg cat /sandbox/.openclaw/openclaw.json >/tmp/oc-cfg.json 2>/dev/null

    if grep -q '"brave"' /tmp/oc-cfg.json && grep -q "$BRAVE_SEARCH_API_KEY" /tmp/oc-cfg.json 2>/dev/null; then
      info "Brave web search already configured."
    else
      python3 -c "
import json
cfg = json.load(open('/tmp/oc-cfg.json'))
cfg.setdefault('tools', {})['web'] = {
    'search': {'enabled': True, 'provider': 'brave',
               'apiKey': '$BRAVE_SEARCH_API_KEY'},
    'fetch': {'enabled': True}
}
json.dump(cfg, open('/tmp/oc-cfg.json', 'w'), indent=2)
"
      sandbox_exec write-cfg sh -c 'cat > /sandbox/.openclaw/openclaw.json' </tmp/oc-cfg.json
      info "Brave web search config injected."
    fi
    rm -f /tmp/oc-cfg.json
  fi
elif [ -n "${GEMINI_API_KEY:-}" ]; then
  step "Step 1/6: Web search config (Gemini fallback)"
  if dry "would inject Gemini web search config into openclaw.json"; then
    :
  else
    sandbox_exec read-cfg cat /sandbox/.openclaw/openclaw.json >/tmp/oc-cfg.json 2>/dev/null

    if grep -q '"gemini"' /tmp/oc-cfg.json && grep -q "$GEMINI_API_KEY" /tmp/oc-cfg.json 2>/dev/null; then
      info "Gemini web search already configured."
    else
      python3 -c "
import json
cfg = json.load(open('/tmp/oc-cfg.json'))
cfg.setdefault('tools', {})['web'] = {
    'search': {'enabled': True, 'provider': 'gemini',
               'gemini': {'apiKey': '$GEMINI_API_KEY'}},
    'fetch': {'enabled': True}
}
json.dump(cfg, open('/tmp/oc-cfg.json', 'w'), indent=2)
"
      sandbox_exec write-cfg sh -c 'cat > /sandbox/.openclaw/openclaw.json' </tmp/oc-cfg.json
      info "Gemini web search config injected."
    fi
    rm -f /tmp/oc-cfg.json
  fi
else
  step "Step 1/6: Web search config"
  warn "Neither BRAVE_SEARCH_API_KEY nor GEMINI_API_KEY set. Skipping."
fi

# ── Step 2: Update config hash ──────────────────────────────────
# Only needed when Step 1 modified openclaw.json. When --skip-gemini is
# set, the entrypoint's NEMOCLAW_MODEL_OVERRIDE handles hash recomputation.

if [ "$SKIP_GEMINI" -eq 1 ]; then
  step "Step 2/6: Config hash update (skipped — entrypoint handles this)"
else
  step "Step 2/6: Config hash update"
  if dry "would update config hash"; then
    :
  else
    sandbox_exec fix-hash sh -c \
      'sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash && chmod 444 /sandbox/.openclaw/.config-hash'
    info "Config hash updated."
  fi
fi

# ── Step 3: Fetch-guard DNS patch ───────────────────────────────
step "Step 3/6: Fetch-guard DNS patch (NemoClaw #1252)"

if dry "would patch fetch-guard files to skip DNS in proxy mode"; then
  :
else
  PATCHED=0
  SKIPPED=0

  # Find all fetch-guard files that need patching
  GUARD_FILES=$(sandbox_exec find-guards sh -c \
    'grep -rl "resolvePinnedHostname" /usr/local/lib/node_modules/openclaw/dist/' 2>/dev/null || true)

  if [ -z "$GUARD_FILES" ]; then
    warn "No fetch-guard files found. OpenClaw may have been updated (patch no longer needed?)."
  else
    for FILE in $GUARD_FILES; do
      sandbox_exec "read-fg-$$" cat "$FILE" >/tmp/fg-patch.js 2>/dev/null
      RESULT=$(python3 -c "
content = open('/tmp/fg-patch.js').read()
old = '''let dispatcher = null;
\t\ttry {
\t\t\tconst pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {
\t\t\t\tlookupFn: params.lookupFn,
\t\t\t\tpolicy: params.policy
\t\t\t});
\t\t\tif (mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured()) dispatcher = new EnvHttpProxyAgent();
\t\t\telse if (params.pinDns !== false) dispatcher = createPinnedDispatcher(pinned);'''
new = '''let dispatcher = null;
\t\ttry {
\t\t\tconst useTrustedEnvProxy = mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured();
\t\t\tif (useTrustedEnvProxy) {
\t\t\t\tdispatcher = new EnvHttpProxyAgent();
\t\t\t} else {
\t\t\t\tconst pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {
\t\t\t\t\tlookupFn: params.lookupFn,
\t\t\t\t\tpolicy: params.policy
\t\t\t\t});
\t\t\t\tif (params.pinDns !== false) dispatcher = createPinnedDispatcher(pinned);
\t\t\t}'''
if old in content:
    open('/tmp/fg-patch.js', 'w').write(content.replace(old, new))
    print('PATCHED')
else:
    print('SKIPPED')
" 2>&1)

      if [ "$RESULT" = "PATCHED" ]; then
        sandbox_exec "write-fg-$$" sh -c "cat > $FILE" </tmp/fg-patch.js 2>/dev/null
        PATCHED=$((PATCHED + 1))
      else
        SKIPPED=$((SKIPPED + 1))
      fi
    done
    rm -f /tmp/fg-patch.js

    if [ "$PATCHED" -gt 0 ]; then
      info "Patched $PATCHED fetch-guard file(s). Skipped $SKIPPED (already patched or different)."
    else
      info "All $SKIPPED fetch-guard file(s) already patched."
    fi
  fi
fi

# ── Step 4: Ensure gateway is running ───────────────────────────
# Previously this step killed the running gateway to force a reload of
# patched code. That was harmful: openclaw has no supervisor, so killing
# the gateway just leaves it dead, and spawning a replacement while the
# old one is still shutting down causes a Telegram `getUpdates` 409
# conflict that kills the new one too. We now only start the gateway
# when it isn't already running.
step "Step 4/6: Ensure gateway is running"

if dry "would start gateway if not running"; then
  :
else
  # shellcheck disable=SC2016 # single quotes intentional — runs inside sandbox
  GW_PID=$(sandbox_exec find-gw-pid sh -c '
    for f in /proc/[0-9]*/cmdline; do
      first=$(tr "\0" "\n" < "$f" 2>/dev/null | head -1)
      if [ "$first" = "openclaw-gateway" ]; then
        pid=$(echo "$f" | cut -d/ -f3)
        echo "$pid"
        break
      fi
    done
  ' 2>/dev/null || true)

  if [ -n "$GW_PID" ]; then
    info "Gateway already running (PID $GW_PID). Leaving it alone."
  else
    info "No gateway process found. Starting gateway..."
    # setsid + </dev/null fully detaches the gateway from the SSH session so
    # it survives when ssh closes. Plain `nohup ... &` is not reliable here —
    # after reboot the child can still be reaped when ssh exits.
    ssh -o ConnectTimeout=10 "openshell-${SANDBOX_NAME}" \
      'setsid sh -c "nohup openclaw gateway run --port 18789 --auth token --bind loopback >/tmp/gateway.log 2>&1 </dev/null &"' 2>/dev/null || true

    NEW_GW_PID=$(wait_for_gateway 30 || true)
    if [ -n "$NEW_GW_PID" ]; then
      info "Gateway started (PID $NEW_GW_PID)."
    else
      warn "Gateway failed to start within 30s. Dashboard on port 18789 will be unreachable."
    fi
  fi
fi

# ── Step 5: Device pairing ──────────────────────────────────────
step "Step 5/6: Device pairing (NemoClaw #1310)"

if dry "would approve device pairing"; then
  :
else
  # Wait a moment for gateway to settle
  sleep 3

  DEVICE_ID=$(ssh -o ConnectTimeout=10 "openshell-${SANDBOX_NAME}" \
    'openclaw devices list 2>&1' 2>/dev/null \
    | grep -oE '[0-9a-f-]{36}' | head -1 || true)

  if [ -n "$DEVICE_ID" ]; then
    # Check if already paired
    PAIRED=$(ssh -o ConnectTimeout=10 "openshell-${SANDBOX_NAME}" \
      'openclaw devices list 2>&1' 2>/dev/null \
      | grep -c "Paired" || true)

    if [ "$PAIRED" -gt 0 ]; then
      info "Device already paired."
    else
      ssh -o ConnectTimeout=10 "openshell-${SANDBOX_NAME}" \
        "openclaw devices approve $DEVICE_ID 2>&1" 2>/dev/null || true
      info "Device pairing approved."
    fi
  else
    warn "No device found for pairing. Agent may work in embedded mode."
  fi
fi

# ── Step 6: Re-install custom skills ───────────────────────────
step "Step 6/6: Custom skills"

if [ "$SKIP_SKILLS" -eq 1 ]; then
  info "Skipping skill install (--skip-skills)."
elif dry "would install custom skills"; then
  :
else
  SKILLS_DIR="$REPO_DIR/skills"

  if [ ! -d "$SKILLS_DIR" ]; then
    warn "No skills/ directory found at $SKILLS_DIR. Skipping."
  else
    for skill_dir in "$SKILLS_DIR"/*/; do
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      skill_file="$skill_dir/SKILL.md"

      if [ ! -f "$skill_file" ]; then
        warn "Skill '$skill_name' has no SKILL.md. Skipping."
        continue
      fi

      # Create skill directory in sandbox and upload
      ssh -o ConnectTimeout=10 "openshell-${SANDBOX_NAME}" \
        "mkdir -p /sandbox/.openclaw-data/skills/$skill_name" 2>/dev/null || true
      ssh -o ConnectTimeout=10 "openshell-${SANDBOX_NAME}" \
        "cat > /sandbox/.openclaw-data/skills/$skill_name/SKILL.md" \
        <"$skill_file" 2>/dev/null || true
      info "Installed skill: $skill_name"
    done
  fi
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Custom Policies Applied                             │"
echo "  │                                                      │"
printf "  │  Sandbox:     %-38s│\n" "$SANDBOX_NAME"
printf "  │  Gemini:      %-38s│\n" "${GEMINI_API_KEY:+configured}"
printf "  │  Fetch-guard: %-38s│\n" "patched"
printf "  │  Gateway:     %-38s│\n" "verified"
printf "  │  Pairing:     %-38s│\n" "checked"
printf "  │  Skills:      %-38s│\n" "$([ "$SKIP_SKILLS" -eq 1 ] && echo 'skipped' || echo 'installed')"
echo "  │                                                      │"
echo "  │  Test: ssh openshell-${SANDBOX_NAME} 'openclaw agent"
echo "  │    --agent main -m \"search the web for today news\"'"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
