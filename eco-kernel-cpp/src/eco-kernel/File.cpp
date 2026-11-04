//===- File.cpp - File kernel module implementation -----------------------===//
//
// Each operation is split in two. The IO is in a binding body, `<name>Body` in the anonymous namespace, which the
// scheduler calls each time it steps the Task. The public function only packs its arguments into one captured value
// and makes the binding around the body.
//
// The captured value is packed by a fixed convention, which each body unpacks to match:
//   * One boxed argument: the argument's HPointer itself.
//   * One Int argument: `tuple2(unboxedInt(i), unit, 0x1)`. Slot 1 holds Unit only to fill the pair.
//   * Two boxed arguments: `tuple2(boxed(a), boxed(b), 0)`.
//   * A boxed argument then an Int: `tuple2(boxed(a), unboxedInt(i), 0x4)`.
//   * An Int then a boxed argument: `tuple2(unboxedInt(i), boxed(b), 0x1)`.
// A mask gives each slot a 2-bit kind, slot 0 in the low bits, and kind 1 is an unboxed Int; so 0x1 marks slot 0
// and 0x4 marks slot 1.
//
//===----------------------------------------------------------------------===//

#include "File.hpp"
#include "KernelDebug.hpp"
#include "KernelHelpers.hpp"
#include "Process.hpp"
#include "TaskBinding.hpp"
#include <atomic>
#include <cerrno>
#include <chrono>
#include <thread>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <fcntl.h>     // _O_RDONLY etc. aliases
#include <io.h>        // _open, _read, _write, _close, _fileno
#include <sys/stat.h>
#include <sys/utime.h> // _utime
#include <process.h>   // _getpid
/// The function that returns the id of the current process.
#define ECO_GETPID _getpid
namespace {
/// The character that separates directories in `PATH` on Windows.
constexpr char kPathListSep = ';';
// The `_eco_*` wrappers give the bodies one spelling of the descriptor calls on both platforms. On Windows they
// call the underscore-prefixed CRT functions.
/// Opens `p` as `open` does, always in binary mode, and returns the descriptor or -1.
inline int _eco_open (const char* p, int flags, int mode) { return ::_open(p, flags | _O_BINARY, mode); }
/// Closes `fd` and returns 0, or -1 on failure.
inline int _eco_close(int fd)                              { return ::_close(fd); }
/// Writes up to `n` bytes from `b` to `fd`, at most `INT_MAX` in one call, and returns the count written or -1.
inline int _eco_write(int fd, const void* b, size_t n)     {
    return ::_write(fd, b, n > 0x7fffffff ? 0x7fffffff : (unsigned int)n);
}
/// Reads up to `n` bytes from `fd` into `b`, at most `INT_MAX` in one call, and returns the count read or -1.
inline int _eco_read (int fd, void* b, size_t n)           {
    return ::_read(fd, b, n > 0x7fffffff ? 0x7fffffff : (unsigned int)n);
}
}
#else
#include <dirent.h>
#include <fcntl.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>
/// The function that returns the id of the current process.
#define ECO_GETPID getpid
namespace {
/// The character that separates directories in `PATH` on POSIX systems.
constexpr char kPathListSep = ':';
// The `_eco_*` wrappers call the POSIX functions of the same name, with the same results.
inline int     _eco_open (const char* p, int flags, int mode) { return ::open(p, flags, mode); }
inline int     _eco_close(int fd)                              { return ::close(fd); }
inline ssize_t _eco_write(int fd, const void* b, size_t n)     { return ::write(fd, b, n); }
inline ssize_t _eco_read (int fd, void* b, size_t n)           { return ::read(fd, b, n); }
}
#endif

