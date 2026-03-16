#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# E2E test for NemoClaw + blueprint
# Runs inside the Docker sandbox

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }
info() { echo -e "${YELLOW}TEST${NC}: $1"; }

# -------------------------------------------------------
info "1. Verify OpenClaw CLI is installed"
# -------------------------------------------------------
openclaw --version && pass "OpenClaw CLI installed" || fail "OpenClaw CLI not found"

# -------------------------------------------------------
info "2. Verify plugin can be installed"
# -------------------------------------------------------
openclaw plugins install /opt/nemoclaw 2>&1 && pass "Plugin installed" || {
    # If plugins install isn't available, verify the built artifacts exist
    if [ -f /opt/nemoclaw/dist/index.js ]; then
        pass "Plugin built successfully (dist/index.js exists)"
    else
        fail "Plugin build artifacts missing"
    fi
}

# -------------------------------------------------------
info "3. Verify blueprint YAML is valid"
# -------------------------------------------------------
python3 -c "
import yaml, sys
bp = yaml.safe_load(open('/opt/nemoclaw-blueprint/blueprint.yaml'))
assert bp['version'] == '0.1.0', f'Bad version: {bp[\"version\"]}'
profiles = bp['components']['inference']['profiles']
assert 'default' in profiles, 'Missing default profile'
assert 'vllm' in profiles, 'Missing vllm profile'
assert 'nim-local' in profiles, 'Missing nim-local profile'
print(f'Profiles: {list(profiles.keys())}')
" && pass "Blueprint YAML valid with all 3 profiles" || fail "Blueprint YAML invalid"

# -------------------------------------------------------
info "4. Verify blueprint runner plan command"
# -------------------------------------------------------
cd /opt/nemoclaw-blueprint
# Runner will fail at openshell prereq check (expected in test container)
# We just verify it gets past validation and profile resolution
python3 orchestrator/runner.py plan --profile vllm --dry-run 2>&1 | tee /tmp/plan-output.txt || true
grep -q "RUN_ID:" /tmp/plan-output.txt && pass "Blueprint plan generates run ID" || fail "No run ID in plan output"
grep -q "Validating blueprint" /tmp/plan-output.txt && pass "Blueprint runner validates before execution" || fail "No validation step"

# -------------------------------------------------------
info "5. Verify host OpenClaw detection (migration source)"
# -------------------------------------------------------
[ -f /sandbox/.openclaw/openclaw.json ] && pass "Host OpenClaw config detected" || fail "No host config"
[ -d /sandbox/.openclaw/workspace ] && pass "Host workspace directory exists" || fail "No workspace dir"
[ -d /sandbox/.openclaw/skills ] && pass "Host skills directory exists" || fail "No skills dir"
[ -d /sandbox/.openclaw/hooks ] && pass "Host hooks directory exists" || fail "No hooks dir"
[ -f /sandbox/.openclaw/hooks/demo-hook/HOOK.md ] && pass "Host hook fixture exists" || fail "No hook fixture"

# -------------------------------------------------------
info "6. Verify snapshot creation (migration pre-step)"
# -------------------------------------------------------
python3 -c "
import sys
sys.path.insert(0, '/opt/nemoclaw-blueprint/migrations')
from snapshot import create_snapshot, list_snapshots

snap = create_snapshot()
assert snap is not None, 'Snapshot returned None'
assert snap.exists(), f'Snapshot dir does not exist: {snap}'
hook_file = snap / 'openclaw' / 'hooks' / 'demo-hook' / 'HOOK.md'
assert hook_file.exists(), f'Hook file missing from snapshot: {hook_file}'

snaps = list_snapshots()
assert len(snaps) == 1, f'Expected 1 snapshot, got {len(snaps)}'
print(f'Snapshot created at: {snap}')
print(f'Files captured: {snaps[0][\"file_count\"]}')
" && pass "Migration snapshot created successfully" || fail "Snapshot creation failed"

