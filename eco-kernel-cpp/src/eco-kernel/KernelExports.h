//===- KernelExports.h - C-linkage exports of the Eco kernel functions ----===//
//
// Declarations of the eco kernel exports: the C-linkage functions through which compiled Elm code reaches the
// native implementations of the `Eco.*` modules (File, Console, Process, MVar and the rest).
//
// Each export is named `Eco_Kernel_<Module>_<function>`, after the kernel function `Eco.Kernel.<Module>.<function>`
// that Elm code calls, and is declared `extern "C"` so that the name is not mangled and generated code can be
// linked against it by that name.
//
// Every argument and result is one 64-bit word. An Int travels as an `int64_t` and a Float as a `double`; every
// other value is an `HPtr`, the encoded `HPointer` of a heap value or of an embedded constant. A Bool is one of the
// True and False constants, never a C `bool`. Three departures from the declared C types recur:
//
// - A parameter declared `HPtr` that stands for a handle (a file descriptor, a console handle, a process id) or an
//   open mode carries the Int itself; the export reads the word's bits as the integer.
// - An export declared to return `uint64_t` returns the same encoded Task word as one returning `HPtr`.
// - An MVar id arrives as a `uint64_t` holding the Int.
//
// Most exports return a Task, and calling one does none of its work. It captures its arguments and returns a Task
// whose work is done each time the scheduler runs it, as `Elm::Platform::makeBinding` describes. The comment on
// each export says what that Task succeeds with and how it fails. An IO failure is the IO error tuple
// `(tag, path, message)`: an Int classifying the error (derived from `errno` where there is one), the path concerned
// or an empty string, and a message. A few Tasks fail with a plain String instead, and each such comment says so.
// The exports that act when called, and return no Task, are `Crash.crash`, `Console.log`, `Process.exit`, the two
// Hash functions and the GC root hooks.
//
// This header also provides `ECO_KERNEL_GUARD`, which an export's definition may wrap around its body so that a C++
// exception becomes a fatal abort instead of unwinding out of a C-linkage function.
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

/// Reports an unrecoverable native fault and aborts the process.
///
/// It flushes stdout, writes `[eco-runtime] FATAL: ` followed by `what` (or `(null)` when `what` is null) to stderr,
/// and calls `std::abort`. It is for faults that cannot be delivered as a Task failure, such as a C++ exception that
/// has reached an export.
[[noreturn]] inline void reportFatal(const char* what) {
    std::fflush(stdout);
    std::fprintf(stderr, "\n[eco-runtime] FATAL: %s\n", what ? what : "(null)");
    std::fflush(stderr);
    std::abort();
}

} // namespace Kernel
} // namespace Eco

/// Runs `BODY` and turns any C++ exception that escapes it into `Eco::Kernel::reportFatal`, so that no exception
/// unwinds out of an `extern "C"` function, which is undefined behaviour.
///
/// A `std::bad_alloc` is reported as running out of memory, any other `std::exception` by its `what()`, and anything
/// else as an unknown native exception. The macro expands to a `try` statement, so `BODY` must contain its own
/// `return`: control never leaves the statement normally. `BODY` is a single macro argument, so a comma in it that is
/// not inside parentheses splits it.
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

/// Returns a Task that reads the file at `path` as UTF-8 text and succeeds with it as a String. It fails with the IO
/// error tuple when the file cannot be opened, sized or read.
HPtr Eco_Kernel_File_readString(HPtr path);

/// Returns a Task that creates or truncates the file at `path`, writes `content` to it as UTF-8, and succeeds with
/// Unit. It fails with the IO error tuple only when the file cannot be opened; an error while writing is not reported.
HPtr Eco_Kernel_File_writeString(HPtr path, HPtr content);

/// Returns a Task that reads the file at `path` and succeeds with its contents as Bytes. It fails with the IO error
/// tuple when the file cannot be opened, sized or read, or is too large for a Bytes value.
HPtr Eco_Kernel_File_readBytes(HPtr path);

/// Returns a Task that creates or truncates the file at `path`, writes `bytes` to it, and succeeds with Unit. It fails
/// with the IO error tuple only when the file cannot be opened; an error while writing is not reported.
HPtr Eco_Kernel_File_writeBytes(HPtr path, HPtr bytes);

