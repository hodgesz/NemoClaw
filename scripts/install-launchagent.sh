#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Render NemoClaw LaunchAgent template(s) for THIS machine and install them.
#
# Why this exists:
#   launchd does not expand $HOME, ~, or environment variables inside plist
#   strings — paths must be absolute and literal at load time. Committing a
#   plist with /Users/<you>/... baked in is not portable, and several of our
#   agents also carry secrets (bot token, API key). So we commit
#   *.plist.template files with placeholders and resolve them here, at install
#   time, from the real environment and a local (uncommitted) secrets file.
#
# Placeholders substituted:
#   __REPO_DIR__   absolute path to this repo checkout (derived from $0)
#   __HOME__       $HOME
#   __NODE_BIN__   directory containing `node` (derived from `command -v node`)
#   __SANDBOX__    sandbox name (--sandbox flag, $NEMOCLAW_SANDBOX_NAME, or default)
#   __VARNAME__    any other placeholder is resolved from the secrets env file
#                  (e.g. __TELEGRAM_BOT_TOKEN__, __NVIDIA_API_KEY__,
#                  __TELEGRAM_CHAT_ID__). Real secrets stay out of the repo:
#                  templates ship placeholders; the env file holds the values.
#
# Secrets env file (default ~/.nemoclaw/launchagent.env, override with
# NEMOCLAW_LAUNCHAGENT_ENV): KEY=VALUE lines, chmod 600, NOT committed. A
# template that references __KEY__ with no matching entry is a hard error.
#
# Usage:
#   ./scripts/install-launchagent.sh <template> [--sandbox NAME] [--no-load] [--force]
#   ./scripts/install-launchagent.sh --all                 # all templates
#   ./scripts/install-launchagent.sh --all --diff          # render & diff vs installed, install nothing
#   ./scripts/install-launchagent.sh <template> --no-load  # write plist, don't (re)load
#
# Idempotent: re-running re-renders and (unless --no-load) kickstarts the agent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/launchagents"
SECRETS_ENV="${NEMOCLAW_LAUNCHAGENT_ENV:-$HOME/.nemoclaw/launchagent.env}"
DEST_DIR="$HOME/Library/LaunchAgents"

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-${SANDBOX_NAME:-my-assistant}}"
TEMPLATES=()
DO_LOAD=1
FORCE=0
ALL=0
DIFF=0

# ── Parse args ─────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a name}"
      shift 2
      ;;
    --all)
      ALL=1
      shift
      ;;
    --diff)
      DIFF=1
      DO_LOAD=0
      shift
      ;;
    --no-load)
      DO_LOAD=0
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
    *)
      TEMPLATES+=("$1")
      shift
      ;;
  esac
done

