/**
 * Process port handlers for Guida IO library.
 * Implements environment and process control operations.
 */
import { ElmApp } from "./ports";
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
export interface ProcessConfig {
    env: NodeJS.ProcessEnv;
    argv: string[];
    cwd: () => string;
    exit: (code: number) => never;
    pathSeparator: string;
}
/**
 * Callback type for exit handling.
 * The host application can provide this to handle the exit response.
 */
export type ExitCallback = (response: unknown) => void;
/**
 * Process port handler class.
 * Manages environment and process operations through Elm ports.
 */
export declare class ProcessPorts {
    private app;
    private config;
    private args;
    private onExit;
    constructor(app: ElmApp, args?: string[], config?: ProcessConfig);
    /**
     * Set the callback for exit handling.
     * The callback receives the response value from the Elm application.
     */
    setExitCallback(callback: ExitCallback): void;
    private sendResponse;
    lookupEnv: (args: LookupEnvArgs) => void;
    getArgs: (args: IdOnlyArgs) => void;
    findExecutable: (args: FindExecutableArgs) => Promise<void>;
    exit: (args: ExitArgs) => void;
}
export {};
