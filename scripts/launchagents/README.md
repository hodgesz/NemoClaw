<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# LaunchAgent templates

macOS LaunchAgent definitions for NemoClaw's always-on host services. These are
**templates**, not ready-to-load plists.

## Why templates?

`launchd` does not expand `$HOME`, `~`, or environment variables inside plist
strings — every path must be absolute and literal at load time. Hardcoding
`/Users/<you>/...` is not portable, and several agents also carry secrets (bot
token, API key). So each `*.plist.template` ships **placeholders**, and
`scripts/install-launchagent.sh` resolves them for the current machine at
install time.

| Placeholder | Resolved from |
|---|---|
| `__REPO_DIR__` | repo checkout path (derived from the installer's location) |
| `__HOME__` | `$HOME` |
| `__NODE_BIN__` | directory of `node` (`command -v node`) |
| `__SANDBOX__` | `--sandbox` flag / `$NEMOCLAW_SANDBOX_NAME` / default `my-assistant` |
| `__TELEGRAM_BOT_TOKEN__`, `__NVIDIA_API_KEY__`, `__TELEGRAM_CHAT_ID__`, … | the secrets env file |

## Secrets

Secret placeholders are resolved from a local env file that is **never
committed** (default `~/.nemoclaw/launchagent.env`, override with
`NEMOCLAW_LAUNCHAGENT_ENV`). Copy the example and fill in real values:

```bash
cp scripts/launchagents/launchagent.env.example ~/.nemoclaw/launchagent.env
chmod 600 ~/.nemoclaw/launchagent.env
# edit in your real token / key / chat id
```

A template that references a placeholder with no matching env entry is a hard
error — the installer refuses to write an incomplete plist.

## Install

```bash
# Install + load every agent for this machine
./scripts/install-launchagent.sh --all

# Render and compare against what's installed — changes nothing
./scripts/install-launchagent.sh --all --diff

# A single agent, write the plist but don't (re)load it
./scripts/install-launchagent.sh \
  scripts/launchagents/com.nemoclaw.bridge-watchdog.plist.template --no-load
```

Rendered plists land in `~/Library/LaunchAgents/` and are gitignored. The
installer is idempotent: re-running re-renders and (unless `--no-load`)
`kickstart`s the agent to pick up changes.
