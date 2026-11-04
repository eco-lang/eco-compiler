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
#include "TaskBinding.hpp"
#include <atomic>
#include <cerrno>
#include <chrono>
#include <thread>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <sstream>
#include <string>

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

// --- 1-arg-HPointer bodies ----------------------------------------------------

/// Reads the file named by the String `captured` and returns a Task that succeeds with its text or fails.
HPointer readStringBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "readString start path=%s", pathStr.c_str());
    // Opened in binary mode at the end, to size the file and then read its bytes unchanged straight into a heap
    // ByteBuffer.
    std::ifstream file(pathStr, std::ios::binary | std::ios::ate);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "readString fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for reading");
    }
    std::streamoff sz = file.tellg();
    if (sz < 0) {
        int err = errno;
        return failErrno(err, pathStr, "could not size file for reading");
    }
    size_t size = static_cast<size_t>(sz);
    file.seekg(0, std::ios::beg);
    if (size == 0) {
        ECO_KLOG("file", "readString done path=%s size=0", pathStr.c_str());
        return succeedString(std::string());
    }
    // Nothing allocates between allocByteBufferBlank and makeUtf8View, so bb.bytes and bufHp stay valid until then;
    // makeUtf8View roots the buffer across its own allocation.
    Elm::alloc::BlankByteBuffer bb = Elm::alloc::allocByteBufferBlank(size);
    HPointer bufHp = bb.hp;
    file.read(reinterpret_cast<char*>(bb.bytes), static_cast<std::streamsize>(size));
    if (!file || static_cast<size_t>(file.gcount()) != size) {
        int err = errno;
        ECO_KLOG("file", "readString short-read path=%s errno=%d", pathStr.c_str(), err);
        return failErrno(err, pathStr, "could not read file contents");
    }
    ECO_KLOG("file", "readString done path=%s size=%zu", pathStr.c_str(), size);
    // All-ASCII content, with UTF-8 strings enabled, becomes a String that is a view over the buffer, with no copy.
    // Anything else is copied out and converted to an ordinary String.
    if (Elm::Allocator::instance().getConfig().utf8_strings_enabled &&
        Elm::Utf8::allAscii(bb.bytes, size)) {
        return succeed(Elm::StringOps::makeUtf8View(bufHp, 0, static_cast<Elm::u32>(size)));
    }
    return succeedString(
        std::string(reinterpret_cast<const char*>(bb.bytes), size));
}

/// Reads the file named by the String `captured` and returns a Task that succeeds with its Bytes or fails.
HPointer readBytesBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "readBytes start path=%s", pathStr.c_str());
    std::ifstream file(pathStr, std::ios::binary | std::ios::ate);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "readBytes fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for reading");
    }
    std::streamoff sz = file.tellg();
    if (sz < 0) {
        int err = errno;
        return failErrno(err ? err : EIO, pathStr, "could not size file for reading");
    }
    if (static_cast<uint64_t>(sz) > UINT32_MAX) { // ByteBuffer header.size is u32
        return failErrno(EFBIG, pathStr, "file too large for Bytes");
    }
    size_t size = static_cast<size_t>(sz);
    if (size == 0) {
        ECO_KLOG("file", "readBytes done path=%s size=0", pathStr.c_str());
        return succeed(Elm::alloc::emptyBytes());
    }
    file.seekg(0, std::ios::beg);
    // Nothing allocates on the heap between allocByteBufferBlank and succeed(), so bb.bytes stays valid for the
    // read and bufHp is current when succeed() takes it.
    Elm::alloc::BlankByteBuffer bb = Elm::alloc::allocByteBufferBlank(size);
    HPointer bufHp = bb.hp;
    file.read(reinterpret_cast<char*>(bb.bytes), static_cast<std::streamsize>(size));
    if (!file || static_cast<size_t>(file.gcount()) != size) {
        int err = errno;
        ECO_KLOG("file", "readBytes short-read path=%s errno=%d", pathStr.c_str(), err);
        return failErrno(err ? err : EIO, pathStr, "could not read file contents");
    }
    ECO_KLOG("file", "readBytes done path=%s size=%zu", pathStr.c_str(), size);
    return succeed(bufHp);
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
/// Returns whether the process may execute `p`, as `access` with `X_OK` decides. A searchable directory passes too.
static bool isExecutableCandidate(const std::filesystem::path& p) {
    return ::access(p.string().c_str(), X_OK) == 0;
}
#endif

/// Searches `PATH` for the String `captured` and returns a Task that succeeds with `Just` the first match or
/// `Nothing`. On Windows `Path` is read when `PATH` is not set.
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
    while (pos < pathStr.size()) {
        size_t sep = pathStr.find(kPathListSep, pos);
        if (sep == std::string::npos) sep = pathStr.size();
        std::filesystem::path dir = pathStr.substr(pos, sep - pos);
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
    auto iter = std::filesystem::directory_iterator(pathStr, ec);
    if (ec) {
        // The error_code's value is passed on as if it were an errno value, which it is on POSIX.
        int err = ec.value();
        ECO_KLOG("file", "list fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open directory");
    }
    for (const auto& entry : iter) {
        std::string name = entry.path().filename().string();
        if (name != "." && name != "..") {
            entries.push_back(name);
        }
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
    int err = ec.value();
    ECO_KLOG("file", "getCwd fail errno=%d msg=%s",
             err, std::strerror(err));
    return failErrno(err, "", "could not get current working directory");
}

/// Makes the String `captured` the working directory and returns a Task that succeeds with Unit or fails.
HPointer setCwdBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "setCwd start path=%s", pathStr.c_str());
    std::error_code ec;
    std::filesystem::current_path(pathStr, ec);
    if (ec) {
        int err = ec.value();
        ECO_KLOG("file", "setCwd fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not set working directory");
    }
    ECO_KLOG("file", "setCwd done path=%s", pathStr.c_str());
    return succeedUnit();
}