namespace Eco::Kernel::File {

namespace {

/// Returns the pair a two-slot captured value refers to. The pointer is valid only until the next allocation.
inline Tuple2* asTuple2(HPointer captured) {
    return static_cast<Tuple2*>(Elm::Allocator::instance().resolve(captured));
}

/// The largest file `readWholeFile` reads, in bytes. A ByteBuffer's `header.size` is a u32, and so is the length of
/// the String view `readString` makes over one.
constexpr uint64_t kMaxWholeFileSize = UINT32_MAX;

/// Returns whether the `st_mode` value `mode` is that of a directory. Spelled with `S_IFMT`, which MSVC has and
/// `S_ISDIR` it does not.
inline bool modeIsDirectory(unsigned mode) { return (mode & S_IFMT) == S_IFDIR; }
/// Returns whether the `st_mode` value `mode` is that of a regular file, as `modeIsDirectory` spells it.
inline bool modeIsRegular(unsigned mode) { return (mode & S_IFMT) == S_IFREG; }

/// Reads from `fd` into `buf` until `n` bytes are read or the file ends, retrying a read that `EINTR` interrupts.
/// Returns the count read, which is less than `n` only at the end of the file, or -1 with `errno` set.
int64_t readUpTo(int fd, uint8_t* buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        auto got = _eco_read(fd, buf + off, n - off);
        if (got < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (got == 0) break;
        off += static_cast<size_t>(got);
    }
    return static_cast<int64_t>(off);
}

/// The contents of a whole file, as `readWholeFile` reads them.
struct WholeFile {
    /// Whether the read succeeded. When it did not, `failure` is the Task to return.
    bool ok;
    /// A Task that fails with the IO error tuple, set when `ok` is false.
    HPointer failure;
    /// The file's bytes in a new heap ByteBuffer, set when `ok` is true and `size` is not 0. Its `bytes` and `hp`
    /// are valid only until the next heap allocation.
    Elm::alloc::BlankByteBuffer buffer;
    /// The number of bytes read.
    size_t size;
};

/// Returns a failed `WholeFile` whose Task fails with the IO error tuple for the `errno` value `err`, or `EIO` when
/// `err` is 0, after closing `fd`. A GC point.
WholeFile wholeFileFailure(int fd, int err, const std::string& path, const std::string& message) {
    _eco_close(fd);
    return WholeFile{false, failErrno(err ? err : EIO, path, message), {}, 0};
}

/// Reads the rest of `fd` to its end, after the bytes already in `data`, closes it, and returns the whole as a
/// `WholeFile`. Used for a file whose size is not known in advance: one that is not regular, such as a pipe, or
/// that reports size 0 or more bytes than it holds, as procfs and sysfs files do. `what` names the result type
/// for the too-large message. A GC point.
WholeFile readToEnd(int fd, const std::string& path, const char* what, std::vector<uint8_t> data) {
    constexpr size_t kChunk = 64 * 1024;
    for (;;) {
        size_t off = data.size();
        if (off > kMaxWholeFileSize) {
            return wholeFileFailure(fd, EFBIG, path, std::string("file too large for ") + what);
        }
        data.resize(off + kChunk);
        int64_t got = readUpTo(fd, data.data() + off, kChunk);
        if (got < 0) {
            int err = errno;
            return wholeFileFailure(fd, err, path, "could not read file contents");
        }
        data.resize(off + static_cast<size_t>(got));
        if (static_cast<size_t>(got) < kChunk) break;
    }
    _eco_close(fd);
    if (data.size() > kMaxWholeFileSize) {
        return WholeFile{false, failErrno(EFBIG, path, std::string("file too large for ") + what), {}, 0};
    }
    if (data.empty()) {
        return WholeFile{true, {}, {}, 0};
    }
    Elm::alloc::BlankByteBuffer bb = Elm::alloc::allocByteBufferBlank(data.size());
    std::memcpy(bb.bytes, data.data(), data.size());
    return WholeFile{true, {}, bb, data.size()};
}

/// Reads the whole file `path` into a new heap ByteBuffer, for `readString` and `readBytes`. `what` names the
/// result type for the too-large message. A GC point.
///
/// The file is opened and `fstat`-ed before anything is allocated. A directory fails with `EISDIR`, and a file
/// larger than `kMaxWholeFileSize` with `EFBIG`, which `readBytes` reports as too large for Bytes and `readString`
/// as too large for String. A regular file of known size is read straight into a ByteBuffer of that size; any other
/// file is read to its end (`readToEnd`). Every failure carries the `errno` value of the call that failed, or `EIO`
/// when that left `errno` at 0.
WholeFile readWholeFile(const std::string& path, const char* what) {
    int fd = _eco_open(path.c_str(), O_RDONLY, 0);
    if (fd < 0) {
        int err = errno;
        ECO_KLOG("file", "read fail path=%s errno=%d msg=%s", path.c_str(), err, std::strerror(err));
        return WholeFile{false, failErrno(err ? err : EIO, path, "could not open file for reading"), {}, 0};
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int err = errno;
        return wholeFileFailure(fd, err, path, "could not size file for reading");
    }
    if (modeIsDirectory(st.st_mode)) {
        return wholeFileFailure(fd, EISDIR, path, "is a directory");
    }
    if (!modeIsRegular(st.st_mode) || st.st_size <= 0) {
        return readToEnd(fd, path, what, {});
    }
    if (static_cast<uint64_t>(st.st_size) > kMaxWholeFileSize) {
        return wholeFileFailure(fd, EFBIG, path, std::string("file too large for ") + what);
    }
    size_t size = static_cast<size_t>(st.st_size);
    // Nothing allocates on the heap between allocByteBufferBlank and the return, so bb.bytes stays valid for the
    // read and bb.hp is current when the caller takes it.
    Elm::alloc::BlankByteBuffer bb = Elm::alloc::allocByteBufferBlank(size);
    int64_t got = readUpTo(fd, bb.bytes, size);
    if (got < 0) {
        int err = errno;
        ECO_KLOG("file", "read short-read path=%s errno=%d", path.c_str(), err);
        return wholeFileFailure(fd, err, path, "could not read file contents");
    }
    if (static_cast<size_t>(got) < size) {
        // The file holds less than it reported: keep what was read (copied off the heap, since the buffer is
        // abandoned) and read on to the end.
        return readToEnd(fd, path, what, std::vector<uint8_t>(bb.bytes, bb.bytes + got));
    }
    _eco_close(fd);
    return WholeFile{true, {}, bb, size};
}

// --- 1-arg-HPointer bodies ----------------------------------------------------

/// Reads the file named by the String `captured` and returns a Task that succeeds with its text or fails, as
/// `readWholeFile` describes.
HPointer readStringBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "readString start path=%s", pathStr.c_str());
    WholeFile f = readWholeFile(pathStr, "String");
    if (!f.ok) {
        return f.failure;
    }
    ECO_KLOG("file", "readString done path=%s size=%zu", pathStr.c_str(), f.size);
    if (f.size == 0) {
        return succeedString(std::string());
    }
    // Nothing allocates between readWholeFile's allocation and makeUtf8View, so f.buffer stays valid until then;
    // makeUtf8View roots the buffer across its own allocation.
    // All-ASCII content, with UTF-8 strings enabled, becomes a String that is a view over the buffer, with no copy.
    // Anything else is copied out and converted to an ordinary String.
    if (Elm::Allocator::instance().getConfig().utf8_strings_enabled &&
        Elm::Utf8::allAscii(f.buffer.bytes, f.size)) {
        return succeed(Elm::StringOps::makeUtf8View(f.buffer.hp, 0, static_cast<Elm::u32>(f.size)));
    }
    return succeedString(
        std::string(reinterpret_cast<const char*>(f.buffer.bytes), f.size));
}

