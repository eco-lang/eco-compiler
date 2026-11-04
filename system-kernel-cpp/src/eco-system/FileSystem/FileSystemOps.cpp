//===- FileSystemOps.cpp - POSIX worker operations of Eco.Kernel.FileSystem ===//
//
// The POSIX definitions of the FileSystem worker operations declared in FileSystem.hpp. Each runs on a
// `SysWorkPool` worker thread, so it reads only its `FsArgs`, returns an `FsRes`, and never touches the Elm heap.
// FileSystemOpsWin32.cpp replaces this file on Windows.
//
// The results follow node's `fs` module, which the Elm API copies:
// - A failure carries the errno and the name of the call node would report, which is not always the call made
//   here (`stat` for statx, `scandir` for opendir/readdir, `rm` for unlink/remove_all), and the path node
//   would quote: the destination for two-path operations, none for fd operations.
// - A stat result is a list of 11 Ints: entity, dev, uid, gid, size, blksize, blocks, atimeMs, mtimeMs,
//   ctimeMs, birthtimeMs. Times are milliseconds since the epoch, truncated.
// - An entity is a file's type as an Int: 0 File, 1 Directory, 2 Socket, 3 Symlink, 4 Device (character,
//   block, or any type not otherwise listed), 5 Pipe.
//
// Every open(2) here passes O_CLOEXEC, and retries on EINTR. An fd opened here is closed before the
// operation returns, except the one handed back in `FsRes::n` by `opOpen`, `opReadFileStream` and
// `opWriteFileStream`.
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystem.hpp"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <system_error>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/sysmacros.h>
#endif

