/**
 * Concurrency port handlers for Guida IO library.
 * Implements MVar and Channel operations with blocking semantics.
 */

import {
    checkPortsExist,
    ElmApp,
    OutgoingPort,
    IncomingPort,
    Response,
    okResponse,
    errorResponse,
} from "./ports";

// Request types
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

// Port types
interface ConcurrencyElmPorts {
    concNewEmptyMVar: OutgoingPort<IdOnlyArgs>;
    concReadMVar: OutgoingPort<MVarIdArgs>;
    concTakeMVar: OutgoingPort<MVarIdArgs>;
    concPutMVar: OutgoingPort<PutMVarArgs>;
    concResponse: IncomingPort<Response>;
}

// MVar internal state
interface MVar {
    value: unknown | undefined;
    subscribers: Array<Subscriber>;
}

// Subscriber waiting for MVar operation
interface Subscriber {
    action: "read" | "take" | "put";
    id: string;
    value?: unknown; // Only for "put" operations
}

/**
 * Concurrency port handler class.
 * Manages MVars with blocking semantics through Elm ports.
 */
export class ConcurrencyPorts {
    private app: { ports: ConcurrencyElmPorts };
    private mVars: Map<number, MVar>;
    private nextMVarId: number;

    constructor(app: ElmApp) {
        this.app = app as unknown as { ports: ConcurrencyElmPorts };
        this.mVars = new Map();
        this.nextMVarId = 1;

        const portNames = [
            "concNewEmptyMVar",
            "concReadMVar",
            "concTakeMVar",
            "concPutMVar",
            "concResponse",
        ];

        checkPortsExist(app, portNames);

        const ports = app.ports as unknown as ConcurrencyElmPorts;
        ports.concNewEmptyMVar.subscribe(this.newEmptyMVar);
        ports.concReadMVar.subscribe(this.readMVar);
        ports.concTakeMVar.subscribe(this.takeMVar);
        ports.concPutMVar.subscribe(this.putMVar);
    }

    private sendResponse(response: Response): void {
        const ports = this.app.ports as unknown as ConcurrencyElmPorts;
        ports.concResponse.send(response);
    }

    /**
     * Create a new empty MVar.
     */
    newEmptyMVar = (args: IdOnlyArgs): void => {
        const mvarId = this.nextMVarId++;
        this.mVars.set(mvarId, {
            value: undefined,
            subscribers: [],
        });

        this.sendResponse({
            id: args.id,
            type_: "MVar",
            payload: mvarId,
        });
    };

    /**
     * Read the value from an MVar without removing it.
     * Blocks if empty.
     */
    readMVar = (args: MVarIdArgs): void => {
        const mvar = this.mVars.get(args.mvarId);

        if (!mvar) {
            this.sendResponse(
                errorResponse(args.id, "MVAR_NOT_FOUND", `MVar ${args.mvarId} not found`)
            );
            return;
        }

        if (mvar.value !== undefined) {
            // MVar has a value, return it immediately
            this.sendResponse({
                id: args.id,
                type_: "Value",
                payload: mvar.value,
            });
        } else {
            // MVar is empty, block by adding to subscribers
            mvar.subscribers.push({
                action: "read",
                id: args.id,
            });
        }
    };

    /**
     * Take the value from an MVar, leaving it empty.
     * Blocks if empty.
     */
    takeMVar = (args: MVarIdArgs): void => {
        const mvar = this.mVars.get(args.mvarId);

        if (!mvar) {
            this.sendResponse(
                errorResponse(args.id, "MVAR_NOT_FOUND", `MVar ${args.mvarId} not found`)
            );
            return;
        }

        if (mvar.value !== undefined) {
            // MVar has a value, take it
            const value = mvar.value;
            mvar.value = undefined;

            // Check if there's a "put" subscriber waiting
            const putSubscriber = mvar.subscribers.find((s) => s.action === "put");
            if (putSubscriber) {
                // Remove the put subscriber and set its value
                mvar.subscribers = mvar.subscribers.filter((s) => s !== putSubscriber);
                mvar.value = putSubscriber.value;

                // Notify the put subscriber that it succeeded
                this.sendResponse(okResponse(putSubscriber.id));

                // Wake up any read subscribers now that there's a value
                this.wakeReadSubscribers(mvar);
            }

            // Return the taken value
            this.sendResponse({
                id: args.id,
                type_: "Value",
                payload: value,
            });
        } else {
            // MVar is empty, block by adding to subscribers
            mvar.subscribers.push({
                action: "take",
                id: args.id,
            });
        }
    };

    /**
     * Put a value into an MVar.
     * Blocks if already full.
     */
    putMVar = (args: PutMVarArgs): void => {
        const mvar = this.mVars.get(args.mvarId);

        if (!mvar) {
            this.sendResponse(
                errorResponse(args.id, "MVAR_NOT_FOUND", `MVar ${args.mvarId} not found`)
            );
            return;
        }

        if (mvar.value === undefined) {
            // MVar is empty, put the value
            mvar.value = args.value;

            // Wake up read subscribers (they don't consume)
            this.wakeReadSubscribers(mvar);

            // Wake up the first take subscriber if any
            const takeSubscriber = mvar.subscribers.find((s) => s.action === "take");
            if (takeSubscriber) {
                // Remove the take subscriber
                mvar.subscribers = mvar.subscribers.filter((s) => s !== takeSubscriber);

                // Give them the value and clear the MVar
                const value = mvar.value;
                mvar.value = undefined;

                this.sendResponse({
                    id: takeSubscriber.id,
                    type_: "Value",
                    payload: value,
                });

                // Check if there's another put waiting
                const nextPut = mvar.subscribers.find((s) => s.action === "put");
                if (nextPut) {
                    mvar.subscribers = mvar.subscribers.filter((s) => s !== nextPut);
                    mvar.value = nextPut.value;
                    this.sendResponse(okResponse(nextPut.id));
                    this.wakeReadSubscribers(mvar);
                }
            }

            // Respond OK to the original put
            this.sendResponse(okResponse(args.id));
        } else {
            // MVar is full, block by adding to subscribers
            mvar.subscribers.push({
                action: "put",
                id: args.id,
                value: args.value,
            });
        }
    };

    /**
     * Wake up all read subscribers with the current value.
     */
    private wakeReadSubscribers(mvar: MVar): void {
        if (mvar.value === undefined) return;

        const readSubscribers = mvar.subscribers.filter((s) => s.action === "read");
        mvar.subscribers = mvar.subscribers.filter((s) => s.action !== "read");

        for (const subscriber of readSubscribers) {
            this.sendResponse({
                id: subscriber.id,
                type_: "Value",
                payload: mvar.value,
            });
        }
    }

    /**
     * Get debug info about MVar state (for testing).
     */
    getDebugInfo(): { mvarCount: number; totalSubscribers: number } {
        let totalSubscribers = 0;
        for (const mvar of this.mVars.values()) {
            totalSubscribers += mvar.subscribers.length;
        }
        return {
            mvarCount: this.mVars.size,
            totalSubscribers,
        };
    }
}
