//===- FileSystem.hpp - eco/system kernel module FileSystem (internal) ----===//
//
// The `Eco.Kernel.FileSystem` kernels must do blocking file system calls without blocking the eco thread, the
// thread that runs the Elm scheduler, and this header is the internal surface that lets them.
//
// Almost every kernel is a P-mode kernel: its Task is an async binding (`makeAsyncBinding`) whose body copies
// its payload out of the Elm heap into plain C++ data, parks the task's resume closure, and submits one
// worker operation to `SysWorkPool`. The operation runs on a worker thread, where it may not touch the Elm heap
// or call Elm, so it takes an `FsArgs` and returns an `FsRes`, both plain C++ data. Back on the eco thread, a
// completion turns the `FsRes` into the Task that resumes the task. One generic body, `fsPoolSubmit`, serves
// every P-mode kernel; what differs between kernels is the worker operation and an `FsKind`.
//
// The four directory getters are S-mode kernels instead: their Task is a synchronous binding (`makeBinding`)
// whose body computes the answer on the eco thread and cannot fail; a C++ exception in the body ends the
// process.
//
// A failing operation fails its Task with an FErr, `( code, message )`, as `Eco::System::failFErr` builds it.
// The code is usually the errno's name, and the message is usually in node's style:
// "ENOENT: no such file or directory, open '/x'".
//
// The payload of every P-mode kernel, built by `packFsArgs`, is one Elm value:
//     tuple2( boxed tuple2( s1, s2 ), boxed tuple3( Int i0, Int i1, Int i2 ) )
// `s1` is usually the path, and `s2` a second path, the open flags, or the Bytes to write. A slot an operation
// does not use holds "" or 0. Each worker operation's declaration below lists the slots it reads.
//
// FileHandle operations name a file by its fd. The open-handle table, kept in FileSystem.cpp on the eco
// thread, holds the fds that `open` returned and `close` has not yet removed. An operation on a handle whose
// fd is not in the table fails with EBADF without reaching the worker. So a handle cannot act on an fd that
// this module's `open` did not return or that has been closed, unless a later `open` has returned the same
// number.
//
// The worker operations are defined in FileSystemOps.cpp, and on Windows in FileSystemOpsWin32.cpp, where
// every one fails with ENOTSUP. The `C` exports are in FileSystemExports.cpp, and the `FileSystem` effect
// manager and the watcher are separate components (FileSystemManager, WatchService).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_FILESYSTEM_FILESYSTEM_HPP
#define ECO_SYSTEM_FILESYSTEM_FILESYSTEM_HPP

#include "eco-system/Core/Core.hpp"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System::Fs {

/// The payload of a P-mode kernel copied out of the Elm heap, as a worker operation reads it.
///
/// The slots are those of the payload described in the file comment. `s2` holds the raw bytes when the
/// kernel's second string slot is Bytes, and text otherwise.
struct FsArgs {
    std::string s1;
    std::string s2;
    int64_t i0 = 0;
    int64_t i1 = 0;
    int64_t i2 = 0;
};

/// The outcome of one worker operation: either a failure or a value of one of the kinds in `Kind`.
///
/// The result is a failure when `err` is not 0 or `code` is not empty, and `kind` is then ignored. Otherwise
/// `kind` says which of the value members hold the result. This is a convention of plain data that nothing
/// enforces.
struct FsRes {
    /// What a successful result carries, and so what Elm value its Task succeeds with. `Ints` gives a
    /// `List Int`, `Dir` a `List ( String, Int )`, and `ReadStream` and `WriteStream` the Int id of a new
    /// stream on the opened fd.
    enum class Kind : uint8_t { Unit, Int, Str, Bytes, Ints, Dir, ReadStream, WriteStream };
    Kind kind = Kind::Unit;

    // Failure: `err` (an errno) or a non-errno `code` such as "ERR_FS_EISDIR".
    int err = 0;
    std::string code;
    std::string message;        ///< The FErr message, used only when `code` is set.
    /// The name of the failing call, used in the message built for `err`. Must point to storage that lives
    /// until the result is completed, such as a string literal.
    const char* syscall = "";
    std::string path;           ///< The path quoted in the message built for `err` when `syscall` is not empty.
                                ///< "" quotes none.

