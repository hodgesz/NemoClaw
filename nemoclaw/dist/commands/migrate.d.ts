import type { PluginLogger, NemoClawConfig } from "../index.js";
export interface HostOpenClawState {
    exists: boolean;
    configDir: string | null;
    workspaceDir: string | null;
    extensionsDir: string | null;
    skillsDir: string | null;
    configFile: string | null;
}
export declare function detectHostOpenClaw(): HostOpenClawState;
export interface MigrateOptions {
    dryRun: boolean;
    profile: string;
    skipBackup: boolean;
    logger: PluginLogger;
    pluginConfig: NemoClawConfig;
}
export declare function cliMigrate(opts: MigrateOptions): Promise<void>;
//# sourceMappingURL=migrate.d.ts.map