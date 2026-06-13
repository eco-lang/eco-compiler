// PlatformPaths.hpp — executable-path discovery, the platform seam for what
// was previously five direct readlink("/proc/self/exe") call sites (Darwin
// has no procfs; Win64 has no procfs and no path-style readlink). Header-only
// so eco-kernel-cpp can use it without library wiring. See
// plans/build-on-mac.md (M2 work items) and plans/build-on-windows.md (item 11).

#pragma once

#include <climits>
#include <cstdint>
#include <cstdlib>
#include <string>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
// Win32 has no PATH_MAX in the POSIX sense; MAX_PATH (260) is too small for
// modern long paths. The widechar API takes a buffer length and tells us how
// many chars it wrote, so we pick a generous size and grow if truncated.
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif

namespace eco::platform {

#if !defined(_WIN32)
namespace detail {
inline char dirSep() { return '/'; }
}
#else
namespace detail {
inline char dirSep() { return '\\'; }
// Convert a Windows-narrow path to forward slashes for callers that join
// with '/'. The Win32 exe path returned by GetModuleFileNameW is canonical
// — drive letter + '\' separators — and downstream code (e.g. paths fed to
// Node's require, MLIR locations) handles both separators, so normalizing
// is convenient but optional.
inline std::string toForwardSlashes(std::string s) {
    for (char& c : s) if (c == '\\') c = '/';
    return s;
}
}
#endif

// Absolute path of the running executable, or "" if it cannot be determined
// (callers treat that as "no exe path" and fall back — see e.g.
// EcoBootConfig.cpp's runtimeDir()).
inline std::string currentExecutablePath() {
#if defined(_WIN32)
    // GetModuleFileNameW(NULL) returns the running executable's path in the
    // current code page; we widen-to-narrow via WideCharToMultiByte(CP_UTF8)
    // so the result round-trips through Node/Elm string handling. Grow the
    // buffer until the API reports it fit (writes fewer chars than buffer).
    std::wstring wbuf;
    DWORD len = 0;
    for (DWORD cap = 512; cap <= 32768; cap *= 2) {
        wbuf.resize(cap);
        len = GetModuleFileNameW(NULL, wbuf.data(), cap);
        if (len == 0) return {};
        if (len < cap) { wbuf.resize(len); break; }
        // Truncated: GetModuleFileNameW returned cap (buffer full) — grow.
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
    // _NSGetExecutablePath may return a symlink-y / non-canonical path;
    // realpath matches readlink(/proc/self/exe)'s resolved behavior.
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

// dirname of the running executable, or "" on failure. (Both behaviors the
// previous per-site implementations had: Runtime.cpp returned the path
// unchanged when it contained no '/', EcoBootConfig.cpp returned "." — a
// path from currentExecutablePath() is absolute, so the case cannot arise.)
//
// Note: on Windows the path returned by currentExecutablePath() has already
// been normalised to forward slashes, so a single find_last_of('/') works on
// all platforms.
inline std::string currentExecutableDir() {
    std::string exe = currentExecutablePath();
    if (exe.empty())
        return {};
    auto pos = exe.find_last_of('/');
    return (pos == std::string::npos) ? std::string(".") : exe.substr(0, pos);
}

} // namespace eco::platform
