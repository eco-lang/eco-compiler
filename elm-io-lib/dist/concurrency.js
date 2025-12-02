"use strict";
/**
 * Concurrency port handlers for Guida IO library.
 * Implements MVar and Channel operations with blocking semantics.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.ConcurrencyPorts = void 0;
const ports_1 = require("./ports");
/**
 * Concurrency port handler class.
 * Manages MVars with blocking semantics through Elm ports.
 */
class ConcurrencyPorts {
    constructor(app) {
        /**
         * Create a new empty MVar.
         */
        this.newEmptyMVar = (args) => {
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
        this.readMVar = (args) => {
            const mvar = this.mVars.get(args.mvarId);
            if (!mvar) {
                this.sendResponse((0, ports_1.errorResponse)(args.id, "MVAR_NOT_FOUND", `MVar ${args.mvarId} not found`));
                return;
            }
            if (mvar.value !== undefined) {
                // MVar has a value, return it immediately
                this.sendResponse({
                    id: args.id,
                    type_: "Value",
                    payload: mvar.value,
                });
            }
            else {
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
        this.takeMVar = (args) => {
            const mvar = this.mVars.get(args.mvarId);
            if (!mvar) {
                this.sendResponse((0, ports_1.errorResponse)(args.id, "MVAR_NOT_FOUND", `MVar ${args.mvarId} not found`));
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
                    this.sendResponse((0, ports_1.okResponse)(putSubscriber.id));
                    // Wake up any read subscribers now that there's a value
                    this.wakeReadSubscribers(mvar);
                }
                // Return the taken value
                this.sendResponse({
                    id: args.id,
                    type_: "Value",
                    payload: value,
                });
            }
            else {
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
        this.putMVar = (args) => {
            const mvar = this.mVars.get(args.mvarId);
            if (!mvar) {
                this.sendResponse((0, ports_1.errorResponse)(args.id, "MVAR_NOT_FOUND", `MVar ${args.mvarId} not found`));
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
                        this.sendResponse((0, ports_1.okResponse)(nextPut.id));
                        this.wakeReadSubscribers(mvar);
                    }
                }
                // Respond OK to the original put
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
            else {
                // MVar is full, block by adding to subscribers
                mvar.subscribers.push({
                    action: "put",
                    id: args.id,
                    value: args.value,
                });
            }
        };
        this.app = app;
        this.mVars = new Map();
        this.nextMVarId = 1;
        const portNames = [
            "concNewEmptyMVar",
            "concReadMVar",
            "concTakeMVar",
            "concPutMVar",
            "concResponse",
        ];
        (0, ports_1.checkPortsExist)(app, portNames);
        const ports = app.ports;
        ports.concNewEmptyMVar.subscribe(this.newEmptyMVar);
        ports.concReadMVar.subscribe(this.readMVar);
        ports.concTakeMVar.subscribe(this.takeMVar);
        ports.concPutMVar.subscribe(this.putMVar);
    }
    sendResponse(response) {
        const ports = this.app.ports;
        ports.concResponse.send(response);
    }
    /**
     * Wake up all read subscribers with the current value.
     */
    wakeReadSubscribers(mvar) {
        if (mvar.value === undefined)
            return;
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
    getDebugInfo() {
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
exports.ConcurrencyPorts = ConcurrencyPorts;
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiY29uY3VycmVuY3kuanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyIuLi9qcy9jb25jdXJyZW5jeS50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiO0FBQUE7OztHQUdHOzs7QUFFSCxtQ0FRaUI7QUF3Q2pCOzs7R0FHRztBQUNILE1BQWEsZ0JBQWdCO0lBS3pCLFlBQVksR0FBVztRQTJCdkI7O1dBRUc7UUFDSCxpQkFBWSxHQUFHLENBQUMsSUFBZ0IsRUFBUSxFQUFFO1lBQ3RDLE1BQU0sTUFBTSxHQUFHLElBQUksQ0FBQyxVQUFVLEVBQUUsQ0FBQztZQUNqQyxJQUFJLENBQUMsS0FBSyxDQUFDLEdBQUcsQ0FBQyxNQUFNLEVBQUU7Z0JBQ25CLEtBQUssRUFBRSxTQUFTO2dCQUNoQixXQUFXLEVBQUUsRUFBRTthQUNsQixDQUFDLENBQUM7WUFFSCxJQUFJLENBQUMsWUFBWSxDQUFDO2dCQUNkLEVBQUUsRUFBRSxJQUFJLENBQUMsRUFBRTtnQkFDWCxLQUFLLEVBQUUsTUFBTTtnQkFDYixPQUFPLEVBQUUsTUFBTTthQUNsQixDQUFDLENBQUM7UUFDUCxDQUFDLENBQUM7UUFFRjs7O1dBR0c7UUFDSCxhQUFRLEdBQUcsQ0FBQyxJQUFnQixFQUFRLEVBQUU7WUFDbEMsTUFBTSxJQUFJLEdBQUcsSUFBSSxDQUFDLEtBQUssQ0FBQyxHQUFHLENBQUMsSUFBSSxDQUFDLE1BQU0sQ0FBQyxDQUFDO1lBRXpDLElBQUksQ0FBQyxJQUFJLEVBQUUsQ0FBQztnQkFDUixJQUFJLENBQUMsWUFBWSxDQUNiLElBQUEscUJBQWEsRUFBQyxJQUFJLENBQUMsRUFBRSxFQUFFLGdCQUFnQixFQUFFLFFBQVEsSUFBSSxDQUFDLE1BQU0sWUFBWSxDQUFDLENBQzVFLENBQUM7Z0JBQ0YsT0FBTztZQUNYLENBQUM7WUFFRCxJQUFJLElBQUksQ0FBQyxLQUFLLEtBQUssU0FBUyxFQUFFLENBQUM7Z0JBQzNCLDBDQUEwQztnQkFDMUMsSUFBSSxDQUFDLFlBQVksQ0FBQztvQkFDZCxF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U0FBUyxFQUFFLElBQUksQ0FBQyxLQUFLLENBQUMsSUFBSTtZQUMxQixnQkFBZ0I7U0FDbkIsQ0FBQztJQUNOLENBQUM7Q0FDSjtBQXpORCw0Q0F5TkMiLCJzb3VyY2VzQ29udGVudCI6WyIvKipcbiAqIENvbmN1cnJlbmN5IHBvcnQgaGFuZGxlcnMgZm9yIEd1aWRhIElPIGxpYnJhcnkuXG4gKiBJbXBsZW1lbnRzIE1WYXIgYW5kIENoYW5uZWwgb3BlcmF0aW9ucyB3aXRoIGJsb2NraW5nIHNlbWFudGljcy5cbiAqL1xuXG5pbXBvcnQge1xuICAgIGNoZWNrUG9ydHNFeGlzdCxcbiAgICBFbG1BcHAsXG4gICAgT3V0Z29pbmdQb3J0LFxuICAgIEluY29taW5nUG9ydCxcbiAgICBSZXNwb25zZSxcbiAgICBva1Jlc3BvbnNlLFxuICAgIGVycm9yUmVzcG9uc2UsXG59IGZyb20gXCIuL3BvcnRzXCI7XG5cbi8vIFJlcXVlc3QgdHlwZXNcbmludGVyZmFjZSBJZE9ubHlBcmdzIHtcbiAgICBpZDogc3RyaW5nO1xufVxuXG5pbnRlcmZhY2UgTVZhcklkQXJncyB7XG4gICAgaWQ6IHN0cmluZztcbiAgICBtdmFySWQ6IG51bWJlcjtcbn1cblxuaW50ZXJmYWNlIFB1dE1WYXJBcmdzIHtcbiAgICBpZDogc3RyaW5nO1xuICAgIG12YXJJZDogbnVtYmVyO1xuICAgIHZhbHVlOiB1bmtub3duO1xufVxuXG4vLyBQb3J0IHR5cGVzXG5pbnRlcmZhY2UgQ29uY3VycmVuY3lFbG1Qb3J0cyB7XG4gICAgY29uY05ld0VtcHR5TVZhcjogT3V0Z29pbmdQb3J0PElkT25seUFyZ3M+O1xuICAgIGNvbmNSZWFkTVZhcjogT3V0Z29pbmdQb3J0PE1WYXJJZEFyZ3M+O1xuICAgIGNvbmNUYWtlTVZhcjogT3V0Z29pbmdQb3J0PE1WYXJJZEFyZ3M+O1xuICAgIGNvbmNQdXRNVmFyOiBPdXRnb2luZ1BvcnQ8UHV0TVZhckFyZ3M+O1xuICAgIGNvbmNSZXNwb25zZTogSW5jb21pbmdQb3J0PFJlc3BvbnNlPjtcbn1cblxuLy8gTVZhciBpbnRlcm5hbCBzdGF0ZVxuaW50ZXJmYWNlIE1WYXIge1xuICAgIHZhbHVlOiB1bmtub3duIHwgdW5kZWZpbmVkO1xuICAgIHN1YnNjcmliZXJzOiBBcnJheTxTdWJzY3JpYmVyPjtcbn1cblxuLy8gU3Vic2NyaWJlciB3YWl0aW5nIGZvciBNVmFyIG9wZXJhdGlvblxuaW50ZXJmYWNlIFN1YnNjcmliZXIge1xuICAgIGFjdGlvbjogXCJyZWFkXCIgfCBcInRha2VcIiB8IFwicHV0XCI7XG4gICAgaWQ6IHN0cmluZztcbiAgICB2YWx1ZT86IHVua25vd247IC8vIE9ubHkgZm9yIFwicHV0XCIgb3BlcmF0aW9uc1xufVxuXG4vKipcbiAqIENvbmN1cnJlbmN5IHBvcnQgaGFuZGxlciBjbGFzcy5cbiAqIE1hbmFnZXMgTVZhcnMgd2l0aCBibG9ja2luZyBzZW1hbnRpY3MgdGhyb3VnaCBFbG0gcG9ydHMuXG4gKi9cbmV4cG9ydCBjbGFzcyBDb25jdXJyZW5jeVBvcnRzIHtcbiAgICBwcml2YXRlIGFwcDogeyBwb3J0czogQ29uY3VycmVuY3lFbG1Qb3J0cyB9O1xuICAgIHByaXZhdGUgbVZhcnM6IE1hcDxudW1iZXIsIE1WYXI+O1xuICAgIHByaXZhdGUgbmV4dE1WYXJJZDogbnVtYmVyO1xuXG4gICAgY29uc3RydWN0b3IoYXBwOiBFbG1BcHApIHtcbiAgICAgICAgdGhpcy5hcHAgPSBhcHAgYXMgdW5rbm93biBhcyB7IHBvcnRzOiBDb25jdXJyZW5jeUVsbVBvcnRzIH07XG4gICAgICAgIHRoaXMubVZhcnMgPSBuZXcgTWFwKCk7XG4gICAgICAgIHRoaXMubmV4dE1WYXJJZCA9IDE7XG5cbiAgICAgICAgY29uc3QgcG9ydE5hbWVzID0gW1xuICAgICAgICAgICAgXCJjb25jTmV3RW1wdHlNVmFyXCIsXG4gICAgICAgICAgICBcImNvbmNSZWFkTVZhclwiLFxuICAgICAgICAgICAgXCJjb25jVGFrZU1WYXJcIixcbiAgICAgICAgICAgIFwiY29uY1B1dE1WYXJcIixcbiAgICAgICAgICAgIFwiY29uY1Jlc3BvbnNlXCIsXG4gICAgICAgIF07XG5cbiAgICAgICAgY2hlY2tQb3J0c0V4aXN0KGFwcCwgcG9ydE5hbWVzKTtcblxuICAgICAgICBjb25zdCBwb3J0cyA9IGFwcC5wb3J0cyBhcyB1bmtub3duIGFzIENvbmN1cnJlbmN5RWxtUG9ydHM7XG4gICAgICAgIHBvcnRzLmNvbmNOZXdFbXB0eU1WYXIuc3Vic2NyaWJlKHRoaXMubmV3RW1wdHlNVmFyKTtcbiAgICAgICAgcG9ydHMuY29uY1JlYWRNVmFyLnN1YnNjcmliZSh0aGlzLnJlYWRNVmFyKTtcbiAgICAgICAgcG9ydHMuY29uY1Rha2VNVmFyLnN1YnNjcmliZSh0aGlzLnRha2VNVmFyKTtcbiAgICAgICAgcG9ydHMuY29uY1B1dE1WYXIuc3Vic2NyaWJlKHRoaXMucHV0TVZhcik7XG4gICAgfVxuXG4gICAgcHJpdmF0ZSBzZW5kUmVzcG9uc2UocmVzcG9uc2U6IFJlc3BvbnNlKTogdm9pZCB7XG4gICAgICAgIGNvbnN0IHBvcnRzID0gdGhpcy5hcHAucG9ydHMgYXMgdW5rbm93biBhcyBDb25jdXJyZW5jeUVsbVBvcnRzO1xuICAgICAgICBwb3J0cy5jb25jUmVzcG9uc2Uuc2VuZChyZXNwb25zZSk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ3JlYXRlIGEgbmV3IGVtcHR5IE1WYXIuXG4gICAgICovXG4gICAgbmV3RW1wdHlNVmFyID0gKGFyZ3M6IElkT25seUFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgY29uc3QgbXZhcklkID0gdGhpcy5uZXh0TVZhcklkKys7XG4gICAgICAgIHRoaXMubVZhcnMuc2V0KG12YXJJZCwge1xuICAgICAgICAgICAgdmFsdWU6IHVuZGVmaW5lZCxcbiAgICAgICAgICAgIHN1YnNjcmliZXJzOiBbXSxcbiAgICAgICAgfSk7XG5cbiAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICB0eXBlXzogXCJNVmFyXCIsXG4gICAgICAgICAgICBwYXlsb2FkOiBtdmFySWQsXG4gICAgICAgIH0pO1xuICAgIH07XG5cbiAgICAvKipcbiAgICAgKiBSZWFkIHRoZSB2YWx1ZSBmcm9tIGFuIE1WYXIgd2l0aG91dCByZW1vdmluZyBpdC5cbiAgICAgKiBCbG9ja3MgaWYgZW1wdHkuXG4gICAgICovXG4gICAgcmVhZE1WYXIgPSAoYXJnczogTVZhcklkQXJncyk6IHZvaWQgPT4ge1xuICAgICAgICBjb25zdCBtdmFyID0gdGhpcy5tVmFycy5nZXQoYXJncy5tdmFySWQpO1xuXG4gICAgICAgIGlmICghbXZhcikge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoXG4gICAgICAgICAgICAgICAgZXJyb3JSZXNwb25zZShhcmdzLmlkLCBcIk1WQVJfTk9UX0ZPVU5EXCIsIGBNVmFyICR7YXJncy5tdmFySWR9IG5vdCBmb3VuZGApXG4gICAgICAgICAgICApO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKG12YXIudmFsdWUgIT09IHVuZGVmaW5lZCkge1xuICAgICAgICAgICAgLy8gTVZhciBoYXMgYSB2YWx1ZSwgcmV0dXJuIGl0IGltbWVkaWF0ZWx5XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZSh7XG4gICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgdHlwZV86IFwiVmFsdWVcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiBtdmFyLnZhbHVlLFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAvLyBNVmFyIGlzIGVtcHR5LCBibG9jayBieSBhZGRpbmcgdG8gc3Vic2NyaWJlcnNcbiAgICAgICAgICAgIG12YXIuc3Vic2NyaWJlcnMucHVzaCh7XG4gICAgICAgICAgICAgICAgYWN0aW9uOiBcInJlYWRcIixcbiAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIC8qKlxuICAgICAqIFRha2UgdGhlIHZhbHVlIGZyb20gYW4gTVZhciwgbGVhdmluZyBpdCBlbXB0eS5cbiAgICAgKiBCbG9ja3MgaWYgZW1wdHkuXG4gICAgICovXG4gICAgdGFrZU1WYXIgPSAoYXJnczogTVZhcklkQXJncyk6IHZvaWQgPT4ge1xuICAgICAgICBjb25zdCBtdmFyID0gdGhpcy5tVmFycy5nZXQoYXJncy5tdmFySWQpO1xuXG4gICAgICAgIGlmICghbXZhcikge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoXG4gICAgICAgICAgICAgICAgZXJyb3JSZXNwb25zZShhcmdzLmlkLCBcIk1WQVJfTk9UX0ZPVU5EXCIsIGBNVmFyICR7YXJncy5tdmFySWR9IG5vdCBmb3VuZGApXG4gICAgICAgICAgICApO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKG12YXIudmFsdWUgIT09IHVuZGVmaW5lZCkge1xuICAgICAgICAgICAgLy8gTVZhciBoYXMgYSB2YWx1ZSwgdGFrZSBpdFxuICAgICAgICAgICAgY29uc3QgdmFsdWUgPSBtdmFyLnZhbHVlO1xuICAgICAgICAgICAgbXZhci52YWx1ZSA9IHVuZGVmaW5lZDtcblxuICAgICAgICAgICAgLy8gQ2hlY2sgaWYgdGhlcmUncyBhIFwicHV0XCIgc3Vic2NyaWJlciB3YWl0aW5nXG4gICAgICAgICAgICBjb25zdCBwdXRTdWJzY3JpYmVyID0gbXZhci5zdWJzY3JpYmVycy5maW5kKChzKSA9PiBzLmFjdGlvbiA9PT0gXCJwdXRcIik7XG4gICAgICAgICAgICBpZiAocHV0U3Vic2NyaWJlcikge1xuICAgICAgICAgICAgICAgIC8vIFJlbW92ZSB0aGUgcHV0IHN1YnNjcmliZXIgYW5kIHNldCBpdHMgdmFsdWVcbiAgICAgICAgICAgICAgICBtdmFyLnN1YnNjcmliZXJzID0gbXZhci5zdWJzY3JpYmVycy5maWx0ZXIoKHMpID0+IHMgIT09IHB1dFN1YnNjcmliZXIpO1xuICAgICAgICAgICAgICAgIG12YXIudmFsdWUgPSBwdXRTdWJzY3JpYmVyLnZhbHVlO1xuXG4gICAgICAgICAgICAgICAgLy8gTm90aWZ5IHRoZSBwdXQgc3Vic2NyaWJlciB0aGF0IGl0IHN1Y2NlZWRlZFxuICAgICAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKG9rUmVzcG9uc2UocHV0U3Vic2NyaWJlci5pZCkpO1xuXG4gICAgICAgICAgICAgICAgLy8gV2FrZSB1cCBhbnkgcmVhZCBzdWJzY3JpYmVycyBub3cgdGhhdCB0aGVyZSdzIGEgdmFsdWVcbiAgICAgICAgICAgICAgICB0aGlzLndha2VSZWFkU3Vic2NyaWJlcnMobXZhcik7XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIC8vIFJldHVybiB0aGUgdGFrZW4gdmFsdWVcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgICAgICB0eXBlXzogXCJWYWx1ZVwiLFxuICAgICAgICAgICAgICAgIHBheWxvYWQ6IHZhbHVlLFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAvLyBNVmFyIGlzIGVtcHR5LCBibG9jayBieSBhZGRpbmcgdG8gc3Vic2NyaWJlcnNcbiAgICAgICAgICAgIG12YXIuc3Vic2NyaWJlcnMucHVzaCh7XG4gICAgICAgICAgICAgICAgYWN0aW9uOiBcInRha2VcIixcbiAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIC8qKlxuICAgICAqIFB1dCBhIHZhbHVlIGludG8gYW4gTVZhci5cbiAgICAgKiBCbG9ja3MgaWYgYWxyZWFkeSBmdWxsLlxuICAgICAqL1xuICAgIHB1dE1WYXIgPSAoYXJnczogUHV0TVZhckFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgY29uc3QgbXZhciA9IHRoaXMubVZhcnMuZ2V0KGFyZ3MubXZhcklkKTtcblxuICAgICAgICBpZiAoIW12YXIpIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKFxuICAgICAgICAgICAgICAgIGVycm9yUmVzcG9uc2UoYXJncy5pZCwgXCJNVkFSX05PVF9GT1VORFwiLCBgTVZhciAke2FyZ3MubXZhcklkfSBub3QgZm91bmRgKVxuICAgICAgICAgICAgKTtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmIChtdmFyLnZhbHVlID09PSB1bmRlZmluZWQpIHtcbiAgICAgICAgICAgIC8vIE1WYXIgaXMgZW1wdHksIHB1dCB0aGUgdmFsdWVcbiAgICAgICAgICAgIG12YXIudmFsdWUgPSBhcmdzLnZhbHVlO1xuXG4gICAgICAgICAgICAvLyBXYWtlIHVwIHJlYWQgc3Vic2NyaWJlcnMgKHRoZXkgZG9uJ3QgY29uc3VtZSlcbiAgICAgICAgICAgIHRoaXMud2FrZVJlYWRTdWJzY3JpYmVycyhtdmFyKTtcblxuICAgICAgICAgICAgLy8gV2FrZSB1cCB0aGUgZmlyc3QgdGFrZSBzdWJzY3JpYmVyIGlmIGFueVxuICAgICAgICAgICAgY29uc3QgdGFrZVN1YnNjcmliZXIgPSBtdmFyLnN1YnNjcmliZXJzLmZpbmQoKHMpID0+IHMuYWN0aW9uID09PSBcInRha2VcIik7XG4gICAgICAgICAgICBpZiAodGFrZVN1YnNjcmliZXIpIHtcbiAgICAgICAgICAgICAgICAvLyBSZW1vdmUgdGhlIHRha2Ugc3Vic2NyaWJlclxuICAgICAgICAgICAgICAgIG12YXIuc3Vic2NyaWJlcnMgPSBtdmFyLnN1YnNjcmliZXJzLmZpbHRlcigocykgPT4gcyAhPT0gdGFrZVN1YnNjcmliZXIpO1xuXG4gICAgICAgICAgICAgICAgLy8gR2l2ZSB0aGVtIHRoZSB2YWx1ZSBhbmQgY2xlYXIgdGhlIE1WYXJcbiAgICAgICAgICAgICAgICBjb25zdCB2YWx1ZSA9IG12YXIudmFsdWU7XG4gICAgICAgICAgICAgICAgbXZhci52YWx1ZSA9IHVuZGVmaW5lZDtcblxuICAgICAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICAgICAgaWQ6IHRha2VTdWJzY3JpYmVyLmlkLFxuICAgICAgICAgICAgICAgICAgICB0eXBlXzogXCJWYWx1ZVwiLFxuICAgICAgICAgICAgICAgICAgICBwYXlsb2FkOiB2YWx1ZSxcbiAgICAgICAgICAgICAgICB9KTtcblxuICAgICAgICAgICAgICAgIC8vIENoZWNrIGlmIHRoZXJlJ3MgYW5vdGhlciBwdXQgd2FpdGluZ1xuICAgICAgICAgICAgICAgIGNvbnN0IG5leHRQdXQgPSBtdmFyLnN1YnNjcmliZXJzLmZpbmQoKHMpID0+IHMuYWN0aW9uID09PSBcInB1dFwiKTtcbiAgICAgICAgICAgICAgICBpZiAobmV4dFB1dCkge1xuICAgICAgICAgICAgICAgICAgICBtdmFyLnN1YnNjcmliZXJzID0gbXZhci5zdWJzY3JpYmVycy5maWx0ZXIoKHMpID0+IHMgIT09IG5leHRQdXQpO1xuICAgICAgICAgICAgICAgICAgICBtdmFyLnZhbHVlID0gbmV4dFB1dC52YWx1ZTtcbiAgICAgICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uob2tSZXNwb25zZShuZXh0UHV0LmlkKSk7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMud2FrZVJlYWRTdWJzY3JpYmVycyhtdmFyKTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIC8vIFJlc3BvbmQgT0sgdG8gdGhlIG9yaWdpbmFsIHB1dFxuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uob2tSZXNwb25zZShhcmdzLmlkKSk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAvLyBNVmFyIGlzIGZ1bGwsIGJsb2NrIGJ5IGFkZGluZyB0byBzdWJzY3JpYmVyc1xuICAgICAgICAgICAgbXZhci5zdWJzY3JpYmVycy5wdXNoKHtcbiAgICAgICAgICAgICAgICBhY3Rpb246IFwicHV0XCIsXG4gICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgdmFsdWU6IGFyZ3MudmFsdWUsXG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfVxuICAgIH07XG5cbiAgICAvKipcbiAgICAgKiBXYWtlIHVwIGFsbCByZWFkIHN1YnNjcmliZXJzIHdpdGggdGhlIGN1cnJlbnQgdmFsdWUuXG4gICAgICovXG4gICAgcHJpdmF0ZSB3YWtlUmVhZFN1YnNjcmliZXJzKG12YXI6IE1WYXIpOiB2b2lkIHtcbiAgICAgICAgaWYgKG12YXIudmFsdWUgPT09IHVuZGVmaW5lZCkgcmV0dXJuO1xuXG4gICAgICAgIGNvbnN0IHJlYWRTdWJzY3JpYmVycyA9IG12YXIuc3Vic2NyaWJlcnMuZmlsdGVyKChzKSA9PiBzLmFjdGlvbiA9PT0gXCJyZWFkXCIpO1xuICAgICAgICBtdmFyLnN1YnNjcmliZXJzID0gbXZhci5zdWJzY3JpYmVycy5maWx0ZXIoKHMpID0+IHMuYWN0aW9uICE9PSBcInJlYWRcIik7XG5cbiAgICAgICAgZm9yIChjb25zdCBzdWJzY3JpYmVyIG9mIHJlYWRTdWJzY3JpYmVycykge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBzdWJzY3JpYmVyLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIlZhbHVlXCIsXG4gICAgICAgICAgICAgICAgcGF5bG9hZDogbXZhci52YWx1ZSxcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogR2V0IGRlYnVnIGluZm8gYWJvdXQgTVZhciBzdGF0ZSAoZm9yIHRlc3RpbmcpLlxuICAgICAqL1xuICAgIGdldERlYnVnSW5mbygpOiB7IG12YXJDb3VudDogbnVtYmVyOyB0b3RhbFN1YnNjcmliZXJzOiBudW1iZXIgfSB7XG4gICAgICAgIGxldCB0b3RhbFN1YnNjcmliZXJzID0gMDtcbiAgICAgICAgZm9yIChjb25zdCBtdmFyIG9mIHRoaXMubVZhcnMudmFsdWVzKCkpIHtcbiAgICAgICAgICAgIHRvdGFsU3Vic2NyaWJlcnMgKz0gbXZhci5zdWJzY3JpYmVycy5sZW5ndGg7XG4gICAgICAgIH1cbiAgICAgICAgcmV0dXJuIHtcbiAgICAgICAgICAgIG12YXJDb3VudDogdGhpcy5tVmFycy5zaXplLFxuICAgICAgICAgICAgdG90YWxTdWJzY3JpYmVycyxcbiAgICAgICAgfTtcbiAgICB9XG59XG4iXX0=