/**
 * FileSystem port handlers for Guida IO library.
 * Implements file and directory operations.
 */

import * as fs from "fs/promises";
import * as path from "path";
import * as os from "os";
import {
    checkPortsExist,
    ElmApp,
    OutgoingPort,
    IncomingPort,
    Response,
    okResponse,
    errorFromException,
} from "./ports";

// Request types
interface ReadArgs {
    id: string;
    path: string;
}

interface WriteStringArgs {
    id: string;
    path: string;
    content: string;
}

interface WriteBinaryArgs {
    id: string;
    path: string;
    content: string; // base64 encoded
}

interface PathArgs {
    id: string;
    path: string;
}

interface IdOnlyArgs {
    id: string;
}

interface AppUserDataArgs {
    id: string;
    appName: string;
}

interface CreateDirectoryArgs {
    id: string;
    path: string;
    createParents: boolean;
}

// Port types
interface FileSystemElmPorts {
    fsRead: OutgoingPort<ReadArgs>;
    fsWriteString: OutgoingPort<WriteStringArgs>;
    fsWriteBinary: OutgoingPort<WriteBinaryArgs>;
    fsBinaryDecode: OutgoingPort<PathArgs>;
    fsDoesFileExist: OutgoingPort<PathArgs>;
    fsDoesDirectoryExist: OutgoingPort<PathArgs>;
    fsCreateDirectory: OutgoingPort<CreateDirectoryArgs>;
    fsListDirectory: OutgoingPort<PathArgs>;
    fsRemoveFile: OutgoingPort<PathArgs>;
    fsRemoveDirectoryRecursive: OutgoingPort<PathArgs>;
    fsCanonicalizePath: OutgoingPort<PathArgs>;
    fsGetCurrentDirectory: OutgoingPort<IdOnlyArgs>;
    fsGetAppUserDataDirectory: OutgoingPort<AppUserDataArgs>;
    fsGetModificationTime: OutgoingPort<PathArgs>;
    fsLockFile: OutgoingPort<PathArgs>;
    fsUnlockFile: OutgoingPort<PathArgs>;
    fsResponse: IncomingPort<Response>;
}

// Configuration interface for dependency injection
export interface FileSystemConfig {
    readFile: (filePath: string, encoding: BufferEncoding) => Promise<string>;
    readFileBuffer: (filePath: string) => Promise<Buffer>;
    writeFile: (filePath: string, content: string | Buffer) => Promise<void>;
    stat: (filePath: string) => Promise<fs.FileHandle | { isFile: () => boolean; isDirectory: () => boolean; mtime: Date }>;
    mkdir: (dirPath: string, options?: { recursive?: boolean }) => Promise<string | undefined>;
    readdir: (dirPath: string) => Promise<string[]>;
    unlink: (filePath: string) => Promise<void>;
    rm: (dirPath: string, options?: { recursive?: boolean; force?: boolean }) => Promise<void>;
    realpath: (filePath: string) => Promise<string>;
    cwd: () => string;
    homedir: () => string;
}

