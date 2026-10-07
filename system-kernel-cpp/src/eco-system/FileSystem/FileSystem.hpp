//===- FileSystem.hpp - eco/system kernel module FileSystem (internal) ----===//
//
// plans/eco-system-library.md Appendix B.3 / E.3. Layout of the module:
//
//   FileSystemExports.cpp   C exports: decode, root, pack, bind (G2).
//   FileSystem.cpp          binding bodies: the generic pool body (T2), the
//                           completion that builds results (T3/T4), the four
//                           S-mode directory getters, the open-handle table.
//   FileSystemOps.cpp       the POSIX worker operations (POD only, G1).
//   FileSystemOpsWin32.cpp  Windows: every operation fails with ENOTSUP (§1).
//   FileSystemManager.*     the `System.File` effect manager (C.2).
//   WatchService.*          the watcher thread (inotify / 1 s polling).
//
// Payload of every P-mode kernel (packFsArgs): one nested tuple
//     tuple2( boxed tuple2( s1, s2 ), boxed tuple3( Int i0, Int i1, Int i2 ) )
// with masks 0 / 0 / 0x15. s1 is usually the path; s2 a second path, the
// open flags, or the Bytes to write. Unused slots are "" / 0.
//
// Templates used: T1, T2, T3, T4.
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

// The decoded payload (worker side: POD only, G1).
struct FsArgs {
    std::string s1;
    std::string s2;
    int64_t i0 = 0;
    int64_t i1 = 0;
    int64_t i2 = 0;
};

// The result of one operation (POD only, G1).
struct FsRes {
    enum class Kind : uint8_t { Unit, Int, Str, Bytes, Ints, Dir, ReadStream, WriteStream };
    Kind kind = Kind::Unit;

    // Failure: `err` (an errno) or a non-errno `code` such as "ERR_FS_EISDIR".
    int err = 0;
    std::string code;
    std::string message;        // only with `code`
    const char* syscall = "";   // for the node-style message
    std::string path;           // ditto ("" for handle operations)

    int64_t n = 0;              // Int; the fd of a stream
    int64_t readLimit = -1;     // ReadStream: FdChannelOptions::readLimit
    bool truncateOnClose = false;   // WriteStream: FdChannelOptions::truncateOnClose
    std::string data;           // Str / Bytes
    std::vector<int64_t> ints;  // Ints (metadata, B.3 stat)
    std::vector<std::pair<std::string, int64_t>> entries;   // Dir

    static FsRes fail(int e, const char* sc, std::string p = std::string()) {
        FsRes r;
        r.err = e;
        r.syscall = sc;
        r.path = std::move(p);
        return r;
    }
};

// A worker operation (runs on a SysWorkPool thread; no heap, no Elm, G1).
using FsOp = FsRes (*)(const FsArgs&);

// --- Worker operations (FileSystemOps.cpp / FileSystemOpsWin32.cpp) ---------
// Argument use is noted as (s1, s2, i0, i1, i2).
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

// --- Directory getters (S mode; main thread, no heap) -----------------------
std::string homeDirectoryString();
std::string currentWorkingDirectoryString();
std::string tmpDirectoryString();
std::string devNullString();

// --- Export side (FileSystem.cpp) -------------------------------------------

// Packs the payload described above. `s1`/`s2` are encoded String/Bytes
// words or 0 for "" (the empty constant). Roots its own temporaries.
HPointer packFsArgs(uint64_t s1, uint64_t s2, int64_t i0 = 0, int64_t i1 = 0, int64_t i2 = 0);

// Which payload slots need special handling in the body.
enum class FsKind : uint8_t {
    Path,       // s1 is a String; s2 (if used) a String
    PathBytes,  // s1 String, s2 Bytes
    Handle,     // i0 is an fd that must be open (EBADF otherwise)
    HandleBytes,// as Handle, s2 Bytes
    Close,      // as Handle, and the fd leaves the open-handle table
    Open,       // the result fd enters the open-handle table
    TempDir,    // s1 is the prefix; the body prepends the tmp directory (E.3)
};

// The generic P-mode body (T2): copy the payload out (G3), register the
// resume, count, submit `op` to the pool.
HPointer fsPoolSubmit(FsOp op, FsKind kind, HPointer captured, HPointer resume);

template <FsOp Op, FsKind K>
HPointer fsPoolBody(HPointer captured, HPointer resume) {
    return fsPoolSubmit(Op, K, captured, resume);
}

// S-mode bodies of the directory getters (T1).
HPointer fsHomeDirectoryBody(HPointer captured);
HPointer fsCurrentWorkingDirectoryBody(HPointer captured);
HPointer fsTmpDirectoryBody(HPointer captured);
HPointer fsDevNullBody(HPointer captured);

} // namespace Eco::System::Fs

#endif // ECO_SYSTEM_FILESYSTEM_FILESYSTEM_HPP
