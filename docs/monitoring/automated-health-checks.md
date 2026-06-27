---
title:
  page: "Automated Health Checks for NemoClaw Services"
  nav: "Automated Health Checks"
description:
  main: "Run automated health checks across all NemoClaw services and receive alerts when failures are detected."
  agent: "Runs automated health checks across all NemoClaw services and receives alerts when failures are detected. Use when setting up monitoring for always-on assistants."
keywords: ["nemoclaw health check", "nemoclaw monitoring", "service alerting"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "openshell", "monitoring", "health-check", "nemoclaw"]
content:
  type: how_to
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Automated Health Checks for NemoClaw Services

The `scripts/health-check.sh` script probes all critical NemoClaw services and reports their status.
It can run interactively, on a timer, or in CI.
It optionally sends alerts when failures are detected.

## What It Checks

The following table lists each check, what it probes, and how the probe works.

| Check | What it probes | How |
|-------|---------------|-----|
| **docker** | Docker daemon responsiveness | `docker info` |
| **gateway** | OpenShell gateway health | `openshell status` |
| **sandbox** | Sandbox readiness | `openshell sandbox get <name>` |
| **ssh** | SSH tunnel to sandbox | `ssh openshell-<name> 'echo ok'` |
| **inference** | Inference provider registered for the sandbox | reads the provider from `~/.nemoclaw/sandboxes.json`, verifies it via `openshell provider list` |
| **inference_live** | End-to-end inference round-trip | runs a minimal `openclaw agent` prompt via SSH |
| **dashboard** | Port forward to sandbox dashboard | `curl http://127.0.0.1:<port>/` |
| **bridge** | *(skipped in v0.0.68)* | the host Telegram bridge was removed in the native-channels migration; inbound Telegram is the sandbox's native telegram channel. Always reports `skip`. |
| **agent** | In-sandbox OpenClaw agent | `openclaw doctor` via SSH |
| **rules** | No pending unapproved network rules | `openshell rule get <name>` |
| **briefing** | Most recent morning-briefing result | reads `/tmp/nemoclaw-briefing-status.json` |

## Usage

Run all checks and print colored status:

```console
$ ./scripts/health-check.sh
```

Check a specific sandbox:

```console
$ ./scripts/health-check.sh --sandbox my-assistant
```

Skip checks that are not relevant to your setup:

```console
$ ./scripts/health-check.sh --skip agent
```

> Note: in v0.0.68 the `bridge` check is an always-`skip` stub (the host
> Telegram bridge was removed in the native-channels migration; inbound
> Telegram is the sandbox's native telegram channel). You don't need to
> skip it explicitly.

### Output Modes

**Pretty (default):** Colored terminal output with pass/fail indicators.

```console
$ ./scripts/health-check.sh

NemoClaw Health Check  (2026-06-27 12:52:20)
Sandbox: my-assistant  Gateway: nemoclaw

  ✓ docker: Docker daemon running
  ✓ gateway: Gateway 'nemoclaw' connected
  ✓ sandbox: Sandbox 'my-assistant' ready
  ✓ ssh: SSH tunnel to sandbox healthy
  ✓ inference: Provider 'gemini-api' registered
  ✓ inference_live: Inference probe OK
  ✓ dashboard: Dashboard on port 18789 (HTTP 200)
  – bridge: skipped
  ✓ agent: openclaw doctor: passed (exit 0)
  ✓ rules: No pending network rules
  ✓ briefing: Last briefing succeeded (2026-06-27T18:23:43Z)

  All 10 checks passed (1 skipped)
```

**JSON:** Machine-readable output for scripting and dashboards.

```console
$ ./scripts/health-check.sh --json
```

**Quiet:** Exit code only (0 = all healthy, 1 = failures).

```console
$ ./scripts/health-check.sh --quiet && echo "healthy" || echo "unhealthy"
```

## Alerting

Send a Telegram message when one or more checks fail:

```console
$ export TELEGRAM_BOT_TOKEN="your-bot-token"
$ export TELEGRAM_CHAT_ID="your-chat-id"
$ ./scripts/health-check.sh --alert telegram
```

When all checks pass, no alert is sent (silent success). This makes the script safe to run frequently on a timer without notification fatigue.

## Running on a Schedule

### macOS (launchd)

Create `~/Library/LaunchAgents/com.nemoclaw.health-check.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nemoclaw.health-check</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/NemoClaw/scripts/health-check.sh</string>
        <string>--sandbox</string>
        <string>my-assistant</string>
        <string>--alert</string>
        <string>telegram</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>StandardOutPath</key>
    <string>/tmp/nemoclaw-health-check.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/nemoclaw-health-check.log</string>
</dict>
</plist>
```

Load the agent:

```console
$ launchctl load ~/Library/LaunchAgents/com.nemoclaw.health-check.plist
```

### Linux (cron)

```console
$ crontab -e
# Check every 10 minutes, alert on failure
*/10 * * * * /path/to/NemoClaw/scripts/health-check.sh --sandbox my-assistant --alert telegram --quiet 2>&1 >> /tmp/nemoclaw-health-check.log
```

### Linux (systemd timer)

Create a service and timer unit for scheduled execution.
See the systemd documentation for details.

## HTML Status Page

Generate a self-contained HTML dashboard from the health check results:

```console
$ ./scripts/health-check-html.sh --sandbox my-assistant --open
```

The page auto-refreshes every 60 seconds. Pair with a scheduler to keep it up to date:

```console
$ watch -n 60 ./scripts/health-check-html.sh --sandbox my-assistant
```

The generated file is written to `/tmp/nemoclaw-status.html` by default, or specify `--output /path/to/file`.

## Telegram

In v0.0.68 the host-side Telegram bridge was removed in the native-channels
migration — inbound Telegram is now the sandbox's **native telegram channel**
(baked at onboard, polled by the in-sandbox `openclaw` process). The daily
morning briefing is delivered directly through the Telegram Bot API by
`scripts/morning-briefing.sh`; replies to the briefing arrive over the native
channel. Verify the poller is healthy by checking the sandbox logs for recent
`api.telegram.org/.../getUpdates` lines (allowed by the `telegram_bot` policy),
or run `./scripts/health-check.sh` and look at the `agent` / `inference_live`
checks.

## Configuration

Use these flags to customize which services are checked and how results are reported.

| Flag | Description | Default |
|------|-------------|---------|
| `--sandbox <name>` | Sandbox to check | `$NEMOCLAW_SANDBOX_NAME` or `my-assistant` |
| `--gateway <name>` | Gateway name | `$NEMOCLAW_GATEWAY_NAME` or `nemoclaw` |
| `--port <number>` | Dashboard port | `$DASHBOARD_PORT` or `18789` |
| `--alert <method>` | Alert method (`telegram`) | *(none — print only)* |
| `--skip <checks>` | Comma-separated checks to skip | *(none)* |
| `--json` | JSON output | *(off)* |
| `--quiet` / `-q` | Exit code only | *(off)* |

## Exit Codes

The script uses the following exit codes for scripting and CI integration.

| Code | Meaning |
|------|---------|
| `0` | All checks passed |
| `1` | One or more checks failed |
| `2` | Script error (bad arguments, missing dependencies) |

## Next Steps

- [Monitor Sandbox Activity](monitor-sandbox-activity.md) for manual inspection and debugging.
- [Recovery After Reboot](../recovery-after-reboot.md) to restore services after a host restart.
- [Troubleshooting](../reference/troubleshooting.md) for common issues and resolution steps.
