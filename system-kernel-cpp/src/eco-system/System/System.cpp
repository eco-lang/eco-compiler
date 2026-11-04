//===- System.cpp - eco/system kernel module System (bodies) --------------===//
//
// The arguments are read from the operating system rather than from what `main` was given, so they are
// the full C argv of the process wherever the program was started from: /proc/self/cmdline on Linux,
// `_NSGetArgc`/`_NSGetArgv` on macOS and `__argc`/`__argv` on Windows. Elsewhere the list is empty.
//
//===----------------------------------------------------------------------===//

#include "eco-system/System/System.hpp"
#include "eco-system/System/SystemManager.hpp"

#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"
#include "allocator/RuntimeExports.h"

#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

#if defined(__APPLE__)
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#endif
#if !defined(_WIN32)
#include <unistd.h>
#endif

#if !defined(_WIN32) && !defined(__APPLE__)
extern char** environ;
#endif

namespace Eco::System {

namespace {

// --- Platform facts (no allocation) -----------------------------------------

// Returns Node's `process.platform` spelling for the platform this file is compiled for, or "unknown".
const char* platformName() {
#if defined(_WIN32)
    return "win32";
#elif defined(__APPLE__)
    return "darwin";
#elif defined(__linux__)
    return "linux";
#elif defined(__FreeBSD__)
    return "freebsd";
#elif defined(__OpenBSD__)
    return "openbsd";
#elif defined(__sun)
    return "sunos";
#elif defined(_AIX)
    return "aix";
#else
    return "unknown";
#endif
}

// Returns Node's `process.arch` spelling for the architecture this file is compiled for, or "unknown".
const char* archName() {
#if defined(__x86_64__) || defined(_M_X64)
    return "x64";
#elif defined(__aarch64__) || defined(_M_ARM64)
    return "arm64";
#elif defined(__i386__) || defined(_M_IX86)
    return "ia32";
#elif defined(__arm__) || defined(_M_ARM)
    return "arm";
#elif defined(__powerpc64__)
    return "ppc64";
#elif defined(__powerpc__)
    return "ppc";
#elif defined(__s390x__)
    return "s390x";
#elif defined(__s390__)
    return "s390";
#elif defined(__mips__) && defined(__MIPSEL__)
    return "mipsel";
#elif defined(__mips__)
    return "mips";
#elif defined(__riscv) && __riscv_xlen == 64
    return "riscv64";
#else
    return "unknown";
#endif
}

// Returns the path of the running executable, or "" if it cannot be read. On macOS the path is resolved
// with `realpath`, falling back to the unresolved one; on Linux it is the /proc/self/exe link; on other
// platforms it is always "".
std::string applicationPath() {
#if defined(__APPLE__)
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string raw(size, '\0');
    if (_NSGetExecutablePath(raw.data(), &size) != 0) return "";
    raw.resize(std::char_traits<char>::length(raw.c_str()));
    char resolved[PATH_MAX];
    if (::realpath(raw.c_str(), resolved)) return resolved;
    return raw;
#elif defined(__linux__)
    std::vector<char> buf(PATH_MAX);
    for (;;) {
        ssize_t n = ::readlink("/proc/self/exe", buf.data(), buf.size());
        if (n < 0) return "";
        if (static_cast<size_t>(n) < buf.size()) return std::string(buf.data(), static_cast<size_t>(n));
        buf.resize(buf.size() * 2);
    }
#else
    return "";
#endif
}

// Returns the process's command-line arguments: /proc/self/cmdline on Linux, `_NSGetArgc`/`_NSGetArgv` on
// macOS, `__argc`/`__argv` on Windows, and an empty list elsewhere. On Linux an unreadable
// /proc/self/cmdline gives an empty list.
std::vector<std::string> processArgs() {
    std::vector<std::string> out;
#if defined(__APPLE__)
    int argc = *_NSGetArgc();
    char** argv = *_NSGetArgv();
    for (int i = 0; i < argc; ++i) out.emplace_back(argv[i] ? argv[i] : "");
#elif defined(__linux__)
    std::ifstream in("/proc/self/cmdline", std::ios::binary);
    std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    size_t start = 0;
    while (start < all.size()) {
        size_t end = all.find('\0', start);
        if (end == std::string::npos) end = all.size();
        out.emplace_back(all, start, end - start);
        start = end + 1;
    }
#elif defined(_WIN32)
    for (int i = 0; i < __argc; ++i) out.emplace_back(__argv[i] ? __argv[i] : "");
#endif
    return out;
}

// Returns the process's environment block, a null-terminated array of "name=value" strings.
char** environment() {
#if defined(__APPLE__)
    return *_NSGetEnviron();
#elif defined(_WIN32)
    return _environ;
#else
    return environ;
#endif
}

// --- Stdio pairs --------------------------------------------------------------

// Writes the ids of the stdin, stdout and stderr stream pairs to `ids`. The pairs are made, without taking
// ownership of fds 0 to 2, and pinned when the cache is from an older heap generation (a heap reset clears
// the stream table) or any cached id is no longer in the table; otherwise the cached ids are reused. Eco
// thread only: the cache is an unguarded function static.
void stdioIds(int64_t ids[3]) {
    struct Cache {
        uint64_t gen = 0;
        bool made = false;
        int64_t ids[3] = {0, 0, 0};
    };
    static Cache c;
    auto& table = streamTable();
    uint64_t g = Allocator::instance().heapGeneration();
    bool valid = c.made && c.gen == g;
    for (int i = 0; valid && i < 3; ++i) valid = table.find(c.ids[i]) != nullptr;
    if (!valid) {
        c.ids[0] = createFdSource(0, /*owns=*/false, "stdio");
        c.ids[1] = createFdSink(1, /*owns=*/false, "stdio");
        c.ids[2] = createFdSink(2, /*owns=*/false, "stdio");
        for (int i = 0; i < 3; ++i) pinStream(c.ids[i]);
        c.gen = g;
        c.made = true;
    }
    for (int i = 0; i < 3; ++i) ids[i] = c.ids[i];
}

// --- Builders (eco thread) ------------------------------------------------------

// Builds an Elm `List String` of `items`, in order.
HPointer stringList(const std::vector<std::string>& items) {
    std::vector<HPointer> ptrs(items.size(), alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);
    for (size_t i = 0; i < items.size(); ++i) {
        ptrs[i] = alloc::allocStringFromUTF8(items[i]);
    }
    HPointer list = alloc::listFromPointers(ptrs);
    rs.restoreStackRangePoint(saved);
    return list;
}

// Builds an Elm `List ( String, String )` of `items`, in order.
HPointer stringPairList(const std::vector<std::pair<std::string, std::string>>& items) {
    std::vector<HPointer> ptrs(items.size(), alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);
    for (size_t i = 0; i < items.size(); ++i) {
        ptrs[i] = alloc::allocStringFromUTF8(items[i].first);   // rooted in the range
        HPointer value = alloc::allocStringFromUTF8(items[i].second);
        // `value` is fresh and goes straight into tuple2, which roots its boxed fields.
        ptrs[i] = alloc::tuple2(alloc::boxed(ptrs[i]), alloc::boxed(value), 0);
    }
    HPointer list = alloc::listFromPointers(ptrs);
    rs.restoreStackRangePoint(saved);
    return list;
}

// Returns the value of the boxed Int `captured`.
int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

} // namespace

HPointer systemEnvironmentNow() {
    // Everything that does not allocate on the heap is gathered first.
    std::string plat = platformName();
    std::string arch = archName();
    std::string app = applicationPath();
    std::vector<std::string> args = processArgs();
    int64_t startMillis = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::system_clock::now().time_since_epoch())
                              .count();
    int64_t ids[3];
    stdioIds(ids);