if [ "$ALL" -eq 1 ]; then
  # Glob all templates; nullglob so an empty dir is a clean error, not a literal.
  shopt -s nullglob
  TEMPLATES=("$TEMPLATE_DIR"/*.plist.template)
  shopt -u nullglob
fi

if [ "${#TEMPLATES[@]}" -eq 0 ]; then
  echo "Usage: $0 <template.plist.template> | --all [--sandbox NAME] [--diff|--no-load] [--force]" >&2
  exit 2
fi

# ── Resolve machine-specific values ───────────────────────────────
NODE_PATH="$(command -v node || true)"
if [ -z "$NODE_PATH" ]; then
  echo "ERROR: node not found on PATH; cannot resolve __NODE_BIN__." >&2
  exit 1
fi
NODE_BIN="$(cd "$(dirname "$NODE_PATH")" && pwd)"

# ── Load secrets (if present) ──────────────────────────────────────
# Sourced into this shell so __KEY__ placeholders resolve from $KEY. Missing
# file is tolerated — only an actually-referenced placeholder forces the error.
if [ -f "$SECRETS_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$SECRETS_ENV"
  set +a
fi

# Render one template to stdout. Resolves the 4 built-ins, then any remaining
# __VAR__ tokens from the environment (secrets). Errors if a token is unset.
render() {
  local template="$1" out var val
  out="$(sed \
    -e "s|__REPO_DIR__|$REPO_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__NODE_BIN__|$NODE_BIN|g" \
    -e "s|__SANDBOX__|$SANDBOX_NAME|g" \
    "$template")"

  # Resolve remaining placeholders from the environment (secrets file).
  while IFS= read -r var; do
    [ -z "$var" ] && continue
    if [ -z "${!var:-}" ]; then
      echo "ERROR: $(basename "$template") references __${var}__ but it is not set." >&2
      echo "       Add ${var}=... to $SECRETS_ENV" >&2
      return 1
    fi
    val="${!var}"
    # Escape sed replacement metacharacters (& and the | delimiter).
    val="${val//\\/\\\\}"
    val="${val//&/\\&}"
    val="${val//|/\\|}"
    out="$(printf '%s' "$out" | sed -e "s|__${var}__|${val}|g")"
  done < <(printf '%s' "$out" | grep -o '__[A-Z0-9_]*__' | sed 's/__//g' | sort -u)

  printf '%s\n' "$out"
}

install_one() {
  local template="$1"
  if [ ! -f "$template" ] && [ -f "$REPO_DIR/$template" ]; then
    template="$REPO_DIR/$template"
  fi
  if [ ! -f "$template" ]; then
    echo "ERROR: template not found: $template" >&2
    return 1
  fi

  local base plist_name label dest tmp
  base="$(basename "$template")"
  plist_name="${base%.template}"
  label="${plist_name%.plist}"
  dest="$DEST_DIR/$plist_name"

  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  render "$template" >"$tmp"

  # Sanity: no placeholders left behind.
  if grep -q '__[A-Z0-9_]*__' "$tmp"; then
    echo "ERROR: unresolved placeholders in $base:" >&2
    grep -o '__[A-Z0-9_]*__' "$tmp" | sort -u >&2
    return 1
  fi

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$tmp" >/dev/null
  fi

  # ── Diff mode: compare against installed, never write ────────────
  if [ "$DIFF" -eq 1 ]; then
    if [ ! -f "$dest" ]; then
      echo "[$label] not installed (would create $dest)"
    elif diff -u "$dest" "$tmp" >/tmp/.la-diff.$$ 2>/dev/null; then
      echo "[$label] IDENTICAL to installed plist ✓"
    else
      echo "[$label] DIFFERS from installed plist:"
      sed 's/^/    /' /tmp/.la-diff.$$
    fi
    rm -f /tmp/.la-diff.$$
    return 0
  fi

  mkdir -p "$DEST_DIR"
  if [ -f "$dest" ] && [ "$FORCE" -eq 0 ] && cmp -s "$tmp" "$dest"; then
    echo "[$label] already installed and identical"
  else
    cp "$tmp" "$dest"
    echo "[$label] installed → $dest"
  fi

  if [ "$DO_LOAD" -eq 0 ]; then
    return 0
  fi

  local gui_target
  gui_target="gui/$(id -u)/${label}"
  if launchctl print "$gui_target" >/dev/null 2>&1; then
    echo "[$label] reloading (kickstart)..."
    launchctl kickstart -k "$gui_target" 2>/dev/null \
      || {
        launchctl unload "$dest" 2>/dev/null || true
        launchctl load "$dest"
      }
  else
    echo "[$label] loading..."
    launchctl load "$dest"
  fi
}

echo "REPO_DIR=$REPO_DIR  HOME=$HOME  NODE_BIN=$NODE_BIN  SANDBOX=$SANDBOX_NAME"
[ -f "$SECRETS_ENV" ] && echo "secrets: $SECRETS_ENV" || echo "secrets: (none — $SECRETS_ENV absent)"
echo

rc=0
for t in "${TEMPLATES[@]}"; do
  install_one "$t" || rc=1
done
exit "$rc"
