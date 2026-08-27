# Plan: migrate reboot/health scripts to OpenShell 0.0.44 + nemoclaw v0.0.68

Step 4/5/6 of the v0.0.68 fork upgrade. Steps 1–3 (land on main, fresh
re-onboard, morning-briefing rework) + step 3's watchdog retirement are DONE
(`main @ e129bbb0b` + `19c71f463`, local-only, runtime verified UP).

## Problem (verified against the live `my-assistant` sandbox, 2026-06-27)

Three host scripts are coupled to OpenShell 0.0.22 + the deleted host bridge.
Under 0.0.44 + v0.0.68 they are either broken, harmful, or obsolete:

1. **`scripts/apply-custom-policies.sh`** — central dependency, called by
   both `auto-start.sh` (RunAtLoad) and `recover-after-reboot.sh`.
   - **Step 1** (inject Brave/Gemini web search into `openclaw.json`):
     **obsolete + contract-violating**. Upstream bakes + hash-verifies
     `openclaw.json` at image build; `nemoclaw-start` says do not rewrite it
     at runtime. Brave is already baked + provider registered + `brave`
     policy preset applied (confirmed in `sandboxes.json` + sandbox log).
   - **Step 1b** (strip `channels.telegram` so the host bridge owns polling):
     **actively HARMFUL**. The host bridge is gone in v0.0.68; the native
     telegram channel is the only poller. Stripping it breaks Telegram.
   - **Step 2** (rewrite `.config-hash` to hide Step 1's mutation):
     circumvents an upstream integrity check. Obsolete once Step 1 goes.
   - **Step 3** (fetch-guard DNS patch, NemoClaw #1252 / OpenClaw #396):
     **GONE upstream**. The exact patched pattern
     (`GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured`) has
     **0 matches** in OpenClaw 2026.5.27's `dist/`. NemoClaw issue **#1252
     is CLOSED** ("Track removal of downstream OpenClaw trusted env-proxy DNS
     workaround"). Web search works through the proxy without the patch
     (confirmed: `openclaw infer web search` returns real Brave results).
   - **Step 4** (match `openclaw-gateway`, launch `openclaw gateway run`):
     `openclaw-gateway` doesn't exist in 0.0.44 (PID 462 is bare `openclaw`),
     so this always thinks the gateway is dead and launches a SECOND gateway.
     Duplicate-gateway risk — same class as the retired watchdog.
   - **Step 5** (device pairing): `openclaw devices approve` still exists;
     a device is already paired (confirmed). No-op-but-harmless.
   - **Step 6** (re-install custom skills): writes to
     `/sandbox/.openclaw-data/skills/` — **wrong path** in 0.0.44 (skills live
     at `/sandbox/.openclaw/skills/`). Repo `skills/` has 4 skills
     (adhd-planner, morning-briefing, nemoclaw-user-guide, personal-crm) —
     fork/personal content that legitimately needs re-install after rebuild.

2. **`scripts/recover-after-reboot.sh`** — mostly ALREADY CORRECT for 0.0.44
   (uses `openshell gateway select/start/status`, `openshell sandbox get`,
   `openshell provider`, `openshell inference set`, `openshell policy set`,
   `openshell forward`). Two issues:
   - **Step 4** recreates the stale Bedrock/Ollama/NVIDIA provider set, but
     this sandbox uses `gemini-api`. Idempotent + harmless, but wrong config.
   - **Step 5b** calls `apply-custom-policies.sh` (inherits all of #1's harm).

3. **`scripts/auto-start.sh`** — structurally fine for 0.0.44. Two issues:
   - **Step 3c** recreates the same stale provider set as #2.
   - **Step 4c** calls `apply-custom-policies.sh --skip-gemini` + a 30s
     gateway-restart wait loop built around the old "kill+respawn to reload
     the patch" model. Comment claims it's needed for fetch-guard + gateway
     restart + pairing + skills — only **skills** remains valid.

4. **`scripts/health-check.sh`** (step 5 of the upgrade):
   - **`check_bridge` + `fix_bridge`**: probe the deleted host Telegram
     bridge. `check_bridge` now false-FAILs every run (tokens set, no bridge
     → "Telegram bridge not running"). `fix_bridge` calls deleted
     `bridge-watchdog.sh` / `com.nemoclaw.telegram-bridge`.
   - **`check_inference`**: probes LiteLLM :4000 / Ollama :11434 / NIM :8000 /
     `nvidia-prod` — none is the actual `gemini-api` inference. False-fails
     unless `nvidia-prod` happens to exist. `check_inference_live` (end-to-end
     agent probe) is the honest signal; `check_inference` (port-sniff) is not.

## Design principles (from feedback memories)

- **No hacky distro changes** (minimize fork divergence): drop the dead
  fetch-guard patch instead of updating it. #1252 is closed upstream.
- **Check upstream first**: already did — #1252 closed, patched pattern gone
  from 2026.5.27 dist, native channels + #4710 watchdog + #2757 respawn in
  `nemoclaw-start`.
- **Separate fork from upstream**: the personal skills (adhd-planner,
  personal-crm) + morning-briefing skill are fork-only and stay fork-only.
- **Stay on main**: all commits on `main`, local-only, push only with your
  explicit confirmation.
- **Confirm before push / remote action**: no push in this plan; host-side
  LaunchAgent edits are visible + reversible (committed templates).

## Approach decision

Per the watchdog precedent (retire, don't rewrite — upstream owns the
runtime concern now), apply the same logic: **retire what upstream now owns,
keep only genuine fork concerns, talk to the sandbox via the modern
`openshell` host CLI + SSH (not the dead `docker exec openshell-cluster-* ctr`
path).** No script in this plan will mutate `openclaw.json` or rewrite
`.config-hash` at runtime.

## Implementation (4 commits, each verified independently)

### Commit 1 — rewrite `apply-custom-policies.sh` to a thin, safe post-build layer

Replace the 6 broken steps with 3 honest ones. Drop `CLUSTER_CONTAINER` /
`docker exec … ctr` entirely; use SSH to the sandbox like `morning-briefing.sh`.

- **Step 1: Re-install custom skills** → `scp`/ssh each `skills/*/SKILL.md`
  into `/sandbox/.openclaw/skills/<name>/SKILL.md` (the CORRECT 0.0.44 path).
  Keep `--skip-skills`. This is the only genuinely fork-needed action.
- **Step 2: Verify inference provider** (read-only) → `openshell inference`
  lists/queries the registered provider; warn (don't fix) if the sandbox's
  `gemini-api` provider is missing. Replaces old Step 1 (config injection).
- **Step 3: Verify telegram channel** (read-only) → `openshell`/ssh confirms
  the native telegram channel is present and polling; warn if absent. NEVER
  strip it. Replaces old Step 1b (which stripped it).
- **DROP** old Steps 1 (config inject), 1b (strip telegram), 2 (hash
  rewrite), 3 (fetch-guard patch — #1252 closed), 4 (gateway launch —
  in-sandbox supervisor owns it), 5 (pairing — already paired, read-only
  check only if kept at all).
- Update the header comment block (the "What it does" list) to match, and
  drop `Requires: GEMINI_API_KEY` (no longer needed).
- Keep `--dry-run`, `--sandbox`, colors, summary box (adjust labels).
- Keep `set -euo pipefail`, SPDX header, shellcheck-clean, shfmt-clean.

Why rewrite-not-delete: both `auto-start.sh` and `recover-after-reboot.sh`
call it; a thin skill-installer + read-only verifier is genuinely useful
post-rebuild and keeps those callers honest. Personal skills are the real
fork value.

### Commit 2 — slim `auto-start.sh` provider set + drop the gateway-restart loop

- **Step 3c**: replace the hardcoded Bedrock/Ollama/NVIDIA provider
  re-creates with a single `openshell inference`/`openshell provider list`
  read-only check that the sandbox's provider (read from
  `~/.nemoclaw/sandboxes.json`: `gemini-api`) is registered; warn if not.
  Do NOT recreate stale providers. (LiteLLM :4000 itself is separately
  supervised by its own LaunchAgent — leave that wait as-is.)
- **Step 4c**: keep the `apply-custom-policies.sh` call (now a thin
  skill-installer, post Commit 1) but DROP the 30s "wait for in-sandbox
  gateway to restart" loop (247-264) — there's no patch to reload, and the
  in-sandbox #4710 supervisor owns gateway health. Replace with a single
  read-only `/health` probe for the summary log.
- Update the Step 4c comment (236-238) — remove "fetch-guard DNS patch" and
  "gateway restart" from the justification; keep "custom skill installation"
  + "verify telegram channel".
- Leave `setup-dns-proxy.sh` (Step 4d) as-is — it's a thin wrapper to the TS
  command, not a distro hack; only act if verification shows it breaks.

### Commit 3 — slim `recover-after-reboot.sh` provider set

- **Step 4**: same provider-set slim as Commit 2 (read-only check against
  `gemini-api`), drop the stale Bedrock/Ollama/NVIDIA/compatible-endpoint
  re-creates. Keep `--provider nvidia|ollama|bedrock` switch but make the
  switch path use `openshell inference set` (it already does) gated on a
  provider that actually exists. Drop the "ensure_provider" legacy block
  entirely or gate it behind `--provider`.
- **Step 5b**: keep the `apply-custom-policies.sh` call (now thin, post
  Commit 1). No other change needed — it was the only broken dependency.
- Step 3b (LiteLLM wait) is fine (it's `--provider bedrock`-gated) — leave.

### Commit 4 — health-check.sh: drop bridge, fix inference (upgrade step 5)

- **Remove `check_bridge`** (call + `fix_bridge` + the `bridge` entry in
  `REMEDIATION_ORDER` + `get_fix_func` + the run-all `check_bridge` line).
  Bridge is gone in v0.0.68; a false-fail every run is worse than no check.
- **Rewrite `check_inference`**: instead of port-sniffing LiteLLM/Ollama/NIM/
  `nvidia-prod`, read the sandbox's provider from
  `~/.nemoclaw/sandboxes.json` and confirm it's registered via
  `openshell provider list` (read-only). `check_inference_live` (end-to-end
  agent probe) stays as the authoritative signal — `check_inference` becomes
  a quick provider-registration gate, not a port check.
- **`fix_inference` / `fix_inference_live`**: drop the LiteLLM-restart +
  compatible-endpoint-recreate legacy; if provider missing, warn only
  (no safe auto-fix for `gemini-api` without the user's API key). Keep
  `fix_*` returning 0 so remediation doesn't error.
- Keep gateway / sandbox / ssh / dashboard / agent / rules / briefing
  checks. `check_agent` (`openclaw doctor`) is now SAFE (watchdog retired,
  #4710 supervisor in place) — keep but it remains opt-in-ish (heavy).
- No LaunchAgent change (no `com.nemoclaw.health-check` template edit needed
  — the installed plist just runs the script; behavior is cleaner now).

### Verification (after each commit; full re-run after Commit 4)

- `bash scripts/apply-custom-policies.sh --sandbox my-assistant --dry-run`
  → shows skill-install + read-only checks, exits 0.
- `bash scripts/apply-custom-policies.sh --sandbox my-assistant`
  → installs skills to `/sandbox/.openclaw/skills/`, verifies
  provider+channel read-only, exits 0, NO `openclaw.json`/hash mutation
  (verify: `sha256sum /sandbox/.openclaw/openclaw.json` unchanged before/after;
  sandbox log: no "integrity check FAILED"; native telegram poller still
  polling `getUpdates` every ~30s, no 409).
- `bash scripts/recover-after-reboot.sh --sandbox my-assistant --dry-run`
  → clean dry-run, no stale provider re-creates.
- `bash scripts/health-check.sh --sandbox my-assistant` → no false
  `bridge` fail; `inference` passes via `gemini-api` provider; overall
  exit 0 (or skip-only on opt-in checks).
- `bash scripts/morning-briefing.sh --chat-id 7236389286` → still
  `(status: ok)` (regression check — skills install path change must not
  affect the briefing).
- Sandbox stays `Up (healthy)` throughout; dashboard :18789 HTTP 200;
  no duplicate `openclaw` gateway process.
- After all 4 commits: `npx prek run --all-files` to run the full hook
  suite (shfmt/shellcheck/SPDX/gitleaks/commitlint already pass per-commit).

### Out of scope / deferred

- `setup-dns-proxy.sh` deep-rewrite (only if verification shows it breaks).
- Stray `fix/ci-pipefail-docker-save` branch retarget (noted in memory).
- Push to `origin/main` (separate explicit-confirmation step after green).
- Memory updates (architecture inference chain, retire bridge/dual-bot
  memories) — after the runtime+scripts are fully green.
- Docs (`docs/monitoring/automated-health-checks.md`, `docs/recovery-after-
  reboot.md`) — a docs-writer subagent pass after the scripts land, per
  CLAUDE.md "documentation" guidance.

## Risk / blast radius

- All 4 commits are fork-only script glue (`scripts/`). No `src/lib/`,
  `nemoclaw/src/`, or upstream code touched. No build impact, no TS.
- Touches NO installed LaunchAgents (no plist edits) — the installed
  `auto-start`/`health-check`/`recover` plists just invoke the scripts;
  improved script behavior surfaces with no reload needed. (If a reload is
  wanted after Commit 4, `launchctl kickstart -k gui/$(id -u)/com.nemoclaw.*`
  is optional and I will ask first.)
- The native telegram channel + in-sandbox supervisor are untouched; the
  only runtime write is skill files under `/sandbox/.openclaw/skills/`.