/// Returns a Task that writes `bytes` to a new temporary file beside `path`, renames it over `path`, and succeeds with
/// Unit, so that the file at `path` is never seen partly written. It fails with the IO error tuple when the temporary
/// file cannot be created, written, closed or renamed, and then removes the temporary file.
HPtr Eco_Kernel_File_writeBytesAtomic(HPtr path, HPtr bytes);

/// Returns a Task that opens the file at `path` and succeeds with its file descriptor as an Int, the handle the other
/// handle functions take. `mode` is an Int: 0 opens for reading, 1 for writing (creating or truncating), 2 for
/// appending (creating), 3 for reading and writing (creating), and any other value for reading. It fails with the IO
/// error tuple when the file cannot be opened.
HPtr Eco_Kernel_File_open(HPtr path, HPtr mode);

/// Returns a Task that closes the file descriptor `handle` and succeeds with Unit. A failure to close is ignored.
HPtr Eco_Kernel_File_close(HPtr handle);

/// Returns a Task that succeeds with the size in bytes of the file open as descriptor `handle`, as an Int. It fails
/// with the IO error tuple when the size cannot be read.
uint64_t Eco_Kernel_File_size(HPtr handle);

/// Returns a Task that succeeds with Unit and does nothing else. No lock is taken.
HPtr Eco_Kernel_File_lock(HPtr path);

/// Returns a Task that succeeds with Unit and does nothing else. No lock is released.
HPtr Eco_Kernel_File_unlock(HPtr path);

/// Returns a Task that succeeds with True when `path` names a regular file, and with False otherwise, including when
/// it cannot be examined.
HPtr Eco_Kernel_File_fileExists(HPtr path);

/// Returns a Task that succeeds with True when `path` names a directory, and with False otherwise, including when it
/// cannot be examined.
HPtr Eco_Kernel_File_dirExists(HPtr path);

/// Returns a Task that searches the directories on `PATH` for an executable called `name`, and succeeds with
/// `Just` the first match's path, written with forward slashes, or with `Nothing`. It never fails.
///
/// On Windows `Path` is read when `PATH` is not set, and a match is any regular file named `name` with no suffix or
/// with `.exe`, `.cmd`, `.bat` or `.com`. Elsewhere a match is any path the process may execute, as `access` with
/// `X_OK` decides, so a searchable directory matches too. An empty `PATH` entry tests `name` against the current
/// directory.
HPtr Eco_Kernel_File_findExecutable(HPtr name);

/// Returns a Task that succeeds with the names of the entries in the directory `path`, as a List of Strings in no
/// particular order. It fails with the IO error tuple when the directory cannot be opened.
HPtr Eco_Kernel_File_list(HPtr path);

/// Returns a Task that succeeds with the modification time of the file at `path`, as an Int count of milliseconds
/// since the Unix epoch. On Windows the time is truncated to whole seconds. It fails with the IO error tuple when the
/// file cannot be examined.
uint64_t Eco_Kernel_File_modificationTime(HPtr path);

/// Returns a Task that succeeds with the current working directory, written with forward slashes. It fails with the IO
/// error tuple when the directory cannot be read.
HPtr Eco_Kernel_File_getCwd();

/// Returns a Task that makes `path` the current working directory of the process and succeeds with Unit. It fails
/// with the IO error tuple when the directory cannot be changed.
HPtr Eco_Kernel_File_setCwd(HPtr path);

/// Returns a Task that succeeds with `path` made absolute, with symbolic links resolved, and written with forward
/// slashes. When the path cannot be resolved, for example because it does not exist, it succeeds instead with `path`
/// made absolute and lexically normalised, without resolving links. It does not fail with an error value.
HPtr Eco_Kernel_File_canonicalize(HPtr path);

/// Returns a Task that succeeds with the path of the per-user data directory for the application `name`. The
/// directory is not created. The path is `$HOME/.<name>`, on macOS `$HOME/Library/Application Support/<name>`, and on
/// Windows `<name>` under `APPDATA`, else `USERPROFILE`, else `HOME`. It fails with a plain String when none of
/// those variables is set.
HPtr Eco_Kernel_File_appDataDir(HPtr name);

/// Returns a Task that creates the directory `path` and succeeds with Unit. When `createParents` is True any missing
/// parent directories are created too. A directory that already exists is not an error. It fails with the IO
/// error tuple when the directory cannot be created.
HPtr Eco_Kernel_File_createDir(HPtr createParents, HPtr path);

/// Returns a Task that removes the file at `path` and succeeds with Unit. It fails with the IO error tuple when the
/// file cannot be removed.
HPtr Eco_Kernel_File_removeFile(HPtr path);