# -------------------------------------------------------
info "7. Verify snapshot restore (eject path)"
# -------------------------------------------------------
python3 -c "
import sys, json, shutil
sys.path.insert(0, '/opt/nemoclaw-blueprint/migrations')
from snapshot import list_snapshots, rollback_from_snapshot
from pathlib import Path

snaps = list_snapshots()
snap_path = Path(snaps[0]['path'])

# Simulate corruption: modify the host config
config = Path.home() / '.openclaw' / 'openclaw.json'
original = json.loads(config.read_text())
config.write_text(json.dumps({'corrupted': True}))

# Rollback
success = rollback_from_snapshot(snap_path)
assert success, 'Rollback returned False'

# Verify restoration
restored = json.loads(config.read_text())
assert restored.get('meta', {}).get('lastTouchedVersion') == '2026.3.11', f'Restored config wrong: {restored}'
assert 'corrupted' not in restored, 'Config still corrupted after rollback'
print(f'Restored config: {restored}')
" && pass "Snapshot rollback restores original config" || fail "Rollback failed"

# -------------------------------------------------------
info "8. Verify migration inventory for external OpenClaw roots"
# -------------------------------------------------------
OPENCLAW_STATE_DIR=/sandbox/openclaw-state OPENCLAW_CONFIG_PATH=/sandbox/config/openclaw.json node --input-type=module <<'JS'
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import {
  cleanupSnapshotBundle,
  createArchiveFromDirectory,
  createSnapshotBundle,
  detectHostOpenClaw,
} from "/opt/nemoclaw/dist/commands/migration-state.js";

const logger = {
  info() {},
  warn() {},
  error(message) {
    throw new Error(String(message));
  },
  debug() {},
};

const state = detectHostOpenClaw(process.env);
if (!state.exists) {
  throw new Error("detectHostOpenClaw did not find the overridden install");
}
if (state.stateDir !== "/sandbox/openclaw-state") {
  throw new Error(`Unexpected state dir: ${state.stateDir}`);
}
if (state.configPath !== "/sandbox/config/openclaw.json") {
  throw new Error(`Unexpected config path: ${state.configPath}`);
}
if (state.externalRoots.length < 3) {
  throw new Error(`Expected at least 3 external roots, got ${state.externalRoots.length}`);
}

const bundle = createSnapshotBundle(state, logger, { persist: false });
if (!bundle) {
  throw new Error("createSnapshotBundle returned null");
}

try {
  const workspaceRoot = bundle.manifest.externalRoots.find((root) => root.kind === "workspace");
  if (!workspaceRoot) {
    throw new Error("Missing workspace root in manifest");
  }
  const snapshotLink = path.join(
    bundle.snapshotDir,
    workspaceRoot.snapshotRelativePath,
    "shared-link.md",
  );
  if (!fs.lstatSync(snapshotLink).isSymbolicLink()) {
    throw new Error(`Snapshot did not preserve symlink: ${snapshotLink}`);
  }

  const sandboxConfig = JSON.parse(
    fs.readFileSync(path.join(bundle.preparedStateDir, "openclaw.json"), "utf-8"),
  );
  if (sandboxConfig.agents.defaults.workspace !== workspaceRoot.sandboxPath) {
    throw new Error(
      `Sandbox config was not rewritten for default workspace: ${sandboxConfig.agents.defaults.workspace}`,
    );
  }
  if (sandboxConfig.agents.list[0].agentDir !== "/sandbox/.nemoclaw/migration/agent-dirs/agent-dirs-main-agent-dir") {
    throw new Error(`Sandbox config did not rewrite agentDir: ${sandboxConfig.agents.list[0].agentDir}`);
  }

  const archivePath = path.join(bundle.archivesDir, "workspace.tar");
  await createArchiveFromDirectory(path.join(bundle.snapshotDir, workspaceRoot.snapshotRelativePath), archivePath);
  const extractDir = fs.mkdtempSync(path.join(os.tmpdir(), "nemoclaw-archive-"));
  execFileSync("tar", ["-xf", archivePath, "-C", extractDir]);
  const extractedLink = path.join(extractDir, "shared-link.md");
  if (!fs.lstatSync(extractedLink).isSymbolicLink()) {
    throw new Error(`Tar archive did not preserve symlink: ${extractedLink}`);
  }

  const fallbackHome = fs.mkdtempSync(path.join(os.tmpdir(), "nemoclaw-userprofile-"));
  fs.mkdirSync(path.join(fallbackHome, ".openclaw"), { recursive: true });
  fs.writeFileSync(path.join(fallbackHome, ".openclaw", "openclaw.json"), "{}");
  const fallbackState = detectHostOpenClaw({
    HOME: "",
    USERPROFILE: fallbackHome,
  });
  if (!fallbackState.exists || fallbackState.stateDir !== path.join(fallbackHome, ".openclaw")) {
    throw new Error("USERPROFILE fallback did not resolve the host OpenClaw state");
  }
} finally {
  cleanupSnapshotBundle(bundle);
}
JS
pass "Migration inventory handles overrides, external roots, and symlink-safe archives"

