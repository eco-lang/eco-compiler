/**
 * Concurrency port handlers for Guida IO library.
 * Implements MVar and Channel operations with blocking semantics.
 */
import { ElmApp } from "./ports";
interface IdOnlyArgs {
    id: string;
}
interface MVarIdArgs {
    id: string;
    mvarId: number;
}
interface PutMVarArgs {
    id: string;
    mvarId: number;
    value: unknown;
}
/**
 * Concurrency port handler class.
 * Manages MVars with blocking semantics through Elm ports.
 */
export declare class ConcurrencyPorts {
    private app;
    private mVars;
    private nextMVarId;
    constructor(app: ElmApp);
    private sendResponse;
    /**
     * Create a new empty MVar.
     */
    newEmptyMVar: (args: IdOnlyArgs) => void;
    /**
     * Read the value from an MVar without removing it.
     * Blocks if empty.
     */
    readMVar: (args: MVarIdArgs) => void;
    /**
     * Take the value from an MVar, leaving it empty.
     * Blocks if empty.
     */
    takeMVar: (args: MVarIdArgs) => void;
    /**
     * Put a value into an MVar.
     * Blocks if already full.
     */
    putMVar: (args: PutMVarArgs) => void;
    /**
     * Wake up all read subscribers with the current value.
     */
    private wakeReadSubscribers;
    /**
     * Get debug info about MVar state (for testing).
     */
    getDebugInfo(): {
        mvarCount: number;
        totalSubscribers: number;
    };
}
export {};
