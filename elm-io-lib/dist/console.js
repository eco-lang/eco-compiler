"use strict";
/**
 * Console port handlers for Guida IO library.
 * Implements terminal/console IO operations.
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
exports.ConsolePorts = void 0;
const readline = __importStar(require("readline"));
const ports_1 = require("./ports");
// Default configuration using process streams
const defaultConfig = {
    stdout: process.stdout,
    stderr: process.stderr,
    stdin: process.stdin,
};
/**
 * Console port handler class.
 * Manages terminal/console IO through Elm ports.
 */
class ConsolePorts {
    constructor(app, config = defaultConfig) {
        this.rl = null;
        // Output operations (fire-and-forget)
        this.write = (args) => {
            try {
                if (args.fd === 1) {
                    this.config.stdout.write(args.content);
                }
                else if (args.fd === 2) {
                    this.config.stderr.write(args.content);
                }
                else {
                    // For other file descriptors, default to stdout
                    // In a full implementation, we'd track open file handles
                    this.config.stdout.write(args.content);
                }
                // Fire-and-forget: no response sent
            }
            catch (error) {
                // Log error but don't send response (fire-and-forget)
                console.error("Console write error:", error);
            }
        };
        // Input operations (call-and-response)
        this.getLine = (args) => {
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
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.replGetInputLine = (args) => {
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
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.app = app;
        this.config = config;
        const portNames = [
            "consoleWrite",
            "consoleGetLine",
            "consoleReplGetInputLine",
            "consoleResponse",
        ];
        (0, ports_1.checkPortsExist)(app, portNames);
        const ports = app.ports;
        ports.consoleWrite.subscribe(this.write);
        ports.consoleGetLine.subscribe(this.getLine);
        ports.consoleReplGetInputLine.subscribe(this.replGetInputLine);
    }
    sendResponse(response) {
        const ports = this.app.ports;
        ports.consoleResponse.send(response);
    }
    getReadlineInterface() {
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
    close() {
        if (this.rl) {
            this.rl.close();
            this.rl = null;
        }
    }
}
exports.ConsolePorts = ConsolePorts;
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiY29uc29sZS5qcyIsInNvdXJjZVJvb3QiOiIiLCJzb3VyY2VzIjpbIi4uL2pzL2NvbnNvbGUudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IjtBQUFBOzs7R0FHRzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBRUgsbURBQXFDO0FBQ3JDLG1DQU9pQjtBQWdDakIsOENBQThDO0FBQzlDLE1BQU0sYUFBYSxHQUFrQjtJQUNqQyxNQUFNLEVBQUUsT0FBTyxDQUFDLE1BQU07SUFDdEIsTUFBTSxFQUFFLE9BQU8sQ0FBQyxNQUFNO0lBQ3RCLEtBQUssRUFBRSxPQUFPLENBQUMsS0FBSztDQUN2QixDQUFDO0FBRUY7OztHQUdHO0FBQ0gsTUFBYSxZQUFZO0lBS3JCLFlBQVksR0FBVyxFQUFFLFNBQXdCLGFBQWE7UUFGdEQsT0FBRSxHQUE4QixJQUFJLENBQUM7UUFvRDdDLHNDQUFzQztRQUV0QyxVQUFLLEdBQUcsQ0FBQyxJQUFlLEVBQVEsRUFBRTtZQUM5QixJQUFJLENBQUM7Z0JBQ0QsSUFBSSxJQUFJLENBQUMsRUFBRSxLQUFLLENBQUMsRUFBRSxDQUFDO29CQUNoQixJQUFJLENBQUMsTUFBTSxDQUFDLE1BQU0sQ0FBQyxLQUFLLENBQUMsSUFBSSxDQUFDLE9BQU8sQ0FBQyxDQUFDO2dCQUMzQyxDQUFDO3FCQUFNLElBQUksSUFBSSxDQUFDLEVBQUUsS0FBSyxDQUFDLEVBQUUsQ0FBQztvQkFDdkIsSUFBSSxDQUFDLE1BQU0sQ0FBQyxNQUFNLENBQUMsS0FBSyxDQUFDLElBQUksQ0FBQyxPQUFPLENBQUMsQ0FBQztnQkFDM0MsQ0FBQztxQkFBTSxDQUFDO29CQUNKLGdEQUFnRDtvQkFDaEQseURBQXlEO29CQUN6RCxJQUFJLENBQUMsTUFBTSxDQUFDLE1BQU0sQ0FBQyxLQUFLLENBQUMsSUFBSSxDQUFDLE9BQU8sQ0FBQyxDQUFDO2dCQUMzQyxDQUFDO2dCQUNELG9DQUFvQztZQUN4QyxDQUFDO1lBQUMsT0FBTyxLQUFLLEVBQUUsQ0FBQztnQkFDYixzREFBc0Q7Z0JBQ3RELE9BQU8sQ0FBQyxLQUFLLENBQUMsc0JBQXNCLEVBQUUsS0FBSyxDQUFDLENBQUM7WUFDakQsQ0FBQztRQUNMLENBQUMsQ0FBQztRQUVGLHVDQUF1QztRQUV2QyxZQUFPLEdBQUcsQ0FBQyxJQUFnQixFQUFRLEVBQUU7WUFDakMsSUFBSSxDQUFDO2dCQUNELE1BQU0sRUFBRSxHQUFHLElBQUksQ0FBQyxvQkFBb0IsRUFBRSxDQUFDO2dCQUV2QyxFQUFFLENBQUMsUUFBUSxDQUFDLEVBQUUsRUFBRSxDQUFDLE1BQU0sRUFBRSxFQUFFO29CQUN2QixJQUFJLENBQUMsWUFBWSxDQUFDO3dCQUNkLEVBQUUsRUFBRSxJQUFJLENBQUMsRUFBRTt3QkFDWCxLQUFLLEVBQUUsU0FBUzt3QkFDaEIsT0FBTyxFQUFFLE1BQU07cUJBQ2xCLENBQUMsQ0FBQztnQkFDUCxDQUFDLENBQUMsQ0FBQztnQkFFSCxhQUFhO2dCQUNiLEVBQUUsQ0FBQyxJQUFJLENBQUMsT0FBTyxFQUFFLEdBQUcsRUFBRTtvQkFDbEIsSUFBSSxDQUFDLFlBQVksQ0FBQzt3QkFDZCxFQUFFLEVBQUUsSUFBSSxDQUFDLEVBQUU7d0JBQ1gsS0FBSyxFQUFFLFlBQVk7d0JBQ25CLE9BQU8sRUFBRSxJQUFJO3FCQUNoQixDQUFDLENBQUM7Z0JBQ1AsQ0FBQyxDQUFDLENBQUM7WUFDUCxDQUFDO1lBQUMsT0FBTyxLQUFLLEVBQUUsQ0FBQztnQkFDYixJQUFJLENBQUMsWUFBWSxDQUFDLElBQUEsMEJBQWtCLEVBQUMsSUFBSSxDQUFDLEVBQUUsRUFBRSxLQUFLLENBQUMsQ0FBQyxDQUFDO1lBQzFELENBQUM7UUFDTCxDQUFDLENBQUM7UUFFRixxQkFBZ0IsR0FBRyxDQUFDLElBQW1CLEVBQVEsRUFBRTtZQUM3QyxJQUFJLENBQUM7Z0JBQ0QsTUFBTSxFQUFFLEdBQUcsSUFBSSxDQUFDLG9CQUFvQixFQUFFLENBQUM7Z0JBRXZDLEVBQUUsQ0FBQyxRQUFRLENBQUMsSUFBSSxDQUFDLE1BQU0sRUFBRSxDQUFDLE1BQU0sRUFBRSxFQUFFO29CQUNoQyxJQUFJLENBQUMsWUFBWSxDQUFDO3dCQUNkLEVBQUUsRUFBRSxJQUFJLENBQUMsRUFBRTt3QkFDWCxLQUFLLEVBQUUsU0FBUzt3QkFDaEIsT0FBTyxFQUFFLE1BQU07cUJBQ2xCLENBQUMsQ0FBQztnQkFDUCxDQUFDLENBQUMsQ0FBQztnQkFFSCxzQkFBc0I7Z0JBQ3RCLEVBQUUsQ0FBQyxJQUFJLENBQUMsT0FBTyxFQUFFLEdBQUcsRUFBRTtvQkFDbEIsSUFBSSxDQUFDLFlBQVksQ0FBQzt3QkFDZCxFQUFFLEVBQUUsSUFBSSxDQUFDLEVBQUU7d0JBQ1gsS0FBSyxFQUFFLFlBQVk7d0JBQ25CLE9BQU8sRUFBRSxJQUFJO3FCQUNoQixDQUFDLENBQUM7Z0JBQ1AsQ0FBQyxDQUFDLENBQUM7WUFDUCxDQUFDO1lBQUMsT0FBTyxLQUFLLEVBQUUsQ0FBQztnQkFDYixJQUFJLENBQUMsWUFBWSxDQUFDLElBQUEsMEJBQWtCLEVBQUMsSUFBSSxDQUFDLEVBQUUsRUFBRSxLQUFLLENBQUMsQ0FBQyxDQUFDO1lBQzFELENBQUM7UUFDTCxDQUFDLENBQUM7UUF2SEUsSUFBSSxDQUFDLEdBQUcsR0FBRyxHQUE0QyxDQUFDO1FBQ3hELElBQUksQ0FBQyxNQUFNLEdBQUcsTUFBTSxDQUFDO1FBRXJCLE1BQU0sU0FBUyxHQUFHO1lBQ2QsY0FBYztZQUNkLGdCQUFnQjtZQUNoQix5QkFBeUI7WUFDekIsaUJBQWlCO1NBQ3BCLENBQUM7UUFFRixJQUFBLHVCQUFlLEVBQUMsR0FBRyxFQUFFLFNBQVMsQ0FBQyxDQUFDO1FBRWhDLE1BQU0sS0FBSyxHQUFHLEdBQUcsQ0FBQyxLQUFtQyxDQUFDO1FBQ3RELEtBQUssQ0FBQyxZQUFZLENBQUMsU0FBUyxDQUFDLElBQUksQ0FBQyxLQUFLLENBQUMsQ0FBQztRQUN6QyxLQUFLLENBQUMsY0FBYyxDQUFDLFNBQVMsQ0FBQyxJQUFJLENBQUMsT0FBTyxDQUFDLENBQUM7UUFDN0MsS0FBSyxDQUFDLHVCQUF1QixDQUFDLFNBQVMsQ0FBQyxJQUFJLENBQUMsZ0JBQWdCLENBQUMsQ0FBQztJQUNuRSxDQUFDO0lBRU8sWUFBWSxDQUFDLFFBQWtCO1FBQ25DLE1BQU0sS0FBSyxHQUFHLElBQUksQ0FBQyxHQUFHLENBQUMsS0FBbUMsQ0FBQztRQUMzRCxLQUFLLENBQUMsZUFBZSxDQUFDLElBQUksQ0FBQyxRQUFRLENBQUMsQ0FBQztJQUN6QyxDQUFDO0lBRU8sb0JBQW9CO1FBQ3hCLElBQUksQ0FBQyxJQUFJLENBQUMsRUFBRSxFQUFFLENBQUM7WUFDWCxJQUFJLENBQUMsRUFBRSxHQUFHLFFBQVEsQ0FBQyxlQUFlLENBQUM7Z0JBQy9CLEtBQUssRUFBRSxJQUFJLENBQUMsTUFBTSxDQUFDLEtBQUs7Z0JBQ3hCLE1BQU0sRUFBRSxJQUFJLENBQUMsTUFBTSxDQUFDLE1BQU07Z0JBQzFCLFFBQVEsRUFBRSxJQUFJLENBQUMsTUFBTSxDQUFDLEtBQUssQ0FBQyxLQUFLLElBQUksS0FBSzthQUM3QyxDQUFDLENBQUM7WUFFSCxJQUFJLENBQUMsRUFBRSxDQUFDLEVBQUUsQ0FBQyxPQUFPLEVBQUUsR0FBRyxFQUFFO2dCQUNyQixJQUFJLENBQUMsRUFBRSxHQUFHLElBQUksQ0FBQztZQUNuQixDQUFDLENBQUMsQ0FBQztRQUNQLENBQUM7UUFDRCxPQUFPLElBQUksQ0FBQyxFQUFFLENBQUM7SUFDbkIsQ0FBQztJQUVEOzs7T0FHRztJQUNILEtBQUs7UUFDRCxJQUFJLElBQUksQ0FBQyxFQUFFLEVBQUUsQ0FBQztZQUNWLElBQUksQ0FBQyxFQUFFLENBQUMsS0FBSyxFQUFFLENBQUM7WUFDaEIsSUFBSSxDQUFDLEVBQUUsR0FBRyxJQUFJLENBQUM7UUFDbkIsQ0FBQztJQUNMLENBQUM7Q0F5RUo7QUE5SEQsb0NBOEhDIiwic291cmNlc0NvbnRlbnQiOlsiLyoqXG4gKiBDb25zb2xlIHBvcnQgaGFuZGxlcnMgZm9yIEd1aWRhIElPIGxpYnJhcnkuXG4gKiBJbXBsZW1lbnRzIHRlcm1pbmFsL2NvbnNvbGUgSU8gb3BlcmF0aW9ucy5cbiAqL1xuXG5pbXBvcnQgKiBhcyByZWFkbGluZSBmcm9tIFwicmVhZGxpbmVcIjtcbmltcG9ydCB7XG4gICAgY2hlY2tQb3J0c0V4aXN0LFxuICAgIEVsbUFwcCxcbiAgICBPdXRnb2luZ1BvcnQsXG4gICAgSW5jb21pbmdQb3J0LFxuICAgIFJlc3BvbnNlLFxuICAgIGVycm9yRnJvbUV4Y2VwdGlvbixcbn0gZnJvbSBcIi4vcG9ydHNcIjtcblxuLy8gUmVxdWVzdCB0eXBlc1xuaW50ZXJmYWNlIFdyaXRlQXJncyB7XG4gICAgZmQ6IG51bWJlcjtcbiAgICBjb250ZW50OiBzdHJpbmc7XG59XG5cbmludGVyZmFjZSBJZE9ubHlBcmdzIHtcbiAgICBpZDogc3RyaW5nO1xufVxuXG5pbnRlcmZhY2UgUmVwbElucHV0QXJncyB7XG4gICAgaWQ6IHN0cmluZztcbiAgICBwcm9tcHQ6IHN0cmluZztcbn1cblxuLy8gUG9ydCB0eXBlc1xuaW50ZXJmYWNlIENvbnNvbGVFbG1Qb3J0cyB7XG4gICAgY29uc29sZVdyaXRlOiBPdXRnb2luZ1BvcnQ8V3JpdGVBcmdzPjtcbiAgICBjb25zb2xlR2V0TGluZTogT3V0Z29pbmdQb3J0PElkT25seUFyZ3M+O1xuICAgIGNvbnNvbGVSZXBsR2V0SW5wdXRMaW5lOiBPdXRnb2luZ1BvcnQ8UmVwbElucHV0QXJncz47XG4gICAgY29uc29sZVJlc3BvbnNlOiBJbmNvbWluZ1BvcnQ8UmVzcG9uc2U+O1xufVxuXG4vLyBDb25maWd1cmF0aW9uIGludGVyZmFjZSBmb3IgZGVwZW5kZW5jeSBpbmplY3Rpb25cbmV4cG9ydCBpbnRlcmZhY2UgQ29uc29sZUNvbmZpZyB7XG4gICAgc3Rkb3V0OiBOb2RlSlMuV3JpdGVTdHJlYW07XG4gICAgc3RkZXJyOiBOb2RlSlMuV3JpdGVTdHJlYW07XG4gICAgc3RkaW46IE5vZGVKUy5SZWFkU3RyZWFtO1xufVxuXG4vLyBEZWZhdWx0IGNvbmZpZ3VyYXRpb24gdXNpbmcgcHJvY2VzcyBzdHJlYW1zXG5jb25zdCBkZWZhdWx0Q29uZmlnOiBDb25zb2xlQ29uZmlnID0ge1xuICAgIHN0ZG91dDogcHJvY2Vzcy5zdGRvdXQsXG4gICAgc3RkZXJyOiBwcm9jZXNzLnN0ZGVycixcbiAgICBzdGRpbjogcHJvY2Vzcy5zdGRpbixcbn07XG5cbi8qKlxuICogQ29uc29sZSBwb3J0IGhhbmRsZXIgY2xhc3MuXG4gKiBNYW5hZ2VzIHRlcm1pbmFsL2NvbnNvbGUgSU8gdGhyb3VnaCBFbG0gcG9ydHMuXG4gKi9cbmV4cG9ydCBjbGFzcyBDb25zb2xlUG9ydHMge1xuICAgIHByaXZhdGUgYXBwOiB7IHBvcnRzOiBDb25zb2xlRWxtUG9ydHMgfTtcbiAgICBwcml2YXRlIGNvbmZpZzogQ29uc29sZUNvbmZpZztcbiAgICBwcml2YXRlIHJsOiByZWFkbGluZS5JbnRlcmZhY2UgfCBudWxsID0gbnVsbDtcblxuICAgIGNvbnN0cnVjdG9yKGFwcDogRWxtQXBwLCBjb25maWc6IENvbnNvbGVDb25maWcgPSBkZWZhdWx0Q29uZmlnKSB7XG4gICAgICAgIHRoaXMuYXBwID0gYXBwIGFzIHVua25vd24gYXMgeyBwb3J0czogQ29uc29sZUVsbVBvcnRzIH07XG4gICAgICAgIHRoaXMuY29uZmlnID0gY29uZmlnO1xuXG4gICAgICAgIGNvbnN0IHBvcnROYW1lcyA9IFtcbiAgICAgICAgICAgIFwiY29uc29sZVdyaXRlXCIsXG4gICAgICAgICAgICBcImNvbnNvbGVHZXRMaW5lXCIsXG4gICAgICAgICAgICBcImNvbnNvbGVSZXBsR2V0SW5wdXRMaW5lXCIsXG4gICAgICAgICAgICBcImNvbnNvbGVSZXNwb25zZVwiLFxuICAgICAgICBdO1xuXG4gICAgICAgIGNoZWNrUG9ydHNFeGlzdChhcHAsIHBvcnROYW1lcyk7XG5cbiAgICAgICAgY29uc3QgcG9ydHMgPSBhcHAucG9ydHMgYXMgdW5rbm93biBhcyBDb25zb2xlRWxtUG9ydHM7XG4gICAgICAgIHBvcnRzLmNvbnNvbGVXcml0ZS5zdWJzY3JpYmUodGhpcy53cml0ZSk7XG4gICAgICAgIHBvcnRzLmNvbnNvbGVHZXRMaW5lLnN1YnNjcmliZSh0aGlzLmdldExpbmUpO1xuICAgICAgICBwb3J0cy5jb25zb2xlUmVwbEdldElucHV0TGluZS5zdWJzY3JpYmUodGhpcy5yZXBsR2V0SW5wdXRMaW5lKTtcbiAgICB9XG5cbiAgICBwcml2YXRlIHNlbmRSZXNwb25zZShyZXNwb25zZTogUmVzcG9uc2UpOiB2b2lkIHtcbiAgICAgICAgY29uc3QgcG9ydHMgPSB0aGlzLmFwcC5wb3J0cyBhcyB1bmtub3duIGFzIENvbnNvbGVFbG1Qb3J0cztcbiAgICAgICAgcG9ydHMuY29uc29sZVJlc3BvbnNlLnNlbmQocmVzcG9uc2UpO1xuICAgIH1cblxuICAgIHByaXZhdGUgZ2V0UmVhZGxpbmVJbnRlcmZhY2UoKTogcmVhZGxpbmUuSW50ZXJmYWNlIHtcbiAgICAgICAgaWYgKCF0aGlzLnJsKSB7XG4gICAgICAgICAgICB0aGlzLnJsID0gcmVhZGxpbmUuY3JlYXRlSW50ZXJmYWNlKHtcbiAgICAgICAgICAgICAgICBpbnB1dDogdGhpcy5jb25maWcuc3RkaW4sXG4gICAgICAgICAgICAgICAgb3V0cHV0OiB0aGlzLmNvbmZpZy5zdGRvdXQsXG4gICAgICAgICAgICAgICAgdGVybWluYWw6IHRoaXMuY29uZmlnLnN0ZGluLmlzVFRZID8/IGZhbHNlLFxuICAgICAgICAgICAgfSk7XG5cbiAgICAgICAgICAgIHRoaXMucmwub24oXCJjbG9zZVwiLCAoKSA9PiB7XG4gICAgICAgICAgICAgICAgdGhpcy5ybCA9IG51bGw7XG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfVxuICAgICAgICByZXR1cm4gdGhpcy5ybDtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDbG9zZSB0aGUgcmVhZGxpbmUgaW50ZXJmYWNlIHdoZW4gZG9uZS5cbiAgICAgKiBTaG91bGQgYmUgY2FsbGVkIHdoZW4gdGhlIGFwcGxpY2F0aW9uIGlzIHNodXR0aW5nIGRvd24uXG4gICAgICovXG4gICAgY2xvc2UoKTogdm9pZCB7XG4gICAgICAgIGlmICh0aGlzLnJsKSB7XG4gICAgICAgICAgICB0aGlzLnJsLmNsb3NlKCk7XG4gICAgICAgICAgICB0aGlzLnJsID0gbnVsbDtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8vIE91dHB1dCBvcGVyYXRpb25zIChmaXJlLWFuZC1mb3JnZXQpXG5cbiAgICB3cml0ZSA9IChhcmdzOiBXcml0ZUFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgdHJ5IHtcbiAgICAgICAgICAgIGlmIChhcmdzLmZkID09PSAxKSB7XG4gICAgICAgICAgICAgICAgdGhpcy5jb25maWcuc3Rkb3V0LndyaXRlKGFyZ3MuY29udGVudCk7XG4gICAgICAgICAgICB9IGVsc2UgaWYgKGFyZ3MuZmQgPT09IDIpIHtcbiAgICAgICAgICAgICAgICB0aGlzLmNvbmZpZy5zdGRlcnIud3JpdGUoYXJncy5jb250ZW50KTtcbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgLy8gRm9yIG90aGVyIGZpbGUgZGVzY3JpcHRvcnMsIGRlZmF1bHQgdG8gc3Rkb3V0XG4gICAgICAgICAgICAgICAgLy8gSW4gYSBmdWxsIGltcGxlbWVudGF0aW9uLCB3ZSdkIHRyYWNrIG9wZW4gZmlsZSBoYW5kbGVzXG4gICAgICAgICAgICAgICAgdGhpcy5jb25maWcuc3Rkb3V0LndyaXRlKGFyZ3MuY29udGVudCk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICAvLyBGaXJlLWFuZC1mb3JnZXQ6IG5vIHJlc3BvbnNlIHNlbnRcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIC8vIExvZyBlcnJvciBidXQgZG9uJ3Qgc2VuZCByZXNwb25zZSAoZmlyZS1hbmQtZm9yZ2V0KVxuICAgICAgICAgICAgY29uc29sZS5lcnJvcihcIkNvbnNvbGUgd3JpdGUgZXJyb3I6XCIsIGVycm9yKTtcbiAgICAgICAgfVxuICAgIH07XG5cbiAgICAvLyBJbnB1dCBvcGVyYXRpb25zIChjYWxsLWFuZC1yZXNwb25zZSlcblxuICAgIGdldExpbmUgPSAoYXJnczogSWRPbmx5QXJncyk6IHZvaWQgPT4ge1xuICAgICAgICB0cnkge1xuICAgICAgICAgICAgY29uc3QgcmwgPSB0aGlzLmdldFJlYWRsaW5lSW50ZXJmYWNlKCk7XG5cbiAgICAgICAgICAgIHJsLnF1ZXN0aW9uKFwiXCIsIChhbnN3ZXIpID0+IHtcbiAgICAgICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZSh7XG4gICAgICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgICAgICB0eXBlXzogXCJDb250ZW50XCIsXG4gICAgICAgICAgICAgICAgICAgIHBheWxvYWQ6IGFuc3dlcixcbiAgICAgICAgICAgICAgICB9KTtcbiAgICAgICAgICAgIH0pO1xuXG4gICAgICAgICAgICAvLyBIYW5kbGUgRU9GXG4gICAgICAgICAgICBybC5vbmNlKFwiY2xvc2VcIiwgKCkgPT4ge1xuICAgICAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgICAgIHR5cGVfOiBcIkVuZE9mSW5wdXRcIixcbiAgICAgICAgICAgICAgICAgICAgcGF5bG9hZDogbnVsbCxcbiAgICAgICAgICAgICAgICB9KTtcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9IGNhdGNoIChlcnJvcikge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoZXJyb3JGcm9tRXhjZXB0aW9uKGFyZ3MuaWQsIGVycm9yKSk7XG4gICAgICAgIH1cbiAgICB9O1xuXG4gICAgcmVwbEdldElucHV0TGluZSA9IChhcmdzOiBSZXBsSW5wdXRBcmdzKTogdm9pZCA9PiB7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgICBjb25zdCBybCA9IHRoaXMuZ2V0UmVhZGxpbmVJbnRlcmZhY2UoKTtcblxuICAgICAgICAgICAgcmwucXVlc3Rpb24oYXJncy5wcm9tcHQsIChhbnN3ZXIpID0+IHtcbiAgICAgICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZSh7XG4gICAgICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgICAgICB0eXBlXzogXCJDb250ZW50XCIsXG4gICAgICAgICAgICAgICAgICAgIHBheWxvYWQ6IGFuc3dlcixcbiAgICAgICAgICAgICAgICB9KTtcbiAgICAgICAgICAgIH0pO1xuXG4gICAgICAgICAgICAvLyBIYW5kbGUgRU9GIChDdHJsK0QpXG4gICAgICAgICAgICBybC5vbmNlKFwiY2xvc2VcIiwgKCkgPT4ge1xuICAgICAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgICAgIHR5cGVfOiBcIkVuZE9mSW5wdXRcIixcbiAgICAgICAgICAgICAgICAgICAgcGF5bG9hZDogbnVsbCxcbiAgICAgICAgICAgICAgICB9KTtcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9IGNhdGNoIChlcnJvcikge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoZXJyb3JGcm9tRXhjZXB0aW9uKGFyZ3MuaWQsIGVycm9yKSk7XG4gICAgICAgIH1cbiAgICB9O1xufVxuIl19