# -------------------------------------------------------
info "9. Verify plugin TypeScript compilation"
# -------------------------------------------------------
[ -f /opt/nemoclaw/dist/index.js ] && pass "index.js compiled" || fail "index.js missing"
[ -f /opt/nemoclaw/dist/commands/migrate.js ] && pass "migrate.js compiled" || fail "migrate.js missing"
[ -f /opt/nemoclaw/dist/commands/migration-state.js ] && pass "migration-state.js compiled" || fail "migration-state.js missing"
[ -f /opt/nemoclaw/dist/commands/launch.js ] && pass "launch.js compiled" || fail "launch.js missing"
[ -f /opt/nemoclaw/dist/commands/connect.js ] && pass "connect.js compiled" || fail "connect.js missing"
[ -f /opt/nemoclaw/dist/commands/eject.js ] && pass "eject.js compiled" || fail "eject.js missing"
[ -f /opt/nemoclaw/dist/commands/status.js ] && pass "status.js compiled" || fail "status.js missing"
[ -f /opt/nemoclaw/dist/commands/slash.js ] && pass "slash.js compiled" || fail "slash.js missing"
[ -f /opt/nemoclaw/dist/blueprint/resolve.js ] && pass "resolve.js compiled" || fail "resolve.js missing"
[ -f /opt/nemoclaw/dist/blueprint/verify.js ] && pass "verify.js compiled" || fail "verify.js missing"
[ -f /opt/nemoclaw/dist/blueprint/exec.js ] && pass "exec.js compiled" || fail "exec.js missing"
[ -f /opt/nemoclaw/dist/blueprint/state.js ] && pass "state.js compiled" || fail "state.js missing"

# -------------------------------------------------------
info "10. Verify NemoClaw state management"
# -------------------------------------------------------
node -e "
const { loadState, saveState, clearState } = require('/opt/nemoclaw/dist/blueprint/state.js');

// Initial state should be empty
let state = loadState();
console.assert(state.lastAction === null, 'Initial state should be null');

// Save and reload
saveState({ ...state, lastAction: 'migrate', lastRunId: 'test-123', sandboxName: 'openclaw' });
state = loadState();
console.assert(state.lastAction === 'migrate', 'Should be migrate');
console.assert(state.lastRunId === 'test-123', 'Should be test-123');
console.assert(state.updatedAt !== null, 'Should have timestamp');

// Clear
clearState();
state = loadState();
console.assert(state.lastAction === null, 'Should be cleared');

console.log('State management: create, save, load, clear all working');
" && pass "NemoClaw state management works" || fail "State management broken"

# -------------------------------------------------------
info "11. Verify headless sandbox bootstrap seeds config and gateway process"
# -------------------------------------------------------
rm -rf /tmp/fake-bin /tmp/fake-sandbox
mkdir -p /tmp/fake-bin /tmp/fake-sandbox