/// Returns a Task that removes `path` and, if it is a directory, everything beneath it, and succeeds with Unit. A
/// path that does not exist is not an error. It fails with the IO error tuple when something cannot be removed.
HPtr Eco_Kernel_File_removeDir(HPtr path);

/// Returns a Task that writes `content` as UTF-8 to the file descriptor `handle` and succeeds with Unit. It makes one
/// write call, so a short write is not retried or reported. It fails with the IO error tuple when the write fails.
HPtr Eco_Kernel_File_hWriteString(HPtr handle, HPtr content);

/// Returns a Task that creates the file at `path` if it does not exist, sets its modification time to now, and
/// succeeds with Unit. It fails with the IO error tuple when the time cannot be set.
HPtr Eco_Kernel_File_touch(HPtr path);

//===----------------------------------------------------------------------===//
// Crash Module - unrecoverable errors
//===----------------------------------------------------------------------===//

/// Writes `Eco crash: ` and `message` to stderr, followed by a backtrace where the platform provides one, and exits
/// the process with status 1. It acts when called and does not return.
HPtr Eco_Kernel_Crash_crash(HPtr message);

//===----------------------------------------------------------------------===//
// Console Module - write to handles, read from stdin
//===----------------------------------------------------------------------===//

/// Returns a Task that writes `content` as UTF-8 to standard output when `handle` is 1, or standard error when it is
/// 2, and succeeds with Unit. For any other `handle` it writes nothing and succeeds. It fails with the IO error tuple
/// when a write fails.
HPtr Eco_Kernel_Console_write(HPtr handle, HPtr content);

/// Returns a Task that reads one line from standard input and succeeds with it, without the line break. At the end of
/// input it succeeds with an empty string; it never fails. The read blocks the thread running the Task.
HPtr Eco_Kernel_Console_readLine();

/// Returns a Task that reads standard input to its end and succeeds with the lines read, joined by `\n`, with no line
/// break after the last. Empty lines before the first non-empty line are dropped. It never fails. The read blocks the
/// thread running the Task.
HPtr Eco_Kernel_Console_readAll();

/// Returns a Task that succeeds with True when `handle` is 0, 1 or 2 and that standard stream is a terminal, and with
/// False otherwise.
HPtr Eco_Kernel_Console_isTerminal(HPtr handle);

/// Writes `tag` and a line break to standard error at once, and returns `value` unchanged. It is the Elm function
/// `String -> a -> a`, not a Task.
HPtr Eco_Kernel_Console_log(HPtr tag, HPtr value);

//===----------------------------------------------------------------------===//
// Env Module - environment variables and CLI args
//===----------------------------------------------------------------------===//

/// Returns a Task that succeeds with `Just` the value of the environment variable `name`, or `Nothing` when it is not
/// set.
HPtr Eco_Kernel_Env_lookup(HPtr name);

/// Returns a Task that succeeds with the program's command-line arguments, without the program name, as a List of
/// Strings. The arguments are those recorded by `Eco::Kernel::Env::init`, and the List is empty before it is called.
HPtr Eco_Kernel_Env_rawArgs();

//===----------------------------------------------------------------------===//
// Process Module - exit and external process management
//===----------------------------------------------------------------------===//

/// Exits the process with status `code`. It acts when called and does not return.
HPtr Eco_Kernel_Process_exit(int64_t code);

/// Returns a Task that starts the program `cmd` with the List of String arguments `args`, without a shell and sharing
/// this process's standard streams, and succeeds with the child's process id as an Int. It fails with the IO error
/// tuple, whose path is `cmd`, when the program cannot be started.
uint64_t Eco_Kernel_Process_spawn(HPtr cmd, HPtr args);

/// Returns a Task that starts the program `cmd` with arguments `args` like `Eco_Kernel_Process_spawn`, and succeeds
/// with a tuple `(stdinHandle, pid)`. `stdin_`, `stdout_` and `stderr_` are Strings. When `stdin_` is `"pipe"` the
/// child's standard input is a pipe and `stdinHandle` is `Just` the descriptor of its writing end, an Int; otherwise
/// standard input is shared and `stdinHandle` is `Nothing`. `stdout_` and `stderr_` are ignored, and those streams
/// are always shared. It fails with the IO error tuple when the program cannot be started.
HPtr Eco_Kernel_Process_spawnProcess(HPtr cmd, HPtr args,
    HPtr stdin_, HPtr stdout_, HPtr stderr_);

