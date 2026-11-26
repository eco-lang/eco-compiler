//===- FileSystemOpsWin32.cpp - Windows worker operations of Eco.Kernel.FileSystem ===//
//
// The Windows definitions of the FileSystem worker operations declared in FileSystem.hpp, replacing
// FileSystemOps.cpp there. Only the operations the eco compiler reaches are implemented (plans/compiler-io-on-
// eco-system.md, D6): stat (following links or not), readFile, writeFile, appendFile, open, writeFromOffset,
// fsync, close, rename, realpath, utimes, remove, listDirectory and makeDirectory. Every other operation fails
// with errno ENOTSUP, giving "eco/system" as the failing call's name and the operation's `s1` slot as the path,
// so the message ends ", eco/system '<s1>'", or ", eco/system" when `s1` is empty. This file also defines the
// UTF-8 helpers FileSystem.cpp's directory getters use on Windows.
//
// The implemented operations follow FileSystemOps.cpp: the same slots, results, entity codes, stat list and
// names of failing calls. On top of that:
// - Paths arrive as UTF-8 with '/' or '\' separators. They are converted to UTF-16 with '\' separators and
//   passed to the W calls; a path of 240 or more UTF-16 units is made absolute and given the "\\?\" prefix,
//   so it is not cut at MAX_PATH. Paths returned (realpath, the current and home directories, entry names)
//   are UTF-8, with Windows' own '\' separators.
// - A Win32 error becomes the errno `errnoFromWin32Error` (FdChannel.hpp) names. One it does not name becomes
//   the code EIO with the system's text for it, as "EIO: <text> (Windows error <n>), <call> '<path>'".
// - Files are opened sharing read, write and delete, so, as on POSIX, an open file can still be read, written,
//   renamed or removed by others. A FileHandle's fd is a CRT fd made with `_open_osfhandle`, which
//   FileSystem.cpp closes with `_close`.
// - A stat gives uid and gid 0, blksize 4096, blocks from the allocation size in 512-byte units, ctime the
//   change time, and birthtime the creation time. A symbolic link or a junction is a Symlink when links are
//   not followed.
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystem.hpp"
#include "eco-system/Core/FdChannel.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>

