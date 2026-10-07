//===- Spawn.cpp - posix_spawn of a child process (POD only) --------------===//
//
// See Spawn.hpp. No heap access (G1/G3): the caller has already copied
// every input out of the heap.
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#include "eco-system/ChildProcess/Spawn.hpp"
#include "eco-system/Core/FdChannel.hpp"   // makeCloexecPipe

#include <cerrno>
#include <cstring>
#include <unordered_map>

#ifndef _WIN32
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#endif

#ifndef _WIN32
extern char** environ;
#endif

namespace Eco::System {

#ifdef _WIN32

SpawnedChild spawnChild(const SpawnSpec&, StdioMode, bool) {
    SpawnedChild c;
    c.err = ENOTSUP;
    return c;
}

#else // POSIX

namespace {

// The environment block for the child, as "K=V" strings.
std::vector<std::string> buildEnv(const SpawnSpec& spec) {
    std::vector<std::string> out;
    if (spec.envMode != kEnvReplace) {
        for (char** e = environ; e && *e; ++e) out.emplace_back(*e);
    }
    if (spec.envMode == kEnvInherit) return out;
    std::unordered_map<std::string, size_t> index;   // key -> position in out
    for (size_t i = 0; i < out.size(); ++i) {
        size_t eq = out[i].find('=');
        index.emplace(out[i].substr(0, eq), i);
    }
    for (const auto& [k, v] : spec.env) {
        std::string kv = k + "=" + v;
        auto it = index.find(k);
        if (it != index.end()) {
            out[it->second] = std::move(kv);
        } else {
            index.emplace(k, out.size());
            out.push_back(std::move(kv));
        }
    }
    return out;
}

std::vector<char*> cstrs(std::vector<std::string>& v) {
    std::vector<char*> out;
    out.reserve(v.size() + 1);
    for (auto& s : v) out.push_back(s.data());
    out.push_back(nullptr);
    return out;
}

void closeIf(int& fd) {
    if (fd >= 0) {
        ::close(fd);
        fd = -1;
    }
}

// RAII for the posix_spawn attribute / file-action objects.
struct SpawnObjects {
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    bool faInit = false, attrInit = false;
    ~SpawnObjects() {
        if (faInit) posix_spawn_file_actions_destroy(&fa);
        if (attrInit) posix_spawnattr_destroy(&attr);
    }
};

} // namespace

SpawnedChild spawnChild(const SpawnSpec& spec, StdioMode mode, bool newSession) {
    SpawnedChild c;

    // --- argv and the file to execute (Shell, step 5.2) --------------------
    std::vector<std::string> argv;
    std::string file;
    bool searchPath = true;
    if (spec.shellKind == kShellNone) {
        file = spec.program;
        argv.push_back(spec.program);
        for (const auto& a : spec.args) argv.push_back(a);
    } else {
        std::string line = spec.program;
        for (const auto& a : spec.args) {
            line += ' ';
            line += a;
        }
        if (spec.shellKind == kShellCustom && !spec.customShell.empty()) {
            file = spec.customShell;
        } else {
            file = "/bin/sh";
            searchPath = false;
        }
        argv.push_back(file);
        argv.push_back("-c");
        argv.push_back(line);
    }

    bool chdirViaShell = false;
#if !defined(ECO_SYSTEM_HAVE_ADDCHDIR_NP)
    if (!spec.inheritCwd) {
        // /bin/sh -c 'cd "$0" && exec "$@"' <cwd> <argv...>
        std::vector<std::string> wrapped{"/bin/sh", "-c", "cd \"$0\" && exec \"$@\"", spec.cwd};
        for (auto& a : argv) wrapped.push_back(std::move(a));
        argv = std::move(wrapped);
        file = "/bin/sh";
        searchPath = false;
        chdirViaShell = true;
    }
#endif
    (void)chdirViaShell;

    std::vector<std::string> envStrs = buildEnv(spec);
    std::vector<char*> argvC = cstrs(argv);
    std::vector<char*> envC = cstrs(envStrs);

    // --- stdio -------------------------------------------------------------
    int inPipe[2] = {-1, -1}, outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
    int devNull = -1;
    auto fail = [&](int e) {
        closeIf(inPipe[0]); closeIf(inPipe[1]);
        closeIf(outPipe[0]); closeIf(outPipe[1]);
        closeIf(errPipe[0]); closeIf(errPipe[1]);
        closeIf(devNull);
        c.err = e;
        return c;
    };
    if (mode == StdioMode::Pipes) {
        if (int e = makeCloexecPipe(inPipe, false)) return fail(e);
    }
    if (mode == StdioMode::Pipes || mode == StdioMode::RunPipes) {
        if (int e = makeCloexecPipe(outPipe, false)) return fail(e);
        if (int e = makeCloexecPipe(errPipe, false)) return fail(e);
    }
    if (mode == StdioMode::Null || mode == StdioMode::RunPipes) {
        devNull = ::open("/dev/null", O_RDWR | O_CLOEXEC);
        if (devNull < 0) return fail(errno);
    }

    SpawnObjects so;
    if (int e = posix_spawn_file_actions_init(&so.fa)) return fail(e);
    so.faInit = true;
    if (int e = posix_spawnattr_init(&so.attr)) return fail(e);
    so.attrInit = true;

    int rc = 0;
    auto dup2Into = [&](int from, int to) {
        if (rc == 0) rc = posix_spawn_file_actions_adddup2(&so.fa, from, to);
    };
    switch (mode) {
        case StdioMode::Inherit:
#if defined(__APPLE__)
            for (int fd = 0; fd <= 2 && rc == 0; ++fd)
                rc = posix_spawn_file_actions_addinherit_np(&so.fa, fd);
#endif
            break;
        case StdioMode::Pipes:
            dup2Into(inPipe[0], 0);
            dup2Into(outPipe[1], 1);
            dup2Into(errPipe[1], 2);
            break;
        case StdioMode::Null:
            dup2Into(devNull, 0);
            dup2Into(devNull, 1);
            dup2Into(devNull, 2);
            break;
        case StdioMode::RunPipes:
            dup2Into(devNull, 0);
            dup2Into(outPipe[1], 1);
            dup2Into(errPipe[1], 2);
            break;
    }
    if (rc) return fail(rc);

#if defined(ECO_SYSTEM_HAVE_ADDCHDIR_NP)
    if (!spec.inheritCwd) {
        if (int e = posix_spawn_file_actions_addchdir_np(&so.fa, spec.cwd.c_str())) return fail(e);
    }
#endif

    short flags = 0;
#if defined(__APPLE__)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    // The child starts with default signal dispositions for the signals we
    // may be catching (a caught signal is reset by exec anyway; SIG_IGN of
    // SIGPIPE, set by eco_entry, would be inherited).
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGWINCH);
    if (int e = posix_spawnattr_setsigdefault(&so.attr, &defaults)) return fail(e);
    flags |= POSIX_SPAWN_SETSIGDEF;
    // Nor does it inherit the calling thread's signal mask.
    sigset_t noMask;
    sigemptyset(&noMask);
    if (int e = posix_spawnattr_setsigmask(&so.attr, &noMask)) return fail(e);
    flags |= POSIX_SPAWN_SETSIGMASK;
    if (newSession) {
#if defined(POSIX_SPAWN_SETSID)
        flags |= POSIX_SPAWN_SETSID;
#else
        if (int e = posix_spawnattr_setpgroup(&so.attr, 0)) return fail(e);
        flags |= POSIX_SPAWN_SETPGROUP;
#endif
    }
    if (int e = posix_spawnattr_setflags(&so.attr, flags)) return fail(e);

    pid_t pid = -1;
    int e = searchPath
        ? posix_spawnp(&pid, file.c_str(), &so.fa, &so.attr, argvC.data(), envC.data())
        : posix_spawn(&pid, file.c_str(), &so.fa, &so.attr, argvC.data(), envC.data());
    if (e != 0) return fail(e);

    // The child's ends belong to the child now.
    closeIf(inPipe[0]);
    closeIf(outPipe[1]);
    closeIf(errPipe[1]);
    closeIf(devNull);
    c.pid = pid;
    c.stdinFd = inPipe[1];
    c.stdoutFd = outPipe[0];
    c.stderrFd = errPipe[0];
    return c;
}

#endif // _WIN32

} // namespace Eco::System