// Default configuration using Node.js fs
const defaultConfig: FileSystemConfig = {
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

// File lock state
interface LockState {
    subscribers: Array<{ id: string }>;
}

/**
 * FileSystem port handler class.
 * Manages file and directory operations through Elm ports.
 */
export class FileSystemPorts {
    private app: { ports: FileSystemElmPorts };
    private config: FileSystemConfig;
    private lockedFiles: Map<string, LockState>;

    constructor(app: ElmApp, config: FileSystemConfig = defaultConfig) {
        this.app = app as unknown as { ports: FileSystemElmPorts };
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

        checkPortsExist(app, portNames);

        const ports = app.ports as unknown as FileSystemElmPorts;
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

    private sendResponse(response: Response): void {
        const ports = this.app.ports as unknown as FileSystemElmPorts;
        ports.fsResponse.send(response);
    }

    // File operations

    read = async (args: ReadArgs): Promise<void> => {
        try {
            const content = await this.config.readFile(args.path, "utf-8");
            this.sendResponse({
                id: args.id,
                type_: "Content",
                payload: content,
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    writeString = async (args: WriteStringArgs): Promise<void> => {
        try {
            await this.config.writeFile(args.path, args.content);
            this.sendResponse(okResponse(args.id));
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    writeBinary = async (args: WriteBinaryArgs): Promise<void> => {
        try {
            // Decode base64 content
            const buffer = Buffer.from(args.content, "base64");
            await this.config.writeFile(args.path, buffer);
            this.sendResponse(okResponse(args.id));
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    binaryDecode = async (args: PathArgs): Promise<void> => {
        try {
            const buffer = await this.config.readFileBuffer(args.path);
            // Encode as base64 for transmission
            this.sendResponse({
                id: args.id,
                type_: "Bytes",
                payload: buffer.toString("base64"),
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    // File queries

    doesFileExist = async (args: PathArgs): Promise<void> => {
        try {
            const stats = await this.config.stat(args.path);
            const isFile = "isFile" in stats ? stats.isFile() : false;
            this.sendResponse({
                id: args.id,
                type_: "Bool",
                payload: isFile,
            });
        } catch {
            // File doesn't exist
            this.sendResponse({
                id: args.id,
                type_: "Bool",
                payload: false,
            });
        }
    };

    doesDirectoryExist = async (args: PathArgs): Promise<void> => {
        try {
            const stats = await this.config.stat(args.path);
            const isDirectory = "isDirectory" in stats ? stats.isDirectory() : false;
            this.sendResponse({
                id: args.id,
                type_: "Bool",
                payload: isDirectory,
            });
        } catch {
            // Directory doesn't exist
            this.sendResponse({
                id: args.id,
                type_: "Bool",
                payload: false,
            });
        }
    };

    // Directory operations

    createDirectory = async (args: CreateDirectoryArgs): Promise<void> => {
        try {
            await this.config.mkdir(args.path, { recursive: args.createParents });
            this.sendResponse(okResponse(args.id));
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    listDirectory = async (args: PathArgs): Promise<void> => {
        try {
            const files = await this.config.readdir(args.path);
            this.sendResponse({
                id: args.id,
                type_: "List",
                payload: files,
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    removeFile = async (args: PathArgs): Promise<void> => {
        try {
            await this.config.unlink(args.path);
            this.sendResponse(okResponse(args.id));
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    removeDirectoryRecursive = async (args: PathArgs): Promise<void> => {
        try {
            await this.config.rm(args.path, { recursive: true, force: true });
            this.sendResponse(okResponse(args.id));
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    // Path operations

    canonicalizePath = async (args: PathArgs): Promise<void> => {
        try {
            const realPath = await this.config.realpath(args.path);
            this.sendResponse({
                id: args.id,
                type_: "Content",
                payload: realPath,
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    getCurrentDirectory = (args: IdOnlyArgs): void => {
        try {
            const cwd = this.config.cwd();
            this.sendResponse({
                id: args.id,
                type_: "Content",
                payload: cwd,
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    getAppUserDataDirectory = (args: AppUserDataArgs): void => {
        try {
            const homedir = this.config.homedir();
            const appDir = path.join(homedir, `.${args.appName}`);
            this.sendResponse({
                id: args.id,
                type_: "Content",
                payload: appDir,
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    getModificationTime = async (args: PathArgs): Promise<void> => {
        try {
            const stats = await this.config.stat(args.path);
            const mtime = "mtime" in stats ? stats.mtime : new Date();
            this.sendResponse({
                id: args.id,
                type_: "Time",
                payload: mtime.getTime(),
            });
        } catch (error) {
            this.sendResponse(errorFromException(args.id, error));
        }
    };

    // File locking

    lockFile = (args: PathArgs): void => {
        const existingLock = this.lockedFiles.get(args.path);

        if (existingLock) {
            // File is already locked, add to waiting queue
            existingLock.subscribers.push({ id: args.id });
        } else {
            // Acquire lock immediately
            this.lockedFiles.set(args.path, { subscribers: [] });
            this.sendResponse(okResponse(args.id));
        }
    };

    unlockFile = (args: PathArgs): void => {
        const lock = this.lockedFiles.get(args.path);

        if (lock) {
            const nextWaiter = lock.subscribers.shift();

            if (nextWaiter) {
                // Give lock to next waiter
                this.sendResponse(okResponse(nextWaiter.id));
            } else {
                // No waiters, remove lock
                this.lockedFiles.delete(args.path);
            }

            // Always respond OK to unlock request
            this.sendResponse(okResponse(args.id));
        } else {
            // Lock doesn't exist, but we'll respond OK anyway
            this.sendResponse(okResponse(args.id));
        }
    };
}
