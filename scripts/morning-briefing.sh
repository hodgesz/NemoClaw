#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Morning Briefing — sends a daily briefing to Telegram via the sandbox agent.
# Designed to be called by cron or launchd on the host.
#
# Flow: gather fresh web results from the sandbox's Brave search provider
# (openclaw infer web search — the agent itself can't search because NemoClaw
# sets agents.defaults.skipBootstrap=true, issue #3240), then feed them to the
# agent as context for a concise briefing, then deliver to Telegram via the
# Bot API. The host Telegram bridge was removed in the v0.0.68 native-channels
# migration; delivery is now direct Bot API + the sandbox's native telegram
# channel handles inbound replies.
#
# Usage: ./scripts/morning-briefing.sh [--chat-id <id>]
#
# Requires: TELEGRAM_BOT_TOKEN in environment, SSH access to a running sandbox
# with the `brave` policy preset applied and the brave web-search provider
# configured (onboard with BRAVE_API_KEY set + `nemoclaw <sb> policy-add brave`).

set -euo pipefail

# Source credentials (launchd doesn't load shell profiles).
# Extract only `export VAR=value` lines from ~/.zshrc since bash can't run
# zsh-specific syntax. Evaluate line-by-line so a single malformed export
# (e.g. a stray trailing token) is suppressed instead of aborting the whole
# load — mirroring the pattern in litellm-launcher.sh. Previously a one-shot
# `eval "$(grep ...)"` would hit `export: '-': not a valid identifier` on a
# bad PATH line and skip every export after it.
_load_exports_from() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*= ]]; then
      eval "$line" 2>/dev/null || true
    fi
  done <"$file"
}
_load_exports_from "$HOME/.zshrc"

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

# ── Gather fresh web context via the sandbox's Brave search provider ──
# NemoClaw sets agents.defaults.skipBootstrap=true (issue #3240), so the main
# agent's LLM toolset does NOT include the brave web.search tool — only the
# built-in tool_search_code. Asking the agent to "search the web" therefore
# fails ("I only have tool_search_code ... cannot browse"). Instead, gather
# results ourselves via the provider-level `openclaw infer web search`
# (which reaches Brave through the my-assistant-brave-search gateway provider
# + the brave policy preset's api.search.brave.com egress), strip Brave's
# EXTERNAL_UNTRUSTED_CONTENT wrapper, and hand the cleaned results to the
# agent as context for the briefing. This respects NemoClaw's design without
# distro patching; see memory: project-upgrade-websearch-agent-tool-gap.
WEB_QUERY="${NEMOCLAW_BRIEFING_QUERY:-top news headlines today}"
# Parse the Brave JSON with a temp-file python parser. Using `python3 -c '...'`
# was brittle: stripping Brave's EXTERNAL_UNTRUSTED_CONTENT markers needs a
# literal apostrophe in the .replace() call, which fights bash single-quoting
# across the whole embedded script. A quoted heredoc to a temp .py file keeps
# the python source byte-for-byte verbatim (no shell interpolation), so the
# parser body is safe to edit.
_BRIEF_PY="$(mktemp -t nemoclaw-brief-parse.XXXXXX.py)"
trap 'rm -f "$_BRIEF_PY"' EXIT
cat >"$_BRIEF_PY" <<'PYEOF'
import json, re, sys
# `openclaw infer` prints a `[proxy] routing ...` line before the JSON; find
# the first "{" so json.loads sees a clean object.
raw = sys.stdin.read()
start = raw.find("{")
try:
    data = json.loads(raw[start:]) if start >= 0 else {}
    items = (data.get("outputs") or [{}])[0].get("result", {}).get("results", [])
except Exception:
    items = []
def clean(s):
    if not isinstance(s, str): return ""
    # Strip Brave EXTERNAL_UNTRUSTED_CONTENT wrappers and HTML entities.
    s = re.sub(r"<<<EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>|<<<END_EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>", "", s)
    s = s.replace("Source: Web Search", "").replace("---", "")
    s = s.replace("&#x27;", "'").replace("&amp;", "&").replace("&quot;", '"')
    return re.sub(r"\s+", " ", s).strip()
lines = []
for i, r in enumerate(items, 1):
    title = clean(r.get("title"))
    url = r.get("url", "")
    desc = clean(r.get("description"))
    if title:
        # Include the description (Brave's snippet) so the agent has actual
        # article content to summarize — titles+URLs alone aren't enough for
        # the LLM to compose a briefing (it can't browse the URLs).
        block = f"{i}. {title}\n   {url}"
        if desc:
            block += f"\n   {desc}"
        lines.append(block)
print("\n".join(lines) if lines else "(no web results)")
PYEOF
WEB_RESULTS=$(ssh -o ConnectTimeout=15 "openshell-${SANDBOX_NAME}" \
  "openclaw infer web search --query '${WEB_QUERY}' --limit 5 --json 2>/dev/null" \
  | python3 "$_BRIEF_PY")

# Run agent in sandbox, feeding the gathered web results as context.
# The agent turn composes the briefing from this context (it cannot search
# itself due to skipBootstrap). SESSION_ID keeps this briefing turn in a
# stable session; note: with native telegram channels, replies to the
# briefing arrive via the sandbox's telegram provider (not a host bridge),
# so the tg-{chatId} coupling is now a stable-session convenience only.
# The prompt is multi-line, so base64 it locally and decode on the remote
# side — this dodges the nested local→ssh→remote shell quoting that splits
# `-m "$(printf '%q' ...)"` across newlines (which produced
# "Too many arguments for this command" against openclaw agent).
read -r -d '' AGENT_PROMPT <<EOF || true
Here are today's web search results (fetched just now via Brave, fresh):
${WEB_RESULTS}

Write my morning briefing: a concise, scannable summary of the most
important items above (and anything obviously related). Lead with the top
headlines. Keep it tight and useful — no preamble, no apologies.
EOF

PROMPT_B64=$(printf '%s' "${AGENT_PROMPT}" | base64 | tr -d '\n')

RESPONSE=$(ssh -o ConnectTimeout=15 "openshell-${SANDBOX_NAME}" \
  "export NVIDIA_API_KEY=unused && nemoclaw-start openclaw agent --agent main \
   -m \"\$(echo ${PROMPT_B64} | base64 -d)\" --session-id ${SESSION_ID}" 2>&1 \
  | grep -v -e '\[SECURITY\]' -e 'Setting up NemoClaw' -e '\[gateway\]' -e 'UNDICI' \
    -e '(node:' -e 'Use .node' -e 'pairing required' -e 'CAP_SET' \
    -e 'privilege separation' -e 'Gateway target:' -e 'Source: local loopback' \
    -e 'Config: /sandbox' -e 'Bind: loopback' -e 'getaddrinfo' \
    -e 'tools websearch' -e 'Gateway agent failed' \
    -e 'GatewayClientRequestError' -e 'abnormal closure' \
    -e 'tools cron failed' -e '\[config\]' -e '\[channels\]' \
    -e '\[plugins\]' -e '\[proxy\]' -e 'routing process' || true)

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
  >"$STATUS_FILE"

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
    >"$STATUS_FILE"
  exit 1
fi
