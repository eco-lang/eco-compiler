/**
 * Console port handlers for Guida IO library.
 * Implements terminal/console IO operations.
 */

import * as readline from "readline";
import {
    checkPortsExist,
    ElmApp,
    OutgoingPort,
    IncomingPort,
    Response,
    errorFromException,
} from "./ports";

// Request types
interface WriteArgs {
    fd: number;
    content: string;
}

interface IdOnlyArgs {
    id: string;
}

interface ReplInputArgs {
    id: string;
    prompt: string;
}

// Port types
interface ConsoleElmPorts {
    consoleWrite: OutgoingPort<WriteArgs>;
    consoleGetLine: OutgoingPort<IdOnlyArgs>;
    consoleReplGetInputLine: OutgoingPort<ReplInputArgs>;
    consoleResponse: IncomingPort<Response>;
}

// Configuration interface for dependency injection
export interface ConsoleConfig {
    stdout: NodeJS.WriteStream;
    stderr: NodeJS.WriteStream;
    stdin: NodeJS.ReadStream;
}

// Default configuration using process streams
const defaultConfig: ConsoleConfig = {
    stdout: process.stdout,
    stderr: process.stderr,
    stdin: process.stdin,
};

/**
 * Console port handler class.
 * Manages terminal/console IO through Elm ports.
 */
export class ConsolePorts {
    private app: { ports: ConsoleElmPorts };
    private config: ConsoleConfig;
    private rl: readline.Interface | null = null;

    constructor(app: ElmApp, config: ConsoleConfig = defaultConfig) {
        this.app = app as unknown as { ports: ConsoleElmPorts };
        this.config = config;

        const portNames = [
            "consoleWrite",
            "consoleGetLine",
            "consoleReplGetInputLine",
            "consoleResponse",
        ];

        checkPortsExist(app, portNames);

        const ports = app.ports as unknown as ConsoleElmPorts;
        ports.consoleWrite.subscribe(this.write);
        ports.consoleGetLine.subscribe(this.getLine);
        ports.consoleReplGetInputLine.subscribe(this.replGetInputLine);
    }

    private sendResponse(response: Response): void {
        const ports = this.app.ports as unknown as ConsoleElmPorts;
        ports.consoleResponse.send(response);
    }

    private getReadlineInterface(): readline.Interface {
        if (!this.rl) {
            this.rl = readline.createInterface({
                input: this.config.stdin,
                output: this.config.stdout,
                terminal: this.config.stdin.isTTY ?? false,
            });

            this.rl.on("close", () => {
                this.rl = null;
            });
        }
        return this.rl;
    }

    /**
     * Close the readline interface when done.
     * Should be called when the application is shutting down.
     */
    close(): void {
        if (this.rl) {
            this.rl.close();
            this.rl = null;
        }
    }

    // Output operations (fire-and-forget)

    write = (args: WriteArgs): void => {
        try {
            if (args.fd === 1) {
                this.config.stdout.write(args.content);
            } else if (args.fd === 2) {
                this.config.stderr.write(args.content);
            } else {
                // For other file descriptors, default to stdout
                // In a full implementation, we'd track open file handles
                this.config.stdout.write(args.content);
            }
            // Fire-and-forget: no response sent
        } catch (error) {
            // Log error but don't send response (fire-and-forget)
            console.error("Console write error:", error);
        }
    };

    // Input operations (call-and-response)

    getLine = (args: IdOnlyArgs): void => {
        try {
            const rl = this.getReadlineInterface();

            rl.question("", (answer) => {
                this.sendResponse({
                    id: args.id,
                    type_: "Content",
                    payload: answer,
                });
            });

            // Handle EOF
            rl.once("close", () => {
                this.sendResponse({
                    id: args.id,
                    type_: "EndOfInput",
                    payload: null,
                });
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    replGetInputLine = (args: ReplInputArgs): void => {
        try {
            const rl = this.getReadlineInterface();

            rl.question(args.prompt, (answer) => {
                this.sendResponse({
                    id: args.id,
                    type_: "Content",
                    payload: answer,
                });
            });

            // Handle EOF (Ctrl+D)
            rl.once("close", () => {
                this.sendResponse({
                    id: args.id,
                    type_: "EndOfInput",
                    payload: null,
                });
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };
}