namespace Eco::System::Fs {

namespace {

/// The size in bytes of the buffer used for each ReadFile call.
constexpr DWORD kChunk = 64 * 1024;
/// The share mode of every file opened here: others may read, write, rename and delete it meanwhile.
constexpr DWORD kShareAll = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
/// The difference between the FILETIME epoch (1601) and the Unix epoch (1970), in 100 ns units.
constexpr int64_t kEpochDiff100ns = 116444736000000000LL;

// Returns the ENOTSUP failure every operation not implemented here gives, quoting `a.s1`.
FsRes unsupported(const FsArgs& a) {
    return FsRes::fail(ENOTSUP, "eco/system", a.s1);
}

// --- Strings and paths ---------------------------------------------------------

/// Returns UTF-16 `w[0..n)` as UTF-8; unpaired surrogates become U+FFFD.
std::string toUtf8(const wchar_t* w, size_t n) {
    if (n == 0) return std::string();
    int len = ::WideCharToMultiByte(CP_UTF8, 0, w, static_cast<int>(n), nullptr, 0, nullptr, nullptr);
    if (len <= 0) return std::string();
    std::string out(static_cast<size_t>(len), '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, w, static_cast<int>(n), &out[0], len, nullptr, nullptr);
    return out;
}

/// Returns UTF-8 `s` as UTF-16 with every '/' turned into '\'; invalid UTF-8 becomes U+FFFD.
std::wstring toWide(const std::string& s) {
    if (s.empty()) return std::wstring();
    int len = ::MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (len <= 0) return std::wstring();
    std::wstring w(static_cast<size_t>(len), L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], len);
    for (wchar_t& c : w)
        if (c == L'/') c = L'\\';
    return w;
}

/// Returns whether `c` is a path separator.
bool isSep(wchar_t c) { return c == L'\\' || c == L'/'; }

/// Returns `p` ready for a W call: unchanged when shorter than 240 units or already a "\\?\" or "\\.\" path,
/// and otherwise made absolute with GetFullPathNameW and given the "\\?\" (or "\\?\UNC\") prefix, which
/// lifts the MAX_PATH limit. Returns `p` unchanged if GetFullPathNameW fails.
std::wstring longPath(const std::wstring& p) {
    if (p.size() < 240) return p;
    if (p.compare(0, 4, L"\\\\?\\") == 0 || p.compare(0, 4, L"\\\\.\\") == 0) return p;
    DWORD n = ::GetFullPathNameW(p.c_str(), 0, nullptr, nullptr);
    if (n == 0) return p;
    std::wstring full(n, L'\0');
    DWORD got = ::GetFullPathNameW(p.c_str(), n, &full[0], nullptr);
    if (got == 0 || got >= n) return p;
    full.resize(got);
    if (full.compare(0, 2, L"\\\\") == 0) return L"\\\\?\\UNC\\" + full.substr(2);
    return L"\\\\?\\" + full;
}

/// Returns UTF-8 path `s` converted for a W call, as `toWide` and then `longPath` do.
std::wstring widePath(const std::string& s) { return longPath(toWide(s)); }

/// Returns `dir` followed by one '\', unless it already ends in a separator.
std::wstring withSep(const std::wstring& dir) {
    if (!dir.empty() && isSep(dir.back())) return dir;
    return dir + L'\\';
}

// --- Failures --------------------------------------------------------------------

/// Returns the system's text for Win32 error `code` in node's style (first letter lower-cased, no final
/// period), followed by " (Windows error <code>)".
std::string systemMessage(DWORD code) {
    wchar_t* buf = nullptr;
    DWORD n = ::FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                   FORMAT_MESSAGE_IGNORE_INSERTS,
                               nullptr, code, 0, reinterpret_cast<LPWSTR>(&buf), 0, nullptr);
    std::string s;
    if (n != 0 && buf) s = toUtf8(buf, n);
    if (buf) ::LocalFree(buf);
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ' || s.back() == '.')) s.pop_back();
    if (s.empty()) s = "i/o error";
    if (s[0] >= 'A' && s[0] <= 'Z') s[0] = static_cast<char>(s[0] - 'A' + 'a');
    return s + " (Windows error " + std::to_string(code) + ")";
}

/// Returns the failure for Win32 error `code` from the call named `sc`, quoting `path`: the errno
/// `errnoFromWin32Error` gives, or else the code EIO with the system's text for `code`.
FsRes winFail(DWORD code, const char* sc, const std::string& path = std::string()) {
    int e = errnoFromWin32Error(code);
    if (e) return FsRes::fail(e, sc, path);
    FsRes r;
    r.code = "EIO";
    r.message = "EIO: " + systemMessage(code);
    if (sc && *sc) {
        r.message += ", ";
        r.message += sc;
        if (!path.empty()) r.message += " '" + path + "'";
    }
    return r;
}

/// Returns the failure for a CreateFileW of `p` (from UTF-8 `path`) that failed with `code`. Windows refuses
/// to open a directory as a file with ERROR_ACCESS_DENIED; when `p` is a directory that becomes EISDIR,
/// reported as `dirSc`, as POSIX reports it. Anything else is reported as `sc`.
FsRes openFail(DWORD code, const std::wstring& p, const char* sc, const char* dirSc, const std::string& path) {
    if (code == ERROR_ACCESS_DENIED) {
        DWORD attrs = ::GetFileAttributesW(p.c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY))
            return FsRes::fail(EISDIR, dirSc, path);
    }
    return winFail(code, sc, path);
}

/// Returns a `Str` success holding `s`.
FsRes stringRes(std::string s) {
    FsRes r;
    r.kind = FsRes::Kind::Str;
    r.data = std::move(s);
    return r;
}

// --- Files -----------------------------------------------------------------------

/// Returns a FILETIME count of 100 ns units as whole milliseconds since the Unix epoch, rounded down.
int64_t fileTimeMs(int64_t t) {
    int64_t d = t - kEpochDiff100ns;
    return d >= 0 ? d / 10000 : -((-d + 9999) / 10000);
}