/// Reads the file named by the String `captured` and returns a Task that succeeds with its Bytes or fails, as
/// `readWholeFile` describes.
HPointer readBytesBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "readBytes start path=%s", pathStr.c_str());
    WholeFile f = readWholeFile(pathStr, "Bytes");
    if (!f.ok) {
        return f.failure;
    }
    ECO_KLOG("file", "readBytes done path=%s size=%zu", pathStr.c_str(), f.size);
    if (f.size == 0) {
        return succeed(Elm::alloc::emptyBytes());
    }
    // f.buffer.hp is current: nothing has allocated since readWholeFile made it.
    return succeed(f.buffer.hp);
}

/// Returns a Task that succeeds with whether the String `captured` names a regular file.
HPointer fileExistsBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    std::error_code ec;
    bool exists = std::filesystem::is_regular_file(pathStr, ec);
    ECO_KLOG("file", "fileExists path=%s result=%d",
             pathStr.c_str(), (int)exists);
    return succeedBool(exists);
}

/// Returns a Task that succeeds with whether the String `captured` names a directory.
HPointer dirExistsBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    std::error_code ec;
    bool exists = std::filesystem::is_directory(pathStr, ec);
    ECO_KLOG("file", "dirExists path=%s result=%d",
             pathStr.c_str(), (int)exists);
    return succeedBool(exists);
}

#if defined(_WIN32)
/// Returns whether `p` is a regular file. On Windows any regular file counts as executable; the extensions tried
/// are chosen by `findExecutableBody`.
static bool isExecutableCandidate(const std::filesystem::path& p) {
    std::error_code ec;
    if (!std::filesystem::is_regular_file(p, ec)) return false;
    return true;
}
#else
/// Returns whether `p` is a regular file that the process may execute, as `access` with `X_OK` decides. A directory,
/// which `access` passes when it is searchable, does not count, as in Haskell's `findExecutable`.
static bool isExecutableCandidate(const std::filesystem::path& p) {
    struct stat st;
    std::string s = p.string();
    return ::stat(s.c_str(), &st) == 0 && modeIsRegular(st.st_mode) && ::access(s.c_str(), X_OK) == 0;
}
#endif

/// Searches `PATH` for the String `captured` and returns a Task that succeeds with `Just` the first match or
/// `Nothing`. On Windows `Path` is read when `PATH` is not set.
///
/// An empty entry of `PATH` (at its start, at its end, or between two separators) names the working directory,
/// as POSIX and Haskell's `splitSearchPath` have it, and a match there is returned as `./<name>`.
HPointer findExecutableBody(HPointer captured) {
    std::string nameStr = toString(Export::encode(captured));
    ECO_KLOG("file", "findExecutable start name=%s", nameStr.c_str());
    const char* pathEnv = std::getenv("PATH");
#if defined(_WIN32)
    if (!pathEnv) pathEnv = std::getenv("Path");
#endif
    if (!pathEnv) {
        ECO_KLOG("file", "findExecutable done name=%s result=none (no PATH)",
                 nameStr.c_str());
        return succeed(Elm::alloc::nothing());
    }

#if defined(_WIN32)
    // The bare name, then a fixed list of suffixes, in each directory. PATHEXT is not consulted.
    const char* exts[] = { "", ".exe", ".cmd", ".bat", ".com" };
#else
    const char* exts[] = { "" };
#endif

    std::string pathStr(pathEnv);
    size_t pos = 0;
    for (;;) {
        size_t sep = pathStr.find(kPathListSep, pos);
        size_t end = sep == std::string::npos ? pathStr.size() : sep;
        std::string entry = pathStr.substr(pos, end - pos);
        // "." / name keeps the dot, so the match is "./name".
        std::filesystem::path dir = entry.empty() ? std::string(".") : entry;
        for (const char* ext : exts) {
            std::filesystem::path full = dir / (nameStr + ext);
            if (isExecutableCandidate(full)) {
                // Forward slashes, because the Elm fp* path code splits on '/'.
                std::string s = full.generic_string();
                ECO_KLOG("file", "findExecutable done name=%s result=%s",
                         nameStr.c_str(), s.c_str());
                HPointer str = Elm::alloc::allocStringFromUTF8(s);
                return succeed(Elm::alloc::just(Elm::alloc::boxed(str), true));
            }
        }
        if (sep == std::string::npos) break;
        pos = sep + 1;
    }
    ECO_KLOG("file", "findExecutable done name=%s result=none",
             nameStr.c_str());
    return succeed(Elm::alloc::nothing());
}

