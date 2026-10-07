//===- System.cpp - eco/system kernel module System (bodies) --------------===//
//
// plans/eco-system-library.md Appendix B.1 and §3.7 / §3.8:
//   * environment   — ((platform, arch, applicationPath), argv, (stdin,
//                     stdout, stderr) pair ids). The stdio pairs are an
//                     FdSource on fd 0 and FdSinks on fds 1 and 2, created
//                     lazily once per process (per heap generation, F24) and
//                     pinned; fds 0–2 are never closed (§3.4).
//   * getPlatform / getCpuArchitecture — compile-time values, Node's
//                     spellings (§3.8).
//   * getEnvironmentVariables — `environ`, split at the first '='.
//   * exitWithCode  — standalone: fflush + std::exit; embed: set the code
//                     and request a stop (§3.7).
//   * setExitCode   — eco_set_exit_code.
//
// argv is read from the operating system (/proc/self/cmdline on Linux,
// _NSGetArgc/_NSGetArgv on macOS, __argc/__argv on Windows), which is the
// full C argv of the process (D10) without a dependency on eco/kernel's Env
// (D1). Embedded in a host, it is the host's argv.
//
// Templates used: T1 (bodies), T3 (lists of strings / pairs).
//
//===----------------------------------------------------------------------===//

#include "eco-system/System/System.hpp"

#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"
#include "allocator/RuntimeExports.h"

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

// Node's compile-time `process.arch` spellings (§3.8).
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

// The stdin/stdout/stderr pair ids, created once per heap generation (the
// table of a dead heap is cleared, F24) and pinned. Main thread only.
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
        c.ids[0] = createFdSource(0, /*owns=*/false);
        c.ids[1] = createFdSink(1, /*owns=*/false);
        c.ids[2] = createFdSink(2, /*owns=*/false);
        for (int i = 0; i < 3; ++i) pinStream(c.ids[i]);
        c.gen = g;
        c.made = true;
    }
    for (int i = 0; i < 3; ++i) ids[i] = c.ids[i];
}

// --- Builders (main thread; T3) -------------------------------------------------

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

HPointer stringPairList(const std::vector<std::pair<std::string, std::string>>& items) {
    std::vector<HPointer> ptrs(items.size(), alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);
    for (size_t i = 0; i < items.size(); ++i) {
        ptrs[i] = alloc::allocStringFromUTF8(items[i].first);   // rooted in the range
        HPointer value = alloc::allocStringFromUTF8(items[i].second);
        // `value` is fresh and goes straight into the helper, which roots it (G4).
        ptrs[i] = alloc::tuple2(alloc::boxed(ptrs[i]), alloc::boxed(value), 0);
    }
    HPointer list = alloc::listFromPointers(ptrs);
    rs.restoreStackRangePoint(saved);
    return list;
}

int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

} // namespace

// environment : Task Never ( ( String, String, String ), List String, ( Int, Int, Int ) )
HPointer systemEnvironmentBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        // G3: gather everything first.
        std::string plat = platformName();
        std::string arch = archName();
        std::string app = applicationPath();
        std::vector<std::string> args = processArgs();
        int64_t ids[3];
        stdioIds(ids);

        HPointer platHP = alloc::allocStringFromUTF8(plat);
        HPointer archHP = alloc::listNil(), appHP = alloc::listNil();
        HPointer names = alloc::listNil(), argList = alloc::listNil();
        Elm::StackRootGuard g({&platHP, &archHP, &appHP, &names, &argList});
        archHP = alloc::allocStringFromUTF8(arch);
        appHP = alloc::allocStringFromUTF8(app);
        names = alloc::tuple3(alloc::boxed(platHP), alloc::boxed(archHP),
                              alloc::boxed(appHP), 0);
        argList = stringList(args);
        HPointer stdio = alloc::tuple3(alloc::unboxedInt(ids[0]), alloc::unboxedInt(ids[1]),
                                       alloc::unboxedInt(ids[2]), 0x15);
        // `stdio` is fresh and goes straight into the helper (G4).
        HPointer result = alloc::tuple3(alloc::boxed(names), alloc::boxed(argList),
                                        alloc::boxed(stdio), 0);
        return succeed(result);
    )
}

// getPlatform : Task Never String
HPointer systemGetPlatformBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        return succeedString(platformName());
    )
}

// getCpuArchitecture : Task Never String
HPointer systemGetCpuArchitectureBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        return succeedString(archName());
    )
}

// getEnvironmentVariables : Task Never (List ( String, String ))
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

// exitWithCode : Int -> Task Never () — payload: boxed Int.
HPointer systemExitWithCodeBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int code = static_cast<int>(payloadInt(captured));
        eco_set_exit_code(code);
        auto& sched = Scheduler::instance();
        if (sched.embedMode()) {
            // The host owns the process: stop the loop; eco_app_join returns
            // the code (§3.7).
            sched.requestStop();
            return succeedUnit();
        }
        std::fflush(nullptr);
        std::exit(code);   // as in gren, pending IO is not waited for
    )
}

// setExitCode : Int -> Task Never () — payload: boxed Int.
HPointer systemSetExitCodeBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        eco_set_exit_code(static_cast<int>(payloadInt(captured)));
        return succeedUnit();
    )
}

} // namespace Eco::System
