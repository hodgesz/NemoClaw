"use strict";
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
exports.cliEject = cliEject;
const node_fs_1 = require("node:fs");
const node_path_1 = require("node:path");
const exec_js_1 = require("../blueprint/exec.js");
const state_js_1 = require("../blueprint/state.js");
const HOME = process.env.HOME ?? "/tmp";
async function cliEject(opts) {
    const { confirm, runId, logger } = opts;
    const state = (0, state_js_1.loadState)();
    if (!state.lastAction) {
        logger.error("No NemoClaw deployment found. Nothing to eject from.");
        return;
    }
    if (!state.migrationSnapshot && !state.hostBackupPath) {
        logger.error("No migration snapshot found. Cannot restore host installation.");
        logger.info("If you used --skip-backup during migrate, manual restoration is required.");
        return;
    }
    const snapshotPath = state.migrationSnapshot ?? state.hostBackupPath;
    if (!snapshotPath) {
        logger.error("No snapshot or backup path found in state. Cannot restore.");
        return;
    }
    const snapshotOpenClawDir = (0, node_path_1.join)(snapshotPath, "openclaw");
    if (!(0, node_fs_1.existsSync)(snapshotOpenClawDir)) {
        logger.error(`Snapshot directory not found: ${snapshotOpenClawDir}`);
        return;
    }
    if (!confirm) {
        logger.info("Eject will:");
        logger.info("  1. Stop the OpenShell sandbox");
        logger.info("  2. Rollback blueprint state");
        logger.info(`  3. Restore ~/.openclaw from snapshot: ${snapshotPath}`);
        logger.info("  4. Clear NemoClaw state");
        logger.info("");
        logger.info("Run with --confirm to proceed, or cancel now.");
        return;
    }
    // Step 1: Rollback blueprint
    if (state.lastRunId && state.blueprintVersion) {
        const blueprintPath = (0, node_path_1.join)(HOME, ".nemoclaw", "blueprints", state.blueprintVersion);
        if ((0, node_fs_1.existsSync)(blueprintPath)) {
            const rollbackResult = await (0, exec_js_1.execBlueprint)({
                blueprintPath,
                action: "rollback",
                profile: "default",
                runId: runId ?? state.lastRunId,
                jsonOutput: true,
            }, logger);
            if (!rollbackResult.success) {
                logger.warn(`Blueprint rollback returned errors: ${rollbackResult.output}`);
                logger.info("Continuing with host restoration...");
            }
        }
    }
    // Step 2: Restore host ~/.openclaw from snapshot
    const currentConfigDir = (0, node_path_1.join)(HOME, ".openclaw");
    try {
        // Archive current sandbox-managed config
        if ((0, node_fs_1.existsSync)(currentConfigDir)) {
            const archiveName = `${currentConfigDir}.nemoclaw-archived-${String(Date.now())}`;
            (0, node_fs_1.renameSync)(currentConfigDir, archiveName);
            logger.info(`Archived current config to ${archiveName}`);
        }
        // Restore from snapshot
        (0, node_fs_1.mkdirSync)(currentConfigDir, { recursive: true });
        (0, node_fs_1.cpSync)(snapshotOpenClawDir, currentConfigDir, { recursive: true });
        logger.info("Host OpenClaw configuration restored.");
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        logger.error(`Restoration failed: ${msg}`);
        logger.info(`Manual restore available at: ${snapshotOpenClawDir}`);
        return;
    }
    // Step 3: Clear NemoClaw state
    (0, state_js_1.clearState)();
    logger.info("");
    logger.info("Eject complete. Host OpenClaw installation has been restored.");
    logger.info("You can now run 'openclaw' directly on your host.");
}
//# sourceMappingURL=eject.js.map