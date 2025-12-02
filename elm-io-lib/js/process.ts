/**
 * Process port handlers for Guida IO library.
 * Implements environment and process control operations.
 */

import * as path from "path";
import * as fs from "fs";
import {
    checkPortsExist,
    ElmApp,
    OutgoingPort,
    IncomingPort,
    Response,
} from "./ports";

// Request types
interface LookupEnvArgs {
    id: string;
    name: string;
}

interface IdOnlyArgs {
    id: string;
}

interface FindExecutableArgs {
    id: string;
    name: string;
}

interface ExitArgs {
    response: unknown;
}

// Port types
interface ProcessElmPorts {
    procLookupEnv: OutgoingPort<LookupEnvArgs>;
    procGetArgs: OutgoingPort<IdOnlyArgs>;
    procFindExecutable: OutgoingPort<FindExecutableArgs>;
    procExit: OutgoingPort<ExitArgs>;
    procResponse: IncomingPort<Response>;
}

// Configuration interface for dependency injection
export interface ProcessConfig {
    env: NodeJS.ProcessEnv;
    argv: string[];
    cwd: () => string;
    exit: (code: number) => never;
    pathSeparator: string;
}

// Default configuration using process
const defaultConfig: ProcessConfig = {
    env: process.env,
    argv: process.argv.slice(2), // Remove node and script path
    cwd: () => process.cwd(),
    exit: (code) => process.exit(code),
    pathSeparator: path.delimiter,
};

/**
 * Callback type for exit handling.
 * The host application can provide this to handle the exit response.
 */
export type ExitCallback = (response: unknown) => void;

/**
 * Process port handler class.
 * Manages environment and process operations through Elm ports.
 */
export class ProcessPorts {
    private app: { ports: ProcessElmPorts };
    private config: ProcessConfig;
    private args: string[];
    private onExit: ExitCallback | null = null;

    constructor(
        app: ElmApp,
        args: string[] = [],
        config: ProcessConfig = defaultConfig
    ) {
        this.app = app as unknown as { ports: ProcessElmPorts };
        this.config = config;
        this.args = args.length > 0 ? args : config.argv;

        const portNames = [
            "procLookupEnv",
            "procGetArgs",
            "procFindExecutable",
            "procExit",
            "procResponse",
        ];

        checkPortsExist(app, portNames);

        const ports = app.ports as unknown as ProcessElmPorts;
        ports.procLookupEnv.subscribe(this.lookupEnv);
        ports.procGetArgs.subscribe(this.getArgs);
        ports.procFindExecutable.subscribe(this.findExecutable);
        ports.procExit.subscribe(this.exit);
    }

    /**
     * Set the callback for exit handling.
     * The callback receives the response value from the Elm application.
     */
    setExitCallback(callback: ExitCallback): void {
        this.onExit = callback;
    }

    private sendResponse(response: Response): void {
        const ports = this.app.ports as unknown as ProcessElmPorts;
        ports.procResponse.send(response);
    }

    // Environment operations

    lookupEnv = (args: LookupEnvArgs): void => {
        const value = this.config.env[args.name];

        if (value !== undefined) {
            this.sendResponse({
                id: args.id,
                type_: "Value",
                payload: value,
            });
        } else {
            this.sendResponse({
                id: args.id,
                type_: "NotFound",
                payload: null,
            });
        }
    };

    getArgs = (args: IdOnlyArgs): void => {
        this.sendResponse({
            id: args.id,
            type_: "Args",
            payload: this.args,
        });
    };

    findExecutable = async (args: FindExecutableArgs): Promise<void> => {
        const pathEnv = this.config.env.PATH || this.config.env.Path || "";
        const pathDirs = pathEnv.split(this.config.pathSeparator);

        // Extensions to check on Windows
        const extensions =
            process.platform === "win32"
                ? [".exe", ".cmd", ".bat", ".com", ""]
                : [""];

        for (const dir of pathDirs) {
            for (const ext of extensions) {
                const fullPath = path.join(dir, args.name + ext);
                try {
                    await fs.promises.access(fullPath, fs.constants.X_OK);
                    this.sendResponse({
                        id: args.id,
                        type_: "Value",
                        payload: fullPath,
                    });
                    return;
                } catch {
                    // File not found or not executable, continue searching
                }
            }
        }

        // Not found in any PATH directory
        this.sendResponse({
            id: args.id,
            type_: "NotFound",
            payload: null,
        });
    };

    // Process control

    exit = (args: ExitArgs): void => {
        if (this.onExit) {
            this.onExit(args.response);
        } else {
            // Default behavior: log response and exit
            console.log(JSON.stringify(args.response));
            this.config.exit(0);
        }
    };
}
