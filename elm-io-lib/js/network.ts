/**
 * Network port handlers for Guida IO library.
 * Implements archive fetching with ZIP extraction and SHA-1 hashing.
 */

/// <reference lib="dom" />

import * as crypto from "crypto";
import {
    checkPortsExist,
    ElmApp,
    OutgoingPort,
    IncomingPort,
    Response,
    errorResponse,
} from "./ports";

// We need JSZip for ZIP extraction
// This will be provided via package.json dependency
import JSZip from "jszip";

// Request types
interface GetArchiveArgs {
    id: string;
    url: string;
}

// Port types
interface NetworkElmPorts {
    netGetArchive: OutgoingPort<GetArchiveArgs>;
    netResponse: IncomingPort<Response>;
}

// Archive entry type
interface ArchiveEntry {
    relativePath: string;
    data: string;
}

// Archive response type
interface ArchiveResponse {
    sha: string;
    entries: ArchiveEntry[];
}

// Configuration interface for dependency injection
export interface NetworkConfig {
    fetch: typeof fetch;
}

// Default configuration using global fetch
const defaultConfig: NetworkConfig = {
    fetch: globalThis.fetch,
};

/**
 * Network port handler class.
 * Manages archive fetching through Elm ports.
 */
export class NetworkPorts {
    private app: { ports: NetworkElmPorts };
    private config: NetworkConfig;

    constructor(app: ElmApp, config: NetworkConfig = defaultConfig) {
        this.app = app as unknown as { ports: NetworkElmPorts };
        this.config = config;

        const portNames = ["netGetArchive", "netResponse"];

        checkPortsExist(app, portNames);

        const ports = app.ports as unknown as NetworkElmPorts;
        ports.netGetArchive.subscribe(this.getArchive);
    }

    private sendResponse(response: Response): void {
        const ports = this.app.ports as unknown as NetworkElmPorts;
        ports.netResponse.send(response);
    }

    /**
     * Fetch a ZIP archive from a URL, extract it, and compute SHA-1 hash.
     */
    getArchive = async (args: GetArchiveArgs): Promise<void> => {
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
            const zip = await JSZip.loadAsync(arrayBuffer);
            const entries: ArchiveEntry[] = [];

            // Process each file in the archive
            const filePromises: Promise<void>[] = [];

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
            const archiveResponse: ArchiveResponse = {
                sha,
                entries,
            };

            this.sendResponse({
                id: args.id,
                type_: "Archive",
                payload: archiveResponse,
            });
        } catch (error) {
            if (error instanceof Error) {
                this.sendResponse(
                    errorResponse(args.id, "NETWORK_ERROR", error.message, {
                        name: error.name,
                        stack: error.stack,
                    })
                );
            } else {
                this.sendResponse(
                    errorResponse(args.id, "UNKNOWN", String(error))
                );
            }
        }
    };

    /**
     * Fetch with automatic redirect following.
     */
    private async fetchWithRedirects(
        url: string,
        maxRedirects: number = 10
    ): Promise<globalThis.Response> {
        let currentUrl = url;
        let redirectCount = 0;

        while (redirectCount < maxRedirects) {
            const response = await this.config.fetch(currentUrl, {
                redirect: "manual",
            });

            // Check for redirect status codes
            if (
                response.status >= 300 &&
                response.status < 400 &&
                response.headers.has("location")
            ) {
                const location = response.headers.get("location")!;
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

/**
 * Alternative implementation using XMLHttpRequest for environments
 * where fetch is not available or has limitations.
 */
export class NetworkPortsXHR {
    private app: { ports: NetworkElmPorts };
    private XMLHttpRequest: new () => XMLHttpRequest;

    constructor(
        app: ElmApp,
        XMLHttpRequestCtor?: new () => XMLHttpRequest
    ) {
        // Use provided XMLHttpRequest or global one
        const XHR = XMLHttpRequestCtor || (typeof XMLHttpRequest !== "undefined" ? XMLHttpRequest : undefined);
        if (!XHR) {
            throw new Error("XMLHttpRequest is not available");
        }
        this.XMLHttpRequest = XHR;
        this.app = app as unknown as { ports: NetworkElmPorts };

        const portNames = ["netGetArchive", "netResponse"];

        checkPortsExist(app, portNames);

        const ports = app.ports as unknown as NetworkElmPorts;
        ports.netGetArchive.subscribe(this.getArchive);
    }

    private sendResponse(response: Response): void {
        const ports = this.app.ports as unknown as NetworkElmPorts;
        ports.netResponse.send(response);
    }

    getArchive = (args: GetArchiveArgs): void => {
        this.download("GET", args.url, args.id);
    };

    private download(method: string, url: string, id: string): void {
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
                    const zip = await JSZip.loadAsync(xhr.response);
                    const entries: ArchiveEntry[] = [];

                    const filePromises: Promise<void>[] = [];

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
                } else if (xhr.status >= 300 && xhr.status < 400) {
                    // Handle redirect
                    const headers = xhr
                        .getAllResponseHeaders()
                        .trim()
                        .split(/[\r\n]+/)
                        .reduce((acc: Record<string, string>, line: string) => {
                            const parts = line.split(": ");
                            const header = parts.shift()!.toLowerCase();
                            const value = parts.join(": ");
                            acc[header] = value;
                            return acc;
                        }, {});

                    if (headers.location) {
                        this.download(method, headers.location, id);
                    } else {
                        this.sendResponse({
                            id,
                            type_: "HttpError",
                            payload: {
                                statusCode: xhr.status,
                                message: "Redirect without location header",
                            },
                        });
                    }
                } else {
                    this.sendResponse({
                        id,
                        type_: "HttpError",
                        payload: {
                            statusCode: xhr.status,
                            message: xhr.statusText,
                        },
                    });
                }
            } catch (error) {
                if (error instanceof Error) {
                    this.sendResponse(
                        errorResponse(id, "EXTRACT_ERROR", error.message)
                    );
                } else {
                    this.sendResponse(
                        errorResponse(id, "UNKNOWN", String(error))
                    );
                }
            }
        };

        xhr.onerror = () => {
            this.sendResponse(
                errorResponse(id, "NETWORK_ERROR", "Network error during download")
            );
        };

        xhr.ontimeout = () => {
            this.sendResponse(
                errorResponse(id, "TIMEOUT", "Download timed out")
            );
        };

        xhr.send();
    }
}
