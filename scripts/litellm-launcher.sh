#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Wrapper that loads GEMINI_API_KEY from dotfiles and exec's litellm.
# Intended for use by a macOS LaunchAgent (which doesn't source login shells).
#
# Backing LLM is Google Gemini via the LiteLLM proxy (port 4000), reached
# by Hermes as model "gemini-flash-latest" (provider custom, base_url
# http://localhost:4000/v1). LiteLLM's --model flag uses the "gemini/<api-id>"
# form; the proxy exposes it to Hermes as the bare "<api-id>". Using Google's
# `gemini-flash-latest` auto-alias so the model survives Gemini deprecations
# (gemini-2.5-flash was retired 2026-07; a pinned id would 404 on the next
# retirement).
#
# Key rotations: restart the LaunchAgent (com.nemoclaw.litellm) to re-source
# GEMINI_API_KEY from ~/.zshrc — `launchctl kickstart -k gui/$(id -u)/com.nemoclaw.litellm`.

set -euo pipefail

# ── Load exports from dotfiles (same pattern as auto-start.sh) ────
_load_exports_from() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([A-Z_][A-Z0-9_]*)= ]]; then
      eval "$line" 2>/dev/null || true
    fi
  done <"$file"
}

for rc in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bashrc"; do
  _load_exports_from "$rc"
done

if [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "ERROR: GEMINI_API_KEY not found in dotfiles. LiteLLM cannot authenticate." >&2
  exit 1
fi

export GEMINI_API_KEY

exec /Users/hodgesz/.local/bin/litellm --model gemini/gemini-flash-latest --port 4000
