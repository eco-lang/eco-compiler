//===- KernelExports.h - C-linkage wrappers for Eco kernel IO functions ---===//
//
// This file declares all Eco kernel IO functions with extern "C" linkage so
// they can be found by the LLVM JIT. Functions are named using the pattern:
//   Eco_Kernel_<Module>_<function>
//
// ABI: All heap-allocated values (String, Bytes, List, Maybe, MVar, Handle,
// ProcessHandle, ExitCode, etc.) are passed as HPtr (encoded HPointer).
// Unboxed types: Int as int64_t, Float as double, Bool as HPtr
// (True/False HPointer constants per REP_ABI_001).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_KERNEL_EXPORTS_H
#define ECO_KERNEL_EXPORTS_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <new>
#include "../../../runtime/src/allocator/Heap.hpp"
using Elm::HPtr;

namespace Eco {
namespace Kernel {

// Report an unrecoverable native fault and abort. Recoverable IO faults are
// returned as Task.fail tuples (see IO_ERR_002); this is only for unexpected
// C++ exceptions that must not cross the extern "C" boundary (FORBID_IO_001).
[[noreturn]] inline void reportFatal(const char* what) {
    std::fflush(stdout);
    std::fprintf(stderr, "\n[eco-runtime] FATAL: %s\n", what ? what : "(null)");
    std::fflush(stderr);
    std::abort();
}

} // namespace Kernel
} // namespace Eco

// Wrap an extern "C" kernel export body so unexpected C++ exceptions are turned
// into a clean fatal abort with diagnostics instead of unwinding across the
// C-linkage boundary (undefined behaviour). BODY must contain its own return.
#define ECO_KERNEL_GUARD(BODY)                                                 \
    try {                                                                      \
        BODY                                                                   \
    } catch (const std::bad_alloc&) {                                          \
        ::Eco::Kernel::reportFatal("out of memory in kernel");                 \
    } catch (const std::exception& ecoGuardEx) {                               \
        ::Eco::Kernel::reportFatal(ecoGuardEx.what());                         \
    } catch (...) {                                                            \
        ::Eco::Kernel::reportFatal("unknown native exception in kernel");      \
    }