/// Returns a Task that succeeds with the entry names of the directory named by the String `captured`, or fails.
HPointer listBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "list start path=%s", pathStr.c_str());
    std::vector<std::string> entries;
    std::error_code ec;
    // The error_code forms of the constructor and of `increment`, since a throwing `operator++` would let a
    // `filesystem_error` escape the body.
    for (auto it = std::filesystem::directory_iterator(pathStr, ec), end = std::filesystem::directory_iterator();
         !ec && it != end; it.increment(ec)) {
        std::string name = it->path().filename().string();
        if (name != "." && name != "..") {
            entries.push_back(name);
        }
    }
    if (ec) {
        ECO_KLOG("file", "list fail path=%s ec=%d msg=%s",
                 pathStr.c_str(), ec.value(), ec.message().c_str());
        return failErrorCode(ec, pathStr, "could not list directory");
    }
    ECO_KLOG("file", "list done path=%s entries=%zu",
             pathStr.c_str(), entries.size());
    return succeedStringList(entries);
}

/// Returns a Task that succeeds with the modification time in milliseconds of the file named by the String
/// `captured`, or fails.
HPointer modificationTimeBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "modificationTime start path=%s", pathStr.c_str());
    struct stat st;
    if (stat(pathStr.c_str(), &st) != 0) {
        int err = errno;
        ECO_KLOG("file", "modificationTime fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not stat file");
    }
#if defined(_WIN32)
    // Only whole seconds are read here, scaled to milliseconds.
    int64_t millis = static_cast<int64_t>(st.st_mtime) * 1000;
#elif defined(__APPLE__)
    const struct timespec &mtim = st.st_mtimespec;
    int64_t millis = static_cast<int64_t>(mtim.tv_sec) * 1000 +
                     static_cast<int64_t>(mtim.tv_nsec) / 1000000;
#else
    const struct timespec &mtim = st.st_mtim;
    int64_t millis = static_cast<int64_t>(mtim.tv_sec) * 1000 +
                     static_cast<int64_t>(mtim.tv_nsec) / 1000000;
#endif
    ECO_KLOG("file", "modificationTime done path=%s millis=%lld",
             pathStr.c_str(), (long long)millis);
    return succeedInt(millis);
}

/// Returns a Task that succeeds with the working directory, or fails. The captured value is Unit and unused.
HPointer getCwdBody(HPointer /*captured*/) {
    std::error_code ec;
    auto cwd = std::filesystem::current_path(ec);
    if (!ec) {
        // Forward slashes, because the Elm fp* path code splits on '/'.
        std::string s = cwd.generic_string();
        ECO_KLOG("file", "getCwd done result=%s", s.c_str());
        return succeedString(s);
    }
    ECO_KLOG("file", "getCwd fail ec=%d msg=%s",
             ec.value(), ec.message().c_str());
    return failErrorCode(ec, "", "could not get current working directory");
}

/// Makes the String `captured` the working directory and returns a Task that succeeds with Unit or fails.
HPointer setCwdBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "setCwd start path=%s", pathStr.c_str());
    std::error_code ec;
    std::filesystem::current_path(pathStr, ec);
    if (ec) {
        ECO_KLOG("file", "setCwd fail path=%s ec=%d msg=%s",
                 pathStr.c_str(), ec.value(), ec.message().c_str());
        return failErrorCode(ec, pathStr, "could not set working directory");
    }
    ECO_KLOG("file", "setCwd done path=%s", pathStr.c_str());
    return succeedUnit();
}

/// Returns a Task that succeeds with the canonical form of the path `captured`, or its normalised absolute form
/// when it cannot be resolved. Fails for the empty path (`ENOENT`, as `realpath` gives), and when the path cannot be
/// made absolute, for instance because it is relative and the working directory was removed.
HPointer canonicalizeBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "canonicalize start path=%s", pathStr.c_str());
    if (pathStr.empty()) {
        return failErrno(ENOENT, pathStr, "could not canonicalize the empty path");
    }
    std::error_code ec;
    auto canonical = std::filesystem::canonical(pathStr, ec);
    if (!ec) {
        std::string s = canonical.generic_string();  // '/' form
        ECO_KLOG("file", "canonicalize done path=%s result=%s",
                 pathStr.c_str(), s.c_str());
        return succeedString(s);
    }
    // Fallback: make the path absolute without following symlinks. The error_code form, since the throwing one
    // would let a `filesystem_error` escape the body.
    ec.clear();
    std::filesystem::path p = std::filesystem::absolute(pathStr, ec);
    if (ec) {
        ECO_KLOG("file", "canonicalize fail path=%s ec=%d msg=%s",
                 pathStr.c_str(), ec.value(), ec.message().c_str());
        return failErrorCode(ec, pathStr, "could not make path absolute");
    }
    std::string result = p.lexically_normal().generic_string();  // '/' form
    ECO_KLOG("file", "canonicalize fallback path=%s result=%s",
             pathStr.c_str(), result.c_str());
    return succeedString(result);
}

