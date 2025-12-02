"use strict";
/**
 * FileSystem port handlers for Guida IO library.
 * Implements file and directory operations.
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
exports.FileSystemPorts = void 0;
const fs = __importStar(require("fs/promises"));
const path = __importStar(require("path"));
const os = __importStar(require("os"));
const ports_1 = require("./ports");
// Default configuration using Node.js fs
const defaultConfig = {
    readFile: (filePath, encoding) => fs.readFile(filePath, { encoding }),
    readFileBuffer: (filePath) => fs.readFile(filePath),
    writeFile: (filePath, content) => fs.writeFile(filePath, content),
    stat: (filePath) => fs.stat(filePath),
    mkdir: (dirPath, options) => fs.mkdir(dirPath, options),
    readdir: (dirPath) => fs.readdir(dirPath),
    unlink: (filePath) => fs.unlink(filePath),
    rm: (dirPath, options) => fs.rm(dirPath, options),
    realpath: (filePath) => fs.realpath(filePath),
    cwd: () => process.cwd(),
    homedir: () => os.homedir(),
};
/**
 * FileSystem port handler class.
 * Manages file and directory operations through Elm ports.
 */
class FileSystemPorts {
    constructor(app, config = defaultConfig) {
        // File operations
        this.read = async (args) => {
            try {
                const content = await this.config.readFile(args.path, "utf-8");
                this.sendResponse({
                    id: args.id,
                    type_: "Content",
                    payload: content,
                });
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.writeString = async (args) => {
            try {
                await this.config.writeFile(args.path, args.content);
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.writeBinary = async (args) => {
            try {
                // Decode base64 content
                const buffer = Buffer.from(args.content, "base64");
                await this.config.writeFile(args.path, buffer);
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.binaryDecode = async (args) => {
            try {
                const buffer = await this.config.readFileBuffer(args.path);
                // Encode as base64 for transmission
                this.sendResponse({
                    id: args.id,
                    type_: "Bytes",
                    payload: buffer.toString("base64"),
                });
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        // File queries
        this.doesFileExist = async (args) => {
            try {
                const stats = await this.config.stat(args.path);
                const isFile = "isFile" in stats ? stats.isFile() : false;
                this.sendResponse({
                    id: args.id,
                    type_: "Bool",
                    payload: isFile,
                });
            }
            catch {
                // File doesn't exist
                this.sendResponse({
                    id: args.id,
                    type_: "Bool",
                    payload: false,
                });
            }
        };
        this.doesDirectoryExist = async (args) => {
            try {
                const stats = await this.config.stat(args.path);
                const isDirectory = "isDirectory" in stats ? stats.isDirectory() : false;
                this.sendResponse({
                    id: args.id,
                    type_: "Bool",
                    payload: isDirectory,
                });
            }
            catch {
                // Directory doesn't exist
                this.sendResponse({
                    id: args.id,
                    type_: "Bool",
                    payload: false,
                });
            }
        };
        // Directory operations
        this.createDirectory = async (args) => {
            try {
                await this.config.mkdir(args.path, { recursive: args.createParents });
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.listDirectory = async (args) => {
            try {
                const files = await this.config.readdir(args.path);
                this.sendResponse({
                    id: args.id,
                    type_: "List",
                    payload: files,
                });
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.removeFile = async (args) => {
            try {
                await this.config.unlink(args.path);
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.removeDirectoryRecursive = async (args) => {
            try {
                await this.config.rm(args.path, { recursive: true, force: true });
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        // Path operations
        this.canonicalizePath = async (args) => {
            try {
                const realPath = await this.config.realpath(args.path);
                this.sendResponse({
                    id: args.id,
                    type_: "Content",
                    payload: realPath,
                });
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.getCurrentDirectory = (args) => {
            try {
                const cwd = this.config.cwd();
                this.sendResponse({
                    id: args.id,
                    type_: "Content",
                    payload: cwd,
                });
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.getAppUserDataDirectory = (args) => {
            try {
                const homedir = this.config.homedir();
                const appDir = path.join(homedir, `.${args.appName}`);
                this.sendResponse({
                    id: args.id,
                    type_: "Content",
                    payload: appDir,
                });
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        this.getModificationTime = async (args) => {
            try {
                const stats = await this.config.stat(args.path);
                const mtime = "mtime" in stats ? stats.mtime : new Date();
                this.sendResponse({
                    id: args.id,
                    type_: "Time",
                    payload: mtime.getTime(),
                });
            }
            catch (error) {
                this.sendResponse((0, ports_1.errorFromException)(args.id, error));
            }
        };
        // File locking
        this.lockFile = (args) => {
            const existingLock = this.lockedFiles.get(args.path);
            if (existingLock) {
                // File is already locked, add to waiting queue
                existingLock.subscribers.push({ id: args.id });
            }
            else {
                // Acquire lock immediately
                this.lockedFiles.set(args.path, { subscribers: [] });
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
        };
        this.unlockFile = (args) => {
            const lock = this.lockedFiles.get(args.path);
            if (lock) {
                const nextWaiter = lock.subscribers.shift();
                if (nextWaiter) {
                    // Give lock to next waiter
                    this.sendResponse((0, ports_1.okResponse)(nextWaiter.id));
                }
                else {
                    // No waiters, remove lock
                    this.lockedFiles.delete(args.path);
                }
                // Always respond OK to unlock request
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
            else {
                // Lock doesn't exist, but we'll respond OK anyway
                this.sendResponse((0, ports_1.okResponse)(args.id));
            }
        };
        this.app = app;
        this.config = config;
        this.lockedFiles = new Map();
        const portNames = [
            "fsRead",
            "fsWriteString",
            "fsWriteBinary",
            "fsBinaryDecode",
            "fsDoesFileExist",
            "fsDoesDirectoryExist",
            "fsCreateDirectory",
            "fsListDirectory",
            "fsRemoveFile",
            "fsRemoveDirectoryRecursive",
            "fsCanonicalizePath",
            "fsGetCurrentDirectory",
            "fsGetAppUserDataDirectory",
            "fsGetModificationTime",
            "fsLockFile",
            "fsUnlockFile",
            "fsResponse",
        ];
        (0, ports_1.checkPortsExist)(app, portNames);
        const ports = app.ports;
        ports.fsRead.subscribe(this.read);
        ports.fsWriteString.subscribe(this.writeString);
        ports.fsWriteBinary.subscribe(this.writeBinary);
        ports.fsBinaryDecode.subscribe(this.binaryDecode);
        ports.fsDoesFileExist.subscribe(this.doesFileExist);
        ports.fsDoesDirectoryExist.subscribe(this.doesDirectoryExist);
        ports.fsCreateDirectory.subscribe(this.createDirectory);
        ports.fsListDirectory.subscribe(this.listDirectory);
        ports.fsRemoveFile.subscribe(this.removeFile);
        ports.fsRemoveDirectoryRecursive.subscribe(this.removeDirectoryRecursive);
        ports.fsCanonicalizePath.subscribe(this.canonicalizePath);
        ports.fsGetCurrentDirectory.subscribe(this.getCurrentDirectory);
        ports.fsGetAppUserDataDirectory.subscribe(this.getAppUserDataDirectory);
        ports.fsGetModificationTime.subscribe(this.getModificationTime);
        ports.fsLockFile.subscribe(this.lockFile);
        ports.fsUnlockFile.subscribe(this.unlockFile);
    }
    sendResponse(response) {
        const ports = this.app.ports;
        ports.fsResponse.send(response);
    }
}
exports.FileSystemPorts = FileSystemPorts;
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiZmlsZXN5c3RlbS5qcyIsInNvdXJjZVJvb3QiOiIiLCJzb3VyY2VzIjpbIi4uL2pzL2ZpbGVzeXN0ZW0udHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IjtBQUFBOzs7R0FHRzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBRUgsZ0RBQWtDO0FBQ2xDLDJDQUE2QjtBQUM3Qix1Q0FBeUI7QUFDekIsbUNBUWlCO0FBNEVqQix5Q0FBeUM7QUFDekMsTUFBTSxhQUFhLEdBQXFCO0lBQ3BDLFFBQVEsRUFBRSxDQUFDLFFBQVEsRUFBRSxRQUFRLEVBQUUsRUFBRSxDQUFDLEVBQUUsQ0FBQyxRQUFRLENBQUMsUUFBUSxFQUFFLEVBQUUsUUFBUSxFQUFFLENBQUM7SUFDckUsY0FBYyxFQUFFLENBQUMsUUFBUSxFQUFFLEVBQUUsQ0FBQyxFQUFFLENBQUMsUUFBUSxDQUFDLFFBQVEsQ0FBQztJQUNuRCxTQUFTLEVBQUUsQ0FBQyxRQUFRLEVBQUUsT0FBTyxFQUFFLEVBQUUsQ0FBQyxFQUFFLENBQUMsU0FBUyxDQUFDLFFBQVEsRUFBRSxPQUFPLENBQUM7SUFDakUsSUFBSSxFQUFFLENBQUMsUUFBUSxFQUFFLEVBQUUsQ0FBQyxFQUFFLENBQUMsSUFBSSxDQUFDLFFBQVEsQ0FBQztJQUNyQyxLQUFLLEVBQUUsQ0FBQyxPQUFPLEVBQUUsT0FBTyxFQUFFLEVBQUUsQ0FBQyxFQUFFLENBQUMsS0FBSyxDQUFDLE9BQU8sRUFBRSxPQUFPLENBQUM7SUFDdkQsT0FBTyxFQUFFLENBQUMsT0FBTyxFQUFFLEVBQUUsQ0FBQyxFQUFFLENBQUMsT0FBTyxDQUFDLE9BQU8sQ0FBQztJQUN6QyxNQUFNLEVBQUUsQ0FBQyxRQUFRLEVBQUUsRUFBRSxDQUFDLEVBQUUsQ0FBQyxNQUFNLENBQUMsUUFBUSxDQUFDO0lBQ3pDLEVBQUUsRUFBRSxDQUFDLE9BQU8sRUFBRSxPQUFPLEVBQUUsRUFBRSxDQUFDLEVBQUUsQ0FBQyxFQUFFLENBQUMsT0FBTyxFQUFFLE9BQU8sQ0FB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cmNlc0NvbnRlbnQiOlsiLyoqXG4gKiBGaWxlU3lzdGVtIHBvcnQgaGFuZGxlcnMgZm9yIEd1aWRhIElPIGxpYnJhcnkuXG4gKiBJbXBsZW1lbnRzIGZpbGUgYW5kIGRpcmVjdG9yeSBvcGVyYXRpb25zLlxuICovXG5cbmltcG9ydCAqIGFzIGZzIGZyb20gXCJmcy9wcm9taXNlc1wiO1xuaW1wb3J0ICogYXMgcGF0aCBmcm9tIFwicGF0aFwiO1xuaW1wb3J0ICogYXMgb3MgZnJvbSBcIm9zXCI7XG5pbXBvcnQge1xuICAgIGNoZWNrUG9ydHNFeGlzdCxcbiAgICBFbG1BcHAsXG4gICAgT3V0Z29pbmdQb3J0LFxuICAgIEluY29taW5nUG9ydCxcbiAgICBSZXNwb25zZSxcbiAgICBva1Jlc3BvbnNlLFxuICAgIGVycm9yRnJvbUV4Y2VwdGlvbixcbn0gZnJvbSBcIi4vcG9ydHNcIjtcblxuLy8gUmVxdWVzdCB0eXBlc1xuaW50ZXJmYWNlIFJlYWRBcmdzIHtcbiAgICBpZDogc3RyaW5nO1xuICAgIHBhdGg6IHN0cmluZztcbn1cblxuaW50ZXJmYWNlIFdyaXRlU3RyaW5nQXJncyB7XG4gICAgaWQ6IHN0cmluZztcbiAgICBwYXRoOiBzdHJpbmc7XG4gICAgY29udGVudDogc3RyaW5nO1xufVxuXG5pbnRlcmZhY2UgV3JpdGVCaW5hcnlBcmdzIHtcbiAgICBpZDogc3RyaW5nO1xuICAgIHBhdGg6IHN0cmluZztcbiAgICBjb250ZW50OiBzdHJpbmc7IC8vIGJhc2U2NCBlbmNvZGVkXG59XG5cbmludGVyZmFjZSBQYXRoQXJncyB7XG4gICAgaWQ6IHN0cmluZztcbiAgICBwYXRoOiBzdHJpbmc7XG59XG5cbmludGVyZmFjZSBJZE9ubHlBcmdzIHtcbiAgICBpZDogc3RyaW5nO1xufVxuXG5pbnRlcmZhY2UgQXBwVXNlckRhdGFBcmdzIHtcbiAgICBpZDogc3RyaW5nO1xuICAgIGFwcE5hbWU6IHN0cmluZztcbn1cblxuaW50ZXJmYWNlIENyZWF0ZURpcmVjdG9yeUFyZ3Mge1xuICAgIGlkOiBzdHJpbmc7XG4gICAgcGF0aDogc3RyaW5nO1xuICAgIGNyZWF0ZVBhcmVudHM6IGJvb2xlYW47XG59XG5cbi8vIFBvcnQgdHlwZXNcbmludGVyZmFjZSBGaWxlU3lzdGVtRWxtUG9ydHMge1xuICAgIGZzUmVhZDogT3V0Z29pbmdQb3J0PFJlYWRBcmdzPjtcbiAgICBmc1dyaXRlU3RyaW5nOiBPdXRnb2luZ1BvcnQ8V3JpdGVTdHJpbmdBcmdzPjtcbiAgICBmc1dyaXRlQmluYXJ5OiBPdXRnb2luZ1BvcnQ8V3JpdGVCaW5hcnlBcmdzPjtcbiAgICBmc0JpbmFyeURlY29kZTogT3V0Z29pbmdQb3J0PFBhdGhBcmdzPjtcbiAgICBmc0RvZXNGaWxlRXhpc3Q6IE91dGdvaW5nUG9ydDxQYXRoQXJncz47XG4gICAgZnNEb2VzRGlyZWN0b3J5RXhpc3Q6IE91dGdvaW5nUG9ydDxQYXRoQXJncz47XG4gICAgZnNDcmVhdGVEaXJlY3Rvcnk6IE91dGdvaW5nUG9ydDxDcmVhdGVEaXJlY3RvcnlBcmdzPjtcbiAgICBmc0xpc3REaXJlY3Rvcnk6IE91dGdvaW5nUG9ydDxQYXRoQXJncz47XG4gICAgZnNSZW1vdmVGaWxlOiBPdXRnb2luZ1BvcnQ8UGF0aEFyZ3M+O1xuICAgIGZzUmVtb3ZlRGlyZWN0b3J5UmVjdXJzaXZlOiBPdXRnb2luZ1BvcnQ8UGF0aEFyZ3M+O1xuICAgIGZzQ2Fub25pY2FsaXplUGF0aDogT3V0Z29pbmdQb3J0PFBhdGhBcmdzPjtcbiAgICBmc0dldEN1cnJlbnREaXJlY3Rvcnk6IE91dGdvaW5nUG9ydDxJZE9ubHlBcmdzPjtcbiAgICBmc0dldEFwcFVzZXJEYXRhRGlyZWN0b3J5OiBPdXRnb2luZ1BvcnQ8QXBwVXNlckRhdGFBcmdzPjtcbiAgICBmc0dldE1vZGlmaWNhdGlvblRpbWU6IE91dGdvaW5nUG9ydDxQYXRoQXJncz47XG4gICAgZnNMb2NrRmlsZTogT3V0Z29pbmdQb3J0PFBhdGhBcmdzPjtcbiAgICBmc1VubG9ja0ZpbGU6IE91dGdvaW5nUG9ydDxQYXRoQXJncz47XG4gICAgZnNSZXNwb25zZTogSW5jb21pbmdQb3J0PFJlc3BvbnNlPjtcbn1cblxuLy8gQ29uZmlndXJhdGlvbiBpbnRlcmZhY2UgZm9yIGRlcGVuZGVuY3kgaW5qZWN0aW9uXG5leHBvcnQgaW50ZXJmYWNlIEZpbGVTeXN0ZW1Db25maWcge1xuICAgIHJlYWRGaWxlOiAoZmlsZVBhdGg6IHN0cmluZywgZW5jb2Rpbmc6IEJ1ZmZlckVuY29kaW5nKSA9PiBQcm9taXNlPHN0cmluZz47XG4gICAgcmVhZEZpbGVCdWZmZXI6IChmaWxlUGF0aDogc3RyaW5nKSA9PiBQcm9taXNlPEJ1ZmZlcj47XG4gICAgd3JpdGVGaWxlOiAoZmlsZVBhdGg6IHN0cmluZywgY29udGVudDogc3RyaW5nIHwgQnVmZmVyKSA9PiBQcm9taXNlPHZvaWQ+O1xuICAgIHN0YXQ6IChmaWxlUGF0aDogc3RyaW5nKSA9PiBQcm9taXNlPGZzLkZpbGVIYW5kbGUgfCB7IGlzRmlsZTogKCkgPT4gYm9vbGVhbjsgaXNEaXJlY3Rvcnk6ICgpID0+IGJvb2xlYW47IG10aW1lOiBEYXRlIH0+O1xuICAgIG1rZGlyOiAoZGlyUGF0aDogc3RyaW5nLCBvcHRpb25zPzogeyByZWN1cnNpdmU/OiBib29sZWFuIH0pID0+IFByb21pc2U8c3RyaW5nIHwgdW5kZWZpbmVkPjtcbiAgICByZWFkZGlyOiAoZGlyUGF0aDogc3RyaW5nKSA9PiBQcm9taXNlPHN0cmluZ1tdPjtcbiAgICB1bmxpbms6IChmaWxlUGF0aDogc3RyaW5nKSA9PiBQcm9taXNlPHZvaWQ+O1xuICAgIHJtOiAoZGlyUGF0aDogc3RyaW5nLCBvcHRpb25zPzogeyByZWN1cnNpdmU/OiBib29sZWFuOyBmb3JjZT86IGJvb2xlYW4gfSkgPT4gUHJvbWlzZTx2b2lkPjtcbiAgICByZWFscGF0aDogKGZpbGVQYXRoOiBzdHJpbmcpID0+IFByb21pc2U8c3RyaW5nPjtcbiAgICBjd2Q6ICgpID0+IHN0cmluZztcbiAgICBob21lZGlyOiAoKSA9PiBzdHJpbmc7XG59XG5cbi8vIERlZmF1bHQgY29uZmlndXJhdGlvbiB1c2luZyBOb2RlLmpzIGZzXG5jb25zdCBkZWZhdWx0Q29uZmlnOiBGaWxlU3lzdGVtQ29uZmlnID0ge1xuICAgIHJlYWRGaWxlOiAoZmlsZVBhdGgsIGVuY29kaW5nKSA9PiBmcy5yZWFkRmlsZShmaWxlUGF0aCwgeyBlbmNvZGluZyB9KSxcbiAgICByZWFkRmlsZUJ1ZmZlcjogKGZpbGVQYXRoKSA9PiBmcy5yZWFkRmlsZShmaWxlUGF0aCksXG4gICAgd3JpdGVGaWxlOiAoZmlsZVBhdGgsIGNvbnRlbnQpID0+IGZzLndyaXRlRmlsZShmaWxlUGF0aCwgY29udGVudCksXG4gICAgc3RhdDogKGZpbGVQYXRoKSA9PiBmcy5zdGF0KGZpbGVQYXRoKSxcbiAgICBta2RpcjogKGRpclBhdGgsIG9wdGlvbnMpID0+IGZzLm1rZGlyKGRpclBhdGgsIG9wdGlvbnMpLFxuICAgIHJlYWRkaXI6IChkaXJQYXRoKSA9PiBmcy5yZWFkZGlyKGRpclBhdGgpLFxuICAgIHVubGluazogKGZpbGVQYXRoKSA9PiBmcy51bmxpbmsoZmlsZVBhdGgpLFxuICAgIHJtOiAoZGlyUGF0aCwgb3B0aW9ucykgPT4gZnMucm0oZGlyUGF0aCwgb3B0aW9ucyksXG4gICAgcmVhbHBhdGg6IChmaWxlUGF0aCkgPT4gZnMucmVhbHBhdGgoZmlsZVBhdGgpLFxuICAgIGN3ZDogKCkgPT4gcHJvY2Vzcy5jd2QoKSxcbiAgICBob21lZGlyOiAoKSA9PiBvcy5ob21lZGlyKCksXG59O1xuXG4vLyBGaWxlIGxvY2sgc3RhdGVcbmludGVyZmFjZSBMb2NrU3RhdGUge1xuICAgIHN1YnNjcmliZXJzOiBBcnJheTx7IGlkOiBzdHJpbmcgfT47XG59XG5cbi8qKlxuICogRmlsZVN5c3RlbSBwb3J0IGhhbmRsZXIgY2xhc3MuXG4gKiBNYW5hZ2VzIGZpbGUgYW5kIGRpcmVjdG9yeSBvcGVyYXRpb25zIHRocm91Z2ggRWxtIHBvcnRzLlxuICovXG5leHBvcnQgY2xhc3MgRmlsZVN5c3RlbVBvcnRzIHtcbiAgICBwcml2YXRlIGFwcDogeyBwb3J0czogRmlsZVN5c3RlbUVsbVBvcnRzIH07XG4gICAgcHJpdmF0ZSBjb25maWc6IEZpbGVTeXN0ZW1Db25maWc7XG4gICAgcHJpdmF0ZSBsb2NrZWRGaWxlczogTWFwPHN0cmluZywgTG9ja1N0YXRlPjtcblxuICAgIGNvbnN0cnVjdG9yKGFwcDogRWxtQXBwLCBjb25maWc6IEZpbGVTeXN0ZW1Db25maWcgPSBkZWZhdWx0Q29uZmlnKSB7XG4gICAgICAgIHRoaXMuYXBwID0gYXBwIGFzIHVua25vd24gYXMgeyBwb3J0czogRmlsZVN5c3RlbUVsbVBvcnRzIH07XG4gICAgICAgIHRoaXMuY29uZmlnID0gY29uZmlnO1xuICAgICAgICB0aGlzLmxvY2tlZEZpbGVzID0gbmV3IE1hcCgpO1xuXG4gICAgICAgIGNvbnN0IHBvcnROYW1lcyA9IFtcbiAgICAgICAgICAgIFwiZnNSZWFkXCIsXG4gICAgICAgICAgICBcImZzV3JpdGVTdHJpbmdcIixcbiAgICAgICAgICAgIFwiZnNXcml0ZUJpbmFyeVwiLFxuICAgICAgICAgICAgXCJmc0JpbmFyeURlY29kZVwiLFxuICAgICAgICAgICAgXCJmc0RvZXNGaWxlRXhpc3RcIixcbiAgICAgICAgICAgIFwiZnNEb2VzRGlyZWN0b3J5RXhpc3RcIixcbiAgICAgICAgICAgIFwiZnNDcmVhdGVEaXJlY3RvcnlcIixcbiAgICAgICAgICAgIFwiZnNMaXN0RGlyZWN0b3J5XCIsXG4gICAgICAgICAgICBcImZzUmVtb3ZlRmlsZVwiLFxuICAgICAgICAgICAgXCJmc1JlbW92ZURpcmVjdG9yeVJlY3Vyc2l2ZVwiLFxuICAgICAgICAgICAgXCJmc0Nhbm9uaWNhbGl6ZVBhdGhcIixcbiAgICAgICAgICAgIFwiZnNHZXRDdXJyZW50RGlyZWN0b3J5XCIsXG4gICAgICAgICAgICBcImZzR2V0QXBwVXNlckRhdGFEaXJlY3RvcnlcIixcbiAgICAgICAgICAgIFwiZnNHZXRNb2RpZmljYXRpb25UaW1lXCIsXG4gICAgICAgICAgICBcImZzTG9ja0ZpbGVcIixcbiAgICAgICAgICAgIFwiZnNVbmxvY2tGaWxlXCIsXG4gICAgICAgICAgICBcImZzUmVzcG9uc2VcIixcbiAgICAgICAgXTtcblxuICAgICAgICBjaGVja1BvcnRzRXhpc3QoYXBwLCBwb3J0TmFtZXMpO1xuXG4gICAgICAgIGNvbnN0IHBvcnRzID0gYXBwLnBvcnRzIGFzIHVua25vd24gYXMgRmlsZVN5c3RlbUVsbVBvcnRzO1xuICAgICAgICBwb3J0cy5mc1JlYWQuc3Vic2NyaWJlKHRoaXMucmVhZCk7XG4gICAgICAgIHBvcnRzLmZzV3JpdGVTdHJpbmcuc3Vic2NyaWJlKHRoaXMud3JpdGVTdHJpbmcpO1xuICAgICAgICBwb3J0cy5mc1dyaXRlQmluYXJ5LnN1YnNjcmliZSh0aGlzLndyaXRlQmluYXJ5KTtcbiAgICAgICAgcG9ydHMuZnNCaW5hcnlEZWNvZGUuc3Vic2NyaWJlKHRoaXMuYmluYXJ5RGVjb2RlKTtcbiAgICAgICAgcG9ydHMuZnNEb2VzRmlsZUV4aXN0LnN1YnNjcmliZSh0aGlzLmRvZXNGaWxlRXhpc3QpO1xuICAgICAgICBwb3J0cy5mc0RvZXNEaXJlY3RvcnlFeGlzdC5zdWJzY3JpYmUodGhpcy5kb2VzRGlyZWN0b3J5RXhpc3QpO1xuICAgICAgICBwb3J0cy5mc0NyZWF0ZURpcmVjdG9yeS5zdWJzY3JpYmUodGhpcy5jcmVhdGVEaXJlY3RvcnkpO1xuICAgICAgICBwb3J0cy5mc0xpc3REaXJlY3Rvcnkuc3Vic2NyaWJlKHRoaXMubGlzdERpcmVjdG9yeSk7XG4gICAgICAgIHBvcnRzLmZzUmVtb3ZlRmlsZS5zdWJzY3JpYmUodGhpcy5yZW1vdmVGaWxlKTtcbiAgICAgICAgcG9ydHMuZnNSZW1vdmVEaXJlY3RvcnlSZWN1cnNpdmUuc3Vic2NyaWJlKHRoaXMucmVtb3ZlRGlyZWN0b3J5UmVjdXJzaXZlKTtcbiAgICAgICAgcG9ydHMuZnNDYW5vbmljYWxpemVQYXRoLnN1YnNjcmliZSh0aGlzLmNhbm9uaWNhbGl6ZVBhdGgpO1xuICAgICAgICBwb3J0cy5mc0dldEN1cnJlbnREaXJlY3Rvcnkuc3Vic2NyaWJlKHRoaXMuZ2V0Q3VycmVudERpcmVjdG9yeSk7XG4gICAgICAgIHBvcnRzLmZzR2V0QXBwVXNlckRhdGFEaXJlY3Rvcnkuc3Vic2NyaWJlKHRoaXMuZ2V0QXBwVXNlckRhdGFEaXJlY3RvcnkpO1xuICAgICAgICBwb3J0cy5mc0dldE1vZGlmaWNhdGlvblRpbWUuc3Vic2NyaWJlKHRoaXMuZ2V0TW9kaWZpY2F0aW9uVGltZSk7XG4gICAgICAgIHBvcnRzLmZzTG9ja0ZpbGUuc3Vic2NyaWJlKHRoaXMubG9ja0ZpbGUpO1xuICAgICAgICBwb3J0cy5mc1VubG9ja0ZpbGUuc3Vic2NyaWJlKHRoaXMudW5sb2NrRmlsZSk7XG4gICAgfVxuXG4gICAgcHJpdmF0ZSBzZW5kUmVzcG9uc2UocmVzcG9uc2U6IFJlc3BvbnNlKTogdm9pZCB7XG4gICAgICAgIGNvbnN0IHBvcnRzID0gdGhpcy5hcHAucG9ydHMgYXMgdW5rbm93biBhcyBGaWxlU3lzdGVtRWxtUG9ydHM7XG4gICAgICAgIHBvcnRzLmZzUmVzcG9uc2Uuc2VuZChyZXNwb25zZSk7XG4gICAgfVxuXG4gICAgLy8gRmlsZSBvcGVyYXRpb25zXG5cbiAgICByZWFkID0gYXN5bmMgKGFyZ3M6IFJlYWRBcmdzKTogUHJvbWlzZTx2b2lkPiA9PiB7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgICBjb25zdCBjb250ZW50ID0gYXdhaXQgdGhpcy5jb25maWcucmVhZEZpbGUoYXJncy5wYXRoLCBcInV0Zi04XCIpO1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIkNvbnRlbnRcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiBjb250ZW50LFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH0gY2F0Y2ggKGVycm9yKSB7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShlcnJvckZyb21FeGNlcHRpb24oYXJncy5pZCwgZXJyb3IpKTtcbiAgICAgICAgfVxuICAgIH07XG5cbiAgICB3cml0ZVN0cmluZyA9IGFzeW5jIChhcmdzOiBXcml0ZVN0cmluZ0FyZ3MpOiBQcm9taXNlPHZvaWQ+ID0+IHtcbiAgICAgICAgdHJ5IHtcbiAgICAgICAgICAgIGF3YWl0IHRoaXMuY29uZmlnLndyaXRlRmlsZShhcmdzLnBhdGgsIGFyZ3MuY29udGVudCk7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShva1Jlc3BvbnNlKGFyZ3MuaWQpKTtcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKGVycm9yRnJvbUV4Y2VwdGlvbihhcmdzLmlkLCBlcnJvcikpO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIHdyaXRlQmluYXJ5ID0gYXN5bmMgKGFyZ3M6IFdyaXRlQmluYXJ5QXJncyk6IFByb21pc2U8dm9pZD4gPT4ge1xuICAgICAgICB0cnkge1xuICAgICAgICAgICAgLy8gRGVjb2RlIGJhc2U2NCBjb250ZW50XG4gICAgICAgICAgICBjb25zdCBidWZmZXIgPSBCdWZmZXIuZnJvbShhcmdzLmNvbnRlbnQsIFwiYmFzZTY0XCIpO1xuICAgICAgICAgICAgYXdhaXQgdGhpcy5jb25maWcud3JpdGVGaWxlKGFyZ3MucGF0aCwgYnVmZmVyKTtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKG9rUmVzcG9uc2UoYXJncy5pZCkpO1xuICAgICAgICB9IGNhdGNoIChlcnJvcikge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoZXJyb3JGcm9tRXhjZXB0aW9uKGFyZ3MuaWQsIGVycm9yKSk7XG4gICAgICAgIH1cbiAgICB9O1xuXG4gICAgYmluYXJ5RGVjb2RlID0gYXN5bmMgKGFyZ3M6IFBhdGhBcmdzKTogUHJvbWlzZTx2b2lkPiA9PiB7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgICBjb25zdCBidWZmZXIgPSBhd2FpdCB0aGlzLmNvbmZpZy5yZWFkRmlsZUJ1ZmZlcihhcmdzLnBhdGgpO1xuICAgICAgICAgICAgLy8gRW5jb2RlIGFzIGJhc2U2NCBmb3IgdHJhbnNtaXNzaW9uXG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZSh7XG4gICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgdHlwZV86IFwiQnl0ZXNcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiBidWZmZXIudG9TdHJpbmcoXCJiYXNlNjRcIiksXG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKGVycm9yRnJvbUV4Y2VwdGlvbihhcmdzLmlkLCBlcnJvcikpO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIC8vIEZpbGUgcXVlcmllc1xuXG4gICAgZG9lc0ZpbGVFeGlzdCA9IGFzeW5jIChhcmdzOiBQYXRoQXJncyk6IFByb21pc2U8dm9pZD4gPT4ge1xuICAgICAgICB0cnkge1xuICAgICAgICAgICAgY29uc3Qgc3RhdHMgPSBhd2FpdCB0aGlzLmNvbmZpZy5zdGF0KGFyZ3MucGF0aCk7XG4gICAgICAgICAgICBjb25zdCBpc0ZpbGUgPSBcImlzRmlsZVwiIGluIHN0YXRzID8gc3RhdHMuaXNGaWxlKCkgOiBmYWxzZTtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgICAgICB0eXBlXzogXCJCb29sXCIsXG4gICAgICAgICAgICAgICAgcGF5bG9hZDogaXNGaWxlLFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH0gY2F0Y2gge1xuICAgICAgICAgICAgLy8gRmlsZSBkb2Vzbid0IGV4aXN0XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZSh7XG4gICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgdHlwZV86IFwiQm9vbFwiLFxuICAgICAgICAgICAgICAgIHBheWxvYWQ6IGZhbHNlLFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH1cbiAgICB9O1xuXG4gICAgZG9lc0RpcmVjdG9yeUV4aXN0ID0gYXN5bmMgKGFyZ3M6IFBhdGhBcmdzKTogUHJvbWlzZTx2b2lkPiA9PiB7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgICBjb25zdCBzdGF0cyA9IGF3YWl0IHRoaXMuY29uZmlnLnN0YXQoYXJncy5wYXRoKTtcbiAgICAgICAgICAgIGNvbnN0IGlzRGlyZWN0b3J5ID0gXCJpc0RpcmVjdG9yeVwiIGluIHN0YXRzID8gc3RhdHMuaXNEaXJlY3RvcnkoKSA6IGZhbHNlO1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIkJvb2xcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiBpc0RpcmVjdG9yeSxcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9IGNhdGNoIHtcbiAgICAgICAgICAgIC8vIERpcmVjdG9yeSBkb2Vzbid0IGV4aXN0XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZSh7XG4gICAgICAgICAgICAgICAgaWQ6IGFyZ3MuaWQsXG4gICAgICAgICAgICAgICAgdHlwZV86IFwiQm9vbFwiLFxuICAgICAgICAgICAgICAgIHBheWxvYWQ6IGZhbHNlLFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH1cbiAgICB9O1xuXG4gICAgLy8gRGlyZWN0b3J5IG9wZXJhdGlvbnNcblxuICAgIGNyZWF0ZURpcmVjdG9yeSA9IGFzeW5jIChhcmdzOiBDcmVhdGVEaXJlY3RvcnlBcmdzKTogUHJvbWlzZTx2b2lkPiA9PiB7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgICBhd2FpdCB0aGlzLmNvbmZpZy5ta2RpcihhcmdzLnBhdGgsIHsgcmVjdXJzaXZlOiBhcmdzLmNyZWF0ZVBhcmVudHMgfSk7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShva1Jlc3BvbnNlKGFyZ3MuaWQpKTtcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKGVycm9yRnJvbUV4Y2VwdGlvbihhcmdzLmlkLCBlcnJvcikpO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIGxpc3REaXJlY3RvcnkgPSBhc3luYyAoYXJnczogUGF0aEFyZ3MpOiBQcm9taXNlPHZvaWQ+ID0+IHtcbiAgICAgICAgdHJ5IHtcbiAgICAgICAgICAgIGNvbnN0IGZpbGVzID0gYXdhaXQgdGhpcy5jb25maWcucmVhZGRpcihhcmdzLnBhdGgpO1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIkxpc3RcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiBmaWxlcyxcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9IGNhdGNoIChlcnJvcikge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoZXJyb3JGcm9tRXhjZXB0aW9uKGFyZ3MuaWQsIGVycm9yKSk7XG4gICAgICAgIH1cbiAgICB9O1xuXG4gICAgcmVtb3ZlRmlsZSA9IGFzeW5jIChhcmdzOiBQYXRoQXJncyk6IFByb21pc2U8dm9pZD4gPT4ge1xuICAgICAgICB0cnkge1xuICAgICAgICAgICAgYXdhaXQgdGhpcy5jb25maWcudW5saW5rKGFyZ3MucGF0aCk7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShva1Jlc3BvbnNlKGFyZ3MuaWQpKTtcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKGVycm9yRnJvbUV4Y2VwdGlvbihhcmdzLmlkLCBlcnJvcikpO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIHJlbW92ZURpcmVjdG9yeVJlY3Vyc2l2ZSA9IGFzeW5jIChhcmdzOiBQYXRoQXJncyk6IFByb21pc2U8dm9pZD4gPT4ge1xuICAgICAgICB0cnkge1xuICAgICAgICAgICAgYXdhaXQgdGhpcy5jb25maWcucm0oYXJncy5wYXRoLCB7IHJlY3Vyc2l2ZTogdHJ1ZSwgZm9yY2U6IHRydWUgfSk7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShva1Jlc3BvbnNlKGFyZ3MuaWQpKTtcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKGVycm9yRnJvbUV4Y2VwdGlvbihhcmdzLmlkLCBlcnJvcikpO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIC8vIFBhdGggb3BlcmF0aW9uc1xuXG4gICAgY2Fub25pY2FsaXplUGF0aCA9IGFzeW5jIChhcmdzOiBQYXRoQXJncyk6IFByb21pc2U8dm9pZD4gPT4ge1xuICAgICAgICB0cnkge1xuICAgICAgICAgICAgY29uc3QgcmVhbFBhdGggPSBhd2FpdCB0aGlzLmNvbmZpZy5yZWFscGF0aChhcmdzLnBhdGgpO1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIkNvbnRlbnRcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiByZWFsUGF0aCxcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9IGNhdGNoIChlcnJvcikge1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2UoZXJyb3JGcm9tRXhjZXB0aW9uKGFyZ3MuaWQsIGVycm9yKSk7XG4gICAgICAgIH1cbiAgICB9O1xuXG4gICAgZ2V0Q3VycmVudERpcmVjdG9yeSA9IChhcmdzOiBJZE9ubHlBcmdzKTogdm9pZCA9PiB7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgICBjb25zdCBjd2QgPSB0aGlzLmNvbmZpZy5jd2QoKTtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgICAgICB0eXBlXzogXCJDb250ZW50XCIsXG4gICAgICAgICAgICAgICAgcGF5bG9hZDogY3dkLFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH0gY2F0Y2ggKGVycm9yKSB7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShlcnJvckZyb21FeGNlcHRpb24oYXJncy5pZCwgZXJyb3IpKTtcbiAgICAgICAgfVxuICAgIH07XG5cbiAgICBnZXRBcHBVc2VyRGF0YURpcmVjdG9yeSA9IChhcmdzOiBBcHBVc2VyRGF0YUFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgdHJ5IHtcbiAgICAgICAgICAgIGNvbnN0IGhvbWVkaXIgPSB0aGlzLmNvbmZpZy5ob21lZGlyKCk7XG4gICAgICAgICAgICBjb25zdCBhcHBEaXIgPSBwYXRoLmpvaW4oaG9tZWRpciwgYC4ke2FyZ3MuYXBwTmFtZX1gKTtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKHtcbiAgICAgICAgICAgICAgICBpZDogYXJncy5pZCxcbiAgICAgICAgICAgICAgICB0eXBlXzogXCJDb250ZW50XCIsXG4gICAgICAgICAgICAgICAgcGF5bG9hZDogYXBwRGlyLFxuICAgICAgICAgICAgfSk7XG4gICAgICAgIH0gY2F0Y2ggKGVycm9yKSB7XG4gICAgICAgICAgICB0aGlzLnNlbmRSZXNwb25zZShlcnJvckZyb21FeGNlcHRpb24oYXJncy5pZCwgZXJyb3IpKTtcbiAgICAgICAgfVxuICAgIH07XG5cbiAgICBnZXRNb2RpZmljYXRpb25UaW1lID0gYXN5bmMgKGFyZ3M6IFBhdGhBcmdzKTogUHJvbWlzZTx2b2lkPiA9PiB7XG4gICAgICAgIHRyeSB7XG4gICAgICAgICAgICBjb25zdCBzdGF0cyA9IGF3YWl0IHRoaXMuY29uZmlnLnN0YXQoYXJncy5wYXRoKTtcbiAgICAgICAgICAgIGNvbnN0IG10aW1lID0gXCJtdGltZVwiIGluIHN0YXRzID8gc3RhdHMubXRpbWUgOiBuZXcgRGF0ZSgpO1xuICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uoe1xuICAgICAgICAgICAgICAgIGlkOiBhcmdzLmlkLFxuICAgICAgICAgICAgICAgIHR5cGVfOiBcIlRpbWVcIixcbiAgICAgICAgICAgICAgICBwYXlsb2FkOiBtdGltZS5nZXRUaW1lKCksXG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKGVycm9yRnJvbUV4Y2VwdGlvbihhcmdzLmlkLCBlcnJvcikpO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIC8vIEZpbGUgbG9ja2luZ1xuXG4gICAgbG9ja0ZpbGUgPSAoYXJnczogUGF0aEFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgY29uc3QgZXhpc3RpbmdMb2NrID0gdGhpcy5sb2NrZWRGaWxlcy5nZXQoYXJncy5wYXRoKTtcblxuICAgICAgICBpZiAoZXhpc3RpbmdMb2NrKSB7XG4gICAgICAgICAgICAvLyBGaWxlIGlzIGFscmVhZHkgbG9ja2VkLCBhZGQgdG8gd2FpdGluZyBxdWV1ZVxuICAgICAgICAgICAgZXhpc3RpbmdMb2NrLnN1YnNjcmliZXJzLnB1c2goeyBpZDogYXJncy5pZCB9KTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIC8vIEFjcXVpcmUgbG9jayBpbW1lZGlhdGVseVxuICAgICAgICAgICAgdGhpcy5sb2NrZWRGaWxlcy5zZXQoYXJncy5wYXRoLCB7IHN1YnNjcmliZXJzOiBbXSB9KTtcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKG9rUmVzcG9uc2UoYXJncy5pZCkpO1xuICAgICAgICB9XG4gICAgfTtcblxuICAgIHVubG9ja0ZpbGUgPSAoYXJnczogUGF0aEFyZ3MpOiB2b2lkID0+IHtcbiAgICAgICAgY29uc3QgbG9jayA9IHRoaXMubG9ja2VkRmlsZXMuZ2V0KGFyZ3MucGF0aCk7XG5cbiAgICAgICAgaWYgKGxvY2spIHtcbiAgICAgICAgICAgIGNvbnN0IG5leHRXYWl0ZXIgPSBsb2NrLnN1YnNjcmliZXJzLnNoaWZ0KCk7XG5cbiAgICAgICAgICAgIGlmIChuZXh0V2FpdGVyKSB7XG4gICAgICAgICAgICAgICAgLy8gR2l2ZSBsb2NrIHRvIG5leHQgd2FpdGVyXG4gICAgICAgICAgICAgICAgdGhpcy5zZW5kUmVzcG9uc2Uob2tSZXNwb25zZShuZXh0V2FpdGVyLmlkKSk7XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgIC8vIE5vIHdhaXRlcnMsIHJlbW92ZSBsb2NrXG4gICAgICAgICAgICAgICAgdGhpcy5sb2NrZWRGaWxlcy5kZWxldGUoYXJncy5wYXRoKTtcbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgLy8gQWx3YXlzIHJlc3BvbmQgT0sgdG8gdW5sb2NrIHJlcXVlc3RcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKG9rUmVzcG9uc2UoYXJncy5pZCkpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgLy8gTG9jayBkb2Vzbid0IGV4aXN0LCBidXQgd2UnbGwgcmVzcG9uZCBPSyBhbnl3YXlcbiAgICAgICAgICAgIHRoaXMuc2VuZFJlc3BvbnNlKG9rUmVzcG9uc2UoYXJncy5pZCkpO1xuICAgICAgICB9XG4gICAgfTtcbn1cbiJdfQ==