extern "C" {

//===----------------------------------------------------------------------===//
// File Module - file I/O by path, handles, locks, directories
//===----------------------------------------------------------------------===//

// Read file as UTF-8 string. Returns Task Never String.
HPtr Eco_Kernel_File_readString(HPtr path);

// Write UTF-8 string to file. Returns Task Never ().
HPtr Eco_Kernel_File_writeString(HPtr path, HPtr content);

// Read file as raw bytes. Returns Task Never Bytes.
HPtr Eco_Kernel_File_readBytes(HPtr path);

// Write raw bytes to file. Returns Task Never ().
HPtr Eco_Kernel_File_writeBytes(HPtr path, HPtr bytes);

// Open file handle with IOMode. Returns Task Never Handle.
HPtr Eco_Kernel_File_open(HPtr path, HPtr mode);

// Close file handle. Returns Task Never ().
HPtr Eco_Kernel_File_close(HPtr handle);

// Get file size via handle. Returns Int (unboxed).
uint64_t Eco_Kernel_File_size(HPtr handle);

// Acquire file lock (blocks). Returns Task Never ().
HPtr Eco_Kernel_File_lock(HPtr path);

// Release file lock. Returns Task Never ().
HPtr Eco_Kernel_File_unlock(HPtr path);

// Check if file exists. Returns Bool (boxed True/False constant).
HPtr Eco_Kernel_File_fileExists(HPtr path);

// Check if directory exists. Returns Bool (boxed True/False constant).
HPtr Eco_Kernel_File_dirExists(HPtr path);

// Find executable on PATH. Returns Maybe String (boxed).
HPtr Eco_Kernel_File_findExecutable(HPtr name);

// List directory contents. Returns List String (boxed).
HPtr Eco_Kernel_File_list(HPtr path);

// Get file modification time. Returns Int (milliseconds since epoch, unboxed).
uint64_t Eco_Kernel_File_modificationTime(HPtr path);

// Get current working directory. Returns String (boxed).
HPtr Eco_Kernel_File_getCwd();

// Set current working directory. Returns Task Never ().
HPtr Eco_Kernel_File_setCwd(HPtr path);

// Canonicalize path (resolve symlinks, normalize). Returns String (boxed).
HPtr Eco_Kernel_File_canonicalize(HPtr path);

// Get app-specific user data directory. Returns String (boxed).
HPtr Eco_Kernel_File_appDataDir(HPtr name);

// Create directory, optionally with parents. Returns Task Never ().
// createParents is boxed Bool.
HPtr Eco_Kernel_File_createDir(HPtr createParents, HPtr path);

// Remove a file. Returns Task Never ().
HPtr Eco_Kernel_File_removeFile(HPtr path);

// Remove a directory tree. Returns Task Never ().
HPtr Eco_Kernel_File_removeDir(HPtr path);

// Write UTF-8 string to file handle. Returns Task Never ().
HPtr Eco_Kernel_File_hWriteString(HPtr handle, HPtr content);

// Touch a file (create if absent, update mtime). Returns Task Never ().
HPtr Eco_Kernel_File_touch(HPtr path);

//===----------------------------------------------------------------------===//
// Crash Module - unrecoverable errors
//===----------------------------------------------------------------------===//

// Crash the program with an error message. Never returns.
HPtr Eco_Kernel_Crash_crash(HPtr message);

//===----------------------------------------------------------------------===//
// Console Module - write to handles, read from stdin
//===----------------------------------------------------------------------===//

// Write string to console handle (stdout/stderr). Returns Task Never ().
HPtr Eco_Kernel_Console_write(HPtr handle, HPtr content);

// Read one line from stdin. Returns String (boxed).
HPtr Eco_Kernel_Console_readLine();

// Read all of stdin as string. Returns String (boxed).
HPtr Eco_Kernel_Console_readAll();

// log(tag, value): write tag to stderr, return value unchanged.
// `String -> a -> a` from Elm's perspective. Allowed under --optimize.
HPtr Eco_Kernel_Console_log(HPtr tag, HPtr value);

//===----------------------------------------------------------------------===//
// Env Module - environment variables and CLI args
//===----------------------------------------------------------------------===//

// Look up environment variable. Returns Maybe String (boxed).
HPtr Eco_Kernel_Env_lookup(HPtr name);

// Get raw CLI args. Returns List String (boxed).
HPtr Eco_Kernel_Env_rawArgs();

//===----------------------------------------------------------------------===//
// Process Module - exit and external process management
//===----------------------------------------------------------------------===//

// Exit process with exit code (unboxed Int). Never returns.
HPtr Eco_Kernel_Process_exit(int64_t code);

// Spawn external process with inherited stdio. Returns pid (unboxed Int).
uint64_t Eco_Kernel_Process_spawn(HPtr cmd, HPtr args);

// Spawn external process with configurable stdio.
// stdin_/stdout_/stderr_ are boxed Strings ("inherit" or "pipe").
// Returns record { stdinHandle: Maybe Int, processHandle: Int } (boxed).
HPtr Eco_Kernel_Process_spawnProcess(HPtr cmd, HPtr args,
    HPtr stdin_, HPtr stdout_, HPtr stderr_);

// Wait for process to exit. Returns Int (exit code, unboxed).
uint64_t Eco_Kernel_Process_wait(HPtr handle);

//===----------------------------------------------------------------------===//
// MVar Module - concurrency primitives
//===----------------------------------------------------------------------===//

// Create new empty MVar. Returns Int (MVar id, unboxed).
// Returns a Task that succeeds with a freshly-allocated MVar id (boxed Int).
// (Elm side: `Eco.Kernel.MVar.new : Task Never Int`, then `Task.map MVar` in
// Eco.MVar wraps the Int in the MVar constructor.)
HPtr Eco_Kernel_MVar_new();

// Read MVar (blocks until full). Returns value (boxed).
HPtr Eco_Kernel_MVar_read(uint64_t id);

// Take MVar (blocks until full, empties). Returns value (boxed).
HPtr Eco_Kernel_MVar_take(uint64_t id);

// Put value into MVar (blocks until empty). Returns Task Never ().
HPtr Eco_Kernel_MVar_put(uint64_t id, HPtr value);

// Per-instance variants for primitive value types. The kernel boxes the
// primitive into an ElmInt / ElmFloat / ElmChar before storing; the slot
// itself still holds an HPointer. These exist so the call site can keep the
// value unboxed in SSA and skip the eco_alloc_* boxing at the boundary.
HPtr Eco_Kernel_MVar_put_Int  (uint64_t id, int64_t  value);
HPtr Eco_Kernel_MVar_put_Float(uint64_t id, double   value);
HPtr Eco_Kernel_MVar_put_Char (uint64_t id, uint16_t value);

// Drop (destroy) an MVar. Returns Task Never ().
HPtr Eco_Kernel_MVar_drop(uint64_t id);

//===----------------------------------------------------------------------===//
// Runtime Module - Node.js specific and REPL state
//===----------------------------------------------------------------------===//

// Get directory of current script/binary. Returns String (boxed).
HPtr Eco_Kernel_Runtime_dirname();

// Get random Float. Returns Float (unboxed).
uint64_t Eco_Kernel_Runtime_random();

// Persist REPL state to runtime storage. Returns Task Never ().
HPtr Eco_Kernel_Runtime_saveState(HPtr state);

// Load persisted REPL state from runtime storage. Returns boxed value.
HPtr Eco_Kernel_Runtime_loadState();

//===----------------------------------------------------------------------===//
// GC root registration hooks. Must be called once per Elm thread, after
// Allocator::initThread() and before any Elm code runs.
//===----------------------------------------------------------------------===//

void Eco_Kernel_MVar_register_gc_roots();
void Eco_Kernel_Runtime_register_gc_roots();
void Eco_Kernel_register_all_gc_roots();

//===----------------------------------------------------------------------===//
// NativeDriver Module - in-process MLIR lowering + native linking
//===----------------------------------------------------------------------===//

// Lower MLIR file at `mlirPath` to ELF executable at `outputPath`. Returns
// Task Never () (succeeds with Unit on success, fails with a String error
// message otherwise). `rootModule` is the program's root module name, baked
// into the output as `__eco_root_module` so the N-API addon exposes
// `Elm.<RootModule>`. Only the unified `eco` binary has the strong
// `eco_native_lower_and_link` symbol linked in; other binaries (which only
// link the weak undefined reference) get a runtime "unavailable" error if
// this is invoked.
HPtr Eco_Kernel_NativeDriver_lowerAndLink(HPtr mlirPath, HPtr outputPath,
                                          HPtr rootModule);

// In-memory MLIR bytes variant. Phase 2 entry point that avoids the temp
// `.mlir` file on disk. `bytes` is an Elm `Bytes` value.
HPtr Eco_Kernel_NativeDriver_lowerAndLinkBytes(HPtr bytes, HPtr outputPath);

//===----------------------------------------------------------------------===//
// Http Module - HTTP requests and archive downloads
//===----------------------------------------------------------------------===//

// Fetch URL with method and headers. Returns Task Never (Result error String) (boxed).
// method and url are boxed Strings, headers is boxed List (String, String).
HPtr Eco_Kernel_Http_fetch(HPtr method, HPtr url, HPtr headers);

// Download and extract ZIP archive. Returns Task Never (Result String record) (boxed).
HPtr Eco_Kernel_Http_getArchive(HPtr url);

} // extern "C"

#endif // ECO_KERNEL_EXPORTS_H