#if !defined(_WIN32)
/// Returns the home directory of the user the process runs as, from its passwd entry, or "" when there is none or
/// it is empty.
std::string passwdHomeDir() {
    long bufSize = ::sysconf(_SC_GETPW_R_SIZE_MAX);
    std::vector<char> buf(bufSize > 0 ? static_cast<size_t>(bufSize) : 16384);
    struct passwd pw;
    struct passwd* result = nullptr;
    int rc;
    while ((rc = ::getpwuid_r(::getuid(), &pw, buf.data(), buf.size(), &result)) == ERANGE && buf.size() < (1u << 20)) {
        buf.resize(buf.size() * 2);
    }
    if (rc != 0 || !result || !result->pw_dir) return std::string();
    return std::string(result->pw_dir);
}
#endif

/// Returns a Task that succeeds with the data directory path for the application named by the String `captured`,
/// or fails with `ENOENT` when no home directory can be found.
///
/// The base is APPDATA, then USERPROFILE, then HOME on Windows. Elsewhere it is HOME, then, when HOME is unset or
/// empty, the home directory of the user's passwd entry, as Haskell's `getAppUserDataDirectory` and Node's
/// `os.homedir()` find it. An empty value counts as unset everywhere.
HPointer appDataDirBody(HPointer captured) {
    std::string nameStr = toString(Export::encode(captured));
    std::string dir;
#if defined(_WIN32)
    // No leading dot on the name. Forward slashes, for the Elm fp* code.
    const char* base = std::getenv("APPDATA");
    if (!base || !*base) base = std::getenv("USERPROFILE");
    if (!base || !*base) base = std::getenv("HOME");
    if (!base || !*base) {
        ECO_KLOG("file", "appDataDir fail name=%s reason=no-APPDATA/USERPROFILE",
                 nameStr.c_str());
        return failErrno(ENOENT, "", "cannot find a home directory: set APPDATA or USERPROFILE");
    }
    dir = std::filesystem::path(std::string(base) + "/" + nameStr)
              .generic_string();
#else
    const char* homeEnv = std::getenv("HOME");
    std::string home = homeEnv ? std::string(homeEnv) : std::string();
    if (home.empty()) {
        home = passwdHomeDir();
    }
    if (home.empty()) {
        ECO_KLOG("file", "appDataDir fail name=%s reason=no-HOME-no-passwd",
                 nameStr.c_str());
        return failErrno(ENOENT, "", "cannot find a home directory: set HOME");
    }
#ifdef __APPLE__
    dir = home + "/Library/Application Support/" + nameStr;
#else
    dir = home + "/." + nameStr;
#endif
#endif
    ECO_KLOG("file", "appDataDir name=%s result=%s",
             nameStr.c_str(), dir.c_str());
    return succeedString(dir);
}

/// Removes the file named by the String `captured` and returns a Task that succeeds with Unit or fails.
HPointer removeFileBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "removeFile start path=%s", pathStr.c_str());
    if (unlink(pathStr.c_str()) != 0) {
        int err = errno;
        ECO_KLOG("file", "removeFile fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not remove file");
    }
    ECO_KLOG("file", "removeFile done path=%s", pathStr.c_str());
    return succeedUnit();
}

/// Removes the path `captured` and everything beneath it, and returns a Task that succeeds with Unit or fails.
HPointer removeDirBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "removeDir start path=%s", pathStr.c_str());
    std::error_code ec;
    std::filesystem::remove_all(pathStr, ec);
    if (ec) {
        ECO_KLOG("file", "removeDir fail path=%s ec=%d msg=%s",
                 pathStr.c_str(), ec.value(), ec.message().c_str());
        return failErrorCode(ec, pathStr, "could not remove directory");
    }
    ECO_KLOG("file", "removeDir done path=%s", pathStr.c_str());
    return succeedUnit();
}

/// Creates the file `captured` if needed, sets its modification time to now, and returns a Task that succeeds with
/// Unit or fails.
///
/// A failure to open an existing file (a directory, or a file that is not writable) is ignored, as touch(1) does,
/// and only setting the time can fail then. When the file is missing after a failed open, the open's error is the
/// one reported, since it says why the file could not be created.
HPointer touchBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "touch start path=%s", pathStr.c_str());
    int openErr = 0;
    int fd = _eco_open(pathStr.c_str(), O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) {
        _eco_close(fd);
    } else {
        openErr = errno;
    }
    std::error_code ec;
    std::filesystem::last_write_time(
        pathStr, std::filesystem::file_time_type::clock::now(), ec);
    if (ec) {
        ECO_KLOG("file", "touch fail path=%s ec=%d open-errno=%d msg=%s",
                 pathStr.c_str(), ec.value(), openErr, ec.message().c_str());
        if (openErr != 0 && ec == std::errc::no_such_file_or_directory) {
            return failErrno(openErr, pathStr, "could not create file");
        }
        return failErrorCode(ec, pathStr, "could not touch file");
    }
    ECO_KLOG("file", "touch done path=%s", pathStr.c_str());
    return succeedUnit();
}