/// Returns a Task that succeeds with the canonical form of the path `captured`, or its normalised absolute form
/// when it cannot be resolved.
HPointer canonicalizeBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "canonicalize start path=%s", pathStr.c_str());
    std::error_code ec;
    auto canonical = std::filesystem::canonical(pathStr, ec);
    if (!ec) {
        std::string s = canonical.generic_string();  // '/' form
        ECO_KLOG("file", "canonicalize done path=%s result=%s",
                 pathStr.c_str(), s.c_str());
        return succeedString(s);
    }
    // Fallback: make the path absolute without following symlinks.
    std::filesystem::path p = std::filesystem::absolute(pathStr);
    std::string result = p.lexically_normal().generic_string();  // '/' form
    ECO_KLOG("file", "canonicalize fallback path=%s result=%s",
             pathStr.c_str(), result.c_str());
    return succeedString(result);
}

/// Returns a Task that succeeds with the data directory path for the application named by the String `captured`,
/// or fails with a String when the environment gives no base directory.
HPointer appDataDirBody(HPointer captured) {
    std::string nameStr = toString(Export::encode(captured));
    std::string dir;
#if defined(_WIN32)
    // APPDATA, then USERPROFILE, then HOME. No leading dot on the name. Forward slashes, for the Elm fp* code.
    const char* base = std::getenv("APPDATA");
    if (!base || !*base) base = std::getenv("USERPROFILE");
    if (!base || !*base) base = std::getenv("HOME");
    if (!base || !*base) {
        ECO_KLOG("file", "appDataDir fail name=%s reason=no-APPDATA/USERPROFILE",
                 nameStr.c_str());
        return failString("APPDATA/USERPROFILE environment variable not set");
    }
    dir = std::filesystem::path(std::string(base) + "/" + nameStr)
              .generic_string();
#else
    const char* home = std::getenv("HOME");
    if (!home) {
        ECO_KLOG("file", "appDataDir fail name=%s reason=no-HOME",
                 nameStr.c_str());
        return failString("HOME environment variable not set");
    }
#ifdef __APPLE__
    dir = std::string(home) + "/Library/Application Support/" + nameStr;
#else
    dir = std::string(home) + "/." + nameStr;
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
        return failErrno(ec.value(), pathStr, "could not remove directory: " + ec.message());
    }
    ECO_KLOG("file", "removeDir done path=%s", pathStr.c_str());
    return succeedUnit();
}

/// Creates the file `captured` if needed, sets its modification time to now, and returns a Task that succeeds with
/// Unit or fails.
HPointer touchBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "touch start path=%s", pathStr.c_str());
    int fd = _eco_open(pathStr.c_str(), O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) {
        _eco_close(fd);
    }
    // A failure to open is not reported here; when the file does not exist, setting the time fails instead.
    std::error_code ec;
    std::filesystem::last_write_time(
        pathStr, std::filesystem::file_time_type::clock::now(), ec);
    if (ec) {
        int err = ec.value();
        ECO_KLOG("file", "touch fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not touch file");
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
HPointer closeBody(HPointer captured) {
    Tuple2* tup = asTuple2(captured);
    int64_t fd = tup->a.i;
    ECO_KLOG("file", "close handle=%lld", (long long)fd);
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

/// Writes the String in slot 1 of `captured` to the file named in slot 0, and returns a Task that succeeds with
/// Unit or fails when the file cannot be opened.
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
    ECO_KLOG("file", "writeString start path=%s size=%zu",
             pathStr.c_str(), data.size());
    std::ofstream file(pathStr);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "writeString fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for writing");
    }
    file << data;
    ECO_KLOG("file", "writeString done path=%s wrote=%zu",
             pathStr.c_str(), data.size());
    return succeedUnit();
}

/// Writes the Bytes in slot 1 of `captured` to the file named in slot 0, and returns a Task that succeeds with
/// Unit or fails when the file cannot be opened.
HPointer writeBytesBody(HPointer captured) {
    HPointer pathHP;
    HPointer bytesHP;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        bytesHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    void* ptr = Elm::alloc::isConstant(bytesHP) ? nullptr : Elm::Allocator::instance().resolve(bytesHP); // empty Bytes = embedded constant
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    ECO_KLOG("file", "writeBytes start path=%s size=%zu",
             pathStr.c_str(), len);
    std::ofstream file(pathStr, std::ios::binary);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "writeBytes fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for writing");
    }
    file.write(reinterpret_cast<const char*>(data), len);
    ECO_KLOG("file", "writeBytes done path=%s wrote=%zu",
             pathStr.c_str(), len);
    return succeedUnit();
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
    size_t off = 0;
    int err = 0;
    while (off < len) {
        auto n = _eco_write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            err = errno;
            break;
        }
        off += static_cast<size_t>(n);
    }
    if (_eco_close(fd) != 0 && err == 0) err = errno;
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
        err = ec.value();
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

/// Writes the String in slot 1 of `captured` to the descriptor in slot 0 with one write call, and returns a Task
/// that succeeds with Unit or fails.
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
    auto written = _eco_write(static_cast<int>(fd), data.data(), data.size());
    if (written < 0) {
        int err = errno;
        ECO_KLOG("file", "hWriteString fail handle=%lld errno=%d msg=%s",
                 (long long)fd, err, std::strerror(err));
        return failErrno(err, "", "write to handle failed");
    }
    ECO_KLOG("file", "hWriteString done handle=%lld wrote=%zd",
             (long long)fd, written);
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
        return failErrno(ec.value(), pathStr, "could not create directory: " + ec.message());
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
