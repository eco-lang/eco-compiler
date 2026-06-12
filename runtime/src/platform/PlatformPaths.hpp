// PlatformPaths.hpp — executable-path discovery, the platform seam for what
// was previously five direct readlink("/proc/self/exe") call sites (Darwin
// has no procfs). Header-only so eco-kernel-cpp can use it without library
// wiring. See plans/build-on-mac.md (M2 work items).

#pragma once

#include <climits>
#include <cstdint>
#include <cstdlib>
#include <string>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif

namespace eco::platform {

// Absolute path of the running executable, or "" if it cannot be determined
// (callers treat that as "no exe path" and fall back — see e.g.
// EcoBootConfig.cpp's runtimeDir()).
inline std::string currentExecutablePath() {
#if defined(__APPLE__)
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
inline std::string currentExecutableDir() {
    std::string exe = currentExecutablePath();
    if (exe.empty())
        return {};
    auto pos = exe.find_last_of('/');
    return (pos == std::string::npos) ? std::string(".") : exe.substr(0, pos);
}

} // namespace eco::platform
