#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Wrapper that loads AWS_BEARER_TOKEN_BEDROCK from dotfiles and exec's litellm.
# Intended for use by a macOS LaunchAgent (which doesn't source login shells).

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

if [ -z "${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then
  echo "ERROR: AWS_BEARER_TOKEN_BEDROCK not found in dotfiles. LiteLLM cannot authenticate." >&2
  exit 1
fi

export AWS_BEARER_TOKEN_BEDROCK
export AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-1}"

exec /Users/hodgesz/.local/bin/litellm --model bedrock/us.anthropic.claude-sonnet-4-6 --port 4000