/// Returns a Task that succeeds with Unit. No lock is taken.
HPointer lockBody(HPointer /*captured*/) { return succeedUnit(); }
/// Returns a Task that succeeds with Unit. No lock is released.
HPointer unlockBody(HPointer /*captured*/) { return succeedUnit(); }

// --- 1-arg-Int bodies ---------------------------------------------------------

/// Closes the descriptor in slot 0 of `captured`, ignoring failure, and returns a Task that succeeds with Unit.
/// A `spawnProcess` stdin handle is forgotten first, so `Console.write` refuses the number from now on.
HPointer closeBody(HPointer captured) {
    Tuple2* tup = asTuple2(captured);
    int64_t fd = tup->a.i;
    ECO_KLOG("file", "close handle=%lld", (long long)fd);
    Process::forgetStreamHandle(fd);
    _eco_close(static_cast<int>(fd));
    return succeedUnit();
}

/// Returns a Task that succeeds with the size of the file open as the descriptor in slot 0 of `captured`, or fails.
HPointer sizeBody(HPointer captured) {
    Tuple2* tup = asTuple2(captured);
    int64_t fd = tup->a.i;
    struct stat st;
    if (fstat(static_cast<int>(fd), &st) != 0) {
        int err = errno;
        ECO_KLOG("file", "size fail handle=%lld errno=%d msg=%s",
                 (long long)fd, err, std::strerror(err));
        return failErrno(err, "", "fstat failed");
    }
    ECO_KLOG("file", "size handle=%lld size=%lld",
             (long long)fd, (long long)st.st_size);
    return succeedInt(static_cast<int64_t>(st.st_size));
}

// --- 2-arg bodies -------------------------------------------------------------

/// Writes the `n` bytes at `data` to `fd`, retrying a write that `EINTR` interrupts and going on after a short
/// write. Returns 0, or the `errno` value of the write that failed; a write that writes nothing counts as `EIO`.
int writeAllFd(int fd, const void* data, size_t n) {
    const uint8_t* p = static_cast<const uint8_t*>(data);
    size_t off = 0;
    while (off < n) {
        auto w = _eco_write(fd, p + off, n - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            return errno ? errno : EIO;
        }
        if (w == 0) return EIO;
        off += static_cast<size_t>(w);
    }
    return 0;
}

/// Replaces the contents of the file `path` with the `n` bytes at `data`, creating it if needed, and returns a Task
/// that succeeds with Unit or fails with the error of the open, of any write, or of the close. `op` names the
/// operation in the log. `data` must stay valid throughout; nothing here allocates on the heap before the result.
/// A GC point.
HPointer writeWholeFile(const char* op, const std::string& path, const void* data, size_t n) {
    ECO_KLOG("file", "%s start path=%s size=%zu", op, path.c_str(), n);
    int fd = _eco_open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        int err = errno;
        ECO_KLOG("file", "%s fail path=%s errno=%d msg=%s", op, path.c_str(), err, std::strerror(err));
        return failErrno(err ? err : EIO, path, "could not open file for writing");
    }
    int err = writeAllFd(fd, data, n);
    if (_eco_close(fd) != 0 && err == 0) err = errno ? errno : EIO;
    if (err != 0) {
        ECO_KLOG("file", "%s fail path=%s errno=%d msg=%s", op, path.c_str(), err, std::strerror(err));
        return failErrno(err, path, "could not write file");
    }
    ECO_KLOG("file", "%s done path=%s wrote=%zu", op, path.c_str(), n);
    return succeedUnit();
}

/// Writes the String in slot 1 of `captured` to the file named in slot 0, as `writeWholeFile` does, and returns a
/// Task that succeeds with Unit or fails. The text is written as UTF-8, byte for byte, on Windows too.
HPointer writeStringBody(HPointer captured) {
    HPointer pathHP;
    HPointer contentHP;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        contentHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    std::string data = toString(Export::encode(contentHP));
    return writeWholeFile("writeString", pathStr, data.data(), data.size());
}

/// Writes the Bytes in slot 1 of `captured` to the file named in slot 0, as `writeWholeFile` does, and returns a
/// Task that succeeds with Unit or fails.
HPointer writeBytesBody(HPointer captured) {
    HPointer pathHP;
    HPointer bytesHP;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        bytesHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    // Nothing allocates between resolve and the last write, so `data` stays valid.
    void* ptr = Elm::alloc::isConstant(bytesHP) ? nullptr : Elm::Allocator::instance().resolve(bytesHP); // empty Bytes = embedded constant
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    return writeWholeFile("writeBytes", pathStr, data, len);
}

/// The next sequence number for a `writeBytesAtomic` temporary file name, shared by the whole process.
std::atomic<uint64_t> gAtomicWriteSeq{0};

