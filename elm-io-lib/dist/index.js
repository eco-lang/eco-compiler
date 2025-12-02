"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.errorFromException = exports.errorResponse = exports.okResponse = exports.checkPortsExist = exports.NetworkPortsXHR = exports.NetworkPorts = exports.ConcurrencyPorts = exports.ProcessPorts = exports.ConsolePorts = exports.FileSystemPorts = void 0;
exports.initializeAllPorts = initializeAllPorts;
exports.waitForExit = waitForExit;
// Export individual port handlers
var filesystem_1 = require("./filesystem");
Object.defineProperty(exports, "FileSystemPorts", { enumerable: true, get: function () { return filesystem_1.FileSystemPorts; } });
var console_1 = require("./console");
Object.defineProperty(exports, "ConsolePorts", { enumerable: true, get: function () { return console_1.ConsolePorts; } });
var process_1 = require("./process");
Object.defineProperty(exports, "ProcessPorts", { enumerable: true, get: function () { return process_1.ProcessPorts; } });
var concurrency_1 = require("./concurrency");
Object.defineProperty(exports, "ConcurrencyPorts", { enumerable: true, get: function () { return concurrency_1.ConcurrencyPorts; } });
var network_1 = require("./network");
Object.defineProperty(exports, "NetworkPorts", { enumerable: true, get: function () { return network_1.NetworkPorts; } });
Object.defineProperty(exports, "NetworkPortsXHR", { enumerable: true, get: function () { return network_1.NetworkPortsXHR; } });
// Export utility functions
var ports_1 = require("./ports");
Object.defineProperty(exports, "checkPortsExist", { enumerable: true, get: function () { return ports_1.checkPortsExist; } });
Object.defineProperty(exports, "okResponse", { enumerable: true, get: function () { return ports_1.okResponse; } });
Object.defineProperty(exports, "errorResponse", { enumerable: true, get: function () { return ports_1.errorResponse; } });
Object.defineProperty(exports, "errorFromException", { enumerable: true, get: function () { return ports_1.errorFromException; } });
// Import for initialization function
const filesystem_2 = require("./filesystem");
const console_2 = require("./console");
const process_2 = require("./process");
const concurrency_2 = require("./concurrency");
const network_2 = require("./network");
/**
 * Initialize all port handlers for a Guida IO application.
 *
 * @param app - The initialized Elm application
 * @param config - Optional configuration for handlers
 * @returns Object containing all initialized port handlers
 */