/// Returns a Task that waits for the child with process id `handle` to exit and succeeds with its exit code as an Int:
/// 128 plus the signal number when a signal ended it, and -1 when it could not be waited for. It never fails. The
/// waiting is done off the thread running the Task, which carries on with other work meanwhile.
uint64_t Eco_Kernel_Process_wait(HPtr handle);

//===----------------------------------------------------------------------===//
// MVar Module - concurrency primitives
//===----------------------------------------------------------------------===//

// An MVar is a slot that is either empty or holds one value. A Task that must wait for it to become full or empty
// parks: it is set aside, the scheduler goes on running other Tasks, and it resumes when another MVar Task changes
// the slot. The read, take and put functions return Tasks that fail with the IO error tuple, message
// `MVar not found: <id>`, when no MVar has that id when they are run.

/// Returns a Task that creates an empty MVar and succeeds with its id as an Int. Each run creates a new MVar.
HPtr Eco_Kernel_MVar_new();

/// Returns a Task that succeeds with the value held by MVar `id`, leaving it there, and parks while the MVar is
/// empty.
HPtr Eco_Kernel_MVar_read(uint64_t id);

/// Returns a Task that empties MVar `id` and succeeds with the value it held, and parks while the MVar is empty.
HPtr Eco_Kernel_MVar_take(uint64_t id);

/// Returns a Task that stores `value` in MVar `id` and succeeds with Unit, and parks while the MVar is full.
HPtr Eco_Kernel_MVar_put(uint64_t id, HPtr value);

// Each of these is `Eco_Kernel_MVar_put` for a value passed unboxed. It boxes the Int, Float or Char when called,
// because the MVar holds a heap value, and returns the Task `Eco_Kernel_MVar_put` returns for the box. `value_raw`
// holds a Char's code point in its low 32 bits; the upper bits are ignored.

/// Returns the Task of `Eco_Kernel_MVar_put` for the Int `value`, boxed.
HPtr Eco_Kernel_MVar_put_Int  (uint64_t id, int64_t  value);
/// Returns the Task of `Eco_Kernel_MVar_put` for the Float `value`, boxed.
HPtr Eco_Kernel_MVar_put_Float(uint64_t id, double   value);
/// Returns the Task of `Eco_Kernel_MVar_put` for the Char whose code point is the low 32 bits of `value_raw`, boxed.
HPtr Eco_Kernel_MVar_put_Char (uint64_t id, uint64_t value_raw);

/// Returns a Task that destroys MVar `id` and succeeds with Unit. Tasks parked on it are abandoned and never resume.
/// An id with no MVar is not an error.
HPtr Eco_Kernel_MVar_drop(uint64_t id);

//===----------------------------------------------------------------------===//
// Hash Module
//===----------------------------------------------------------------------===//

/// Returns the narrow hash of the String `str` from `seed`, computed when called and without allocating, as
/// `Eco::Kernel::Hash::stringWithSeed` describes. Note the argument order: `seed` comes first here and last there.
int64_t Eco_Kernel_Hash_stringWithSeed(int64_t seed, HPtr str);

/// Returns the full 64-bit hash of the String `str` from `seed`, computed when called and without allocating, as
/// `Eco::Kernel::Hash::string64` describes. `seed` comes first here and last there.
int64_t Eco_Kernel_Hash_string64(int64_t seed, HPtr str);

//===----------------------------------------------------------------------===//
// Runtime Module - executable directory, random numbers and saved state
//===----------------------------------------------------------------------===//

/// Returns a Task that succeeds with the directory containing the running executable. It fails with a plain String
/// when that directory cannot be determined.
HPtr Eco_Kernel_Runtime_dirname();

/// Returns a Task that succeeds with a random Float in [0, 1), drawing a new one each time it is run.
uint64_t Eco_Kernel_Runtime_random();

/// Returns a Task that keeps `state` as the saved state, replacing any earlier one, and succeeds with Unit. The saved
/// value lives in this process's memory only and is kept alive across collections by the scanner that
/// `Eco_Kernel_Runtime_register_gc_roots` registers.
HPtr Eco_Kernel_Runtime_saveState(HPtr state);

/// Returns a Task that succeeds with the value last saved by `Eco_Kernel_Runtime_saveState`, itself and not wrapped
/// in a `Maybe`, or with the `Nothing` constant when nothing has been saved.
HPtr Eco_Kernel_Runtime_loadState();