/// Writes the Bytes in slot 1 of `captured` to a new temporary file beside the path in slot 0, renames it over that
/// path, and returns a Task that succeeds with Unit or fails.
///
/// The temporary file is `<path>.tmp-<pid>-<seq>`, created exclusively; a name that exists already is skipped, up
/// to 16 names. A write, close or rename error is reported, and the temporary file is then removed. On Windows a
/// failed rename is retried five times, after waits of 10 ms doubling to 160 ms.
HPointer writeBytesAtomicBody(HPointer captured) {
    HPointer pathHP;
    HPointer bytesHP;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        bytesHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    std::string tmp;
    int fd = -1;
    // O_EXCL, so two writers never share a temporary file even when their pids and sequence numbers coincide.
    for (int tries = 0; fd < 0 && tries < 16; ++tries) {
        tmp = pathStr + ".tmp-" + std::to_string(static_cast<long long>(ECO_GETPID())) + "-" +
              std::to_string(gAtomicWriteSeq.fetch_add(1, std::memory_order_relaxed));
        fd = _eco_open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_TRUNC, 0644);
        if (fd < 0 && errno != EEXIST) break;
    }
    if (fd < 0) {
        int err = errno;
        ECO_KLOG("file", "writeBytesAtomic fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not create temp file for writing");
    }
    // Nothing allocates between resolve and the last write, so `data` stays valid.
    void* ptr = Elm::alloc::isConstant(bytesHP) ? nullptr : Elm::Allocator::instance().resolve(bytesHP); // empty Bytes = embedded constant
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    int err = writeAllFd(fd, data, len);
    if (_eco_close(fd) != 0 && err == 0) err = errno ? errno : EIO;
    if (err == 0) {
        std::error_code ec;
        std::filesystem::rename(tmp, pathStr, ec); // POSIX rename(2): atomic replace
#if defined(_WIN32)
        // A failed rename is retried a bounded number of times, as happens while another process holds the
        // target open.
        for (int i = 0; ec && i < 5; ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10 << i));
            ec.clear();
            std::filesystem::rename(tmp, pathStr, ec);
        }
#endif
        if (!ec) {
            ECO_KLOG("file", "writeBytesAtomic done path=%s wrote=%zu", pathStr.c_str(), len);
            return succeedUnit();
        }
        std::error_code ignored;
        std::filesystem::remove(tmp, ignored); // best effort
        ECO_KLOG("file", "writeBytesAtomic rename fail path=%s ec=%d", pathStr.c_str(), ec.value());
        return failErrorCode(ec, pathStr, "could not write file atomically");
    }
    std::error_code ignored;
    std::filesystem::remove(tmp, ignored); // best effort
    ECO_KLOG("file", "writeBytesAtomic fail path=%s errno=%d", pathStr.c_str(), err);
    return failErrno(err, pathStr, "could not write file atomically");
}

/// Opens the file named in slot 0 of `captured` in the mode in slot 1, and returns a Task that succeeds with the
/// descriptor or fails.
HPointer openBody(HPointer captured) {
    HPointer pathHP;
    int64_t modeVal;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        modeVal = tup->b.i;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    int flags;
    switch (modeVal) {
        case 0: flags = O_RDONLY; break;
        case 1: flags = O_WRONLY | O_CREAT | O_TRUNC; break;
        case 2: flags = O_WRONLY | O_CREAT | O_APPEND; break;
        case 3: flags = O_RDWR | O_CREAT; break;
        default: flags = O_RDONLY; break;
    }
    ECO_KLOG("file", "open start path=%s mode=%lld",
             pathStr.c_str(), (long long)modeVal);
    int fd = _eco_open(pathStr.c_str(), flags, 0644);
    if (fd < 0) {
        int err = errno;
        ECO_KLOG("file", "open fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file");
    }
    ECO_KLOG("file", "open done path=%s handle=%d",
             pathStr.c_str(), fd);
    return succeedInt(fd);
}

/// Writes the String in slot 1 of `captured` to the descriptor in slot 0, all of it (`writeAllFd`), and returns a
/// Task that succeeds with Unit or fails.
HPointer hWriteStringBody(HPointer captured) {
    int64_t fd;
    HPointer contentHP;
    {
        Tuple2* tup = asTuple2(captured);
        fd = tup->a.i;
        contentHP = tup->b.p;
    }
    std::string data = toString(Export::encode(contentHP));
    ECO_KLOG("file", "hWriteString start handle=%lld size=%zu",
             (long long)fd, data.size());
    int err = writeAllFd(static_cast<int>(fd), data.data(), data.size());
    if (err != 0) {
        ECO_KLOG("file", "hWriteString fail handle=%lld errno=%d msg=%s",
                 (long long)fd, err, std::strerror(err));
        return failErrno(err, "", "write to handle failed");
    }
    ECO_KLOG("file", "hWriteString done handle=%lld wrote=%zu",
             (long long)fd, data.size());
    return succeedUnit();
}

