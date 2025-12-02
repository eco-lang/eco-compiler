/**
 * FileSystem port handlers for Guida IO library.
 * Implements file and directory operations.
 */
import * as fs from "fs/promises";
import { ElmApp } from "./ports";
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
    content: string;
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
export interface FileSystemConfig {
    readFile: (filePath: string, encoding: BufferEncoding) => Promise<string>;
    readFileBuffer: (filePath: string) => Promise<Buffer>;
    writeFile: (filePath: string, content: string | Buffer) => Promise<void>;
    stat: (filePath: string) => Promise<fs.FileHandle | {
        isFile: () => boolean;
        isDirectory: () => boolean;
        mtime: Date;
    }>;
    mkdir: (dirPath: string, options?: {
        recursive?: boolean;
    }) => Promise<string | undefined>;
    readdir: (dirPath: string) => Promise<string[]>;
    unlink: (filePath: string) => Promise<void>;
    rm: (dirPath: string, options?: {
        recursive?: boolean;
        force?: boolean;
    }) => Promise<void>;
    realpath: (filePath: string) => Promise<string>;
    cwd: () => string;
    homedir: () => string;
}
/**
 * FileSystem port handler class.
 * Manages file and directory operations through Elm ports.
 */
export declare class FileSystemPorts {
    private app;
    private config;
    private lockedFiles;
    constructor(app: ElmApp, config?: FileSystemConfig);
    private sendResponse;
    read: (args: ReadArgs) => Promise<void>;
    writeString: (args: WriteStringArgs) => Promise<void>;
    writeBinary: (args: WriteBinaryArgs) => Promise<void>;
    binaryDecode: (args: PathArgs) => Promise<void>;
    doesFileExist: (args: PathArgs) => Promise<void>;
    doesDirectoryExist: (args: PathArgs) => Promise<void>;
    createDirectory: (args: CreateDirectoryArgs) => Promise<void>;
    listDirectory: (args: PathArgs) => Promise<void>;
    removeFile: (args: PathArgs) => Promise<void>;
    removeDirectoryRecursive: (args: PathArgs) => Promise<void>;
    canonicalizePath: (args: PathArgs) => Promise<void>;
    getCurrentDirectory: (args: IdOnlyArgs) => void;
    getAppUserDataDirectory: (args: AppUserDataArgs) => void;
    getModificationTime: (args: PathArgs) => Promise<void>;
    lockFile: (args: PathArgs) => void;
    unlockFile: (args: PathArgs) => void;
}
export {};
