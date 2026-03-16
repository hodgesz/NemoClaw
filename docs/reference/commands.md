---
title:
  page: "NemoClaw CLI Commands Reference"
  nav: "Commands"
description: "Full CLI reference for plugin and standalone NemoClaw commands."
keywords: ["nemoclaw cli commands", "nemoclaw command reference"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "openshell", "nemoclaw", "cli"]
content:
  type: reference
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Commands

NemoClaw provides two command interfaces.
The plugin commands run under the `openclaw nemoclaw` namespace inside the OpenClaw CLI.
The standalone `nemoclaw` binary handles host-side setup, deployment, and service management.
Both interfaces are installed when you run `npm install -g nemoclaw`.

## Plugin Commands

### `openclaw nemoclaw launch`

Bootstrap a fresh OpenClaw installation inside an OpenShell sandbox.
After provisioning the sandbox, NemoClaw runs `openclaw setup` and
`nemoclaw-gateway.sh ensure` inside it so the config, workspace, sessions,
gateway auth token, and direct Gateway process all exist before first use.
If NemoClaw detects an existing host installation, `launch` stops and points you
to `openclaw nemoclaw migrate` unless you pass `--force`.
The Gateway manager uses `~/.openclaw/run/gateway.pid` and
`~/.openclaw/run/gateway.lock` so headless bootstrap stays non-interactive and
does not depend on systemd or root-only service installation.

```console
$ openclaw nemoclaw launch [--force] [--profile <profile>]
```

`--force`
: Skip the ergonomics warning and force plugin-driven bootstrap. Without this flag,
  NemoClaw recommends using `openshell sandbox create` directly for new installs.

`--profile <profile>`
: Blueprint profile to use. Default: `default`.

### `openclaw nemoclaw migrate`

Migrate an existing host OpenClaw installation into an OpenShell sandbox.
The command snapshots the resolved OpenClaw state, captures external agent roots
referenced by config, preserves symlinks in tar archives, rewrites migrated
config paths, verifies the migrated paths inside the sandbox, and then re-runs
the same headless bootstrap so migrated installs also have a ready gateway
token and Gateway runtime after cutover.

```console
$ openclaw nemoclaw migrate [--dry-run] [--profile <profile>] [--skip-backup]
```

`--dry-run`
: Show what would be migrated without making changes.

`--profile <profile>`
: Blueprint profile to use. Default: `default`.

`--skip-backup`
: Skip creating a host backup snapshot before migration.

### `nemoclaw <name> connect`

Open an interactive shell inside the OpenClaw sandbox as the `sandbox` user.
This routes through `nemoclaw-shell`, which is a thin shell wrapper used by the
host-side bootstrap helpers.

```console
$ nemoclaw my-assistant connect
```

### `openclaw nemoclaw status`

Display sandbox health, blueprint run state, and inference configuration.

```console
$ openclaw nemoclaw status [--json]
```

`--json`
: Output as JSON for programmatic consumption.

### `openclaw nemoclaw logs`

Stream blueprint execution and sandbox logs.

```console
$ openclaw nemoclaw logs [-f] [-n <count>] [--run-id <id>]
```

`-f, --follow`
: Follow log output, similar to `tail -f`.

`-n, --lines <count>`
: Number of lines to show. Default: `50`.

`--run-id <id>`
: Show logs for a specific blueprint run instead of the latest.

### `openclaw nemoclaw eject`

Roll back from the sandbox and restore the host OpenClaw installation from a snapshot.

```console
$ openclaw nemoclaw eject [--run-id <id>] [--confirm]
```

`--run-id <id>`
: Specific blueprint run ID to rollback from. Without this, uses the most recent run.

`--confirm`
: Skip the confirmation prompt.

### `/nemoclaw` Slash Command

The `/nemoclaw` slash command is available inside the OpenClaw chat interface for quick actions:

| Subcommand | Description |
|---|---|
| `/nemoclaw status` | Show sandbox and inference state |
| `/nemoclaw eject` | Show rollback instructions |

## Standalone Wrapper Commands

The `nemoclaw` binary handles host-side operations that run outside the OpenClaw plugin context.

### `nemoclaw setup`

Run the full host-side setup: start an OpenShell gateway, register inference providers, build the sandbox image, and create the sandbox.

```console
$ nemoclaw setup
```

The first run prompts for your NVIDIA API key and saves it to `~/.nemoclaw/credentials.json`.

### `nemoclaw deploy`

Deploy NemoClaw to a remote GPU instance through [Brev](https://brev.nvidia.com).
The deploy script installs Docker, NVIDIA Container Toolkit if a GPU is present, and OpenShell on the VM, then runs setup and connects to the sandbox.

```console
$ nemoclaw deploy <instance-name>
```

### `nemoclaw <name> connect`

Connect to a sandbox by name.

```console
$ nemoclaw my-assistant connect
```

### `nemoclaw term`

Open the OpenShell TUI to monitor sandbox activity and approve network egress requests.

```console
$ nemoclaw term                  # local
$ nemoclaw term my-gpu-box       # remote Brev instance
```

### `nemoclaw start`

Start auxiliary services, such as the Telegram bridge and cloudflared tunnel.

```console
$ nemoclaw start
```

Requires `TELEGRAM_BOT_TOKEN` for the Telegram bridge.

### `nemoclaw stop`

Stop all auxiliary services.

```console
$ nemoclaw stop
```

### `nemoclaw status`

Show the status of running auxiliary services.

```console
$ nemoclaw status
```