    int64_t n = 0;              ///< The value for `Int`; the opened fd for `ReadStream` and `WriteStream`.
    int64_t readLimit = -1;     ///< `ReadStream`: the channel's `FdChannelOptions::readLimit`.
    bool truncateOnClose = false;   ///< `WriteStream`: the channel's `FdChannelOptions::truncateOnClose`.
    bool syncOnClose = false;       ///< `WriteStream`: the channel's `FdChannelOptions::syncOnClose`.
    std::string data;           ///< The value for `Str` (UTF-8 text) and `Bytes` (raw bytes).
    std::vector<int64_t> ints;  ///< The value for `Ints`.
    std::vector<std::pair<std::string, int64_t>> entries;   ///< The value for `Dir`: each entry's name and Int.

    /// Returns a failure for errno `e` from the call named `sc`, quoting path `p`. `sc` is kept, so it must
    /// live as long as the result, as a string literal does.
    static FsRes fail(int e, const char* sc, std::string p = std::string()) {
        FsRes r;
        r.err = e;
        r.syscall = sc;
        r.path = std::move(p);
        return r;
    }
};

/// A worker operation: a function that performs one file system call on a `SysWorkPool` worker thread and
/// returns its outcome. It must not touch the Elm heap or call Elm.
using FsOp = FsRes (*)(const FsArgs&);

// --- Worker operations ------------------------------------------------------
// Each performs the operation its name gives, on a worker thread. The trailing comment lists what it reads from
// the slots (s1, s2, i0, i1, i2); "-" is a slot it does not read.
FsRes opStat(const FsArgs&);             // (path, -, resolveLink)
FsRes opAccess(const FsArgs&);           // (path, -, mode)
FsRes opChmod(const FsArgs&);            // (path, -, mode)
FsRes opChown(const FsArgs&);            // (path, -, resolveLink, uid, gid)
FsRes opUtimes(const FsArgs&);           // (path, -, resolveLink, atime, mtime)
FsRes opRename(const FsArgs&);           // (from, to)
FsRes opRealpath(const FsArgs&);         // (path)
FsRes opCopyFile(const FsArgs&);         // (src, dest)
FsRes opAppendFile(const FsArgs&);       // (path, bytes)
FsRes opReadFile(const FsArgs&);         // (path)
FsRes opWriteFile(const FsArgs&);        // (path, bytes)
FsRes opTruncate(const FsArgs&);         // (path, -, length)
FsRes opRemove(const FsArgs&);           // (path, -, recursive)
FsRes opListDirectory(const FsArgs&);    // (path)
FsRes opMakeDirectory(const FsArgs&);    // (path, -, recursive)
FsRes opMakeTempDirectory(const FsArgs&);// (tmpDir/prefix, without the XXXXXX)
FsRes opLink(const FsArgs&);             // (src, dest)
FsRes opSymlink(const FsArgs&);          // (src, dest)
FsRes opReadLink(const FsArgs&);         // (path)
FsRes opUnlink(const FsArgs&);           // (path)
FsRes opOpen(const FsArgs&);             // (path, flags)
FsRes opClose(const FsArgs&);            // (-, -, fd)
FsRes opFstat(const FsArgs&);            // (-, -, fd)
FsRes opFchmod(const FsArgs&);           // (-, -, fd, mode)
FsRes opFchown(const FsArgs&);           // (-, -, fd, uid, gid)
FsRes opFutimes(const FsArgs&);          // (-, -, fd, atime, mtime)
FsRes opReadFromOffset(const FsArgs&);   // (-, -, fd, offset, length)
FsRes opWriteFromOffset(const FsArgs&);  // (-, bytes, fd, offset)
FsRes opFtruncate(const FsArgs&);        // (-, -, fd, length)
FsRes opFsync(const FsArgs&);            // (-, -, fd)
FsRes opFdatasync(const FsArgs&);        // (-, -, fd)
FsRes opReadFileStream(const FsArgs&);   // (path, -, start, endInclusive | -1)
FsRes opWriteFileStream(const FsArgs&);  // (path, -, mode, position)

// --- Directory getters -------------------------------------------------------
// They do not touch the Elm heap. They read the environment, and `homeDirectoryString` may call `getpwuid`,
// whose result is static storage, so they must be called on the eco thread.

