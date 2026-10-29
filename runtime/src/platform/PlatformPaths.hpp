// PlatformPaths.hpp - where the running executable is.
//
// Each operating system answers "where is the running executable" differently:
// Linux reads the /proc/self/exe link, Darwin asks dyld and resolves the
// answer with realpath, and Windows asks GetModuleFileNameW and converts the
// UTF-16 result to UTF-8. This header hides that behind two functions that
// return a path with '/' separators on every platform. It is header-only, so
// it can be used without linking against any runtime library.

#pragma once

#include <climits>
#include <cstdint>
#include <cstdlib>
#include <string>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif

namespace eco::platform {

#if !defined(_WIN32)
namespace detail {
// Returns the platform's native directory separator.
inline char dirSep() { return '/'; }
}
#else
namespace detail {
// Returns the platform's native directory separator.
inline char dirSep() { return '\\'; }
// Returns `s` with every backslash replaced by a forward slash.
inline std::string toForwardSlashes(std::string s) {
    for (char& c : s) if (c == '\\') c = '/';
    return s;
}
}
#endif

// Returns the path of the running executable, or "" if it cannot be
// determined.
//
// On Linux it is the target of /proc/self/exe, and a path of PATH_MAX bytes
// or more is silently cut short. On Darwin it is the dyld path resolved by
// realpath, or the unresolved dyld path if realpath fails. On Windows it is
// the module path converted to UTF-8, with backslashes turned into forward
// slashes; a path that does not fit in 32768 UTF-16 units is not detected
// and comes back cut short.
inline std::string currentExecutablePath() {
#if defined(_WIN32)
    // GetModuleFileNameW reports truncation by filling the whole buffer, so
    // the buffer doubles until the result is shorter than it.
    std::wstring wbuf;
    DWORD len = 0;
    for (DWORD cap = 512; cap <= 32768; cap *= 2) {
        wbuf.resize(cap);
        len = GetModuleFileNameW(NULL, wbuf.data(), cap);
        if (len == 0) return {};
        if (len < cap) { wbuf.resize(len); break; }
    }
    if (len == 0 || len >= wbuf.size() + 1) return {};
    int u8 = WideCharToMultiByte(CP_UTF8, 0, wbuf.data(), (int)wbuf.size(),
                                 nullptr, 0, nullptr, nullptr);
    if (u8 <= 0) return {};
    std::string out(u8, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wbuf.data(), (int)wbuf.size(),
                        out.data(), u8, nullptr, nullptr);
    return detail::toForwardSlashes(std::move(out));
#elif defined(__APPLE__)
    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0)
        return {};
    // _NSGetExecutablePath may return a path through symlinks; realpath
    // resolves it, as the kernel does for /proc/self/exe.
    char real[PATH_MAX];
    if (::realpath(buf, real) != nullptr)
        return std::string(real);
    return std::string(buf);
#else
    char buf[PATH_MAX];
    ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0)
        return {};
    buf[n] = '\0';
    return std::string(buf);
#endif
}

// Returns the directory that holds the running executable: the path from
// `currentExecutablePath` up to its last '/'. Returns "" if the path cannot
// be determined, and also for an executable directly under "/", and "." if
// the path contains no '/'.
inline std::string currentExecutableDir() {
    std::string exe = currentExecutablePath();
    if (exe.empty())
        return {};
    auto pos = exe.find_last_of('/');
    return (pos == std::string::npos) ? std::string(".") : exe.substr(0, pos);
}

} // namespace eco::platform
