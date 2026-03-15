"use strict";
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
exports.detectHostOpenClaw = detectHostOpenClaw;
exports.cliMigrate = cliMigrate;
const node_fs_1 = require("node:fs");
const node_path_1 = require("node:path");
const resolve_js_1 = require("../blueprint/resolve.js");
const verify_js_1 = require("../blueprint/verify.js");
const exec_js_1 = require("../blueprint/exec.js");
const state_js_1 = require("../blueprint/state.js");
const HOME = process.env.HOME ?? "/tmp";
function detectHostOpenClaw() {
    const configDir = (0, node_path_1.join)(HOME, ".openclaw");
    const exists = (0, node_fs_1.existsSync)(configDir);
    if (!exists) {
        return {
            exists: false,
            configDir: null,
            workspaceDir: null,
            extensionsDir: null,
            skillsDir: null,
            configFile: null,
        };
    }
    const configFile = (0, node_fs_1.existsSync)((0, node_path_1.join)(configDir, "openclaw.json"))
        ? (0, node_path_1.join)(configDir, "openclaw.json")
        : null;
    const workspaceDir = (0, node_fs_1.existsSync)((0, node_path_1.join)(configDir, "workspace"))
        ? (0, node_path_1.join)(configDir, "workspace")
        : null;
    const extensionsDir = (0, node_fs_1.existsSync)((0, node_path_1.join)(configDir, "extensions"))
        ? (0, node_path_1.join)(configDir, "extensions")
        : null;
    const skillsDir = (0, node_fs_1.existsSync)((0, node_path_1.join)(configDir, "skills")) ? (0, node_path_1.join)(configDir, "skills") : null;
    return {
        exists: true,
        configDir,
        workspaceDir,
        extensionsDir,
        skillsDir,
        configFile,
    };
}
async function cliMigrate(opts) {
    const { dryRun, profile, skipBackup, logger, pluginConfig } = opts;
    logger.info("NemoClaw migrate: moving host OpenClaw into OpenShell sandbox");
    // Step 1: Detect host OpenClaw state
    logger.info("Detecting host OpenClaw installation...");
    const hostState = detectHostOpenClaw();
    if (!hostState.exists) {
        logger.error("No OpenClaw installation found at ~/.openclaw");
        logger.info("Use 'openclaw nemoclaw launch' for a fresh install.");
        return;
    }
    logger.info(`Found OpenClaw config at ${hostState.configDir ?? "~/.openclaw"}`);
    if (hostState.configFile)
        logger.info(`  Config: ${hostState.configFile}`);
    if (hostState.workspaceDir)
        logger.info(`  Workspace: ${hostState.workspaceDir}`);
    if (hostState.extensionsDir)
        logger.info(`  Extensions: ${hostState.extensionsDir}`);
    if (hostState.skillsDir)
        logger.info(`  Skills: ${hostState.skillsDir}`);
    // Step 2: Create snapshot backup
    let snapshotPath = null;
    if (!skipBackup) {
        logger.info("Creating host backup snapshot...");
        snapshotPath = createSnapshot(hostState, logger);
        if (!snapshotPath) {
            logger.error("Failed to create backup snapshot. Use --skip-backup to proceed anyway.");
            return;
        }
        logger.info(`Snapshot saved to ${snapshotPath}`);
    }
    if (dryRun) {
        logger.info("");
        logger.info("[Dry run] Would perform the following:");
        logger.info("  1. Resolve and verify blueprint");
        logger.info("  2. Create OpenShell sandbox");
        logger.info("  3. Copy config, workspace, extensions, and skills into sandbox");
        logger.info("  4. Patch paths for sandbox context");
        logger.info("  5. Configure inference provider");
        logger.info("  6. Cut over to sandbox runtime");
        logger.info("  7. Archive host ~/.openclaw");
        return;
    }
    // Step 3: Resolve and verify blueprint
    logger.info("Resolving blueprint...");
    const blueprint = await (0, resolve_js_1.resolveBlueprint)(pluginConfig);
    logger.info("Verifying blueprint...");
    const verification = (0, verify_js_1.verifyBlueprintDigest)(blueprint.localPath, blueprint.manifest);
    if (!verification.valid) {
        logger.error(`Blueprint verification failed: ${verification.errors.join(", ")}`);
        return;
    }
    // Step 4: Plan migration
    logger.info("Planning migration...");
    const planResult = await (0, exec_js_1.execBlueprint)({
        blueprintPath: blueprint.localPath,
        action: "plan",
        profile,
        jsonOutput: true,
    }, logger);
    if (!planResult.success) {
        logger.error(`Migration plan failed: ${planResult.output}`);
        return;
    }
    // Step 5: Apply migration
    logger.info("Provisioning OpenShell sandbox...");
    const applyResult = await (0, exec_js_1.execBlueprint)({
        blueprintPath: blueprint.localPath,
        action: "apply",
        profile,
        planPath: planResult.runId,
        jsonOutput: true,
    }, logger);
    if (!applyResult.success) {
        logger.error(`Migration apply failed: ${applyResult.output}`);
        if (snapshotPath) {
            logger.info(`Restore from snapshot: ${snapshotPath}`);
        }
        return;
    }
    // Step 6: Save state for eject
    (0, state_js_1.saveState)({
        ...(0, state_js_1.loadState)(),
        lastRunId: applyResult.runId,
        lastAction: "migrate",
        blueprintVersion: blueprint.version,
        sandboxName: pluginConfig.sandboxName,
        migrationSnapshot: snapshotPath,
        hostBackupPath: snapshotPath,
    });
    logger.info("");
    logger.info("Migration complete. OpenClaw is now running inside OpenShell.");
    logger.info(`Sandbox: ${pluginConfig.sandboxName}`);
    logger.info("");
    logger.info("Next steps:");
    logger.info("  openclaw nemoclaw connect    # Enter the sandbox");
    logger.info("  openclaw nemoclaw status     # Verify everything is healthy");
    logger.info("  openshell term               # Monitor sandbox activity");
    logger.info("");
    logger.info("To rollback to your host installation:");
    logger.info("  openclaw nemoclaw eject");
}
function createSnapshot(hostState, logger) {
    if (!hostState.configDir)
        return null;
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const snapshotDir = (0, node_path_1.join)(HOME, ".nemoclaw", "snapshots", timestamp);
    try {
        (0, node_fs_1.mkdirSync)(snapshotDir, { recursive: true });
        (0, node_fs_1.cpSync)(hostState.configDir, (0, node_path_1.join)(snapshotDir, "openclaw"), {
            recursive: true,
        });
        // Record what was captured
        const manifest = {
            timestamp,
            source: hostState.configDir,
            contents: (0, node_fs_1.readdirSync)((0, node_path_1.join)(snapshotDir, "openclaw")),
        };
        (0, node_fs_1.writeFileSync)((0, node_path_1.join)(snapshotDir, "snapshot.json"), JSON.stringify(manifest, null, 2));
        return snapshotDir;
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        logger.error(`Snapshot failed: ${msg}`);
        return null;
    }
}
//# sourceMappingURL=migrate.js.map