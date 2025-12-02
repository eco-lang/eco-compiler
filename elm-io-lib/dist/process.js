"use strict";
/**
 * Process port handlers for Guida IO library.
 * Implements environment and process control operations.
 */
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.ProcessPorts = void 0;
const path = __importStar(require("path"));
const fs = __importStar(require("fs"));
const ports_1 = require("./ports");
// Default configuration using process
const defaultConfig = {
    env: process.env,
    argv: process.argv.slice(2), // Remove node and script path
    cwd: () => process.cwd(),
    exit: (code) => process.exit(code),
    pathSeparator: path.delimiter,
};
/**
 * Process port handler class.
 * Manages environment and process operations through Elm ports.
 */
class ProcessPorts {
    constructor(app, args = [], config = defaultConfig) {
        this.onExit = null;
        // Environment operations
        this.lookupEnv = (args) => {
            const value = this.config.env[args.name];
            if (value !== undefined) {
                this.sendResponse({
                    id: args.id,
                    type_: "Value",
                    payload: value,
                });
            }
            else {
                this.sendResponse({
                    id: args.id,
                    type_: "NotFound",
                    payload: null,
                });
            }
        };
        this.getArgs = (args) => {
            this.sendResponse({
                id: args.id,
                type_: "Args",
                payload: this.args,
            });
        };
        this.findExecutable = async (args) => {
            const pathEnv = this.config.env.PATH || this.config.env.Path || "";
            const pathDirs = pathEnv.split(this.config.pathSeparator);
            // Extensions to check on Windows
            const extensions = process.platform === "win32"
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
                    }
                    catch {
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
        this.exit = (args) => {
            if (this.onExit) {
                this.onExit(args.response);
            }
            else {
                // Default behavior: log response and exit
                console.log(JSON.stringify(args.response));
                this.config.exit(0);
            }
        };
        this.app = app;
        this.config = config;
        this.args = args.length > 0 ? args : config.argv;
        const portNames = [
            "procLookupEnv",
            "procGetArgs",
            "procFindExecutable",
            "procExit",
            "procResponse",
        ];
        (0, ports_1.checkPortsExist)(app, portNames);
        const ports = app.ports;
        ports.procLookupEnv.subscribe(this.lookupEnv);
        ports.procGetArgs.subscribe(this.getArgs);
        ports.procFindExecutable.subscribe(this.findExecutable);
        ports.procExit.subscribe(this.exit);
    }
    /**
     * Set the callback for exit handling.
     * The callback receives the response value from the Elm application.
     */
    setExitCallback(callback) {
        this.onExit = callback;
    }
    sendResponse(response) {
        const ports = this.app.ports;
        ports.procResponse.send(response);
    }
}
exports.ProcessPorts = ProcessPorts;
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoicHJvY2Vzcy5qcyIsInNvdXJjZVJvb3QiOiIiLCJzb3VyY2VzIjpbIi4uL2pzL3Byb2Nlc3MudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IjtBQUFBOzs7R0FHRzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBRUgsMkNBQTZCO0FBQzdCLHVDQUF5QjtBQUN6QixtQ0FNaUI7QUF1Q2pCLHNDQUFzQztBQUN0QyxNQUFNLGFBQWEsR0FBa0I7SUFDakMsR0FBRyxFQUFFLE9BQU8sQ0FBQyxHQUFHO0lBQ2hCLElBQUksRUFBRSxPQUFPLENBQUMsSUFBSSxDQUFDLEtBQUssQ0FBQyxDQUFDLENBQUMsRUFBRSw4QkFBOEI7SUFDM0QsR0FBRyxFQUFFLEdBQUcsRUFBRSxDQUFDLE9BQU8sQ0FBQyxHQUFHLEVBQUU7SUFDeEIsSUFBSSxFQUFFLENBQUMsSUFBSSxFQUFFLEVBQUUsQ0FBQyxPQUFPLENBQUMsSUFBSSxDQUFDLElBQUksQ0FBQztJQUNsQyxhQUFhLEVBQUUsSUFBSSxDQUFDLFNBQVM7Q0FDaEMsQ0FBQztBQVFGOzs7R0FHRztBQUNILE1BQWEsWUFBWTtJQU1yQixZQUNJLEdBQVcsRUFDWCxPQUFpQixFQUFFLEVBQ25CLFNBQXdCLGFBQWE7UUFMakMsV0FBTSxHQUF3QixJQUFJLENBQUM7UUF5QzNDLHlCQUF5QjtRQUV6QixjQUFTLEdBQUcsQ0FBQyxJQUFtQixFQUFRLEVBQUU7WUFDdEMsTUFBTSxLQUFLLEdBQUcsSUFBSSxDQUFDLE1BQU0sQ0FBQyxHQUFHLENBQUMsSUFBSSxDQUFDLElBQUksQ0FBQyxDQUFDO1lBRXpDLElBQUksS0FBSyxLQUFLLFNBQVMsRUFBRSxDQUFDO2dCQUN0QixJQUFJLENBQUMsWUFBWSxDQUFDO29CQUNkLEVBQUUsRUFBRSxJQUFJLENBQUMsRUFBRTtvQkFDWCxLQUFLLEVBQUUsT0FBTztvQkFDZCxPQUFPLEVBQUUsS0FBSztpQkFDakIsQ0FBQyxDQUFDO1lBQ1AsQ0FBQztpQkFBTSxDQUFDO2dCQUNKLElB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QUMsQ0FBQyxNQUFNLENBQUMsSUFBSSxDQUFDO1FBRWpELE1BQU0sU0FBUyxHQUFHO1lBQ2QsZUFBZTtZQUNmLGFBQWE7WUFDYixvQkFBb0I7WUFDcEIsVUFBVTtZQUNWLGNBQWM7U0FDakIsQ0FBQztRQUVGLElBQUEsdUJBQWUsRUFBQyxHQUFHLEVBQUUsU0FBUyxDQUFDLENBQUM7UUFFaEMsTUFBTSxLQUFLLEdBQUcsR0FBRyxDQUFDLEtBQW1DLENBQUM7UUFDdEQsS0FBSyxDQUFDLGFBQWEsQ0FBQyxTQUFTLENBQUMsSUFBSSxDQUFDLFNBQVMsQ0FBQyxDQUFDO1FBQzlDLEtBQUssQ0FBQyxXQUFXLENBQUMsU0FBUyxDQUFDLElBQUksQ0FBQyxPQUFPLENBQUMsQ0FBQztRQUMxQyxLQUFLLENBQUMsa0JBQWtCLENBQUMsU0FBUyxDQUFDLElBQUksQ0FBQyxjQUFjLENBQUMsQ0FBQztRQUN4RCxLQUFLLENBQUMsUUFBUSxDQUFDLFNBQVMsQ0FBQyxJQUFJLENBQUMsSUFBSSxDQUFDLENBQUM7SUFDeEMsQ0FBQztJQUVEOzs7T0FHRztJQUNILGVBQWUsQ0FBQyxRQUFzQjtRQUNsQyxJQUFJLENBQUMsTUFBTSxHQUFHLFFBQVEsQ0FBQztJQUMzQixDQUFDO0lBRU8sWUFBWSxDQUFDLFFBQWtCO1FBQ25DLE1BQU0sS0FBSyxHQUFHLElBQUksQ0FBQyxHQUFHLENBQUMsS0FBbUMsQ0FBQztRQUMzRCxLQUFLLENBQUMsWUFBWSxDQUFDLElBQUksQ0FBQyxRQUFRLENBQUMsQ0FBQztJQUN0QyxDQUFDO0NBNEVKO0FBdkhELG9DQXVIQyIsInNvdXJjZXNDb250ZW50IjpbIi8qKlxuICogUHJvY2VzcyBwb3J0IGhhbmRsZXJzIGZvciBHdWlkYSBJTyBsaWJyYXJ5LlxuICogSW1wbGVtZW50cyBlbnZpcm9ubWVudCBhbmQgcHJvY2VzcyBjb250cm9sIG9wZXJhdGlvbnMuXG4gKi9cblxuaW1wb3J0ICogYXMgcGF0aCBmcm9tIFwicGF0aFwiO1xuaW1wb3J0ICogYXMgZnMgZnJvbSBcImZzXCI7XG5pbXBvcnQge1xuICAgIGNoZWNrUG9ydHNFeGlzdCxcbiAgICBFbG1BcHAsXG4gICAgT3V0Z29pbmdQb3J0LFxuICAgIEluY29taW5nUG9ydCxcbiAgICBSZXNwb25zZSxcbn0gZnJvbSBcIi4vcG9ydHNcIjtcblxuLy8gUmVxdWVzdCB0eXBlc1xuaW50ZXJmYWNlIExvb2t1cEVudkFyZ3Mge1xuICAgIGlkOiBzdHJpbmc7XG4gICAgbmFtZTogc3RyaW5nO1xufVxuXG5pbnRlcmZhY2UgSWRPbmx5QXJncyB7XG4gICAgaWQ6IHN0cmluZztcbn1cblxuaW50ZXJmYWNlIEZpbmRFeGVjdXRhYmxlQXJncyB7XG4gICAgaWQ6IHN0cmluZztcbiAgICBuYW1lOiBzdHJpbmc7XG59XG5cbmludGVyZmFjZSBFeGl0QXJncyB7XG4gICAgcmVzcG9uc2U6IHVua25vd247XG59XG5cbi8vIFBvcnQgdHlwZXNcbmludGVyZmFjZSBQcm9jZXNzRWxtUG9ydHMge1xuICAgIHByb2NMb29rdXBFbnY6IE91dGdvaW5nUG9ydDxMb29rdXBFbnZBcmdzPjtcbiAgICBwcm9jR2V0QXJnczogT3V0Z29pbmdQb3J0PElkT25seUFyZ3M+O1xuICAgIHByb2NGaW5kRXhlY3V0YWJsZTogT3V0Z29pbmdQb3J0PEZpbmRFeGVjdXRhYmxlQXJncz47XG4gICAgcHJvY0V4aXQ6IE91dGdvaW5nUG9ydDxFeGl0QXJncz47XG4gICAgcHJvY1Jlc3BvbnNlOiBJbmNvbWluZ1BvcnQ8UmVzcG9uc2U+O1xufVxuXG4vLyBDb25maWd1cmF0aW9uIGludGVyZmFjZSBmb3IgZGVwZW5kZW5jeSBpbmplY3Rpb25cbmV4cG9ydCBpbnRlcmZhY2UgUHJvY2Vzc0NvbmZpZyB7XG4gICAgZW52OiBOb2RlSlMuUHJvY2Vzc0VudjtcbiAgICBhcmd2OiBzdHJpbmdbXTtcbiAgICBjd2Q6ICgpID0+IHN0cmluZztcbiAgICBleGl0OiAoY29kZTogbnVtYmVyKSA9PiBuZXZlcjtcbiAgICBwYXRoU2VwYXJhdG9yOiBzdHJpbmc7XG59XG5cbi8vIERlZmF1bHQgY29uZmlndXJhdGlvbiB1c2luZyBwcm9jZXNzXG5jb25zdCBkZWZhdWx0Q29uZmlnOiBQcm9jZXNzQ29uZmlnID0ge1xuICAgIGVudjogcHJvY2Vzcy5lbnYsXG4gICAgYXJndjogcHJvY2Vzcy5hcmd2LnNsaWNlKDIpLCAvLyBSZW1vdmUgbm9kZSBhbmQgc2NyaXB0IHBhdGhcbiAgICBjd2Q6ICgpID0+IHByb2Nlc3MuY3dkKCksXG4gICAgZXhpdDogKGNvZGUpID0+IHByb2Nlc3MuZXhpdChjb2RlKSxcbiAgICBwYXRoU2VwYXJhdG9yOiBwYXRoLmRlbGltaXRlcixcbn07XG5cbi8qKlxuICogQ2FsbGJhY2sgdHlwZSBmb3IgZXhpdCBoYW5kbGluZy5cbiAqIFRoZSBob3N0IGFwcGxpY2F0aW9uIGNhbiBwcm92aWRlIHRoaXMgdG8gaGFuZGxlIHRoZSBleGl0IHJlc3BvbnNlLlxuICovXG5leHBvcnQgdHlwZSBFeGl0Q2FsbGJhY2sgPSAocmVzcG9uc2U6IHVua25vd24pID0+IHZvaWQ7XG5cbi8qKlxuICogUHJvY2VzcyBwb3J0IGhhbmRsZXIgY2xhc3MuXG4gKiBNYW5hZ2VzIGVudmlyb25tZW50IGFuZCBwcm9jZXNzIG9wZXJhdGlvbnMgdGhyb3VnaCBFbG0gcG9ydHMuXG4gKi9cbmV4cG9ydCBjbGFzcyBQcm9jZXNzUG9ydHMge1xuICAgIHByaXZhdGUgYXBwOiB7IHBvcnRzOiBQcm9jZXNzRWxtUG9ydHMgfTtcbiAgICBwcml2YXRlIGNvbmZpZzogUHJvY2Vzc0NvbmZpZztcbiAgICBwcml2YXRlIGFyZ3M6IHN0cmluZ1tdO1xuICAgIHByaXZhdGUgb25FeGl0OiBFeGl0Q2FsbGJhY2sgfCBudWxsID0gbnVsbDtcblxuICAgIGNvbnN0cnVjdG9yKFxuICAgICAgICBhcHA6IEVsbUFwcCxcbiAgICAgICAgYXJnczogc3RyaW5nW10gPSBbXSxcbiAgICAgICAgY29uZmlnOiBQcm9jZXNzQ29uZmlnID0gZGVmYXVsdENvbmZpZ1xuICAgICkge1xuICAgICAgICB0aGlzLmFwcCA9IGFwcCBhcyB1bmtub3duIGFzIHsgcG9ydHM6IFByb2Nlc3NFbG1Qb3J0cyB9O1xuICAgICAgICB0aGlzLmNvbmZpZyA9IGNvbmZpZztcbiAgICAgICAgdGhpcy5hcmdzID0gYXJncy5sZW5ndGggPiAwID8gYXJncyA6IGNvbmZpZy5hcmd2O1xuXG4gICAgICAgIGNvbnN0IHBvcnROYW1lcyA9IFtcbiAgICAgICAgICAgIFwicHJvY0xvb2t1cEVudlwiLFxuICAgICAgICAgICAgXCJwcm9jR2V0QXJnc1wiLFxuICAgICAgICAgICAgXCJwcm9jRmluZEV4ZWN1dGFibGVcIixcbiAgICAgICAgICAgIFwicHJvY0V4aXRcIixcbiAgICAgICAgICAgIFwicHJvY1Jlc3BvbnNlXCIsXG4gICAgICAgIF07XG5cbiAgICAgICAgY2hlY2tQb3J0c0V4aXN0KGFwcCwgcG9ydE5hbWVzKTtcblxuICAgICAgICBjb25zdCBwb3J0cyA9IGFwcC5wb3J0cyBhcyB1bmtub3duIGFzIFByb2Nlc3NFbG1Qb3J0cztcbiAgICAgICAgcG9ydHMucHJvY0xvb2t1cEVudi5zdWJzY3JpYmUodGhpcy5sb29rdXBFbnYpO1xuICAgICAgICBwb3J0cy5wcm9jR2V0QXJncy5zdWJzY3JpYmUodGhpcy5nZXRBcmdzKTtcbiAgICAgICAgcG9ydHMucHJvY0ZpbmRFeGVjdXRhYmxlLnN1YnNjcmliZSh0aGlzLmZpbmRFeGVjdXRhYmxlKTtcbiAgICAgICAgcG9ydHMucHJvY0V4aXQuc3Vic2NyaWJlKHRoaXMuZXhpdCk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogU2V0IHRoZSBjYWxsYmFjayBmb3IgZXhpdCBoYW5kbGluZy5cbiAgICAgKiBUaGUgY2FsbGJhY2sgcmVjZWl2ZXMgdGhlIHJlc3BvbnNlIHZhbHVlIGZyb20gdGhlIEVsbSBhcHBsaWNhdGlvbi5cbiAgICAgKi9cbiAgICBzZXRFeGl0Q2FsbGJhY2soY2FsbGJhY2s6IEV4aXRDYWxsYmFjayk6IHZvaWQge1xuICAgICAgICB0aGlzLm9uRXhpdCA9IGNhbGxiYWNrO1xuICAgIH1cblxuICAgIHByaXZhdGUgc2VuZFJlc3BvbnNlKHJlc3BvbnNlOiBSZXNwb25zZSk6IHZvaWQge1xuICAgICAgICBjb25zdCBwb3J0cyA9IHRoaXMuYXBwLnBvcnRzIGFzIHVua25vd24gYXMgUHJvY2Vzc0VsbVBvcnRzO1xuICAgICAgICBwb3J0cy5wcm9jUmVzcG9uc2Uuc2VuZChyZXNwb25zZSk7XG4gICAgfVxuXG4gICAgLy8gRW52aXJvbm1lbnQgb3BlcmF0aW9uc1xuXG4gICAgbG9va3VwRW52ID0gKGFyZ3M6IExvb2t1cEVudkFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgY29uc3QgdmFsdWUgPSB0aGlzLmNvbmZpZy5lbnZbYXJncy5uYW1lXTtcblxuICAgICAgICBpZiAodmFsdWUgIT09IHVuZGVmaW5lZCkge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIlZhbHVlXCIsXG4gICAgICAgICAgICAgICAgcGF5bG9hZDogdmFsdWUsXG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgICAgICB0eXBlXzogXCJOb3RGb3VuZFwiLFxuICAgICAgICAgICAgICAgIHBheWxvYWQ6IG51bGwsXG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfVxuICAgIH07XG5cbiAgICBnZXRBcmdzID0gKGFyZ3M6IElkT25seUFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICB0eXBlXzogXCJBcmdzXCIsXG4gICAgICAgICAgICBwYXlsb2FkOiB0aGlzLmFyZ3MsXG4gICAgICAgIH0pO1xuICAgIH07XG5cbiAgICBmaW5kRXhlY3V0YWJsZSA9IGFzeW5jIChhcmdzOiBGaW5kRXhlY3V0YWJsZUFyZ3MpOiBQcm9taXNlPHZvaWQ+ID0+IHtcbiAgICAgICAgY29uc3QgcGF0aEVudiA9IHRoaXMuY29uZmlnLmVudi5QQVRIIHx8IHRoaXMuY29uZmlnLmVudi5QYXRoIHx8IFwiXCI7XG4gICAgICAgIGNvbnN0IHBhdGhEaXJzID0gcGF0aEVudi5zcGxpdCh0aGlzLmNvbmZpZy5wYXRoU2VwYXJhdG9yKTtcblxuICAgICAgICAvLyBFeHRlbnNpb25zIHRvIGNoZWNrIG9uIFdpbmRvd3NcbiAgICAgICAgY29uc3QgZXh0ZW5zaW9ucyA9XG4gICAgICAgICAgICBwcm9jZXNzLnBsYXRmb3JtID09PSBcIndpbjMyXCJcbiAgICAgICAgICAgICAgICA/IFtcIi5leGVcIiwgXCIuY21kXCIsIFwiLmJhdFwiLCBcIi5jb21cIiwgXCJcIl1cbiAgICAgICAgICAgICAgICA6IFtcIlwiXTtcblxuICAgICAgICBmb3IgKGNvbnN0IGRpciBvZiBwYXRoRGlycykge1xuICAgICAgICAgICAgZm9yIChjb25zdCBleHQgb2YgZXh0ZW5zaW9ucykge1xuICAgICAgICAgICAgICAgIGNvbnN0IGZ1bGxQYXRoID0gcGF0aC5qb2luKGRpciwgYXJncy5uYW1lICsgZXh0KTtcbiAgICAgICAgICAgICAgICB0cnkge1xuICAgICAgICAgICAgICAgICAgICBhd2FpdCBmcy5wcm9taXNlcy5hY2Nlc3MoZnVsbFBhdGgsIGZzLmNvbnN0YW50cy5YX09LKTtcbiAgICAgICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgICAgICAgICB0eXBlXzogXCJWYWx1ZVwiLFxuICAgICAgICAgICAgICAgICAgICAgICAgcGF5bG9hZDogZnVsbFBhdGgsXG4gICAgICAgICAgICAgICAgICAgIH0pO1xuICAgICAgICAgICAgICAgICAgICByZXR1cm47XG4gICAgICAgICAgICAgICAgfSBjYXRjaCB7XG4gICAgICAgICAgICAgICAgICAgIC8vIEZpbGUgbm90IGZvdW5kIG9yIG5vdCBleGVjdXRhYmxlLCBjb250aW51ZSBzZWFyY2hpbmdcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgICAgICAvLyBOb3QgZm91bmQgaW4gYW55IFBBVEggZGlyZWN0b3J5XG4gICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgdHlwZV86IFwiTm90Rm91bmRcIixcbiAgICAgICAgICAgIHBheWxvYWQ6IG51bGwsXG4gICAgICAgIH0pO1xuICAgIH07XG5cbiAgICAvLyBQcm9jZXNzIGNvbnRyb2xcblxuICAgIGV4aXQgPSAoYXJnczogRXhpdEFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgaWYgKHRoaXMub25FeGl0KSB7XG4gICAgICAgICAgICB0aGlzLm9uRXhpdChhcmdzLnJlc3BvbnNlKTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIC8vIERlZmF1bHQgYmVoYXZpb3I6IGxvZyByZXNwb25zZSBhbmQgZXhpdFxuICAgICAgICAgICAgY29uc29sZS5sb2coSlNPTi5zdHJpbmdpZnkoYXJncy5yZXNwb25zZSkpO1xuICAgICAgICAgICAgdGhpcy5jb25maWcuZXhpdCgwKTtcbiAgICAgICAgfVxuICAgIH07XG59XG4iXX0=