/// Creates the directory named in slot 1 of `captured`, with its parents when the Bool in slot 0 is True, and
/// returns a Task that succeeds with Unit or fails.
HPointer createDirBody(HPointer captured) {
    HPointer createParentsHP;
    HPointer pathHP;
    {
        Tuple2* tup = asTuple2(captured);
        createParentsHP = tup->a.p;
        pathHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    bool parents = Export::decodeBoxedBool(Export::encode(createParentsHP));
    ECO_KLOG("file", "createDir start path=%s parents=%d",
             pathStr.c_str(), (int)parents);
    std::error_code ec;
    if (parents) {
        std::filesystem::create_directories(pathStr, ec);
    } else {
        std::filesystem::create_directory(pathStr, ec);
    }
    if (ec) {
        ECO_KLOG("file", "createDir fail path=%s ec=%d msg=%s",
                 pathStr.c_str(), ec.value(), ec.message().c_str());
        return failErrorCode(ec, pathStr, "could not create directory");
    }
    ECO_KLOG("file", "createDir done path=%s", pathStr.c_str());
    return succeedUnit();
}

} // anonymous namespace

// ============================================================================
// Public API: each function packs its arguments and makes the binding around its body.
// ============================================================================

uint64_t readString(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<readStringBody>(Export::decode(path)));
}

uint64_t writeString(uint64_t path, uint64_t content) {
    HPointer pathHP = Export::decode(path);
    HPointer contentHP = Export::decode(content);
    Elm::StackRootGuard g(&pathHP, &contentHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(pathHP), Elm::alloc::boxed(contentHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<writeStringBody>(payload));
}

uint64_t readBytes(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<readBytesBody>(Export::decode(path)));
}

uint64_t writeBytes(uint64_t path, uint64_t bytes) {
    HPointer pathHP = Export::decode(path);
    HPointer bytesHP = Export::decode(bytes);
    Elm::StackRootGuard g(&pathHP, &bytesHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(pathHP), Elm::alloc::boxed(bytesHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<writeBytesBody>(payload));
}

uint64_t writeBytesAtomic(uint64_t path, uint64_t bytes) {
    HPointer pathHP = Export::decode(path);
    HPointer bytesHP = Export::decode(bytes);
    Elm::StackRootGuard g(&pathHP, &bytesHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(pathHP), Elm::alloc::boxed(bytesHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<writeBytesAtomicBody>(payload));
}

uint64_t open(uint64_t path, uint64_t mode) {
    HPointer pathHP = Export::decode(path);
    Elm::StackRootGuard g(&pathHP);
    // mode arrives as the raw bits of an Int, though the export's parameter is HPtr-typed.
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(pathHP),
        Elm::alloc::unboxedInt(static_cast<int64_t>(mode)),
        /*mask: slot 1 unboxed Int (kind 01 << 2)=*/0x4);
    return Export::encode(Eco::Kernel::makeBinding<openBody>(payload));
}

uint64_t close(uint64_t handle) {
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        0x1);
    return Export::encode(Eco::Kernel::makeBinding<closeBody>(payload));
}

uint64_t hWriteString(uint64_t handle, uint64_t content) {
    HPointer contentHP = Export::decode(content);
    Elm::StackRootGuard g(&contentHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(contentHP),
        0x1);
    return Export::encode(Eco::Kernel::makeBinding<hWriteStringBody>(payload));
}

uint64_t size(uint64_t handle) {
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        0x1);
    return Export::encode(Eco::Kernel::makeBinding<sizeBody>(payload));
}

uint64_t lock(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<lockBody>(Export::decode(path)));
}

uint64_t unlock(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<unlockBody>(Export::decode(path)));
}

uint64_t fileExists(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<fileExistsBody>(Export::decode(path)));
}

uint64_t dirExists(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<dirExistsBody>(Export::decode(path)));
}

uint64_t findExecutable(uint64_t name) {
    return Export::encode(
        Eco::Kernel::makeBinding<findExecutableBody>(Export::decode(name)));
}

uint64_t list(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<listBody>(Export::decode(path)));
}

uint64_t modificationTime(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<modificationTimeBody>(Export::decode(path)));
}

uint64_t getCwd() {
    return Export::encode(
        Eco::Kernel::makeBinding<getCwdBody>(Elm::alloc::unit()));
}

uint64_t setCwd(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<setCwdBody>(Export::decode(path)));
}

uint64_t canonicalize(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<canonicalizeBody>(Export::decode(path)));
}

uint64_t appDataDir(uint64_t name) {
    return Export::encode(
        Eco::Kernel::makeBinding<appDataDirBody>(Export::decode(name)));
}

uint64_t createDir(uint64_t createParents, uint64_t path) {
    HPointer createParentsHP = Export::decode(createParents);
    HPointer pathHP = Export::decode(path);
    Elm::StackRootGuard g(&createParentsHP, &pathHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(createParentsHP), Elm::alloc::boxed(pathHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<createDirBody>(payload));
}

uint64_t removeFile(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<removeFileBody>(Export::decode(path)));
}

uint64_t removeDir(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<removeDirBody>(Export::decode(path)));
}

uint64_t touch(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<touchBody>(Export::decode(path)));
}

} // namespace Eco::Kernel::File