function initializeAllPorts(app, config = {}) {
    const fileSystem = new filesystem_2.FileSystemPorts(app, config.fileSystem);
    const console = new console_2.ConsolePorts(app, config.console);
    const processHandler = new process_2.ProcessPorts(app, config.args, config.process);
    const concurrency = new concurrency_2.ConcurrencyPorts(app);
    const network = new network_2.NetworkPorts(app, config.network);
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
function waitForExit(processHandler) {
    return new Promise((resolve) => {
        processHandler.setExitCallback(resolve);
    });
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiaW5kZXguanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyIuLi9qcy9pbmRleC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiO0FBQUE7Ozs7Ozs7Ozs7Ozs7Ozs7R0FnQkc7OztBQTRESCxnREFxQkM7QUFTRCxrQ0FJQztBQTVGRCxrQ0FBa0M7QUFDbEMsMkNBQWlFO0FBQXhELDZHQUFBLGVBQWUsT0FBQTtBQUN4QixxQ0FBd0Q7QUFBL0MsdUdBQUEsWUFBWSxPQUFBO0FBQ3JCLHFDQUFzRTtBQUE3RCx1R0FBQSxZQUFZLE9BQUE7QUFDckIsNkNBQWlEO0FBQXhDLCtHQUFBLGdCQUFnQixPQUFBO0FBQ3pCLHFDQUF5RTtBQUFoRSx1R0FBQSxZQUFZLE9BQUE7QUFBRSwwR0FBQSxlQUFlLE9BQUE7QUFFdEMsMkJBQTJCO0FBQzNCLGlDQVVpQjtBQVRiLHdHQUFBLGVBQWUsT0FBQTtBQU1mLG1HQUFBLFVBQVUsT0FBQTtBQUNWLHNHQUFBLGFBQWEsT0FBQTtBQUNiLDJHQUFBLGtCQUFrQixPQUFBO0FBR3RCLHFDQUFxQztBQUNyQyw2Q0FBaUU7QUFDakUsdUNBQXdEO0FBQ3hELHVDQUFzRTtBQUN0RSwrQ0FBaUQ7QUFDakQsdUNBQXdEO0FBMEJ4RDs7Ozs7O0dBTUc7QUFDSCxTQUFnQixrQkFBa0IsQ0FDOUIsR0FBVyxFQUNYLFNBQXlCLEVBQUU7SUFFM0IsTUFBTSxVQUFVLEdBQUcsSUFBSSw0QkFBZSxDQUFDLEdBQUcsRUFBRSxNQUFNLENBQUMsVUFBVSxDQUFDLENBQUM7SUFDL0QsTUFBTSxPQUFPLEdBQUcsSUFBSSxzQkFBWSxDQUFDLEdBQUcsRUFBRSxNQUFNLENBQUMsT0FBTyxDQUFDLENBQUM7SUFDdEQsTUFBTSxjQUFjLEdBQUcsSUFBSSxzQkFBWSxDQUFDLEdBQUcsRUFBRSxNQUFNLENBQUMsSUFBSSxFQUFFLE1BQU0sQ0FBQyxPQUFPLENBQUMsQ0FBQztJQUMxRSxNQUFNLFdBQVcsR0FBRyxJQUFJLDhCQUFnQixDQUFDLEdBQUcsQ0FBQyxDQUFDO0lBQzlDLE1BQU0sT0FBTyxHQUFHLElBQUksc0JBQVksQ0FBQyxHQUFHLEVBQUUsTUFBTSxDQUFDLE9BQU8sQ0FBQyxDQUFDO0lBRXRELElBQUksTUFBTSxDQUFDLE1BQU0sRUFBRSxDQUFDO1FBQ2hCLGNBQWMsQ0FBQyxlQUFlLENBQUMsTUFBTSxDQUFDLE1BQU0sQ0FBQyxDQUFDO0lBQ2xELENBQUM7SUFFRCxPQUFPO1FBQ0gsVUFBVTtRQUNWLE9BQU87UUFDUCxPQUFPLEVBQUUsY0FBYztRQUN2QixXQUFXO1FBQ1gsT0FBTztLQUNWLENBQUM7QUFDTixDQUFDO0FBRUQ7Ozs7OztHQU1HO0FBQ0gsU0FBZ0IsV0FBVyxDQUFDLGNBQTRCO0lBQ3BELE9BQU8sSUFBSSxPQUFPLENBQUMsQ0FBQyxPQUFPLEVBQUUsRUFBRTtRQUMzQixjQUFjLENBQUMsZUFBZSxDQUFDLE9BQU8sQ0FBQyxDQUFDO0lBQzVDLENBQUMsQ0FBQyxDQUFDO0FBQ1AsQ0FBQyIsInNvdXJjZXNDb250ZW50IjpbIi8qKlxuICogR3VpZGEgSU8gTGlicmFyeSAtIFR5cGVTY3JpcHQgcG9ydCBoYW5kbGVyc1xuICpcbiAqIFRoaXMgbW9kdWxlIGV4cG9ydHMgYWxsIHBvcnQgaGFuZGxlciBjbGFzc2VzIGZvciB1c2Ugd2l0aCBFbG0gYXBwbGljYXRpb25zLlxuICpcbiAqIFVzYWdlOlxuICogYGBgdHlwZXNjcmlwdFxuICogaW1wb3J0IHsgaW5pdGlhbGl6ZUFsbFBvcnRzLCBGaWxlU3lzdGVtUG9ydHMsIENvbnNvbGVQb3J0cyB9IGZyb20gJ0BndWlkYS9lbG0taW8nO1xuICpcbiAqIC8vIEluaXRpYWxpemUgYWxsIHBvcnRzIGF0IG9uY2VcbiAqIGNvbnN0IGhhbmRsZXJzID0gaW5pdGlhbGl6ZUFsbFBvcnRzKGFwcCk7XG4gKlxuICogLy8gT3IgaW5pdGlhbGl6ZSBpbmRpdmlkdWFsIGhhbmRsZXJzXG4gKiBjb25zdCBmc1BvcnRzID0gbmV3IEZpbGVTeXN0ZW1Qb3J0cyhhcHApO1xuICogY29uc3QgY29uc29sZVBvcnRzID0gbmV3IENvbnNvbGVQb3J0cyhhcHApO1xuICogYGBgXG4gKi9cblxuLy8gRXhwb3J0IGluZGl2aWR1YWwgcG9ydCBoYW5kbGVyc1xuZXhwb3J0IHsgRmlsZVN5c3RlbVBvcnRzLCBGaWxlU3lzdGVtQ29uZmlnIH0gZnJvbSBcIi4vZmlsZXN5c3RlbVwiO1xuZXhwb3J0IHsgQ29uc29sZVBvcnRzLCBDb25zb2xlQ29uZmlnIH0gZnJvbSBcIi4vY29uc29sZVwiO1xuZXhwb3J0IHsgUHJvY2Vzc1BvcnRzLCBQcm9jZXNzQ29uZmlnLCBFeGl0Q2FsbGJhY2sgfSBmcm9tIFwiLi9wcm9jZXNzXCI7XG5leHBvcnQgeyBDb25jdXJyZW5jeVBvcnRzIH0gZnJvbSBcIi4vY29uY3VycmVuY3lcIjtcbmV4cG9ydCB7IE5ldHdvcmtQb3J0cywgTmV0d29ya1BvcnRzWEhSLCBOZXR3b3JrQ29uZmlnIH0gZnJvbSBcIi4vbmV0d29ya1wiO1xuXG4vLyBFeHBvcnQgdXRpbGl0eSBmdW5jdGlvbnNcbmV4cG9ydCB7XG4gICAgY2hlY2tQb3J0c0V4aXN0LFxuICAgIEVsbUFwcCxcbiAgICBPdXRnb2luZ1BvcnQsXG4gICAgSW5jb21pbmdQb3J0LFxuICAgIFJlc3BvbnNlLFxuICAgIEVycm9yUGF5bG9hZCxcbiAgICBva1Jlc3BvbnNlLFxuICAgIGVycm9yUmVzcG9uc2UsXG4gICAgZXJyb3JGcm9tRXhjZXB0aW9uLFxufSBmcm9tIFwiLi9wb3J0c1wiO1xuXG4vLyBJbXBvcnQgZm9yIGluaXRpYWxpemF0aW9uIGZ1bmN0aW9uXG5pbXBvcnQgeyBGaWxlU3lzdGVtUG9ydHMsIEZpbGVTeXN0ZW1Db25maWcgfSBmcm9tIFwiLi9maWxlc3lzdGVtXCI7XG5pbXBvcnQgeyBDb25zb2xlUG9ydHMsIENvbnNvbGVDb25maWcgfSBmcm9tIFwiLi9jb25zb2xlXCI7XG5pbXBvcnQgeyBQcm9jZXNzUG9ydHMsIFByb2Nlc3NDb25maWcsIEV4aXRDYWxsYmFjayB9IGZyb20gXCIuL3Byb2Nlc3NcIjtcbmltcG9ydCB7IENvbmN1cnJlbmN5UG9ydHMgfSBmcm9tIFwiLi9jb25jdXJyZW5jeVwiO1xuaW1wb3J0IHsgTmV0d29ya1BvcnRzLCBOZXR3b3JrQ29uZmlnIH0gZnJvbSBcIi4vbmV0d29ya1wiO1xuaW1wb3J0IHsgRWxtQXBwIH0gZnJvbSBcIi4vcG9ydHNcIjtcblxuLyoqXG4gKiBDb25maWd1cmF0aW9uIGZvciBpbml0aWFsaXppbmcgYWxsIHBvcnQgaGFuZGxlcnMuXG4gKi9cbmV4cG9ydCBpbnRlcmZhY2UgQWxsUG9ydHNDb25maWcge1xuICAgIGZpbGVTeXN0ZW0/OiBGaWxlU3lzdGVtQ29uZmlnO1xuICAgIGNvbnNvbGU/OiBDb25zb2xlQ29uZmlnO1xuICAgIHByb2Nlc3M/OiBQcm9jZXNzQ29uZmlnO1xuICAgIG5ldHdvcms/OiBOZXR3b3JrQ29uZmlnO1xuICAgIGFyZ3M/OiBzdHJpbmdbXTtcbiAgICBvbkV4aXQ/OiBFeGl0Q2FsbGJhY2s7XG59XG5cbi8qKlxuICogQWxsIGluaXRpYWxpemVkIHBvcnQgaGFuZGxlcnMuXG4gKi9cbmV4cG9ydCBpbnRlcmZhY2UgQWxsUG9ydEhhbmRsZXJzIHtcbiAgICBmaWxlU3lzdGVtOiBGaWxlU3lzdGVtUG9ydHM7XG4gICAgY29uc29sZTogQ29uc29sZVBvcnRzO1xuICAgIHByb2Nlc3M6IFByb2Nlc3NQb3J0cztcbiAgICBjb25jdXJyZW5jeTogQ29uY3VycmVuY3lQb3J0cztcbiAgICBuZXR3b3JrOiBOZXR3b3JrUG9ydHM7XG59XG5cbi8qKlxuICogSW5pdGlhbGl6ZSBhbGwgcG9ydCBoYW5kbGVycyBmb3IgYSBHdWlkYSBJTyBhcHBsaWNhdGlvbi5cbiAqXG4gKiBAcGFyYW0gYXBwIC0gVGhlIGluaXRpYWxpemVkIEVsbSBhcHBsaWNhdGlvblxuICogQHBhcmFtIGNvbmZpZyAtIE9wdGlvbmFsIGNvbmZpZ3VyYXRpb24gZm9yIGhhbmRsZXJzXG4gKiBAcmV0dXJucyBPYmplY3QgY29udGFpbmluZyBhbGwgaW5pdGlhbGl6ZWQgcG9ydCBoYW5kbGVyc1xuICovXG5leHBvcnQgZnVuY3Rpb24gaW5pdGlhbGl6ZUFsbFBvcnRzKFxuICAgIGFwcDogRWxtQXBwLFxuICAgIGNvbmZpZzogQWxsUG9ydHNDb25maWcgPSB7fVxuKTogQWxsUG9ydEhhbmRsZXJzIHtcbiAgICBjb25zdCBmaWxlU3lzdGVtID0gbmV3IEZpbGVTeXN0ZW1Qb3J0cyhhcHAsIGNvbmZpZy5maWxlU3lzdGVtKTtcbiAgICBjb25zdCBjb25zb2xlID0gbmV3IENvbnNvbGVQb3J0cyhhcHAsIGNvbmZpZy5jb25zb2xlKTtcbiAgICBjb25zdCBwcm9jZXNzSGFuZGxlciA9IG5ldyBQcm9jZXNzUG9ydHMoYXBwLCBjb25maWcuYXJncywgY29uZmlnLnByb2Nlc3MpO1xuICAgIGNvbnN0IGNvbmN1cnJlbmN5ID0gbmV3IENvbmN1cnJlbmN5UG9ydHMoYXBwKTtcbiAgICBjb25zdCBuZXR3b3JrID0gbmV3IE5ldHdvcmtQb3J0cyhhcHAsIGNvbmZpZy5uZXR3b3JrKTtcblxuICAgIGlmIChjb25maWcub25FeGl0KSB7XG4gICAgICAgIHByb2Nlc3NIYW5kbGVyLnNldEV4aXRDYWxsYmFjayhjb25maWcub25FeGl0KTtcbiAgICB9XG5cbiAgICByZXR1cm4ge1xuICAgICAgICBmaWxlU3lzdGVtLFxuICAgICAgICBjb25zb2xlLFxuICAgICAgICBwcm9jZXNzOiBwcm9jZXNzSGFuZGxlcixcbiAgICAgICAgY29uY3VycmVuY3ksXG4gICAgICAgIG5ldHdvcmssXG4gICAgfTtcbn1cblxuLyoqXG4gKiBIZWxwZXIgZnVuY3Rpb24gdG8gY3JlYXRlIGEgcHJvbWlzZSB0aGF0IHJlc29sdmVzIHdoZW4gdGhlIEVsbSBhcHAgZXhpdHMuXG4gKiBVc2VmdWwgZm9yIENMSSBhcHBsaWNhdGlvbnMgdGhhdCBuZWVkIHRvIHdhaXQgZm9yIGNvbXBsZXRpb24uXG4gKlxuICogQHBhcmFtIHByb2Nlc3NIYW5kbGVyIC0gVGhlIFByb2Nlc3NQb3J0cyBoYW5kbGVyXG4gKiBAcmV0dXJucyBQcm9taXNlIHRoYXQgcmVzb2x2ZXMgd2l0aCB0aGUgZXhpdCByZXNwb25zZVxuICovXG5leHBvcnQgZnVuY3Rpb24gd2FpdEZvckV4aXQocHJvY2Vzc0hhbmRsZXI6IFByb2Nlc3NQb3J0cyk6IFByb21pc2U8dW5rbm93bj4ge1xuICAgIHJldHVybiBuZXcgUHJvbWlzZSgocmVzb2x2ZSkgPT4ge1xuICAgICAgICBwcm9jZXNzSGFuZGxlci5zZXRFeGl0Q2FsbGJhY2socmVzb2x2ZSk7XG4gICAgfSk7XG59XG4iXX0=