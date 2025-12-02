/**
 * Guida IO Library - TypeScript port handlers
 *
 * This module exports all port handler classes for use with Elm applications.
 *
 * Usage:
 * ```typescript
 * import { initializeAllPorts, FileSystemPorts, ConsolePorts } from '@guida/elm-io';
 *
 * // Initialize all ports at once
 * const handlers = initializeAllPorts(app);
 *
 * // Or initialize individual handlers
 * const fsPorts = new FileSystemPorts(app);
 * const consolePorts = new ConsolePorts(app);
 * ```
 */

// Export individual port handlers
export { FileSystemPorts, FileSystemConfig } from "./filesystem";
export { ConsolePorts, ConsoleConfig } from "./console";
export { ProcessPorts, ProcessConfig, ExitCallback } from "./process";
export { ConcurrencyPorts } from "./concurrency";
export { NetworkPorts, NetworkPortsXHR, NetworkConfig } from "./network";

// Export utility functions
export {
    checkPortsExist,
    ElmApp,
    OutgoingPort,
    IncomingPort,
    Response,
    ErrorPayload,
    okResponse,
    errorResponse,
    errorFromException,
} from "./ports";

// Import for initialization function
import { FileSystemPorts, FileSystemConfig } from "./filesystem";
import { ConsolePorts, ConsoleConfig } from "./console";
import { ProcessPorts, ProcessConfig, ExitCallback } from "./process";
import { ConcurrencyPorts } from "./concurrency";
import { NetworkPorts, NetworkConfig } from "./network";
import { ElmApp } from "./ports";

/**
 * Configuration for initializing all port handlers.
 */
export interface AllPortsConfig {
    fileSystem?: FileSystemConfig;
    console?: ConsoleConfig;
    process?: ProcessConfig;
    network?: NetworkConfig;
    args?: string[];
    onExit?: ExitCallback;
}

/**
 * All initialized port handlers.
 */
export interface AllPortHandlers {
    fileSystem: FileSystemPorts;
    console: ConsolePorts;
    process: ProcessPorts;
    concurrency: ConcurrencyPorts;
    network: NetworkPorts;
}

/**
 * Initialize all port handlers for a Guida IO application.
 *
 * @param app - The initialized Elm application
 * @param config - Optional configuration for handlers
 * @returns Object containing all initialized port handlers
 */
export function initializeAllPorts(
    app: ElmApp,
    config: AllPortsConfig = {}
): AllPortHandlers {
    const fileSystem = new FileSystemPorts(app, config.fileSystem);
    const console = new ConsolePorts(app, config.console);
    const processHandler = new ProcessPorts(app, config.args, config.process);
    const concurrency = new ConcurrencyPorts(app);
    const network = new NetworkPorts(app, config.network);

    if (config.onExit) {
        processHandler.setExitCallback(config.onExit);
    }

    return {
        fileSystem,
        console,
        process: processHandler,
        concurrency,
        network,
    };
}

/**
 * Helper function to create a promise that resolves when the Elm app exits.
 * Useful for CLI applications that need to wait for completion.
 *
 * @param processHandler - The ProcessPorts handler
 * @returns Promise that resolves with the exit response
 */
export function waitForExit(processHandler: ProcessPorts): Promise<unknown> {
    return new Promise((resolve) => {
        processHandler.setExitCallback(resolve);
    });
}