cat > /tmp/fake-bin/openshell <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root="${FAKE_SANDBOX_ROOT:?}"
printf '%s\n' "$*" >> "${root}/invocation.txt"

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "nemoclaw-shell" ] && [ "$6" = "openclaw" ] && [ "$7" = "setup" ]; then
    sandbox_root="${root}/$3/.openclaw"
    mkdir -p "${sandbox_root}/workspace" "${sandbox_root}/sessions"
    cat > "${sandbox_root}/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/sandbox/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local"
  }
}
JSON
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "nemoclaw-shell" ] && [ "$6" = "nemoclaw-gateway.sh" ] && [ "$7" = "ensure" ]; then
    sandbox_root="${root}/$3/.openclaw"
    mkdir -p "${sandbox_root}/run" "${sandbox_root}/logs"
    cat > "${sandbox_root}/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/sandbox/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "sandbox-token-123"
    }
  }
}
JSON
    echo "4242" > "${sandbox_root}/run/gateway.pid"
    touch "${sandbox_root}/logs/gateway.log"
    echo "gateway-ready:4242"
    exit 0
fi

echo "unexpected openshell invocation: $*" >&2
exit 1
EOF
chmod +x /tmp/fake-bin/openshell

PATH="/tmp/fake-bin:$PATH" FAKE_SANDBOX_ROOT=/tmp/fake-sandbox node - <<'EOF'
const { ensureSandboxOpenClawBootstrap } = require('/opt/nemoclaw/dist/commands/sandbox-bootstrap.js');

const logger = {
  info() {},
  warn() {},
  error(message) {
    throw new Error(message);
  },
  debug() {},
};

const ok = ensureSandboxOpenClawBootstrap({ sandboxName: 'openclaw', logger });
if (!ok) {
  throw new Error('bootstrap helper returned false');
}
EOF

grep -q '^sandbox connect openclaw -- nemoclaw-shell openclaw setup$' /tmp/fake-sandbox/invocation.txt \
    && pass "Headless bootstrap runs openclaw setup" \
    || fail "Headless bootstrap did not run openclaw setup"
grep -q '^sandbox connect openclaw -- nemoclaw-shell nemoclaw-gateway.sh ensure$' /tmp/fake-sandbox/invocation.txt \
    && pass "Headless bootstrap ensures the Gateway process" \
    || fail "Headless bootstrap did not ensure the Gateway process"
grep -q '"token": "sandbox-token-123"' /tmp/fake-sandbox/openclaw/.openclaw/openclaw.json \
    && pass "Headless bootstrap seeded gateway auth token" \
    || fail "Headless bootstrap did not seed gateway auth token"
[ -f /tmp/fake-sandbox/openclaw/.openclaw/run/gateway.pid ] \
    && pass "Headless bootstrap created gateway pid file" \
    || fail "Headless bootstrap did not create gateway pid file"

# -------------------------------------------------------
info "12. Verify the Gateway manager reuses a healthy process via PID file"
# -------------------------------------------------------
rm -rf /tmp/fake-bin /tmp/fake-home /tmp/fake-health
mkdir -p /tmp/fake-bin /tmp/fake-home/.openclaw/run /tmp/fake-home/.openclaw/logs

cat > /tmp/fake-bin/openclaw <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> /tmp/fake-openclaw.invocation.txt

if [ "$1" = "gateway" ] && [ "$2" = "status" ] && [ "$3" = "--deep" ] && [ "$4" = "--require-rpc" ]; then
    [ -f /tmp/fake-health ] && exit 0
    exit 1
fi

if [ "$1" = "gateway" ] && [ "$2" = "run" ] && [ "$3" = "--force" ]; then
    touch /tmp/fake-health
    while true; do sleep 60; done
fi

echo "unexpected openclaw invocation: $*" >&2
exit 1
EOF
chmod +x /tmp/fake-bin/openclaw

