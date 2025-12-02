/**
 * Console port handlers for Guida IO library.
 * Implements terminal/console IO operations.
 */
import { ElmApp } from "./ports";
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
export interface ConsoleConfig {
    stdout: NodeJS.WriteStream;
    stderr: NodeJS.WriteStream;
    stdin: NodeJS.ReadStream;
}
/**
 * Console port handler class.
 * Manages terminal/console IO through Elm ports.
 */
export declare class ConsolePorts {
    private app;
    private config;
    private rl;
    constructor(app: ElmApp, config?: ConsoleConfig);
    private sendResponse;
    private getReadlineInterface;
    /**
     * Close the readline interface when done.
     * Should be called when the application is shutting down.
     */
    close(): void;
    write: (args: WriteArgs) => void;
    getLine: (args: IdOnlyArgs) => void;
    replGetInputLine: (args: ReplInputArgs) => void;
}
export {};
