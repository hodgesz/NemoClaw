---
name: "nemoclaw-user-monitor-sandbox"
description: "Runs automated health checks across all NemoClaw services and receives alerts when failures are detected. Use when setting up monitoring for always-on assistants. Inspects sandbox health, traces agent behavior, and diagnoses problems. Use when monitoring a running sandbox, debugging agent issues, or checking sandbox logs."
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# NemoClaw User Monitor Sandbox

Runs automated health checks across all NemoClaw services and receives alerts when failures are detected. Use when setting up monitoring for always-on assistants.

## Prerequisites

- A running NemoClaw sandbox.
- The OpenShell CLI on your `PATH`.

The `scripts/health-check.sh` script probes all critical NemoClaw services and reports their status.
It can run interactively, on a timer, or in CI.
It optionally sends alerts when failures are detected.

## Step 1: What It Checks

The following table lists each check, what it probes, and how the probe works.

| Check | What it probes | How |
|-------|---------------|-----|
| **docker** | Docker daemon responsiveness | `docker info` |
| **gateway** | OpenShell gateway health | `openshell status` |
| **sandbox** | Sandbox readiness | `openshell sandbox get <name>` |
| **ssh** | SSH tunnel to sandbox | `ssh openshell-<name> 'echo ok'` |
| **inference** | Inference endpoint (LiteLLM, Ollama, vLLM/NIM, NVIDIA cloud) | `curl` health endpoints, `openshell provider list` |
| **dashboard** | Port forward to sandbox dashboard | `curl http://127.0.0.1:<port>/` |
| **bridge** | Telegram bridge process | PID file liveness check |
| **agent** | In-sandbox OpenClaw agent | `openclaw doctor` via SSH |

## Step 2: Usage

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
$ ./scripts/health-check.sh --skip bridge,agent
```

### Output Modes

**Pretty (default):** Colored terminal output with pass/fail indicators.

```console
$ ./scripts/health-check.sh

NemoClaw Health Check  (2026-04-06 08:15:00)
Sandbox: my-assistant  Gateway: nemoclaw

  ✓ docker: Docker daemon running
  ✓ gateway: Gateway 'nemoclaw' connected
  ✓ sandbox: Sandbox 'my-assistant' ready
  ✓ ssh: SSH tunnel to sandbox healthy
  ✓ inference: LiteLLM (port 4000)
  ✓ dashboard: Dashboard on port 18789
  ✓ bridge: Telegram bridge running (PID 12345)
  ✓ agent: openclaw doctor: passed (exit 0)

  All 8 checks passed (0 skipped)
```

**JSON:** Machine-readable output for scripting and dashboards.

```console
$ ./scripts/health-check.sh --json
```

**Quiet:** Exit code only (0 = all healthy, 1 = failures).

```console
$ ./scripts/health-check.sh --quiet && echo "healthy" || echo "unhealthy"
```

## Step 3: Alerting

Send a Telegram message when one or more checks fail:

```console
$ export TELEGRAM_BOT_TOKEN="your-bot-token"
$ export TELEGRAM_CHAT_ID="your-chat-id"
$ ./scripts/health-check.sh --alert telegram
```

When all checks pass, no alert is sent (silent success). This makes the script safe to run frequently on a timer without notification fatigue.

## Step 4: Running on a Schedule

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

## Linux (systemd timer)

Create a service and timer unit for scheduled execution.
See the systemd documentation for details.

## Step 5: HTML Status Page

Generate a self-contained HTML dashboard from the health check results:

```console
$ ./scripts/health-check-html.sh --sandbox my-assistant --open
```

The page auto-refreshes every 60 seconds. Pair with a scheduler to keep it up to date:

```console
$ watch -n 60 ./scripts/health-check-html.sh --sandbox my-assistant
```

The generated file is written to `/tmp/nemoclaw-status.html` by default, or specify `--output /path/to/file`.

## Step 6: Telegram /status Command

If you are running the Telegram bridge (`scripts/telegram-bridge.js`), send `/status` to the bot to get a health report directly in Telegram. This runs the same checks as the CLI script.

## Step 7: Configuration

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

## Step 8: Exit Codes

The script uses the following exit codes for scripting and CI integration.

| Code | Meaning |
|------|---------|
| `0` | All checks passed |
| `1` | One or more checks failed |
| `2` | Script error (bad arguments, missing dependencies) |

---

Use the NemoClaw status, logs, and TUI tools together to inspect sandbox health, trace agent behavior, and diagnose problems.

## Step 9: Check Sandbox Health

Run the status command to view the sandbox state, blueprint run information, and active inference configuration:

```console
$ nemoclaw <name> status
```

Key fields in the output include the following:

- Sandbox state, which indicates whether the sandbox is running, stopped, or in an error state.
- Blueprint run ID, which is the identifier for the most recent blueprint execution.
- Inference provider, which shows the active provider, model, and endpoint.

Run `nemoclaw <name> status` on the host to check sandbox state.
Use `openshell sandbox list` for the underlying sandbox details.

## Step 10: View Blueprint and Sandbox Logs

Stream the most recent log output from the blueprint runner and sandbox:

```console
$ nemoclaw <name> logs
```

To follow the log output in real time:

```console
$ nemoclaw <name> logs --follow
```

## Step 11: Monitor Network Activity in the TUI

Open the OpenShell terminal UI for a live view of sandbox network activity and egress requests:

```console
$ openshell term
```

For a remote sandbox, SSH to the instance and run `openshell term` there.

The TUI shows the following information:

- Active network connections from the sandbox.
- Blocked egress requests awaiting operator approval.
- Inference routing status.

Refer to Approve or Deny Agent Network Requests (see the `nemoclaw-user-manage-policy` skill) for details on handling blocked requests.

## Step 12: Test Inference

Run a test inference request to verify that the provider is responding:

```console
$ nemoclaw my-assistant connect
$ openclaw agent --agent main --local -m "Test inference" --session-id debug
```

If the request fails, check the following:

1. Run `nemoclaw <name> status` to confirm the active provider and endpoint.
2. Run `nemoclaw <name> logs --follow` to view error messages from the blueprint runner.
3. Verify that the inference endpoint is reachable from the host.

## Related Skills

- `nemoclaw-user-overview` — Recovery After Reboot to restore services after a host restart
- `nemoclaw-user-reference` — Troubleshooting for common issues and resolution steps
- `nemoclaw-user-manage-policy` — Approve or Deny Agent Network Requests for the operator approval flow
- `nemoclaw-user-configure-inference` — Switch Inference Providers to change the active provider