/// Returns the user's home directory: `HOME` when set and not empty, then on Windows `USERPROFILE`, and
/// elsewhere the password database's entry for the real user. Returns "" when none gives one.
std::string homeDirectoryString();
/// Returns the current working directory, or "." if it cannot be read.
std::string currentWorkingDirectoryString();
/// Returns the first of `TMPDIR`, `TMP` and `TEMP` that is set and not empty, without trailing '/'
/// characters (but "/" stays), or else "/tmp", or "C:/Windows/Temp" on Windows.
std::string tmpDirectoryString();
/// Returns the path of the null device: "/dev/null", or "//./nul" on Windows.
std::string devNullString();

// --- Export side -------------------------------------------------------------

/// Builds the payload described in the file comment. `s1` and `s2` are encoded String or Bytes words, or 0
/// for a slot that is unused, which then holds the empty-string constant. Allocates on the Elm heap and roots
/// its own temporaries; eco thread only.
HPointer packFsArgs(uint64_t s1, uint64_t s2, int64_t i0 = 0, int64_t i1 = 0, int64_t i2 = 0);

/// How `fsPoolSubmit` treats a kernel's payload and result beyond submitting its operation: how `s2` is copied
/// out, whether `i0` is a FileHandle fd checked against the open-handle table, and what is done to the table.
enum class FsKind : uint8_t {
    Path,       ///< `s1` is a String, and `s2`, if used, a String.
    PathBytes,  ///< `s1` is a String and `s2` Bytes.
    Handle,     ///< `i0` is an fd that must be in the open-handle table, or the Task fails with EBADF.
    HandleBytes,///< As `Handle`, and `s2` is Bytes.
    Close,      ///< As `Handle`, and the fd leaves the table before the operation runs.
    Open,       ///< On success, the fd in the result enters the table.
    TempDir,    ///< `s1` is a name prefix, to which the temporary directory is prepended.
};

/// Starts worker operation `op` on the payload `captured`, and arranges for `resume` to be called with its
/// result Task on the eco thread. This is the body of every P-mode kernel's async binding, called on the eco
/// thread when the Task runs.
///
/// The payload is copied out according to `kind` before anything else. For a `Handle`, `HandleBytes` or
/// `Close` kind whose fd is not in the open-handle table, `resume` is called at once with the FErr
/// `( "EBADF", "EBADF: bad file descriptor" )` and nothing is submitted. A `Close` removes the fd from the
/// table before the close is submitted, so the handle is unusable afterwards even if the close fails. For
/// `TempDir`, `s1` is prefixed with `tmpDirectoryString()` and a '/', which is left out when that directory
/// ends in one.
///
/// Otherwise, unless an exception is thrown first, the resume is parked with a Task hold and `op` is submitted with
/// `SysWorkPool::submit`, whose drain completes the task with the Task built from the `FsRes`. For an `Open`
/// that succeeds, the new fd enters the table at that point. A C++ exception thrown here becomes an FErr
/// failure, through `ECO_SYSTEM_ASYNC_GUARD`.
///
/// Returns `()` as the kill handle, so killing the task does not withdraw the operation.
HPointer fsPoolSubmit(FsOp op, FsKind kind, HPointer captured, HPointer resume);

/// Calls `fsPoolSubmit` with `Op` and `K`. Being a template, it gives each kernel a distinct function to pass
/// to `makeAsyncBinding` as a template argument.
template <FsOp Op, FsKind K>
HPointer fsPoolBody(HPointer captured, HPointer resume) {
    return fsPoolSubmit(Op, K, captured, resume);
}

// The synchronous binding bodies of the directory getters. Each ignores its captured value and returns a Task
// that succeeds with the String its getter above returns, on the eco thread.

/// Returns a Task that succeeds with `homeDirectoryString()`.
HPointer fsHomeDirectoryBody(HPointer captured);
/// Returns a Task that succeeds with `currentWorkingDirectoryString()`.
HPointer fsCurrentWorkingDirectoryBody(HPointer captured);
/// Returns a Task that succeeds with `tmpDirectoryString()`.
HPointer fsTmpDirectoryBody(HPointer captured);
/// Returns a Task that succeeds with `devNullString()`.
HPointer fsDevNullBody(HPointer captured);

} // namespace Eco::System::Fs

#endif // ECO_SYSTEM_FILESYSTEM_FILESYSTEM_HPP
