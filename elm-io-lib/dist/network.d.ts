/**
 * Network port handlers for Guida IO library.
 * Implements archive fetching with ZIP extraction and SHA-1 hashing.
 */
import { ElmApp } from "./ports";
interface GetArchiveArgs {
    id: string;
    url: string;
}
export interface NetworkConfig {
    fetch: typeof fetch;
}
/**
 * Network port handler class.
 * Manages archive fetching through Elm ports.
 */
export declare class NetworkPorts {
    private app;
    private config;
    constructor(app: ElmApp, config?: NetworkConfig);
    private sendResponse;
    /**
     * Fetch a ZIP archive from a URL, extract it, and compute SHA-1 hash.
     */
    getArchive: (args: GetArchiveArgs) => Promise<void>;
    /**
     * Fetch with automatic redirect following.
     */
    private fetchWithRedirects;
}
/**
 * Alternative implementation using XMLHttpRequest for environments
 * where fetch is not available or has limitations.
 */
export declare class NetworkPortsXHR {
    private app;
    private XMLHttpRequest;
    constructor(app: ElmApp, XMLHttpRequestCtor?: new () => XMLHttpRequest);
    private sendResponse;
    getArchive: (args: GetArchiveArgs) => void;
    private download;
}
export {};