/// Returns `ft` as a count of 100 ns units.
int64_t fileTimeUnits(const FILETIME& ft) {
    return static_cast<int64_t>((static_cast<uint64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime);
}

/// Returns `sec` seconds since the Unix epoch as a FILETIME, clamped at the FILETIME epoch.
FILETIME secondsToFileTime(int64_t sec) {
    int64_t t = sec < -kEpochDiff100ns / 10000000 ? 0 : sec * 10000000 + kEpochDiff100ns;
    FILETIME ft;
    ft.dwLowDateTime = static_cast<DWORD>(static_cast<uint64_t>(t) & 0xFFFFFFFFu);
    ft.dwHighDateTime = static_cast<DWORD>(static_cast<uint64_t>(t) >> 32);
    return ft;
}

/// Returns whether reparse tag `tag` is a link: a symbolic link or a junction (mount point).
bool isLinkTag(DWORD tag) { return tag == IO_REPARSE_TAG_SYMLINK || tag == IO_REPARSE_TAG_MOUNT_POINT; }

/// Returns whether the entry at `p` (not ending in a separator) is a symbolic link or a junction itself.
bool isLinkPath(const std::wstring& p) {
    WIN32_FIND_DATAW fd;
    HANDLE f = ::FindFirstFileW(longPath(p).c_str(), &fd);
    if (f == INVALID_HANDLE_VALUE) return false;
    ::FindClose(f);
    return (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && isLinkTag(fd.dwReserved0);
}

/// Sets `out` to the 11-Int stat list of open handle `h`. `follow` says whether `h` was opened through a
/// final link; when it was not, a link is reported as a Symlink. Returns 0 or the Win32 error.
DWORD statHandle(HANDLE h, bool follow, std::vector<int64_t>& out) {
    int64_t entity = 0, dev = 0, size = 0, blocks = 0, atime = 0, mtime = 0, ctime = 0, birth = 0;
    DWORD type = ::GetFileType(h);
    if (type == FILE_TYPE_CHAR) {
        entity = 4;
    } else if (type == FILE_TYPE_PIPE) {
        entity = 5;
    } else {
        BY_HANDLE_FILE_INFORMATION info;
        if (!::GetFileInformationByHandle(h, &info)) return ::GetLastError();
        dev = static_cast<int64_t>(info.dwVolumeSerialNumber);
        size = static_cast<int64_t>((static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow);
        atime = fileTimeMs(fileTimeUnits(info.ftLastAccessTime));
        mtime = fileTimeMs(fileTimeUnits(info.ftLastWriteTime));
        birth = fileTimeMs(fileTimeUnits(info.ftCreationTime));
        ctime = mtime;
        FILE_BASIC_INFO basic;
        if (::GetFileInformationByHandleEx(h, FileBasicInfo, &basic, sizeof basic))
            ctime = fileTimeMs(basic.ChangeTime.QuadPart);
        blocks = (size + 511) / 512;
        FILE_STANDARD_INFO standard;
        if (::GetFileInformationByHandleEx(h, FileStandardInfo, &standard, sizeof standard))
            blocks = standard.AllocationSize.QuadPart / 512;
        entity = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
        if (!follow && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            FILE_ATTRIBUTE_TAG_INFO tag;
            if (::GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof tag) &&
                isLinkTag(tag.ReparseTag))
                entity = 3;
        }
    }
    out = {entity, dev, 0, 0, size, 4096, blocks, atime, mtime, ctime, birth};
    return 0;
}

/// Writes all `len` bytes at `data` to `h`, at byte `offset` when it is not negative and otherwise at the file
/// pointer. Returns 0 or the Win32 error of the failing write, after which some bytes may have been written.
/// A positioned write moves the file pointer, as WriteFile with an OVERLAPPED offset does on a synchronous
/// handle.
DWORD writeAllHandle(HANDLE h, const char* data, size_t len, int64_t offset) {
    size_t done = 0;
    while (done < len) {
        size_t rest = len - done;
        DWORD chunk = static_cast<DWORD>(rest > (1u << 30) ? (1u << 30) : rest);
        DWORD put = 0;
        BOOL ok;
        if (offset >= 0) {
            OVERLAPPED ov = {};
            uint64_t at = static_cast<uint64_t>(offset) + done;
            ov.Offset = static_cast<DWORD>(at & 0xFFFFFFFFu);
            ov.OffsetHigh = static_cast<DWORD>(at >> 32);
            ok = ::WriteFile(h, data + done, chunk, &put, &ov);
        } else {
            ok = ::WriteFile(h, data + done, chunk, &put, nullptr);
        }
        if (!ok) return ::GetLastError();
        if (put == 0) return ERROR_WRITE_FAULT;
        done += put;
    }
    return 0;
}

/// Opens `a.s1` for writing with access `access` and disposition `disposition`, truncates it when `truncate`,
/// writes all of `a.s2`, and closes it. A failing open is reported as `open`; a failing write or close as `sc`,
/// quoting `a.s1`.
FsRes writeWhole(const FsArgs& a, DWORD access, DWORD disposition, bool truncate, const char* sc) {
    std::wstring p = widePath(a.s1);
    HANDLE h = ::CreateFileW(p.c_str(), access, kShareAll, nullptr, disposition, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return openFail(::GetLastError(), p, "open", "open", a.s1);
    if (truncate && !::SetEndOfFile(h)) {   // the file pointer is at 0 after the open
        DWORD code = ::GetLastError();
        ::CloseHandle(h);
        return winFail(code, "open", a.s1);
    }
    DWORD code = writeAllHandle(h, a.s2.data(), a.s2.size(), -1);
    if (!::CloseHandle(h) && code == 0) code = ::GetLastError();
    if (code) return winFail(code, sc, a.s1);
    return FsRes{};
}

/// Returns the OS handle of CRT fd `fd`, which must be open.
HANDLE handleOfFd(int64_t fd) {
    return reinterpret_cast<HANDLE>(::_get_osfhandle(static_cast<int>(fd)));
}

// --- Directories -------------------------------------------------------------------

/// Returns whether `p` names a root a directory cannot be created at: a drive ("C:"), a UNC share
/// ("\\server\share") or less, or a "\\?\" prefix alone.
bool isRootPath(const std::wstring& p) {
    if (p.empty() || p.back() == L':') return true;
    if (p.compare(0, 2, L"\\\\") == 0) {
        size_t seps = 0;
        for (size_t i = 2; i < p.size(); ++i)
            if (p[i] == L'\\') ++seps;
        return seps < 2;
    }
    return false;
}

/// Creates directory `p` and any missing ancestors, as `mkdir -p` does. Returns 0 when `p` ends up a
/// directory, including when it already was, ERROR_ALREADY_EXISTS when it exists as something else, and
/// otherwise the Win32 error of the failing call. Ancestors created before a failure remain.
DWORD mkdirRecursive(const std::wstring& p) {
    if (p.empty()) return ERROR_PATH_NOT_FOUND;
    if (::CreateDirectoryW(longPath(p).c_str(), nullptr)) return 0;
    DWORD code = ::GetLastError();
    if (code == ERROR_ALREADY_EXISTS || code == ERROR_ACCESS_DENIED) {
        DWORD attrs = ::GetFileAttributesW(longPath(p).c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) return 0;
        return code;
    }
    if (code != ERROR_PATH_NOT_FOUND) return code;
    // A missing ancestor: create the parent, then retry.
    std::wstring parent = p;
    while (parent.size() > 1 && isSep(parent.back())) parent.pop_back();
    size_t slash = parent.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return code;
    parent.resize(slash);
    if (isRootPath(parent) || parent == p) return code;
    DWORD pe = mkdirRecursive(parent);
    if (pe) return pe;
    if (::CreateDirectoryW(longPath(p).c_str(), nullptr)) return 0;
    code = ::GetLastError();
    if (code == ERROR_ALREADY_EXISTS) {
        DWORD attrs = ::GetFileAttributesW(longPath(p).c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) return 0;
    }
    return code;
}

/// Removes the entry `p` that is not a directory to descend into: a file, or a link (a directory link with
/// RemoveDirectoryW). `attrs` are its attributes. A read-only file loses that attribute first, since POSIX
/// unlink does not look at it. Returns 0 or the Win32 error.
DWORD removeEntry(const std::wstring& p, DWORD attrs) {
    std::wstring lp = longPath(p);
    if (attrs & FILE_ATTRIBUTE_DIRECTORY) return ::RemoveDirectoryW(lp.c_str()) ? 0 : ::GetLastError();
    if (attrs & FILE_ATTRIBUTE_READONLY) {
        DWORD keep = attrs & (FILE_ATTRIBUTE_ARCHIVE | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED |
                              FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_SYSTEM | FILE_ATTRIBUTE_TEMPORARY);
        ::SetFileAttributesW(lp.c_str(), keep ? keep : FILE_ATTRIBUTE_NORMAL);
    }
    return ::DeleteFileW(lp.c_str()) ? 0 : ::GetLastError();
}

/// Removes directory `dir` with its contents, without following links inside it. Returns 0 or the Win32 error
/// of the first failure, after which some entries may be gone. Removing the emptied directory is retried a few
/// times while it fails with ERROR_DIR_NOT_EMPTY, since a deleted file another process still has open lingers
/// until that process closes it.
DWORD removeTree(const std::wstring& dir) {
    std::wstring base = withSep(dir);
    WIN32_FIND_DATAW fd;
    HANDLE f = ::FindFirstFileW(longPath(base + L'*').c_str(), &fd);
    if (f == INVALID_HANDLE_VALUE) {
        DWORD c = ::GetLastError();
        if (c != ERROR_FILE_NOT_FOUND) return c;
    } else {
        DWORD code = 0;
        do {
            const wchar_t* n = fd.cFileName;
            if (std::wcscmp(n, L".") == 0 || std::wcscmp(n, L"..") == 0) continue;
            std::wstring child = base + n;
            bool link = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && isLinkTag(fd.dwReserved0);
            if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !link) code = removeTree(child);
            else code = removeEntry(child, fd.dwFileAttributes);
            if (code) break;
        } while (::FindNextFileW(f, &fd));
        if (code == 0) {
            DWORD c = ::GetLastError();
            if (c != ERROR_NO_MORE_FILES) code = c;
        }
        ::FindClose(f);
        if (code) return code;
    }
    std::wstring lp = longPath(dir);
    for (int attempt = 0;; ++attempt) {
        if (::RemoveDirectoryW(lp.c_str())) return 0;
        DWORD c = ::GetLastError();
        if (c != ERROR_DIR_NOT_EMPTY || attempt == 4) return c;
        ::Sleep(10u << attempt);
    }
}

} // namespace

// ---------------------------------------------------------------------------
// Directory getter helpers (FileSystem.hpp)
// ---------------------------------------------------------------------------

std::string win32CurrentDirectoryUtf8() {
    DWORD n = ::GetCurrentDirectoryW(0, nullptr);
    if (n == 0) return std::string();
    std::wstring w(n, L'\0');
    DWORD got = ::GetCurrentDirectoryW(n, &w[0]);
    if (got == 0 || got >= n) return std::string();
    return toUtf8(w.data(), got);
}

std::string win32EnvUtf8(const wchar_t* name) {
    DWORD n = ::GetEnvironmentVariableW(name, nullptr, 0);
    if (n == 0) return std::string();
    std::wstring w(n, L'\0');
    DWORD got = ::GetEnvironmentVariableW(name, &w[0], n);
    if (got == 0 || got >= n) return std::string();
    return toUtf8(w.data(), got);
}

// ---------------------------------------------------------------------------
// Path operations
// ---------------------------------------------------------------------------

// Follows a final link only when `i0` is not 0, and reports a failure as `stat` or `lstat` accordingly.
FsRes opStat(const FsArgs& a) {
    const bool follow = a.i0 != 0;
    const char* sc = follow ? "stat" : "lstat";
    std::wstring p = widePath(a.s1);
    DWORD flags = FILE_FLAG_BACKUP_SEMANTICS | (follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT);
    HANDLE h = ::CreateFileW(p.c_str(), FILE_READ_ATTRIBUTES, kShareAll, nullptr, OPEN_EXISTING, flags, nullptr);
    if (h == INVALID_HANDLE_VALUE) return winFail(::GetLastError(), sc, a.s1);
    FsRes r;
    DWORD code = statHandle(h, follow, r.ints);
    ::CloseHandle(h);
    if (code) return winFail(code, sc, a.s1);
    r.kind = FsRes::Kind::Ints;
    return r;
}

FsRes opAccess(const FsArgs& a) { return unsupported(a); }
FsRes opChmod(const FsArgs& a) { return unsupported(a); }
FsRes opChown(const FsArgs& a) { return unsupported(a); }

// `i1` and `i2` are the access and modification times in whole seconds. Changes a link itself when `i0` is 0,
// reporting a failure as `lutime`.
FsRes opUtimes(const FsArgs& a) {
    const char* sc = a.i0 ? "utime" : "lutime";
    std::wstring p = widePath(a.s1);
    DWORD flags = FILE_FLAG_BACKUP_SEMANTICS | (a.i0 ? 0 : FILE_FLAG_OPEN_REPARSE_POINT);
    HANDLE h = ::CreateFileW(p.c_str(), FILE_WRITE_ATTRIBUTES, kShareAll, nullptr, OPEN_EXISTING, flags, nullptr);
    if (h == INVALID_HANDLE_VALUE) return winFail(::GetLastError(), sc, a.s1);
    FILETIME at = secondsToFileTime(a.i1);
    FILETIME mt = secondsToFileTime(a.i2);
    DWORD code = ::SetFileTime(h, nullptr, &at, &mt) ? 0 : ::GetLastError();
    ::CloseHandle(h);
    if (code) return winFail(code, sc, a.s1);
    return FsRes{};
}

// Replaces an existing `s2` (but not a directory, which Windows refuses with EACCES). A failure quotes `s2`.
FsRes opRename(const FsArgs& a) {
    std::wstring from = widePath(a.s1);
    std::wstring to = widePath(a.s2);
    if (!::MoveFileExW(from.c_str(), to.c_str(), MOVEFILE_REPLACE_EXISTING))
        return winFail(::GetLastError(), "rename", a.s2);
    return FsRes{};
}

// Succeeds with the absolute path, with every link resolved, as a `Str`, without the "\\?\" prefix the system
// gives it ("\\?\UNC\" becomes "\\").
FsRes opRealpath(const FsArgs& a) {
    std::wstring p = widePath(a.s1);
    HANDLE h = ::CreateFileW(p.c_str(), 0, kShareAll, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (h == INVALID_HANDLE_VALUE) return winFail(::GetLastError(), "realpath", a.s1);
    std::vector<wchar_t> buf(512);
    DWORD n;
    for (;;) {
        n = ::GetFinalPathNameByHandleW(h, buf.data(), static_cast<DWORD>(buf.size()),
                                        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (n == 0) {
            DWORD code = ::GetLastError();
            ::CloseHandle(h);
            return winFail(code, "realpath", a.s1);
        }
        if (n < buf.size()) break;
        buf.resize(static_cast<size_t>(n) + 1);   // `n` is the size needed, with the terminating NUL
    }
    ::CloseHandle(h);
    std::wstring w(buf.data(), n);
    if (w.compare(0, 8, L"\\\\?\\UNC\\") == 0) w = L"\\\\" + w.substr(8);
    else if (w.compare(0, 4, L"\\\\?\\") == 0) w = w.substr(4);
    return stringRes(toUtf8(w.data(), w.size()));
}

FsRes opCopyFile(const FsArgs& a) { return unsupported(a); }

// Appends the bytes `s2` to `s1`, creating it if needed. A failing write is reported as `write`.
FsRes opAppendFile(const FsArgs& a) {
    return writeWhole(a, FILE_APPEND_DATA | SYNCHRONIZE, OPEN_ALWAYS, false, "write");
}

// Succeeds with the whole contents of `s1` as `Bytes`. A failing read or close is reported as `read`, and so is
// EISDIR for a directory.
FsRes opReadFile(const FsArgs& a) {
    std::wstring p = widePath(a.s1);
    HANDLE h = ::CreateFileW(p.c_str(), GENERIC_READ, kShareAll, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                             nullptr);
    if (h == INVALID_HANDLE_VALUE) return openFail(::GetLastError(), p, "open", "read", a.s1);
    FsRes r;
    r.kind = FsRes::Kind::Bytes;
    LARGE_INTEGER size;
    if (::GetFileSizeEx(h, &size) && size.QuadPart > 0) r.data.reserve(static_cast<size_t>(size.QuadPart));
    std::vector<char> buf(kChunk);
    DWORD code = 0;
    for (;;) {
        DWORD got = 0;
        if (!::ReadFile(h, buf.data(), kChunk, &got, nullptr)) {
            code = ::GetLastError();
            if (code == ERROR_HANDLE_EOF || code == ERROR_BROKEN_PIPE) code = 0;
            break;
        }
        if (got == 0) break;
        r.data.append(buf.data(), got);
    }
    if (!::CloseHandle(h) && code == 0) code = ::GetLastError();
    if (code) return winFail(code, "read", a.s1);
    return r;
}

// Replaces the contents of `s1` with the bytes `s2`, creating it if needed. The file is truncated rather than
// recreated, so it keeps its identity and attributes, as with POSIX O_TRUNC.
FsRes opWriteFile(const FsArgs& a) {
    return writeWhole(a, GENERIC_WRITE, OPEN_ALWAYS, true, "write");
}

FsRes opTruncate(const FsArgs& a) { return unsupported(a); }

// Removes `s1` without following a final link. A directory is removed with its contents when `i0` is not 0,
// and otherwise fails with node's code `ERR_FS_EISDIR` rather than an errno. Failures are reported as `rm`.
FsRes opRemove(const FsArgs& a) {
    std::wstring raw = toWide(a.s1);
    if (raw.empty()) return FsRes::fail(ENOENT, "rm", a.s1);
    DWORD attrs = ::GetFileAttributesW(longPath(raw).c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES) return winFail(::GetLastError(), "rm", a.s1);
    std::wstring entry = raw;
    while (entry.size() > 1 && isSep(entry.back()) && entry[entry.size() - 2] != L':') entry.pop_back();
    bool link = (attrs & FILE_ATTRIBUTE_REPARSE_POINT) && isLinkPath(entry);
    DWORD code;
    if ((attrs & FILE_ATTRIBUTE_DIRECTORY) && !link) {
        if (!a.i0) {
            FsRes r;
            r.code = "ERR_FS_EISDIR";
            r.message = "Path is a directory: rm returned EISDIR (is a directory) " + a.s1;
            return r;
        }
        code = removeTree(entry);
    } else {
        code = removeEntry(entry, attrs);
    }
    if (code) return winFail(code, "rm", a.s1);
    return FsRes{};
}

// Succeeds with the entries of directory `s1`, other than . and .., as `Dir` pairs of name and entity code,
// sorted by name in UTF-8 byte order. A link is reported as Symlink, not as its target. A path that exists but
// is not a directory fails with ENOTDIR.
FsRes opListDirectory(const FsArgs& a) {
    std::wstring raw = toWide(a.s1);
    if (raw.empty()) return FsRes::fail(ENOENT, "scandir", a.s1);
    WIN32_FIND_DATAW fd;
    HANDLE f = ::FindFirstFileExW(longPath(withSep(raw) + L'*').c_str(), FindExInfoBasic, &fd, FindExSearchNameMatch,
                                  nullptr, FIND_FIRST_EX_LARGE_FETCH);
    FsRes r;
    r.kind = FsRes::Kind::Dir;
    if (f == INVALID_HANDLE_VALUE) {
        DWORD code = ::GetLastError();
        DWORD attrs = ::GetFileAttributesW(longPath(raw).c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY))
            return FsRes::fail(ENOTDIR, "scandir", a.s1);
        if (attrs != INVALID_FILE_ATTRIBUTES && code == ERROR_FILE_NOT_FOUND) return r;   // an empty root
        return winFail(code, "scandir", a.s1);
    }
    DWORD code = 0;
    do {
        const wchar_t* n = fd.cFileName;
        if (std::wcscmp(n, L".") == 0 || std::wcscmp(n, L"..") == 0) continue;
        int64_t kind = 0;
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && isLinkTag(fd.dwReserved0)) kind = 3;
        else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) kind = 1;
        r.entries.emplace_back(toUtf8(n, std::wcslen(n)), kind);
    } while (::FindNextFileW(f, &fd));
    code = ::GetLastError();
    ::FindClose(f);
    if (code != ERROR_NO_MORE_FILES) return winFail(code, "scandir", a.s1);
    std::sort(r.entries.begin(), r.entries.end(),
              [](const auto& x, const auto& y) { return std::strcmp(x.first.c_str(), y.first.c_str()) < 0; });
    return r;
}