namespace Eco::System::Fs {

namespace {

/// The size in bytes of the buffer used for each read(2) or pread(2) call.
constexpr size_t kChunk = 64 * 1024;

/// Returns the entity code, as the file comment lists them, of the file type in mode `m`.
int64_t entityFromMode(mode_t m) {
    if (S_ISREG(m)) return 0;
    if (S_ISDIR(m)) return 1;
    if (S_ISFIFO(m)) return 5;
    if (S_ISSOCK(m)) return 2;
    if (S_ISLNK(m)) return 3;
    return 4;
}

/// Returns a time of `sec` seconds and `nsec` nanoseconds as whole milliseconds, truncated.
int64_t toMillis(int64_t sec, int64_t nsec) {
    return sec * 1000 + nsec / 1000000;
}

/// Returns the 11-Int stat list, as the file comment lays it out, for `sb`. `birthMs` is the birth time in
/// milliseconds, or negative when unknown, in which case the list gives ctime as the birth time.
std::vector<int64_t> statInts(const struct stat& sb, int64_t birthMs) {
    std::vector<int64_t> v;
    v.reserve(11);
    v.push_back(entityFromMode(sb.st_mode));
    v.push_back(static_cast<int64_t>(sb.st_dev));
    v.push_back(static_cast<int64_t>(sb.st_uid));
    v.push_back(static_cast<int64_t>(sb.st_gid));
    v.push_back(static_cast<int64_t>(sb.st_size));
    v.push_back(static_cast<int64_t>(sb.st_blksize));
    v.push_back(static_cast<int64_t>(sb.st_blocks));
#if defined(__APPLE__)
    v.push_back(toMillis(sb.st_atimespec.tv_sec, sb.st_atimespec.tv_nsec));
    v.push_back(toMillis(sb.st_mtimespec.tv_sec, sb.st_mtimespec.tv_nsec));
    v.push_back(toMillis(sb.st_ctimespec.tv_sec, sb.st_ctimespec.tv_nsec));
#else
    v.push_back(toMillis(sb.st_atim.tv_sec, sb.st_atim.tv_nsec));
    v.push_back(toMillis(sb.st_mtim.tv_sec, sb.st_mtim.tv_nsec));
    v.push_back(toMillis(sb.st_ctim.tv_sec, sb.st_ctim.tv_nsec));
#endif
    v.push_back(birthMs >= 0 ? birthMs : v[9]);
    return v;
}

/// Returns the birth time in `sb` in milliseconds on macOS, and -1 (unknown) elsewhere, where `struct stat`
/// has no birth time.
int64_t birthMillis(const struct stat& sb) {
#if defined(__APPLE__)
    return toMillis(sb.st_birthtimespec.tv_sec, sb.st_birthtimespec.tv_nsec);
#else
    (void)sb;
    return -1;
#endif
}

/// Sets `out` to the stat list of fd `fd` when `fd >= 0`, and otherwise of `path`, following a final
/// symlink only when `follow` is true. Returns 0, or the errno of the failing call, leaving `out` unchanged.
/// On Linux, when STATX_BTIME is defined, it uses statx, for the birth time, and falls back to
/// fstat/stat/lstat when statx fails with ENOSYS or EPERM.
int statList(int fd, const std::string& path, bool follow, std::vector<int64_t>& out) {
#if defined(__linux__) && defined(STATX_BTIME)
    {
        struct statx sx;
        int flags = fd >= 0 ? AT_EMPTY_PATH : (follow ? 0 : AT_SYMLINK_NOFOLLOW);
        int rc = ::statx(fd >= 0 ? fd : AT_FDCWD, fd >= 0 ? "" : path.c_str(), flags,
                         STATX_BASIC_STATS | STATX_BTIME, &sx);
        if (rc == 0) {
            struct stat sb;
            std::memset(&sb, 0, sizeof sb);
            sb.st_mode = sx.stx_mode;
            sb.st_dev = makedev(sx.stx_dev_major, sx.stx_dev_minor);
            sb.st_uid = sx.stx_uid;
            sb.st_gid = sx.stx_gid;
            sb.st_size = static_cast<off_t>(sx.stx_size);
            sb.st_blksize = static_cast<blksize_t>(sx.stx_blksize);
            sb.st_blocks = static_cast<blkcnt_t>(sx.stx_blocks);
            sb.st_atim.tv_sec = sx.stx_atime.tv_sec;
            sb.st_atim.tv_nsec = sx.stx_atime.tv_nsec;
            sb.st_mtim.tv_sec = sx.stx_mtime.tv_sec;
            sb.st_mtim.tv_nsec = sx.stx_mtime.tv_nsec;
            sb.st_ctim.tv_sec = sx.stx_ctime.tv_sec;
            sb.st_ctim.tv_nsec = sx.stx_ctime.tv_nsec;
            int64_t birth = (sx.stx_mask & STATX_BTIME)
                                ? toMillis(sx.stx_btime.tv_sec, sx.stx_btime.tv_nsec)
                                : -1;
            out = statInts(sb, birth);
            return 0;
        }
        int e = errno;
        if (e != ENOSYS && e != EPERM) return e;   // EPERM: a seccomp sandbox may block statx
    }
#endif
    struct stat sb;
    int rc = fd >= 0 ? ::fstat(fd, &sb)
                     : (follow ? ::stat(path.c_str(), &sb) : ::lstat(path.c_str(), &sb));
    if (rc != 0) return errno;
    out = statInts(sb, birthMillis(sb));
    return 0;
}

/// Writes all `len` bytes at `data` to `fd`, retrying short writes and EINTR. With `offset >= 0` it writes
/// at that file offset with pwrite and leaves the file position alone; otherwise it writes at the file
/// position. Returns 0, or the errno of the failing write, after which some bytes may have been written.
int writeAll(int fd, const char* data, size_t len, int64_t offset) {
    size_t done = 0;
    while (done < len) {
        ssize_t w;
        if (offset >= 0) {
            w = ::pwrite(fd, data + done, len - done, static_cast<off_t>(offset + done));
        } else {
            w = ::write(fd, data + done, len - done);
        }
        if (w < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        done += static_cast<size_t>(w);
    }
    return 0;
}

/// Closes `fd` and returns `err` if it is not 0, otherwise the errno of a failing close. A close failing
/// with EINTR counts as success.
int closeKeep(int fd, int err) {
    if (::close(fd) != 0 && err == 0 && errno != EINTR) return errno;
    return err;
}

/// Opens `a.s1` with `flags` (mode 0666 before the umask), writes all of `a.s2`, and closes it. A failing
/// open is reported as `open`; a failing write or close as `sc`, quoting `a.s1`.
FsRes writeWhole(const FsArgs& a, int flags, const char* sc) {
    int fd;
    do { fd = ::open(a.s1.c_str(), flags | O_CLOEXEC, 0666); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return FsRes::fail(errno, "open", a.s1);
    int e = writeAll(fd, a.s2.data(), a.s2.size(), -1);
    e = closeKeep(fd, e);
    if (e) return FsRes::fail(e, sc, a.s1);
    return FsRes{};
}

/// Creates directory `p` and any missing ancestors, as `mkdir -p` does, with mode 0777 before the umask.
/// Returns 0 when `p` ends up a directory, including when it already was, EEXIST when it exists as
/// something else, and otherwise the errno of the failing mkdir. Ancestors created before a failure remain.
int mkdirRecursive(const std::string& p) {
    if (p.empty()) return ENOENT;
    if (::mkdir(p.c_str(), 0777) == 0) return 0;
    int e = errno;
    if (e == EEXIST) {
        struct stat sb;
        if (::stat(p.c_str(), &sb) == 0 && S_ISDIR(sb.st_mode)) return 0;
        return EEXIST;
    }
    if (e != ENOENT) return e;
    // ENOENT: create the parent, then retry.
    std::string parent = p;
    while (parent.size() > 1 && parent.back() == '/') parent.pop_back();
    size_t slash = parent.rfind('/');
    if (slash == std::string::npos) return ENOENT;
    parent.resize(slash == 0 ? 1 : slash);
    if (parent == p) return ENOENT;
    int pe = mkdirRecursive(parent);
    if (pe) return pe;
    if (::mkdir(p.c_str(), 0777) == 0) return 0;
    e = errno;
    if (e == EEXIST) {
        struct stat sb;
        if (::stat(p.c_str(), &sb) == 0 && S_ISDIR(sb.st_mode)) return 0;
    }
    return e;
}

/// Sets `flags` to the open(2) flags of node flag string `f` and returns true, for the strings r, r+, w, wx,
/// w+ and wx+ only. Returns false, leaving `flags` alone, for any other string, including a and a+.
bool parseOpenFlags(const std::string& f, int& flags) {
    if (f == "r") flags = O_RDONLY;
    else if (f == "r+") flags = O_RDWR;
    else if (f == "w") flags = O_WRONLY | O_CREAT | O_TRUNC;
    else if (f == "wx") flags = O_WRONLY | O_CREAT | O_TRUNC | O_EXCL;
    else if (f == "w+") flags = O_RDWR | O_CREAT | O_TRUNC;
    else if (f == "wx+") flags = O_RDWR | O_CREAT | O_TRUNC | O_EXCL;
    else return false;
    return true;
}

/// Returns a Unit success when `rc` is 0, and otherwise a failure from the current errno, reported as call
/// `sc` quoting `path`. Must be called right after the call that returned `rc`, before errno can change.
FsRes unitOr(int rc, const char* sc, const std::string& path) {
    if (rc != 0) return FsRes::fail(errno, sc, path);
    return FsRes{};
}

/// Returns a `Str` success holding `s`.
FsRes stringRes(std::string s) {
    FsRes r;
    r.kind = FsRes::Kind::Str;
    r.data = std::move(s);
    return r;
}

} // namespace

// ---------------------------------------------------------------------------
// Path operations
// ---------------------------------------------------------------------------

// Follows a final symlink only when `i0` is not 0, and reports a failure as `stat` or `lstat` accordingly.
FsRes opStat(const FsArgs& a) {
    FsRes r;
    int e = statList(-1, a.s1, a.i0 != 0, r.ints);
    if (e) return FsRes::fail(e, a.i0 ? "stat" : "lstat", a.s1);
    r.kind = FsRes::Kind::Ints;
    return r;
}

// `i0` is node's mode bits: 4 read, 2 write, 1 execute; 0 checks only that the path exists.
FsRes opAccess(const FsArgs& a) {
    int mode = F_OK;
    if (a.i0 & 4) mode |= R_OK;
    if (a.i0 & 2) mode |= W_OK;
    if (a.i0 & 1) mode |= X_OK;
    return unitOr(::access(a.s1.c_str(), mode), "access", a.s1);
}

// Sets the permission bits of `s1` to `i0`.
FsRes opChmod(const FsArgs& a) {
    return unitOr(::chmod(a.s1.c_str(), static_cast<mode_t>(a.i0)), "chmod", a.s1);
}

// Sets the owner of `s1` to uid `i1` and gid `i2`, changing the symlink itself (lchown) when `i0` is 0.
FsRes opChown(const FsArgs& a) {
    uid_t uid = static_cast<uid_t>(a.i1);
    gid_t gid = static_cast<gid_t>(a.i2);
    if (a.i0) return unitOr(::chown(a.s1.c_str(), uid, gid), "chown", a.s1);
    return unitOr(::lchown(a.s1.c_str(), uid, gid), "lchown", a.s1);
}

// `i1` and `i2` are the access and modification times in whole seconds; nanoseconds are set to 0. Changes
// the symlink itself when `i0` is 0, reporting a failure as `lutime`.
FsRes opUtimes(const FsArgs& a) {
    struct timespec ts[2];
    ts[0].tv_sec = static_cast<time_t>(a.i1);
    ts[0].tv_nsec = 0;
    ts[1].tv_sec = static_cast<time_t>(a.i2);
    ts[1].tv_nsec = 0;
    int flags = a.i0 ? 0 : AT_SYMLINK_NOFOLLOW;
    return unitOr(::utimensat(AT_FDCWD, a.s1.c_str(), ts, flags), a.i0 ? "utime" : "lutime", a.s1);
}

// A failure quotes the destination, `s2`.
FsRes opRename(const FsArgs& a) {
    return unitOr(::rename(a.s1.c_str(), a.s2.c_str()), "rename", a.s2);
}

// Succeeds with the absolute path, with every symlink resolved, as a `Str`.
FsRes opRealpath(const FsArgs& a) {
    char* p = ::realpath(a.s1.c_str(), nullptr);
    if (!p) return FsRes::fail(errno, "realpath", a.s1);
    std::string s(p);
    std::free(p);
    return stringRes(std::move(s));
}

// Copies the contents of `s1` to `s2`, replacing `s2`, and gives `s2` the permission bits of `s1`. Fails
// with EISDIR when `s1` is a directory. Every failure, including one on `s1`, is reported as `copyfile`
// quoting `s2`. A failure partway leaves `s2` partly written.
FsRes opCopyFile(const FsArgs& a) {
    int in;
    do { in = ::open(a.s1.c_str(), O_RDONLY | O_CLOEXEC); } while (in < 0 && errno == EINTR);
    if (in < 0) return FsRes::fail(errno, "copyfile", a.s2);
    struct stat sb;
    if (::fstat(in, &sb) != 0) {
        int e = errno;
        ::close(in);
        return FsRes::fail(e, "copyfile", a.s2);
    }
    if (S_ISDIR(sb.st_mode)) {
        ::close(in);
        return FsRes::fail(EISDIR, "copyfile", a.s2);
    }
    int out;
    do {
        out = ::open(a.s2.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, sb.st_mode & 07777);
    } while (out < 0 && errno == EINTR);
    if (out < 0) {
        int e = errno;
        ::close(in);
        return FsRes::fail(e, "copyfile", a.s2);
    }
    std::vector<char> buf(kChunk);
    int e = 0;
    for (;;) {
        ssize_t n = ::read(in, buf.data(), buf.size());
        if (n < 0) {
            if (errno == EINTR) continue;
            e = errno;
            break;
        }
        if (n == 0) break;
        e = writeAll(out, buf.data(), static_cast<size_t>(n), -1);
        if (e) break;
    }
    if (e == 0 && ::fchmod(out, sb.st_mode & 07777) != 0) e = errno;
    ::close(in);
    e = closeKeep(out, e);
    if (e) return FsRes::fail(e, "copyfile", a.s2);
    return FsRes{};
}

// Appends the bytes `s2` to `s1`, creating it if needed. A failing write is reported as `write`.
FsRes opAppendFile(const FsArgs& a) {
    return writeWhole(a, O_WRONLY | O_CREAT | O_APPEND, "write");
}

// Succeeds with the whole contents of `s1` as `Bytes`. A failing read or close is reported as `read`.
FsRes opReadFile(const FsArgs& a) {
    int fd;
    do { fd = ::open(a.s1.c_str(), O_RDONLY | O_CLOEXEC); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return FsRes::fail(errno, "open", a.s1);
    FsRes r;
    r.kind = FsRes::Kind::Bytes;
    struct stat sb;
    if (::fstat(fd, &sb) == 0 && S_ISREG(sb.st_mode) && sb.st_size > 0)
        r.data.reserve(static_cast<size_t>(sb.st_size));
    std::vector<char> buf(kChunk);
    int e = 0;
    for (;;) {
        ssize_t n = ::read(fd, buf.data(), buf.size());
        if (n < 0) {
            if (errno == EINTR) continue;
            e = errno;
            break;
        }
        if (n == 0) break;
        r.data.append(buf.data(), static_cast<size_t>(n));
    }
    e = closeKeep(fd, e);
    if (e) return FsRes::fail(e, "read", a.s1);
    return r;
}

// Replaces the contents of `s1` with the bytes `s2`, creating it if needed.
FsRes opWriteFile(const FsArgs& a) {
    return writeWhole(a, O_WRONLY | O_CREAT | O_TRUNC, "write");
}

// Sets the length of file `s1` to `i0` bytes.
FsRes opTruncate(const FsArgs& a) {
    int rc;
    do { rc = ::truncate(a.s1.c_str(), static_cast<off_t>(a.i0)); } while (rc != 0 && errno == EINTR);
    return unitOr(rc, "truncate", a.s1);
}

// Removes `s1` without following a final symlink. A directory is removed with its contents when `i0` is not
// 0, and otherwise fails with node's code `ERR_FS_EISDIR` rather than an errno. Failures are reported as `rm`.
FsRes opRemove(const FsArgs& a) {
    struct stat sb;
    if (::lstat(a.s1.c_str(), &sb) != 0) return FsRes::fail(errno, "rm", a.s1);
    if (S_ISDIR(sb.st_mode)) {
        if (!a.i0) {
            FsRes r;
            r.code = "ERR_FS_EISDIR";
            r.message = "Path is a directory: rm returned EISDIR (is a directory) " + a.s1;
            return r;
        }
        std::error_code ec;
        std::filesystem::remove_all(std::filesystem::path(a.s1), ec);
        if (ec) return FsRes::fail(ec.value() ? ec.value() : EIO, "rm", a.s1);
        return FsRes{};
    }
    return unitOr(::unlink(a.s1.c_str()), "rm", a.s1);
}

// Succeeds with the entries of directory `s1`, other than . and .., as `Dir` pairs of name and entity
// code, sorted by name in byte order. A symlink is reported as Symlink, not as its target. Where readdir does
// not give the type, it comes from fstatat; if that fails too, the entry is reported as a File.
FsRes opListDirectory(const FsArgs& a) {
    DIR* d = ::opendir(a.s1.c_str());
    if (!d) return FsRes::fail(errno, "scandir", a.s1);
    FsRes r;
    r.kind = FsRes::Kind::Dir;
    int e = 0;
    for (;;) {
        errno = 0;
        struct dirent* ent = ::readdir(d);
        if (!ent) {
            e = errno;
            break;
        }
        const char* name = ent->d_name;
        if (std::strcmp(name, ".") == 0 || std::strcmp(name, "..") == 0) continue;
        int64_t kind = -1;
#if defined(DT_UNKNOWN)
        switch (ent->d_type) {
        case DT_REG: kind = 0; break;
        case DT_DIR: kind = 1; break;
        case DT_SOCK: kind = 2; break;
        case DT_LNK: kind = 3; break;
        case DT_CHR:
        case DT_BLK: kind = 4; break;
        case DT_FIFO: kind = 5; break;
        default: break;
        }
#endif
        if (kind < 0) {   // DT_UNKNOWN, or no d_type on this platform
            struct stat sb;
            if (::fstatat(dirfd(d), name, &sb, AT_SYMLINK_NOFOLLOW) == 0) kind = entityFromMode(sb.st_mode);
            else kind = 0;
        }
        r.entries.emplace_back(std::string(name), kind);
    }
    ::closedir(d);
    if (e) return FsRes::fail(e, "scandir", a.s1);
    std::sort(r.entries.begin(), r.entries.end(),
              [](const auto& x, const auto& y) { return std::strcmp(x.first.c_str(), y.first.c_str()) < 0; });
    return r;
}

// Creates directory `s1`, with any missing ancestors when `i0` is not 0, in which case an existing directory
// is not an error.
FsRes opMakeDirectory(const FsArgs& a) {
    if (a.i0) {
        int e = mkdirRecursive(a.s1);
        if (e) return FsRes::fail(e, "mkdir", a.s1);
        return FsRes{};
    }
    return unitOr(::mkdir(a.s1.c_str(), 0777), "mkdir", a.s1);
}

// Creates a new directory named `s1` followed by six random characters, and succeeds with its path as a
// `Str`.
FsRes opMakeTempDirectory(const FsArgs& a) {
    std::string t = a.s1 + "XXXXXX";
    std::vector<char> buf(t.begin(), t.end());
    buf.push_back('\0');
    if (!::mkdtemp(buf.data())) return FsRes::fail(errno, "mkdtemp", a.s1);
    return stringRes(std::string(buf.data()));
}

// Creates hard link `s2` to `s1`. A failure quotes `s2`.
FsRes opLink(const FsArgs& a) {
    return unitOr(::link(a.s1.c_str(), a.s2.c_str()), "link", a.s2);
}

// Creates symlink `s2` whose target is the text `s1`. A failure quotes `s2`.
FsRes opSymlink(const FsArgs& a) {
    return unitOr(::symlink(a.s1.c_str(), a.s2.c_str()), "symlink", a.s2);
}

// Succeeds with the target of symlink `s1` as a `Str`, growing the buffer until the whole target fits.
FsRes opReadLink(const FsArgs& a) {
    std::vector<char> buf(256);
    for (;;) {
        ssize_t n = ::readlink(a.s1.c_str(), buf.data(), buf.size());
        if (n < 0) return FsRes::fail(errno, "readlink", a.s1);
        if (static_cast<size_t>(n) < buf.size()) return stringRes(std::string(buf.data(), static_cast<size_t>(n)));
        buf.resize(buf.size() * 2);
    }
}

// Removes the name `s1`; a directory fails, as unlink(2) does.
FsRes opUnlink(const FsArgs& a) {
    return unitOr(::unlink(a.s1.c_str()), "unlink", a.s1);
}

// ---------------------------------------------------------------------------
// File handles
// ---------------------------------------------------------------------------

// Opens `s1` with node flag string `s2` (one of r, r+, w, wx, w+, wx+; any other fails with EINVAL), and
// succeeds with the fd as an `Int`. A created file gets mode 0666 before the umask.
FsRes opOpen(const FsArgs& a) {
    int flags;
    if (!parseOpenFlags(a.s2, flags)) return FsRes::fail(EINVAL, "open", a.s1);
    int fd;
    do { fd = ::open(a.s1.c_str(), flags | O_CLOEXEC, 0666); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return FsRes::fail(errno, "open", a.s1);
    FsRes r;
    r.kind = FsRes::Kind::Int;
    r.n = fd;
    return r;
}

// Closes fd `i0`. A close failing with EINTR counts as success.
FsRes opClose(const FsArgs& a) {
    if (::close(static_cast<int>(a.i0)) != 0 && errno != EINTR) return FsRes::fail(errno, "close");
    return FsRes{};
}

// Succeeds with the stat list of fd `i0`.
FsRes opFstat(const FsArgs& a) {
    FsRes r;
    int e = statList(static_cast<int>(a.i0), std::string(), true, r.ints);
    if (e) return FsRes::fail(e, "fstat");
    r.kind = FsRes::Kind::Ints;
    return r;
}

// Sets the permission bits of fd `i0` to `i1`.
FsRes opFchmod(const FsArgs& a) {
    return unitOr(::fchmod(static_cast<int>(a.i0), static_cast<mode_t>(a.i1)), "fchmod", std::string());
}

// Sets the owner of fd `i0` to uid `i1` and gid `i2`.
FsRes opFchown(const FsArgs& a) {
    return unitOr(::fchown(static_cast<int>(a.i0), static_cast<uid_t>(a.i1), static_cast<gid_t>(a.i2)),
                  "fchown", std::string());
}

// Sets the access time of fd `i0` to `i1` and its modification time to `i2`, in whole seconds with
// nanoseconds set to 0.
FsRes opFutimes(const FsArgs& a) {
    struct timespec ts[2];
    ts[0].tv_sec = static_cast<time_t>(a.i1);
    ts[0].tv_nsec = 0;
    ts[1].tv_sec = static_cast<time_t>(a.i2);
    ts[1].tv_nsec = 0;
    return unitOr(::futimens(static_cast<int>(a.i0), ts), "futime", std::string());
}

// Succeeds with up to `i2` bytes of fd `i0` read from offset `i1`, as `Bytes`, without moving the file
// position. A negative offset reads from 0, and a negative length reads to the end of the file. The result is
// shorter than `i2` only at the end of the file.
FsRes opReadFromOffset(const FsArgs& a) {
    int fd = static_cast<int>(a.i0);
    int64_t off = a.i1 < 0 ? 0 : a.i1;
    bool toEof = a.i2 < 0;
    uint64_t want = toEof ? UINT64_MAX : static_cast<uint64_t>(a.i2);
    FsRes r;
    r.kind = FsRes::Kind::Bytes;
    std::vector<char> buf(kChunk);
    while (r.data.size() < want) {
        size_t n = static_cast<size_t>(std::min<uint64_t>(buf.size(), want - r.data.size()));
        ssize_t got = ::pread(fd, buf.data(), n, static_cast<off_t>(off + static_cast<int64_t>(r.data.size())));
        if (got < 0) {
            if (errno == EINTR) continue;
            return FsRes::fail(errno, "read");
        }
        if (got == 0) break;
        r.data.append(buf.data(), static_cast<size_t>(got));
    }
    return r;
}

// Writes all of the bytes `s2` to fd `i0` at offset `i1`, without moving the file position, or at the
// file position, advancing it, when `i1` is negative (node's -1).
FsRes opWriteFromOffset(const FsArgs& a) {
    int e = writeAll(static_cast<int>(a.i0), a.s2.data(), a.s2.size(), a.i1 < 0 ? -1 : a.i1);
    if (e) return FsRes::fail(e, "write");
    return FsRes{};
}

// Sets the length of the file of fd `i0` to `i1` bytes.
FsRes opFtruncate(const FsArgs& a) {
    int rc;
    do { rc = ::ftruncate(static_cast<int>(a.i0), static_cast<off_t>(a.i1)); } while (rc != 0 && errno == EINTR);
    return unitOr(rc, "ftruncate", std::string());
}

// Flushes the data and metadata of fd `i0` to storage.
FsRes opFsync(const FsArgs& a) {
    return unitOr(::fsync(static_cast<int>(a.i0)), "fsync", std::string());
}

// Flushes the data of fd `i0` to storage with fdatasync. On macOS, which has no fdatasync, asks the drive
// to flush with F_FULLFSYNC, and falls back to fsync if that fails, reporting its failure as `fdatasync`.
FsRes opFdatasync(const FsArgs& a) {
    int fd = static_cast<int>(a.i0);
#if defined(__APPLE__)
    if (::fcntl(fd, F_FULLFSYNC) == 0) return FsRes{};
    return unitOr(::fsync(fd), "fdatasync", std::string());
#else
    return unitOr(::fdatasync(fd), "fdatasync", std::string());
#endif
}

// ---------------------------------------------------------------------------
// File streams: each opens an fd that the completion, on the eco thread, hands to an FdChannel
// ---------------------------------------------------------------------------

// Opens `s1` for reading at byte `i0` (negative reads from 0) and succeeds with the fd as a `ReadStream`.
// When `i1` is not negative it is the inclusive end offset, so, with `start` being `i0` clamped to 0, the
// channel reads at most `i1 - start + 1` bytes, or none when `i1 < start`. A directory fails here with
// EISDIR, reported as `read`.
FsRes opReadFileStream(const FsArgs& a) {
    int fd;
    do { fd = ::open(a.s1.c_str(), O_RDONLY | O_CLOEXEC); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return FsRes::fail(errno, "open", a.s1);
    struct stat sb;
    if (::fstat(fd, &sb) != 0) {
        int e = errno;
        ::close(fd);
        return FsRes::fail(e, "fstat", a.s1);
    }
    if (S_ISDIR(sb.st_mode)) {
        ::close(fd);
        return FsRes::fail(EISDIR, "read", a.s1);
    }
    int64_t start = a.i0 < 0 ? 0 : a.i0;
    if (start > 0 && ::lseek(fd, static_cast<off_t>(start), SEEK_SET) < 0) {
        int e = errno;
        ::close(fd);
        return FsRes::fail(e, "read", a.s1);
    }
    FsRes r;
    r.kind = FsRes::Kind::ReadStream;
    r.n = fd;
    if (a.i1 >= 0) r.readLimit = a.i1 >= start ? a.i1 - start + 1 : 0;   // inclusive end
    return r;
}

// Opens `s1` for writing and succeeds with the fd as a `WriteStream`. `i0` packs the options: bits 0-1 the
// mode, bit 2 createNew (create the file, failing with EEXIST if it exists), bit 3 sync when the channel
// closes. The modes are 0 Replace (truncate, creating if needed), 1 ReplaceFrom (write over the existing
// file from byte `i1`, and truncate it at the channel's file position when the channel closes; the file must
// exist unless createNew is set), 2 Append (creating if needed); 3 is treated as Replace.
FsRes opWriteFileStream(const FsArgs& a) {
    int flags;
    bool truncateOnClose = false;
    const int64_t mode = a.i0 & 0x3;
    const bool createNew = (a.i0 & 0x4) != 0;
    const bool syncOnClose = (a.i0 & 0x8) != 0;
    switch (mode) {
    case 1: flags = O_RDWR; truncateOnClose = true; break;          // ReplaceFrom: r+
    case 2: flags = O_WRONLY | O_CREAT | O_APPEND; break;            // Append: a
    default: flags = O_WRONLY | O_CREAT | O_TRUNC; break;            // Replace: w
    }
    if (createNew) flags |= O_CREAT | O_EXCL;
    int fd;
    do { fd = ::open(a.s1.c_str(), flags | O_CLOEXEC, 0666); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return FsRes::fail(errno, "open", a.s1);
    if (mode == 1 && a.i1 > 0 && ::lseek(fd, static_cast<off_t>(a.i1), SEEK_SET) < 0) {
        int e = errno;
        ::close(fd);
        return FsRes::fail(e, "write", a.s1);
    }
    FsRes r;
    r.kind = FsRes::Kind::WriteStream;
    r.n = fd;
    r.truncateOnClose = truncateOnClose;
    r.syncOnClose = syncOnClose;
    return r;
}

} // namespace Eco::System::Fs
