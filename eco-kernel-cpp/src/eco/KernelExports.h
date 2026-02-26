//===- KernelExports.h - C-linkage wrappers for Eco kernel IO functions ---===//
//
// This file declares all Eco kernel IO functions with extern "C" linkage so
// they can be found by the LLVM JIT. Functions are named using the pattern:
//   Eco_Kernel_<Module>_<function>
//
// ABI: All heap-allocated values (String, Bytes, List, Maybe, MVar, Handle,
// ProcessHandle, ExitCode, etc.) are passed as uint64_t (encoded HPointer).
// Unboxed types: Int as int64_t, Float as double, Bool as uint64_t
// (True/False HPointer constants per REP_ABI_001).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_KERNEL_EXPORTS_H
#define ECO_KERNEL_EXPORTS_H

#include <cstdint>

extern "C" {

//===----------------------------------------------------------------------===//
// File Module - file I/O by path, handles, locks, directories
//===----------------------------------------------------------------------===//

// Read file as UTF-8 string. Returns Task Never String.
uint64_t Eco_Kernel_File_readString(uint64_t path);

// Write UTF-8 string to file. Returns Task Never ().
uint64_t Eco_Kernel_File_writeString(uint64_t path, uint64_t content);

// Read file as raw bytes. Returns Task Never Bytes.
uint64_t Eco_Kernel_File_readBytes(uint64_t path);

// Write raw bytes to file. Returns Task Never ().
uint64_t Eco_Kernel_File_writeBytes(uint64_t path, uint64_t bytes);

// Open file handle with IOMode. Returns Task Never Handle.
uint64_t Eco_Kernel_File_open(uint64_t path, uint64_t mode);

// Close file handle. Returns Task Never ().
uint64_t Eco_Kernel_File_close(uint64_t handle);

// Get file size via handle. Returns Int (unboxed).
int64_t Eco_Kernel_File_size(uint64_t handle);

// Acquire file lock (blocks). Returns Task Never ().
uint64_t Eco_Kernel_File_lock(uint64_t path);

// Release file lock. Returns Task Never ().
uint64_t Eco_Kernel_File_unlock(uint64_t path);

// Check if file exists. Returns Bool (boxed True/False constant).
uint64_t Eco_Kernel_File_fileExists(uint64_t path);

// Check if directory exists. Returns Bool (boxed True/False constant).
uint64_t Eco_Kernel_File_dirExists(uint64_t path);

// Find executable on PATH. Returns Maybe String (boxed).
uint64_t Eco_Kernel_File_findExecutable(uint64_t name);

// List directory contents. Returns List String (boxed).
uint64_t Eco_Kernel_File_list(uint64_t path);

// Get file modification time. Returns Int (milliseconds since epoch, unboxed).
int64_t Eco_Kernel_File_modificationTime(uint64_t path);

// Get current working directory. Returns String (boxed).
uint64_t Eco_Kernel_File_getCwd();

// Set current working directory. Returns Task Never ().
uint64_t Eco_Kernel_File_setCwd(uint64_t path);

// Canonicalize path (resolve symlinks, normalize). Returns String (boxed).
uint64_t Eco_Kernel_File_canonicalize(uint64_t path);

// Get app-specific user data directory. Returns String (boxed).
uint64_t Eco_Kernel_File_appDataDir(uint64_t name);

// Create directory, optionally with parents. Returns Task Never ().
// createParents is boxed Bool.
uint64_t Eco_Kernel_File_createDir(uint64_t createParents, uint64_t path);

// Remove a file. Returns Task Never ().
uint64_t Eco_Kernel_File_removeFile(uint64_t path);

// Remove a directory tree. Returns Task Never ().
uint64_t Eco_Kernel_File_removeDir(uint64_t path);

//===----------------------------------------------------------------------===//
// Console Module - write to handles, read from stdin
//===----------------------------------------------------------------------===//

// Write string to console handle (stdout/stderr). Returns Task Never ().
uint64_t Eco_Kernel_Console_write(uint64_t handle, uint64_t content);

// Read one line from stdin. Returns String (boxed).
uint64_t Eco_Kernel_Console_readLine();

// Read all of stdin as string. Returns String (boxed).
uint64_t Eco_Kernel_Console_readAll();

//===----------------------------------------------------------------------===//
// Env Module - environment variables and CLI args
//===----------------------------------------------------------------------===//

// Look up environment variable. Returns Maybe String (boxed).
uint64_t Eco_Kernel_Env_lookup(uint64_t name);

// Get raw CLI args. Returns List String (boxed).
uint64_t Eco_Kernel_Env_rawArgs();

//===----------------------------------------------------------------------===//
// Process Module - exit and external process management
//===----------------------------------------------------------------------===//

// Exit process with ExitCode. Never returns. Returns Task Never () nominally.
uint64_t Eco_Kernel_Process_exit(uint64_t code);

// Spawn external process. Returns (Maybe Handle, ProcessHandle) (boxed tuple).
uint64_t Eco_Kernel_Process_spawn(uint64_t config);

// Wait for process to exit. Returns ExitCode (boxed).
uint64_t Eco_Kernel_Process_wait(uint64_t handle);

//===----------------------------------------------------------------------===//
// MVar Module - concurrency primitives
//===----------------------------------------------------------------------===//

// Create new empty MVar. Returns Int (MVar id, unboxed).
int64_t Eco_Kernel_MVar_new();

// Read MVar (blocks until full). Returns value (boxed).
// typeTag is unused at runtime but required by Elm type system.
uint64_t Eco_Kernel_MVar_read(uint64_t typeTag, uint64_t id);

// Take MVar (blocks until full, empties). Returns value (boxed).
uint64_t Eco_Kernel_MVar_take(uint64_t typeTag, uint64_t id);

// Put value into MVar (blocks until empty). Returns Task Never ().
uint64_t Eco_Kernel_MVar_put(uint64_t typeTag, uint64_t id, uint64_t value);

//===----------------------------------------------------------------------===//
// Runtime Module - Node.js specific and REPL state
//===----------------------------------------------------------------------===//

// Get directory of current script/binary. Returns String (boxed).
uint64_t Eco_Kernel_Runtime_dirname();

// Get random Float. Returns Float (unboxed).
double Eco_Kernel_Runtime_random();

// Persist REPL state to runtime storage. Returns Task Never ().
uint64_t Eco_Kernel_Runtime_saveState(uint64_t state);

} // extern "C"

#endif // ECO_KERNEL_EXPORTS_H