// Creates directory `s1`, with any missing ancestors when `i0` is not 0, in which case an existing directory
// is not an error.
FsRes opMakeDirectory(const FsArgs& a) {
    std::wstring raw = toWide(a.s1);
    if (raw.empty()) return FsRes::fail(ENOENT, "mkdir", a.s1);
    DWORD code;
    if (a.i0) code = mkdirRecursive(raw);
    else code = ::CreateDirectoryW(longPath(raw).c_str(), nullptr) ? 0 : ::GetLastError();
    if (code) return winFail(code, "mkdir", a.s1);
    return FsRes{};
}

FsRes opMakeTempDirectory(const FsArgs& a) { return unsupported(a); }
FsRes opLink(const FsArgs& a) { return unsupported(a); }
FsRes opSymlink(const FsArgs& a) { return unsupported(a); }
FsRes opReadLink(const FsArgs& a) { return unsupported(a); }
FsRes opUnlink(const FsArgs& a) { return unsupported(a); }

// ---------------------------------------------------------------------------
// File handles
// ---------------------------------------------------------------------------

// Opens `s1` with node flag string `s2` (one of r, r+, w, wx, w+, wx+; any other fails with EINVAL), and
// succeeds with a CRT fd for it as an `Int`.
FsRes opOpen(const FsArgs& a) {
    const std::string& f = a.s2;
    DWORD access, disposition;
    bool truncate = false;
    int crtFlags = 0;
    if (f == "r") { access = GENERIC_READ; disposition = OPEN_EXISTING; crtFlags = _O_RDONLY; }
    else if (f == "r+") { access = GENERIC_READ | GENERIC_WRITE; disposition = OPEN_EXISTING; }
    else if (f == "w") { access = GENERIC_WRITE; disposition = OPEN_ALWAYS; truncate = true; }
    else if (f == "wx") { access = GENERIC_WRITE; disposition = CREATE_NEW; }
    else if (f == "w+") { access = GENERIC_READ | GENERIC_WRITE; disposition = OPEN_ALWAYS; truncate = true; }
    else if (f == "wx+") { access = GENERIC_READ | GENERIC_WRITE; disposition = CREATE_NEW; }
    else return FsRes::fail(EINVAL, "open", a.s1);
    std::wstring p = widePath(a.s1);
    HANDLE h = ::CreateFileW(p.c_str(), access, kShareAll, nullptr, disposition, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return openFail(::GetLastError(), p, "open", "open", a.s1);
    if (truncate && !::SetEndOfFile(h)) {   // the file pointer is at 0 after the open
        DWORD code = ::GetLastError();
        ::CloseHandle(h);
        return winFail(code, "open", a.s1);
    }
    int fd = ::_open_osfhandle(reinterpret_cast<intptr_t>(h), crtFlags);
    if (fd < 0) {
        ::CloseHandle(h);
        return FsRes::fail(EMFILE, "open", a.s1);
    }
    FsRes r;
    r.kind = FsRes::Kind::Int;
    r.n = fd;
    return r;
}

// Closes CRT fd `i0`, and with it its OS handle.
FsRes opClose(const FsArgs& a) {
    if (::_close(static_cast<int>(a.i0)) != 0) return FsRes::fail(errno, "close");
    return FsRes{};
}

FsRes opFstat(const FsArgs& a) { return unsupported(a); }
FsRes opFchmod(const FsArgs& a) { return unsupported(a); }
FsRes opFchown(const FsArgs& a) { return unsupported(a); }
FsRes opFutimes(const FsArgs& a) { return unsupported(a); }
FsRes opReadFromOffset(const FsArgs& a) { return unsupported(a); }

// Writes all of the bytes `s2` to fd `i0` at offset `i1`, leaving the file pointer where it was (it is saved
// and restored around the write), or at the file pointer, advancing it, when `i1` is negative (node's -1).
FsRes opWriteFromOffset(const FsArgs& a) {
    HANDLE h = handleOfFd(a.i0);
    if (h == INVALID_HANDLE_VALUE) return FsRes::fail(EBADF, "write");
    const int64_t offset = a.i1 < 0 ? -1 : a.i1;
    LARGE_INTEGER zero = {};
    LARGE_INTEGER saved = {};
    bool restore = offset >= 0 && ::SetFilePointerEx(h, zero, &saved, FILE_CURRENT);
    DWORD code = writeAllHandle(h, a.s2.data(), a.s2.size(), offset);
    if (restore) ::SetFilePointerEx(h, saved, nullptr, FILE_BEGIN);
    if (code) return winFail(code, "write");
    return FsRes{};
}

FsRes opFtruncate(const FsArgs& a) { return unsupported(a); }

// Flushes the data and metadata of fd `i0` to storage. A handle opened only for reading has nothing to flush,
// and succeeds, as POSIX fsync does, although FlushFileBuffers refuses it with ERROR_ACCESS_DENIED.
FsRes opFsync(const FsArgs& a) {
    HANDLE h = handleOfFd(a.i0);
    if (h == INVALID_HANDLE_VALUE) return FsRes::fail(EBADF, "fsync");
    if (!::FlushFileBuffers(h)) {
        DWORD code = ::GetLastError();
        if (code != ERROR_ACCESS_DENIED) return winFail(code, "fsync");
    }
    return FsRes{};
}

FsRes opFdatasync(const FsArgs& a) { return unsupported(a); }
FsRes opReadFileStream(const FsArgs& a) { return unsupported(a); }
FsRes opWriteFileStream(const FsArgs& a) { return unsupported(a); }

} // namespace Eco::System::Fs