//===----------------------------------------------------------------------===//
// GC Module - explicit collections
//===----------------------------------------------------------------------===//

// The two Tasks collect when they are run, never when these functions are called, and allocate their result only
// after the collection. The String each succeeds with is a JSON object reporting the collection: its kind
// (`"minor"` or `"major"`), timings in nanoseconds, memory sizes in bytes before and after, the old generation's
// high-water mark, collection counters and the result of the trim, or `{"kind":"error"}` if the report could not be
// formatted.

/// Returns a Task that runs a minor collection and succeeds with its report.
HPtr Eco_Kernel_GC_minorGC();

/// Returns a Task that runs a major collection that also returns freed memory to the operating system
/// (`Elm::Allocator::collectMajorAndRelease`), and succeeds with its report.
HPtr Eco_Kernel_GC_majorGC();

//===----------------------------------------------------------------------===//
// GC root registration hooks. Call each hook, or
// Eco_Kernel_register_all_gc_roots instead of them, once, after the allocator
// is initialised.
//===----------------------------------------------------------------------===//

// Each hook adds a root scanner to the allocator's root set, so that the values a module keeps outside the heap's
// reach survive collections. A hook called twice adds its scanner twice.

/// Registers the scanner for the values held in MVars and carried by Tasks parked to put one.
void Eco_Kernel_MVar_register_gc_roots();
/// Registers the scanner for the state kept by `Eco_Kernel_Runtime_saveState`.
void Eco_Kernel_Runtime_register_gc_roots();
/// Calls the MVar and Runtime hooks, and also elm-kernel-cpp's hook for the Order values when that is linked in.
void Eco_Kernel_register_all_gc_roots();

//===----------------------------------------------------------------------===//
// NativeDriver Module - in-process MLIR lowering + native linking
//===----------------------------------------------------------------------===//

// Lowering and linking are done by `eco_native_lower_and_link` and `eco_native_lower_and_link_bytes`, which are
// linked into the program from outside this package. A program that does not link the real ones gets stand-ins that
// return -1, so the Tasks below fail with the message for code -1 instead of doing any work. The work runs on the
// thread running the Task, and blocks it until the driver returns.

/// Returns a Task that lowers the MLIR file at `mlirPath` to a native executable at `outputPath` and succeeds with
/// Unit. `rootModule` is the name of the program's root module, passed to the driver. It fails with a plain String,
/// `lowering/linking failed (rc=<code>)` after a prefix naming the function, when the driver returns non-zero.
HPtr Eco_Kernel_NativeDriver_lowerAndLink(HPtr mlirPath, HPtr outputPath,
                                          HPtr rootModule);

/// Returns a Task like `Eco_Kernel_NativeDriver_lowerAndLink`, except that the MLIR is the contents of the Bytes
/// value `bytes` instead of a file, and no root module name is passed.
HPtr Eco_Kernel_NativeDriver_lowerAndLinkBytes(HPtr bytes, HPtr outputPath);

//===----------------------------------------------------------------------===//
// Http Module - HTTP requests and archive downloads
//===----------------------------------------------------------------------===//

/// Returns a Task that sends an HTTP request with the String `method` to the String `url` with `headers`, a List of
/// (name, value) String tuples, and succeeds with a `Result`. It never fails. The `Result` is `Ok` the response body
/// as a String for a 2xx status, and otherwise `Err (status, statusText)`, an Int and a String, where an empty status
/// text is replaced by `HTTP <status>`. A request that got no response has status 0 and a message as `statusText`.
/// The thread running the Task carries on with other work while the request is in flight.
HPtr Eco_Kernel_Http_fetch(HPtr method, HPtr url, HPtr headers);

/// Returns a Task that downloads the ZIP archive at `url` and succeeds with a `Result`. It never fails. The `Result` is
/// `Ok (sha, entries)`, where `sha` is the lowercase hex SHA-1 of the body and `entries` is a List of
/// `(relativePath, content)` String tuples, or `Err` a String message when the transfer or the archive fails. The HTTP
/// status is not checked: the body of any response is hashed and opened as an archive. A directory entry has empty
/// content, an entry that cannot be opened is left out, and an entry read short keeps its full length, padded with
/// zero bytes.
HPtr Eco_Kernel_Http_getArchive(HPtr url);

} // extern "C"

#endif // ECO_KERNEL_EXPORTS_H