    HPointer platHP = alloc::allocStringFromUTF8(plat);
    HPointer archHP = alloc::listNil(), appHP = alloc::listNil();
    HPointer names = alloc::listNil(), argList = alloc::listNil(), argsTime = alloc::listNil();
    Elm::StackRootGuard g({&platHP, &archHP, &appHP, &names, &argList, &argsTime});
    archHP = alloc::allocStringFromUTF8(arch);
    appHP = alloc::allocStringFromUTF8(app);
    names = alloc::tuple3(alloc::boxed(platHP), alloc::boxed(archHP),
                          alloc::boxed(appHP), 0);
    argList = stringList(args);
    // ( List String, Int ): slot 1 unboxed (2 bits per slot, so mask 0x4).
    argsTime = alloc::tuple2(alloc::boxed(argList), alloc::unboxedInt(startMillis), 0x4);
    HPointer stdio = alloc::tuple3(alloc::unboxedInt(ids[0]), alloc::unboxedInt(ids[1]),
                                   alloc::unboxedInt(ids[2]), 0x15);
    // `stdio` is fresh and goes straight into tuple3, which roots its boxed fields.
    return alloc::tuple3(alloc::boxed(names), alloc::boxed(argsTime), alloc::boxed(stdio), 0);
}

HPointer systemGetEnvironmentVariablesBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        std::vector<std::pair<std::string, std::string>> vars;
        if (char** env = environment()) {
            for (char** e = env; *e; ++e) {
                std::string entry(*e);
                size_t eq = entry.find('=');
                if (eq == std::string::npos) {
                    vars.emplace_back(entry, std::string());
                } else {
                    vars.emplace_back(entry.substr(0, eq), entry.substr(eq + 1));
                }
            }
        }
        return succeed(stringPairList(vars));
    )
}

HPointer systemExitWithCodeBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int code = static_cast<int>(payloadInt(captured));
        eco_set_exit_code(code);
        auto& sched = Scheduler::instance();
        if (sched.embedMode()) {
            // The host owns the process, so only the loop stops; the host's
            // eco_app_join returns the code.
            sched.requestStop();
            return succeedUnit();
        }
        std::fflush(nullptr);
        std::exit(code);
    )
}

HPointer systemSetExitCodeBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        eco_set_exit_code(static_cast<int>(payloadInt(captured)));
        return succeedUnit();
    )
}

HPointer systemRearmEmptyEventLoopBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        SystemManager::rearmEmptyEventLoop();
        return succeedUnit();
    )
}

} // namespace Eco::System