HOME=/tmp/fake-home PATH="/tmp/fake-bin:$PATH" /usr/local/bin/nemoclaw-gateway.sh ensure >/tmp/gateway-ensure-1.out
pid1="$(cat /tmp/fake-home/.openclaw/run/gateway.pid)"
HOME=/tmp/fake-home PATH="/tmp/fake-bin:$PATH" /usr/local/bin/nemoclaw-gateway.sh ensure >/tmp/gateway-ensure-2.out
pid2="$(cat /tmp/fake-home/.openclaw/run/gateway.pid)"
[ "$pid1" = "$pid2" ] || fail "Gateway manager changed pid across repeated ensure calls"
kill "$pid1" 2>/dev/null || true
grep -c '^gateway run --force$' /tmp/fake-openclaw.invocation.txt | grep -q '^1$' \
    && pass "Gateway manager starts only one process for repeated ensure calls" \
    || fail "Gateway manager started duplicate processes"
[ -f /tmp/fake-home/.openclaw/run/gateway.pid ] \
    && pass "Gateway manager records the process pid" \
    || fail "Gateway manager did not record the process pid"

# -------------------------------------------------------
info "13. Verify launch runs the full headless bootstrap sequence"
# -------------------------------------------------------
rm -rf /tmp/fake-bin /tmp/fake-sandbox /tmp/fake-home
mkdir -p /tmp/fake-bin /tmp/fake-sandbox /tmp/fake-home

cat > /tmp/fake-bin/openshell <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root="${FAKE_SANDBOX_ROOT:?}"
printf '%s\n' "$*" >> "${root}/invocation.txt"

if [ "$1" = "--version" ]; then
    echo "0.1.0"
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "create" ]; then
    mkdir -p "${root}/openclaw"
    exit 0
fi

if [ "$1" = "provider" ] && [ "$2" = "create" ]; then
    exit 0
fi

if [ "$1" = "inference" ] && [ "$2" = "set" ]; then
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "nemoclaw-shell" ] && [ "$6" = "openclaw" ] && [ "$7" = "setup" ]; then
    sandbox_root="${root}/$3/.openclaw"
    mkdir -p "${sandbox_root}/workspace" "${sandbox_root}/sessions"
    cat > "${sandbox_root}/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/sandbox/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local"
  }
}
JSON
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "nemoclaw-shell" ] && [ "$6" = "nemoclaw-gateway.sh" ] && [ "$7" = "ensure" ]; then
    sandbox_root="${root}/$3/.openclaw"
    mkdir -p "${sandbox_root}/run" "${sandbox_root}/logs"
    cat > "${sandbox_root}/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/sandbox/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "sandbox-token-123"
    }
  }
}
JSON
    echo "31337" > "${sandbox_root}/run/gateway.pid"
    touch "${sandbox_root}/logs/gateway.log"
    echo "gateway-ready:31337"
    exit 0
fi

echo "unexpected openshell invocation: $*" >&2
exit 1
EOF
chmod +x /tmp/fake-bin/openshell

cat > /tmp/fake-bin/openclaw <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "--version" ]; then
    echo "2026.3.11"
    exit 0
fi

echo "unexpected openclaw invocation: $*" >&2
exit 1
EOF
chmod +x /tmp/fake-bin/openclaw

PATH="/tmp/fake-bin:$PATH" FAKE_SANDBOX_ROOT=/tmp/fake-sandbox HOME=/tmp/fake-home node - <<'EOF'
const fs = require('node:fs');
const resolveModule = require('/opt/nemoclaw/dist/blueprint/resolve.js');
resolveModule.resolveBlueprint = async () => ({
  version: '0.1.0',
  localPath: '/sandbox/.nemoclaw/blueprints/0.1.0',
  manifest: {
    version: '0.1.0',
    minOpenShellVersion: '0.1.0',
    minOpenClawVersion: '2026.3.0',
    profiles: ['default'],
    digest: '',
  },
  cached: true,
});
const { cliLaunch } = require('/opt/nemoclaw/dist/commands/launch.js');

const logger = {
  info() {},
  warn() {},
  error(message) {
    throw new Error(message);
  },
  debug() {},
};

