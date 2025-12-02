"use strict";
/**
 * Network port handlers for Guida IO library.
 * Implements archive fetching with ZIP extraction and SHA-1 hashing.
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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.NetworkPortsXHR = exports.NetworkPorts = void 0;
/// <reference lib="dom" />
const crypto = __importStar(require("crypto"));
const ports_1 = require("./ports");
// We need JSZip for ZIP extraction
// This will be provided via package.json dependency
const jszip_1 = __importDefault(require("jszip"));
// Default configuration using global fetch
const defaultConfig = {
    fetch: globalThis.fetch,
};
/**
 * Network port handler class.
 * Manages archive fetching through Elm ports.
 */
class NetworkPorts {
    constructor(app, config = defaultConfig) {
        /**
         * Fetch a ZIP archive from a URL, extract it, and compute SHA-1 hash.
         */
        this.getArchive = async (args) => {
            try {
                // Fetch the archive
                const response = await this.fetchWithRedirects(args.url);
                if (!response.ok) {
                    this.sendResponse({
                        id: args.id,
                        type_: "HttpError",
                        payload: {
                            statusCode: response.status,
                            message: response.statusText,
                        },
                    });
                    return;
                }
                // Get the response as ArrayBuffer
                const arrayBuffer = await response.arrayBuffer();
                // Compute SHA-1 hash
                const hashBuffer = crypto
                    .createHash("sha1")
                    .update(Buffer.from(arrayBuffer))
                    .digest();
                const sha = hashBuffer.toString("hex");
                // Extract ZIP contents
                const zip = await jszip_1.default.loadAsync(arrayBuffer);
                const entries = [];
                // Process each file in the archive
                const filePromises = [];
                zip.forEach((relativePath, file) => {
                    if (!file.dir) {
                        const promise = file.async("string").then((data) => {
                            entries.push({
                                relativePath,
                                data,
                            });
                        });
                        filePromises.push(promise);
                    }
                });
                await Promise.all(filePromises);
                // Send successful response
                const archiveResponse = {
                    sha,
                    entries,
                };
                this.sendResponse({
                    id: args.id,
                    type_: "Archive",
                    payload: archiveResponse,
                });
            }
            catch (error) {
                if (error instanceof Error) {
                    this.sendResponse((0, ports_1.errorResponse)(args.id, "NETWORK_ERROR", error.message, {
                        name: error.name,
                        stack: error.stack,
                    }));
                }
                else {
                    this.sendResponse((0, ports_1.errorResponse)(args.id, "UNKNOWN", String(error)));
                }
            }
        };
        this.app = app;
        this.config = config;
        const portNames = ["netGetArchive", "netResponse"];
        (0, ports_1.checkPortsExist)(app, portNames);
        const ports = app.ports;
        ports.netGetArchive.subscribe(this.getArchive);
    }
    sendResponse(response) {
        const ports = this.app.ports;
        ports.netResponse.send(response);
    }
    /**
     * Fetch with automatic redirect following.
     */
    async fetchWithRedirects(url, maxRedirects = 10) {
        let currentUrl = url;
        let redirectCount = 0;
        while (redirectCount < maxRedirects) {
            const response = await this.config.fetch(currentUrl, {
                redirect: "manual",
            });
            // Check for redirect status codes
            if (response.status >= 300 &&
                response.status < 400 &&
                response.headers.has("location")) {
                const location = response.headers.get("location");
                // Handle relative URLs
                currentUrl = new URL(location, currentUrl).toString();
                redirectCount++;
                continue;
            }
            return response;
        }
        throw new Error(`Too many redirects (max ${maxRedirects})`);
    }
}
exports.NetworkPorts = NetworkPorts;
/**
 * Alternative implementation using XMLHttpRequest for environments
 * where fetch is not available or has limitations.
 */