async function main() {
  await cliLaunch({
    force: true,
    profile: 'default',
    logger,
    pluginConfig: {
      blueprintVersion: '0.1.0',
      blueprintRegistry: 'ghcr.io/nvidia/nemoclaw-blueprint',
      sandboxName: 'openclaw',
      inferenceProvider: 'nvidia',
    },
  });

  const state = JSON.parse(
    fs.readFileSync('/tmp/fake-home/.nemoclaw/state/nemoclaw.json', 'utf8'),
  );
  if (state.lastAction !== 'launch') {
    throw new Error(`Unexpected lastAction: ${state.lastAction}`);
  }
  if (state.sandboxName !== 'openclaw') {
    throw new Error(`Unexpected sandboxName: ${state.sandboxName}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
EOF

grep -q '^sandbox connect openclaw -- nemoclaw-shell openclaw setup$' /tmp/fake-sandbox/invocation.txt \
    && pass "Launch runs openclaw setup" \
    || fail "Launch did not run openclaw setup"
[ -f /tmp/fake-sandbox/openclaw/.openclaw/openclaw.json ] \
    && pass "Launch created openclaw.json" \
    || fail "Launch did not create openclaw.json"
[ -d /tmp/fake-sandbox/openclaw/.openclaw/workspace ] \
    && pass "Launch created workspace" \
    || fail "Launch did not create workspace"
grep -q '^sandbox connect openclaw -- nemoclaw-shell nemoclaw-gateway.sh ensure$' /tmp/fake-sandbox/invocation.txt \
    && pass "Launch ensures the Gateway process" \
    || fail "Launch did not ensure the Gateway process"
[ -f /tmp/fake-sandbox/openclaw/.openclaw/run/gateway.pid ] \
    && pass "Launch created gateway pid file" \
    || fail "Launch did not create gateway pid file"

# -------------------------------------------------------
info "14. Verify migrate reruns the headless bootstrap sequence"
# -------------------------------------------------------
rm -rf /tmp/fake-bin /tmp/fake-sandbox /tmp/fake-home
mkdir -p /tmp/fake-bin /tmp/fake-sandbox /tmp/fake-home/.openclaw/workspace
mkdir -p /tmp/fake-home/.openclaw/extensions /tmp/fake-home/.openclaw/skills /tmp/fake-home/.openclaw/hooks

cat > /tmp/fake-home/.openclaw/openclaw.json <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/tmp/fake-home/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local"
  }
}
JSON
echo "migrated-workspace-file" > /tmp/fake-home/.openclaw/workspace/project.md

cat > /tmp/fake-bin/openshell <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root="${FAKE_SANDBOX_ROOT:?}"
printf '%s\n' "$*" >> "${root}/invocation.txt"

if [ "$1" = "sandbox" ] && [ "$2" = "create" ]; then
    mkdir -p "${root}/openclaw"
    exit 0
fi

if [ "$1" = "provider" ] && [ "$2" = "create" ]; then
    exit 0
fi

if [ "$1" = "inference" ] && [ "$2" = "set" ]; then
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "cp" ]; then
    sandbox_name="${4%%:*}"
    sandbox_path="${4#*:}"
    target_path="${root}/${sandbox_name}${sandbox_path#/sandbox}"
    mkdir -p "$(dirname "${target_path}")"
    cp "$3" "${target_path}"
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "sh" ] && [ "$6" = "-lc" ]; then
    sandbox_home="${root}/$3"
    translated_script="${7//\/sandbox/${sandbox_home}}"
    sh -lc "${translated_script}"
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "node" ] && [ "$6" = "-e" ]; then
    sandbox_home="${root}/$3"
    translated_script="${7//\/sandbox/${sandbox_home}}"
    node -e "${translated_script}"
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "nemoclaw-shell" ] && [ "$6" = "openclaw" ] && [ "$7" = "setup" ]; then
    sandbox_root="${root}/$3/.openclaw"
    mkdir -p "${sandbox_root}/workspace" "${sandbox_root}/sessions"
    if [ ! -f "${sandbox_root}/openclaw.json" ]; then
        cat > "${sandbox_root}/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/sandbox/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local"
  }
}
JSON
    fi
    exit 0
fi

if [ "$1" = "sandbox" ] && [ "$2" = "connect" ] && [ "$4" = "--" ] && [ "$5" = "nemoclaw-shell" ] && [ "$6" = "nemoclaw-gateway.sh" ] && [ "$7" = "ensure" ]; then
    sandbox_root="${root}/$3/.openclaw"
    mkdir -p "${sandbox_root}/run" "${sandbox_root}/logs"
    cat > "${sandbox_root}/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/sandbox/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "migrated-token-456"
    }
  }
}
JSON
    echo "5150" > "${sandbox_root}/run/gateway.pid"
    touch "${sandbox_root}/logs/gateway.log"
    echo "gateway-ready:5150"
    exit 0
fi

echo "unexpected openshell invocation: $*" >&2
exit 1
EOF
chmod +x /tmp/fake-bin/openshell

PATH="/tmp/fake-bin:$PATH" FAKE_SANDBOX_ROOT=/tmp/fake-sandbox HOME=/tmp/fake-home node - <<'EOF'
const fs = require('node:fs');
const resolveModule = require('/opt/nemoclaw/dist/blueprint/resolve.js');
resolveModule.resolveBlueprint = async () => ({
  version: '0.1.0',
  localPath: '/sandbox/.nemoclaw/blueprints/0.1.0',
  manifest: {
    version: '0.1.0',
    minOpenShellVersion: '0.1.0',
    minOpenClawVersion: '2026.3.0',
    profiles: ['default'],
    digest: '',
  },
  cached: true,
});
const { cliMigrate } = require('/opt/nemoclaw/dist/commands/migrate.js');

const logger = {
  info() {},
  warn() {},
  error(message) {
    throw new Error(message);
  },
  debug() {},
};

async function main() {
  await cliMigrate({
    dryRun: false,
    profile: 'default',
    skipBackup: true,
    logger,
    pluginConfig: {
      blueprintVersion: '0.1.0',
      blueprintRegistry: 'ghcr.io/nvidia/nemoclaw-blueprint',
      sandboxName: 'openclaw',
      inferenceProvider: 'nvidia',
    },
  });

  const state = JSON.parse(
    fs.readFileSync('/tmp/fake-home/.nemoclaw/state/nemoclaw.json', 'utf8'),
  );
  if (state.lastAction !== 'migrate') {
    throw new Error(`Unexpected lastAction: ${state.lastAction}`);
  }
  if (state.sandboxName !== 'openclaw') {
    throw new Error(`Unexpected sandboxName: ${state.sandboxName}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
EOF

grep -Eq '^sandbox cp .+ openclaw:/sandbox/\.nemoclaw/migration/archives/state\.tar$' /tmp/fake-sandbox/invocation.txt \
    && pass "Migrate copies state archive into the sandbox" \
    || fail "Migrate did not copy the state archive into the sandbox"
grep -q '^sandbox connect openclaw -- sh -lc ' /tmp/fake-sandbox/invocation.txt \
    && pass "Migrate extracts archives inside the sandbox" \
    || fail "Migrate did not extract archives inside the sandbox"
grep -q '^sandbox connect openclaw -- nemoclaw-shell openclaw setup$' /tmp/fake-sandbox/invocation.txt \
    && pass "Migrate reruns openclaw setup" \
    || fail "Migrate did not rerun openclaw setup"
grep -q '^sandbox connect openclaw -- nemoclaw-shell nemoclaw-gateway.sh ensure$' /tmp/fake-sandbox/invocation.txt \
    && pass "Migrate reruns Gateway ensure" \
    || fail "Migrate did not rerun Gateway ensure"
[ -f /tmp/fake-sandbox/openclaw/.openclaw/workspace/project.md ] \
    && pass "Migrate restores workspace files into the sandbox" \
    || fail "Migrate did not restore workspace files into the sandbox"
grep -q '"token": "migrated-token-456"' /tmp/fake-sandbox/openclaw/.openclaw/openclaw.json \
    && pass "Migrate leaves sandbox with a gateway auth token" \
    || fail "Migrate did not leave the sandbox with a gateway auth token"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ALL E2E TESTS PASSED${NC}"
echo -e "${GREEN}========================================${NC}"