class NetworkPortsXHR {
    constructor(app, XMLHttpRequestCtor) {
        this.getArchive = (args) => {
            this.download("GET", args.url, args.id);
        };
        // Use provided XMLHttpRequest or global one
        const XHR = XMLHttpRequestCtor || (typeof XMLHttpRequest !== "undefined" ? XMLHttpRequest : undefined);
        if (!XHR) {
            throw new Error("XMLHttpRequest is not available");
        }
        this.XMLHttpRequest = XHR;
        this.app = app;
        const portNames = ["netGetArchive", "netResponse"];
        (0, ports_1.checkPortsExist)(app, portNames);
        const ports = app.ports;
        ports.netGetArchive.subscribe(this.getArchive);
    }
    sendResponse(response) {
        const ports = this.app.ports;
        ports.netResponse.send(response);
    }
    download(method, url, id) {
        const xhr = new this.XMLHttpRequest();
        xhr.open(method, url, true);
        xhr.responseType = "arraybuffer";
        xhr.onload = async () => {
            try {
                if (xhr.status >= 200 && xhr.status < 300) {
                    // Compute SHA-1 hash
                    const hashBuffer = crypto
                        .createHash("sha1")
                        .update(Buffer.from(xhr.response))
                        .digest();
                    const sha = hashBuffer.toString("hex");
                    // Extract ZIP contents
                    const zip = await jszip_1.default.loadAsync(xhr.response);
                    const entries = [];
                    const filePromises = [];
                    zip.forEach((relativePath, file) => {
                        if (!file.dir) {
                            const promise = file.async("string").then((data) => {
                                entries.push({
                                    relativePath,
                                    data,
                                });
                            });
                            filePromises.push(promise);
                        }
                    });
                    await Promise.all(filePromises);
                    this.sendResponse({
                        id,
                        type_: "Archive",
                        payload: { sha, entries },
                    });
                }
                else if (xhr.status >= 300 && xhr.status < 400) {
                    // Handle redirect
                    const headers = xhr
                        .getAllResponseHeaders()
                        .trim()
                        .split(/[\r\n]+/)
                        .reduce((acc, line) => {
                        const parts = line.split(": ");
                        const header = parts.shift().toLowerCase();
                        const value = parts.join(": ");
                        acc[header] = value;
                        return acc;
                    }, {});
                    if (headers.location) {
                        this.download(method, headers.location, id);
                    }
                    else {
                        this.sendResponse({
                            id,
                            type_: "HttpError",
                            payload: {
                                statusCode: xhr.status,
                                message: "Redirect without location header",
                            },
                        });
                    }
                }
                else {
                    this.sendResponse({
                        id,
                        type_: "HttpError",
                        payload: {
                            statusCode: xhr.status,
                            message: xhr.statusText,
                        },
                    });
                }
            }
            catch (error) {
                if (error instanceof Error) {
                    this.sendResponse((0, ports_1.errorResponse)(id, "EXTRACT_ERROR", error.message));
                }
                else {
                    this.sendResponse((0, ports_1.errorResponse)(id, "UNKNOWN", String(error)));
                }
            }
        };
        xhr.onerror = () => {
            this.sendResponse((0, ports_1.errorResponse)(id, "NETWORK_ERROR", "Network error during download"));
        };
        xhr.ontimeout = () => {
            this.sendResponse((0, ports_1.errorResponse)(id, "TIMEOUT", "Download timed out"));
        };
        xhr.send();
    }
}
exports.NetworkPortsXHR = NetworkPortsXHR;
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoibmV0d29yay5qcyIsInNvdXJjZVJvb3QiOiIiLCJzb3VyY2VzIjpbIi4uL2pzL25ldHdvcmsudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IjtBQUFBOzs7R0FHRzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBRUgsMkJBQTJCO0FBRTNCLCtDQUFpQztBQUNqQyxtQ0FPaUI7QUFFakIsbUNBQW1DO0FBQ25DLG9EQUFvRDtBQUNwRCxrREFBMEI7QUErQjFCLDJDQUEyQztBQUMzQyxNQUFNLGFBQWEsR0FBa0I7SUFDakMsS0FBSyxFQUFFLFVBQVUsQ0FBQyxLQUFLO0NBQzFCLENBQUM7QUFFRjs7O0dBR0c7QUFDSCxNQUFhLFlBQVk7SUFJckIsWUFBWSxHQUFXLEVBQUUsU0FBd0IsYUFBYTtRQWlCOUQ7O1dBRUc7UUFDSCxlQUFVLEdBQUcsS0FBSyxFQUFFLElBQW9CLEVBQWlCLEVBQUU7WUFDdkQsSUFBSSxDQUFDO2dCQUNELG9CQUFvQjtnQkFDcEIsTUFBTSxRQUFRLEdBQUcsTUFBTSxJQUFJLENBQUMsa0JBQWtCLENBQUMsSUFBSSxDQUFDLEdBQUcsQ0FBQyxDQUFDO2dCQUV6RCxJQUFJLENBQUMsUUFBUSxDQUFDLEVBQUUsRUFBRSxDQUFDO29CQUNmLElBQUksQ0FBQyxZQUFZLENBQUM7d0JBQ2QsRUFBRSxFQUFFLElBQUksQ0FBQyxFQUFFO3dCQUNYLEtBQUssRUFBRSxXQUFXO3dCQUNsQixPQUFPLEVBQUU7NEJBQ0wsVUFBVSxFQUFFLFFBQVEsQ0FBQyxNQUFNOzRCQUMzQixPQUFPLEVBQUUsUUFBUSxDQUFDLFVBQVU7eUJBQy9CO3FCQUNKLENBQUMsQ0FBQztvQkFDSCxPQUFPO2dCQUNYLENBQUM7Z0JBRUQsa0NBQWtDO2dCQUNsQyxNQUFNLFdBQVcsR0FBRyxNQUFNLFFBQVEsQ0FBQyxXQUFXLEVBQUUsQ0FBQztnQkFFakQscUJBQXFCO2dCQUNyQixNQUFNLFVBQVUsR0FBRyxNQUFNO3FCQUNwQixVQUFVLENBQUMsTUFBTSxD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QUFDO2dCQUNQLENBQUM7WUFDTCxDQUFDO1lBQUMsT0FBTyxLQUFLLEVBQUUsQ0FBQztnQkFDYixJQUFJLEtBQUssWUFBWSxLQUFLLEVBQUUsQ0FBQztvQkFDekIsSUFBSSxDQUFDLFlBQVksQ0FDYixJQUFBLHFCQUFhLEVBQUMsRUFBRSxFQUFFLGVBQWUsRUFBRSxLQUFLLENBQUMsT0FBTyxDQUFDLENBQ3BELENBQUM7Z0JBQ04sQ0FBQztxQkFBTSxDQUFDO29CQUNKLElBQUksQ0FBQyxZQUFZLENBQ2IsSUFBQSxxQkFBYSxFQUFDLEVBQUUsRUFBRSxTQUFTLEVBQUUsTUFBTSxDQUFDLEtBQUssQ0FBQyxDQUFDLENBQzlDLENBQUM7Z0JBQ04sQ0FBQztZQUNMLENBQUM7UUFDTCxDQUFDLENBQUM7UUFFRixHQUFHLENBQUMsT0FBTyxHQUFHLEdBQUcsRUFBRTtZQUNmLElBQUksQ0FBQyxZQUFZLENBQ2IsSUFBQSxxQkFBYSxFQUFDLEVBQUUsRUFBRSxlQUFlLEVBQUUsK0JBQStCLENBQUMsQ0FDdEUsQ0FBQztRQUNOLENBQUMsQ0FBQztRQUVGLEdBQUcsQ0FBQyxTQUFTLEdBQUcsR0FBRyxFQUFFO1lBQ2pCLElBQUksQ0FBQyxZQUFZLENBQ2IsSUFBQSxxQkFBYSxFQUFDLEVBQUUsRUFBRSxTQUFTLEVBQUUsb0JBQW9CLENBQUMsQ0FDckQsQ0FBQztRQUNOLENBQUMsQ0FBQztRQUVGLEdBQUcsQ0FBQyxJQUFJLEVBQUUsQ0FBQztJQUNmLENBQUM7Q0FDSjtBQXhJRCwwQ0F3SUMiLCJzb3VyY2VzQ29udGVudCI6WyIvKipcbiAqIE5ldHdvcmsgcG9ydCBoYW5kbGVycyBmb3IgR3VpZGEgSU8gbGlicmFyeS5cbiAqIEltcGxlbWVudHMgYXJjaGl2ZSBmZXRjaGluZyB3aXRoIFpJUCBleHRyYWN0aW9uIGFuZCBTSEEtMSBoYXNoaW5nLlxuICovXG5cbi8vLyA8cmVmZXJlbmNlIGxpYj1cImRvbVwiIC8+XG5cbmltcG9ydCAqIGFzIGNyeXB0byBmcm9tIFwiY3J5cHRvXCI7XG5pbXBvcnQge1xuICAgIGNoZWNrUG9ydHNFeGlzdCxcbiAgICBFbG1BcHAsXG4gICAgT3V0Z29pbmdQb3J0LFxuICAgIEluY29taW5nUG9ydCxcbiAgICBSZXNwb25zZSxcbiAgICBlcnJvclJlc3BvbnNlLFxufSBmcm9tIFwiLi9wb3J0c1wiO1xuXG4vLyBXZSBuZWVkIEpTWmlwIGZvciBaSVAgZXh0cmFjdGlvblxuLy8gVGhpcyB3aWxsIGJlIHByb3ZpZGVkIHZpYSBwYWNrYWdlLmpzb24gZGVwZW5kZW5jeVxuaW1wb3J0IEpTWmlwIGZyb20gXCJqc3ppcFwiO1xuXG4vLyBSZXF1ZXN0IHR5cGVzXG5pbnRlcmZhY2UgR2V0QXJjaGl2ZUFyZ3Mge1xuICAgIGlkOiBzdHJpbmc7XG4gICAgdXJsOiBzdHJpbmc7XG59XG5cbi8vIFBvcnQgdHlwZXNcbmludGVyZmFjZSBOZXR3b3JrRWxtUG9ydHMge1xuICAgIG5ldEdldEFyY2hpdmU6IE91dGdvaW5nUG9ydDxHZXRBcmNoaXZlQXJncz47XG4gICAgbmV0UmVzcG9uc2U6IEluY29taW5nUG9ydDxSZXNwb25zZT47XG59XG5cbi8vIEFyY2hpdmUgZW50cnkgdHlwZVxuaW50ZXJmYWNlIEFyY2hpdmVFbnRyeSB7XG4gICAgcmVsYXRpdmVQYXRoOiBzdHJpbmc7XG4gICAgZGF0YTogc3RyaW5nO1xufVxuXG4vLyBBcmNoaXZlIHJlc3BvbnNlIHR5cGVcbmludGVyZmFjZSBBcmNoaXZlUmVzcG9uc2Uge1xuICAgIHNoYTogc3RyaW5nO1xuICAgIGVudHJpZXM6IEFyY2hpdmVFbnRyeVtdO1xufVxuXG4vLyBDb25maWd1cmF0aW9uIGludGVyZmFjZSBmb3IgZGVwZW5kZW5jeSBpbmplY3Rpb25cbmV4cG9ydCBpbnRlcmZhY2UgTmV0d29ya0NvbmZpZyB7XG4gICAgZmV0Y2g6IHR5cGVvZiBmZXRjaDtcbn1cblxuLy8gRGVmYXVsdCBjb25maWd1cmF0aW9uIHVzaW5nIGdsb2JhbCBmZXRjaFxuY29uc3QgZGVmYXVsdENvbmZpZzogTmV0d29ya0NvbmZpZyA9IHtcbiAgICBmZXRjaDogZ2xvYmFsVGhpcy5mZXRjaCxcbn07XG5cbi8qKlxuICogTmV0d29yayBwb3J0IGhhbmRsZXIgY2xhc3MuXG4gKiBNYW5hZ2VzIGFyY2hpdmUgZmV0Y2hpbmcgdGhyb3VnaCBFbG0gcG9ydHMuXG4gKi9cbmV4cG9ydCBjbGFzcyBOZXR3b3JrUG9ydHMge1xuICAgIHByaXZhdGUgYXBwOiB7IHBvcnRzOiBOZXR3b3JrRWxtUG9ydHMgfTtcbiAgICBwcml2YXRlIGNvbmZpZzogTmV0d29ya0NvbmZpZztcblxuICAgIGNvbnN0cnVjdG9yKGFwcDogRWxtQXBwLCBjb25maWc6IE5ldHdvcmtDb25maWcgPSBkZWZhdWx0Q29uZmlnKSB7XG4gICAgICAgIHRoaXMuYXBwID0gYXBwIGFzIHVua25vd24gYXMgeyBwb3J0czogTmV0d29ya0VsbVBvcnRzIH07XG4gICAgICAgIHRoaXMuY29uZmlnID0gY29uZmlnO1xuXG4gICAgICAgIGNvbnN0IHBvcnROYW1lcyA9IFtcIm5ldEdldEFyY2hpdmVcIiwgXCJuZXRSZXNwb25zZVwiXTtcblxuICAgICAgICBjaGVja1BvcnRzRXhpc3QoYXBwLCBwb3J0TmFtZXMpO1xuXG4gICAgICAgIGNvbnN0IHBvcnRzID0gYXBwLnBvcnRzIGFzIHVua25vd24gYXMgTmV0d29ya0VsbVBvcnRzO1xuICAgICAgICBwb3J0cy5uZXRHZXRBcmNoaXZlLnN1YnNjcmliZSh0aGlzLmdldEFyY2hpdmUpO1xuICAgIH1cblxuICAgIHByaXZhdGUgc2VuZFJlc3BvbnNlKHJlc3BvbnNlOiBSZXNwb25zZSk6IHZvaWQge1xuICAgICAgICBjb25zdCBwb3J0cyA9IHRoaXMuYXBwLnBvcnRzIGFzIHVua25vd24gYXMgTmV0d29ya0VsbVBvcnRzO1xuICAgICAgICBwb3J0cy5uZXRSZXNwb25zZS5zZW5kKHJlc3BvbnNlKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBGZXRjaCBhIFpJUCBhcmNoaXZlIGZyb20gYSBVUkwsIGV4dHJhY3QgaXQsIGFuZCBjb21wdXRlIFNIQS0xIGhhc2guXG4gICAgICovXG4gICAgZ2V0QXJjaGl2ZSA9IGFzeW5jIChhcmdzOiBHZXRBcmNoaXZlQXJncyk6IFByb21pc2U8dm9pZD4gPT4ge1xuICAgICAgICB0cnkge1xuICAgICAgICAgICAgLy8gRmV0Y2ggdGhlIGFyY2hpdmVcbiAgICAgICAgICAgIGNvbnN0IHJlc3BvbnNlID0gYXdhaXQgdGhpcy5mZXRjaFdpdGhSZWRpcmVjdHMoYXJncy51cmwpO1xuXG4gICAgICAgICAgICBpZiAoIXJlc3BvbnNlLm9rKSB7XG4gICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgICAgICAgICAgdHlwZV86IFwiSHR0cEVycm9yXCIsXG4gICAgICAgICAgICAgICAgICAgIHBheWxvYWQ6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIHN0YXR1c0NvZGU6IHJlc3BvbnNlLnN0YXR1cyxcbiAgICAgICAgICAgICAgICAgICAgICAgIG1lc3NhZ2U6IHJlc3BvbnNlLnN0YXR1c1RleHQsXG4gICAgICAgICAgICAgICAgICAgIH0sXG4gICAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICAvLyBHZXQgdGhlIHJlc3BvbnNlIGFzIEFycmF5QnVmZmVyXG4gICAgICAgICAgICBjb25zdCBhcnJheUJ1ZmZlciA9IGF3YWl0IHJlc3BvbnNlLmFycmF5QnVmZmVyKCk7XG5cbiAgICAgICAgICAgIC8vIENvbXB1dGUgU0hBLTEgaGFzaFxuICAgICAgICAgICAgY29uc3QgaGFzaEJ1ZmZlciA9IGNyeXB0b1xuICAgICAgICAgICAgICAgIC5jcmVhdGVIYXNoKFwic2hhMVwiKVxuICAgICAgICAgICAgICAgIC51cGRhdGUoQnVmZmVyLmZyb20oYXJyYXlCdWZmZXIpKVxuICAgICAgICAgICAgICAgIC5kaWdlc3QoKTtcbiAgICAgICAgICAgIGNvbnN0IHNoYSA9IGhhc2hCdWZmZXIudG9TdHJpbmcoXCJoZXhcIik7XG5cbiAgICAgICAgICAgIC8vIEV4dHJhY3QgWklQIGNvbnRlbnRzXG4gICAgICAgICAgICBjb25zdCB6aXAgPSBhd2FpdCBKU1ppcC5sb2FkQXN5bmMoYXJyYXlCdWZmZXIpO1xuICAgICAgICAgICAgY29uc3QgZW50cmllczogQXJjaGl2ZUVudHJ5W10gPSBbXTtcblxuICAgICAgICAgICAgLy8gUHJvY2VzcyBlYWNoIGZpbGUgaW4gdGhlIGFyY2hpdmVcbiAgICAgICAgICAgIGNvbnN0IGZpbGVQcm9taXNlczogUHJvbWlzZTx2b2lkPltdID0gW107XG5cbiAgICAgICAgICAgIHppcC5mb3JFYWNoKChyZWxhdGl2ZVBhdGgsIGZpbGUpID0+IHtcbiAgICAgICAgICAgICAgICBpZiAoIWZpbGUuZGlyKSB7XG4gICAgICAgICAgICAgICAgICAgIGNvbnN0IHByb21pc2UgPSBmaWxlLmFzeW5jKFwic3RyaW5nXCIpLnRoZW4oKGRhdGEpID0+IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIGVudHJpZXMucHVzaCh7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgcmVsYXRpdmVQYXRoLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgIGRhdGEsXG4gICAgICAgICAgICAgICAgICAgICAgICB9KTtcbiAgICAgICAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICAgICAgICAgIGZpbGVQcm9taXNlcy5wdXNoKHByb21pc2UpO1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH0pO1xuXG4gICAgICAgICAgICBhd2FpdCBQcm9taXNlLmFsbChmaWxlUHJvbWlzZXMpO1xuXG4gICAgICAgICAgICAvLyBTZW5kIHN1Y2Nlc3NmdWwgcmVzcG9uc2VcbiAgICAgICAgICAgIGNvbnN0IGFyY2hpdmVSZXNwb25zZTogQXJjaGl2ZVJlc3BvbnNlID0ge1xuICAgICAgICAgICAgICAgIHNoYSxcbiAgICAgICAgICAgICAgICBlbnRyaWVzLFxuICAgICAgICAgICAgfTtcblxuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIkFyY2hpdmVcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiBhcmNoaXZlUmVzcG9uc2UsXG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIGlmIChlcnJvciBpbnN0YW5jZW9mIEVycm9yKSB7XG4gICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoXG4gICAgICAgICAgICAgICAgICAgIGVycm9yUmVzcG9uc2UoYXJncy5pZCwgXCJORVRXT1JLX0VSUk9SXCIsIGVycm9yLm1lc3NhZ2UsIHtcbiAgICAgICAgICAgICAgICAgICAgICAgIG5hbWU6IGVycm9yLm5hbWUsXG4gICAgICAgICAgICAgICAgICAgICAgICBzdGFjazogZXJyb3Iuc3RhY2ssXG4gICAgICAgICAgICAgICAgICAgIH0pXG4gICAgICAgICAgICAgICAgKTtcbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoXG4gICAgICAgICAgICAgICAgICAgIGVycm9yUmVzcG9uc2UoYXJncy5pZCwgXCJVTktOT1dOXCIsIFN0cmluZyhlcnJvcikpXG4gICAgICAgICAgICAgICAgKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgIH07XG5cbiAgICAvKipcbiAgICAgKiBGZXRjaCB3aXRoIGF1dG9tYXRpYyByZWRpcmVjdCBmb2xsb3dpbmcuXG4gICAgICovXG4gICAgcHJpdmF0ZSBhc3luYyBmZXRjaFdpdGhSZWRpcmVjdHMoXG4gICAgICAgIHVybDogc3RyaW5nLFxuICAgICAgICBtYXhSZWRpcmVjdHM6IG51bWJlciA9IDEwXG4gICAgKTogUHJvbWlzZTxnbG9iYWxUaGlzLlJlc3BvbnNlPiB7XG4gICAgICAgIGxldCBjdXJyZW50VXJsID0gdXJsO1xuICAgICAgICBsZXQgcmVkaXJlY3RDb3VudCA9IDA7XG5cbiAgICAgICAgd2hpbGUgKHJlZGlyZWN0Q291bnQgPCBtYXhSZWRpcmVjdHMpIHtcbiAgICAgICAgICAgIGNvbnN0IHJlc3BvbnNlID0gYXdhaXQgdGhpcy5jb25maWcuZmV0Y2goY3VycmVudFVybCwge1xuICAgICAgICAgICAgICAgIHJlZGlyZWN0OiBcIm1hbnVhbFwiLFxuICAgICAgICAgICAgfSk7XG5cbiAgICAgICAgICAgIC8vIENoZWNrIGZvciByZWRpcmVjdCBzdGF0dXMgY29kZXNcbiAgICAgICAgICAgIGlmIChcbiAgICAgICAgICAgICAgICByZXNwb25zZS5zdGF0dXMgPj0gMzAwICYmXG4gICAgICAgICAgICAgICAgcmVzcG9uc2Uuc3RhdHVzIDwgNDAwICYmXG4gICAgICAgICAgICAgICAgcmVzcG9uc2UuaGVhZGVycy5oYXMoXCJsb2NhdGlvblwiKVxuICAgICAgICAgICAgKSB7XG4gICAgICAgICAgICAgICAgY29uc3QgbG9jYXRpb24gPSByZXNwb25zZS5oZWFkZXJzLmdldChcImxvY2F0aW9uXCIpITtcbiAgICAgICAgICAgICAgICAvLyBIYW5kbGUgcmVsYXRpdmUgVVJMc1xuICAgICAgICAgICAgICAgIGN1cnJlbnRVcmwgPSBuZXcgVVJMKGxvY2F0aW9uLCBjdXJyZW50VXJsKS50b1N0cmluZygpO1xuICAgICAgICAgICAgICAgIHJlZGlyZWN0Q291bnQrKztcbiAgICAgICAgICAgICAgICBjb250aW51ZTtcbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgcmV0dXJuIHJlc3BvbnNlO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhyb3cgbmV3IEVycm9yKGBUb28gbWFueSByZWRpcmVjdHMgKG1heCAke21heFJlZGlyZWN0c30pYCk7XG4gICAgfVxufVxuXG4vKipcbiAqIEFsdGVybmF0aXZlIGltcGxlbWVudGF0aW9uIHVzaW5nIFhNTEh0dHBSZXF1ZXN0IGZvciBlbnZpcm9ubWVudHNcbiAqIHdoZXJlIGZldGNoIGlzIG5vdCBhdmFpbGFibGUgb3IgaGFzIGxpbWl0YXRpb25zLlxuICovXG5leHBvcnQgY2xhc3MgTmV0d29ya1BvcnRzWEhSIHtcbiAgICBwcml2YXRlIGFwcDogeyBwb3J0czogTmV0d29ya0VsbVBvcnRzIH07XG4gICAgcHJpdmF0ZSBYTUxIdHRwUmVxdWVzdDogbmV3ICgpID0+IFhNTEh0dHBSZXF1ZXN0O1xuXG4gICAgY29uc3RydWN0b3IoXG4gICAgICAgIGFwcDogRWxtQXBwLFxuICAgICAgICBYTUxIdHRwUmVxdWVzdEN0b3I/OiBuZXcgKCkgPT4gWE1MSHR0cFJlcXVlc3RcbiAgICApIHtcbiAgICAgICAgLy8gVXNlIHByb3ZpZGVkIFhNTEh0dHBSZXF1ZXN0IG9yIGdsb2JhbCBvbmVcbiAgICAgICAgY29uc3QgWEhSID0gWE1MSHR0cFJlcXVlc3RDdG9yIHx8ICh0eXBlb2YgWE1MSHR0cFJlcXVlc3QgIT09IFwidW5kZWZpbmVkXCIgPyBYTUxIdHRwUmVxdWVzdCA6IHVuZGVmaW5lZCk7XG4gICAgICAgIGlmICghWEhSKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoXCJYTUxIdHRwUmVxdWVzdCBpcyBub3QgYXZhaWxhYmxlXCIpO1xuICAgICAgICB9XG4gICAgICAgIHRoaXMuWE1MSHR0cFJlcXVlc3QgPSBYSFI7XG4gICAgICAgIHRoaXMuYXBwID0gYXBwIGFzIHVua25vd24gYXMgeyBwb3J0czogTmV0d29ya0VsbVBvcnRzIH07XG5cbiAgICAgICAgY29uc3QgcG9ydE5hbWVzID0gW1wibmV0R2V0QXJjaGl2ZVwiLCBcIm5ldFJlc3BvbnNlXCJdO1xuXG4gICAgICAgIGNoZWNrUG9ydHNFeGlzdChhcHAsIHBvcnROYW1lcyk7XG5cbiAgICAgICAgY29uc3QgcG9ydHMgPSBhcHAucG9ydHMgYXMgdW5rbm93biBhcyBOZXR3b3JrRWxtUG9ydHM7XG4gICAgICAgIHBvcnRzLm5ldEdldEFyY2hpdmUuc3Vic2NyaWJlKHRoaXMuZ2V0QXJjaGl2ZSk7XG4gICAgfVxuXG4gICAgcHJpdmF0ZSBzZW5kUmVzcG9uc2UocmVzcG9uc2U6IFJlc3BvbnNlKTogdm9pZCB7XG4gICAgICAgIGNvbnN0IHBvcnRzID0gdGhpcy5hcHAucG9ydHMgYXMgdW5rbm93biBhcyBOZXR3b3JrRWxtUG9ydHM7XG4gICAgICAgIHBvcnRzLm5ldFJlc3BvbnNlLnNlbmQocmVzcG9uc2UpO1xuICAgIH1cblxuICAgIGdldEFyY2hpdmUgPSAoYXJnczogR2V0QXJjaGl2ZUFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgdGhpcy5kb3dubG9hZChcIkdFVFwiLCBhcmdzLnVybCwgYXJncy5pZCk7XG4gICAgfTtcblxuICAgIHByaXZhdGUgZG93bmxvYWQobWV0aG9kOiBzdHJpbmcsIHVybDogc3RyaW5nLCBpZDogc3RyaW5nKTogdm9pZCB7XG4gICAgICAgIGNvbnN0IHhociA9IG5ldyB0aGlzLlhNTEh0dHBSZXF1ZXN0KCk7XG4gICAgICAgIHhoci5vcGVuKG1ldGhvZCwgdXJsLCB0cnVlKTtcbiAgICAgICAgeGhyLnJlc3BvbnNlVHlwZSA9IFwiYXJyYXlidWZmZXJcIjtcblxuICAgICAgICB4aHIub25sb2FkID0gYXN5bmMgKCkgPT4ge1xuICAgICAgICAgICAgdHJ5IHtcbiAgICAgICAgICAgICAgICBpZiAoeGhyLnN0YXR1cyA+PSAyMDAgJiYgeGhyLnN0YXR1cyA8IDMwMCkge1xuICAgICAgICAgICAgICAgICAgICAvLyBDb21wdXRlIFNIQS0xIGhhc2hcbiAgICAgICAgICAgICAgICAgICAgY29uc3QgaGFzaEJ1ZmZlciA9IGNyeXB0b1xuICAgICAgICAgICAgICAgICAgICAgICAgLmNyZWF0ZUhhc2goXCJzaGExXCIpXG4gICAgICAgICAgICAgICAgICAgICAgICAudXBkYXRlKEJ1ZmZlci5mcm9tKHhoci5yZXNwb25zZSkpXG4gICAgICAgICAgICAgICAgICAgICAgICAuZGlnZXN0KCk7XG4gICAgICAgICAgICAgICAgICAgIGNvbnN0IHNoYSA9IGhhc2hCdWZmZXIudG9TdHJpbmcoXCJoZXhcIik7XG5cbiAgICAgICAgICAgICAgICAgICAgLy8gRXh0cmFjdCBaSVAgY29udGVudHNcbiAgICAgICAgICAgICAgICAgICAgY29uc3QgemlwID0gYXdhaXQgSlNaaXAubG9hZEFzeW5jKHhoci5yZXNwb25zZSk7XG4gICAgICAgICAgICAgICAgICAgIGNvbnN0IGVudHJpZXM6IEFyY2hpdmVFbnRyeVtdID0gW107XG5cbiAgICAgICAgICAgICAgICAgICAgY29uc3QgZmlsZVByb21pc2VzOiBQcm9taXNlPHZvaWQ+W10gPSBbXTtcblxuICAgICAgICAgICAgICAgICAgICB6aXAuZm9yRWFjaCgocmVsYXRpdmVQYXRoLCBmaWxlKSA9PiB7XG4gICAgICAgICAgICAgICAgICAgICAgICBpZiAoIWZpbGUuZGlyKSB7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgY29uc3QgcHJvbWlzZSA9IGZpbGUuYXN5bmMoXCJzdHJpbmdcIikudGhlbigoZGF0YSkgPT4ge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBlbnRyaWVzLnB1c2goe1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcmVsYXRpdmVQYXRoLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZGF0YSxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgZmlsZVByb21pc2VzLnB1c2gocHJvbWlzZSk7XG4gICAgICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgICAgIH0pO1xuXG4gICAgICAgICAgICAgICAgICAgIGF3YWl0IFByb21pc2UuYWxsKGZpbGVQcm9taXNlcyk7XG5cbiAgICAgICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgICAgICAgICAgaWQsXG4gICAgICAgICAgICAgICAgICAgICAgICB0eXBlXzogXCJBcmNoaXZlXCIsXG4gICAgICAgICAgICAgICAgICAgICAgICBwYXlsb2FkOiB7IHNoYSwgZW50cmllcyB9LFxuICAgICAgICAgICAgICAgICAgICB9KTtcbiAgICAgICAgICAgICAgICB9IGVsc2UgaWYgKHhoci5zdGF0dXMgPj0gMzAwICYmIHhoci5zdGF0dXMgPCA0MDApIHtcbiAgICAgICAgICAgICAgICAgICAgLy8gSGFuZGxlIHJlZGlyZWN0XG4gICAgICAgICAgICAgICAgICAgIGNvbnN0IGhlYWRlcnMgPSB4aHJcbiAgICAgICAgICAgICAgICAgICAgICAgIC5nZXRBbGxSZXNwb25zZUhlYWRlcnMoKVxuICAgICAgICAgICAgICAgICAgICAgICAgLnRyaW0oKVxuICAgICAgICAgICAgICAgICAgICAgICAgLnNwbGl0KC9bXFxyXFxuXSsvKVxuICAgICAgICAgICAgICAgICAgICAgICAgLnJlZHVjZSgoYWNjOiBSZWNvcmQ8c3RyaW5nLCBzdHJpbmc+LCBsaW5lOiBzdHJpbmcpID0+IHtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBjb25zdCBwYXJ0cyA9IGxpbmUuc3BsaXQoXCI6IFwiKTtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBjb25zdCBoZWFkZXIgPSBwYXJ0cy5zaGlmdCgpIS50b0xvd2VyQ2FzZSgpO1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNvbnN0IHZhbHVlID0gcGFydHMuam9pbihcIjogXCIpO1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIGFjY1toZWFkZXJdID0gdmFsdWU7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGFjYztcbiAgICAgICAgICAgICAgICAgICAgICAgIH0sIHt9KTtcblxuICAgICAgICAgICAgICAgICAgICBpZiAoaGVhZGVycy5sb2NhdGlvbikge1xuICAgICAgICAgICAgICAgICAgICAgICAgdGhpcy5kb3dubG9hZChtZXRob2QsIGhlYWRlcnMubG9jYXRpb24sIGlkKTtcbiAgICAgICAgICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBpZCxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICB0eXBlXzogXCJIdHRwRXJyb3JcIixcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBwYXlsb2FkOiB7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0YXR1c0NvZGU6IHhoci5zdGF0dXMsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIG1lc3NhZ2U6IFwiUmVkaXJlY3Qgd2l0aG91dCBsb2NhdGlvbiBoZWFkZXJcIixcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZSh7XG4gICAgICAgICAgICAgICAgICAgICAgICBpZCxcbiAgICAgICAgICAgICAgICAgICAgICAgIHR5cGVfOiBcIkh0dHBFcnJvclwiLFxuICAgICAgICAgICAgICAgICAgICAgICAgcGF5bG9hZDoge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0YXR1c0NvZGU6IHhoci5zdGF0dXMsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgbWVzc2FnZTogeGhyLnN0YXR1c1RleHQsXG4gICAgICAgICAgICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICAgICAgICB9KTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9IGNhdGNoIChlcnJvcikge1xuICAgICAgICAgICAgICAgIGlmIChlcnJvciBpbnN0YW5jZW9mIEVycm9yKSB7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKFxuICAgICAgICAgICAgICAgICAgICAgICAgZXJyb3JSZXNwb25zZShpZCwgXCJFWFRSQUNUX0VSUk9SXCIsIGVycm9yLm1lc3NhZ2UpXG4gICAgICAgICAgICAgICAgICAgICk7XG4gICAgICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoXG4gICAgICAgICAgICAgICAgICAgICAgICBlcnJvclJlc3BvbnNlKGlkLCBcIlVOS05PV05cIiwgU3RyaW5nKGVycm9yKSlcbiAgICAgICAgICAgICAgICAgICAgKTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG4gICAgICAgIH07XG5cbiAgICAgICAgeGhyLm9uZXJyb3IgPSAoKSA9PiB7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShcbiAgICAgICAgICAgICAgICBlcnJvclJlc3BvbnNlKGlkLCBcIk5FVFdPUktfRVJST1JcIiwgXCJOZXR3b3JrIGVycm9yIGR1cmluZyBkb3dubG9hZFwiKVxuICAgICAgICAgICAgKTtcbiAgICAgICAgfTtcblxuICAgICAgICB4aHIub250aW1lb3V0ID0gKCkgPT4ge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoXG4gICAgICAgICAgICAgICAgZXJyb3JSZXNwb25zZShpZCwgXCJUSU1FT1VUXCIsIFwiRG93bmxvYWQgdGltZWQgb3V0XCIpXG4gICAgICAgICAgICApO1xuICAgICAgICB9O1xuXG4gICAgICAgIHhoci5zZW5kKCk7XG4gICAgfVxufVxuIl19