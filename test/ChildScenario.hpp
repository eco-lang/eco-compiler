#pragma once

// Self-spawned child scenarios for the small unit-test binaries (eco-system-core-test,
// elm-kernel-time-test), plans/kernel-lib-bug-fixes.md "Shared infrastructure".
//
// A scenario is a named `int()` function registered with ChildScenario::add. The binary's main
// calls ChildScenario::dispatch(argc, argv) first thing: for `<binary> --child <name>` it runs that
// one scenario in this (fresh) process and exits with its return value, without static
// destructors. The parent starts it with ChildScenario::runChildScenario, which uses posix_spawn
// (never fork: a forked child inherits a copy of the parent's heap and singletons but none of their
// worker threads), passes extra environment variables, captures stdout and stderr, and returns how
// the child ended.
//
// A scenario starts from nothing: no allocator, no Scheduler, no service singletons. It sets up
// what it needs itself (the binaries offer a helper, e.g. initCoreRuntime() in
// test/eco-system-core/EcoSystemCoreTest.hpp). An uncaught exception exits with 99.
//
// Header-only and independent of any test framework. POSIX only.

#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <functional>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <poll.h>
#include <sys/resource.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#include <mach-o/dyld.h>
#endif

#if !defined(__APPLE__)
extern char** environ;
#endif

namespace ChildScenario {

using Scenario = std::function<int()>;

inline std::map<std::string, Scenario>& registry() {
    static std::map<std::string, Scenario> r;
    return r;
}

// Registers scenario `name`. Names are global to the binary: prefix them with the area under
// test ("work-pool/partial-start"). Registering a name twice aborts.
inline void add(const std::string& name, Scenario fn) {
    if (!registry().emplace(name, std::move(fn)).second) {
        std::fprintf(stderr, "ChildScenario: scenario '%s' registered twice\n", name.c_str());
        std::abort();
    }
}

// How a child scenario ended.
struct ChildRun {
    bool started = false;    // posix_spawn succeeded
    bool exited = false;     // ended normally, with exit status `exitCode`
    int exitCode = -1;
    bool signaled = false;   // killed by signal `signal`
    int signal = 0;
    bool timedOut = false;   // killed (SIGKILL) by runChildScenario at its timeout
    std::string out;         // everything the child wrote to stdout
    std::string err;         // everything the child wrote to stderr

    // Exited with status 0.
    bool ok() const { return exited && exitCode == 0; }
    // Killed by a signal (abort, segfault) or by the timeout.
    bool crashed() const { return signaled || timedOut; }
    // A one-line description, for test messages.
    std::string describe() const {
        if (!started) return "child not started";
        if (timedOut) return "timed out";
        if (signaled) return "killed by signal " + std::to_string(signal) + " (" + strsignal(signal) + ")";
        if (exited) return "exit " + std::to_string(exitCode);
        return "unknown end";
    }
};

inline std::string selfExePath() {
#if defined(__APPLE__)
    char buf[4096];
    uint32_t size = sizeof buf;
    if (_NSGetExecutablePath(buf, &size) == 0) return buf;
    return {};
#else
    char buf[4096];
    const ssize_t n = ::readlink("/proc/self/exe", buf, sizeof buf - 1);
    if (n <= 0) return {};
    buf[n] = '\0';
    return buf;
#endif
}

// Runs scenario `name` in a freshly spawned `<self> --child <name>`, with the parent's environment
// plus `extraEnv` (a pair replaces a variable of the same name), stdin from /dev/null. Waits up to
// `timeoutMs`, then kills it. Thread-safe with respect to other spawns (pipes are close-on-exec).
inline ChildRun runChildScenario(const std::string& name,
                                 const std::vector<std::pair<std::string, std::string>>& extraEnv = {},
                                 int timeoutMs = 60000) {
    ChildRun r;
    const std::string self = selfExePath();
    if (self.empty()) {
        r.err = "ChildScenario: cannot find own executable";
        return r;
    }
    std::fflush(stdout);
    std::fflush(stderr);

    // Environment: parent's minus the overridden names, then the extra pairs.
#if defined(__APPLE__)
    char** envp = *_NSGetEnviron();
#else
    char** envp = environ;
#endif
    std::vector<std::string> envStrings;
    for (char** e = envp; e && *e; ++e) {
        const char* eq = std::strchr(*e, '=');
        const std::string key = eq ? std::string(*e, static_cast<size_t>(eq - *e)) : std::string(*e);
        bool overridden = false;
        for (const auto& kv : extraEnv) overridden = overridden || kv.first == key;
        if (!overridden) envStrings.emplace_back(*e);
    }
    for (const auto& kv : extraEnv) envStrings.push_back(kv.first + "=" + kv.second);
    std::vector<char*> envv;
    for (auto& s : envStrings) envv.push_back(s.data());
    envv.push_back(nullptr);

    std::string a0 = self, a1 = "--child", a2 = name;
    char* argv[] = {a0.data(), a1.data(), a2.data(), nullptr};

    int outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
    auto mkpipe = [](int p[2]) {
#if defined(__linux__)
        return ::pipe2(p, O_CLOEXEC) == 0;
#else
        if (::pipe(p) != 0) return false;
        ::fcntl(p[0], F_SETFD, FD_CLOEXEC);
        ::fcntl(p[1], F_SETFD, FD_CLOEXEC);
        return true;
#endif
    };
    if (!mkpipe(outPipe) || !mkpipe(errPipe)) {
        r.err = std::string("ChildScenario: pipe failed: ") + std::strerror(errno);
        return r;
    }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1);
    posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t none;
    sigemptyset(&none);
    posix_spawnattr_setsigmask(&attr, &none);
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGTERM);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);

    pid_t pid = -1;
    const int rc = ::posix_spawn(&pid, self.c_str(), &fa, &attr, argv, envv.data());
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    ::close(outPipe[1]);
    ::close(errPipe[1]);
    if (rc != 0) {
        ::close(outPipe[0]);
        ::close(errPipe[0]);
        r.err = std::string("ChildScenario: posix_spawn failed: ") + std::strerror(rc);
        return r;
    }
    r.started = true;

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    bool outOpen = true, errOpen = true;
    bool reaped = false;
    int status = 0;
    char buf[4096];
    // Reads what is ready on the open pipes, waiting at most `waitMs`; returns whether anything was read.
    auto pump = [&](int waitMs) {
        pollfd fds[2];
        int n = 0;
        if (outOpen) fds[n++] = {outPipe[0], POLLIN, 0};
        if (errOpen) fds[n++] = {errPipe[0], POLLIN, 0};
        if (n == 0) {
            ::usleep(static_cast<useconds_t>(waitMs) * 1000);
            return false;
        }
        const int pr = ::poll(fds, static_cast<nfds_t>(n), waitMs);
        bool any = false;
        for (int i = 0; i < n && pr > 0; ++i) {
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            const ssize_t got = ::read(fds[i].fd, buf, sizeof buf);
            const bool isOut = fds[i].fd == outPipe[0];
            if (got > 0) {
                (isOut ? r.out : r.err).append(buf, static_cast<size_t>(got));
                any = true;
            } else if (got == 0 || (errno != EINTR && errno != EAGAIN)) {
                (isOut ? outOpen : errOpen) = false;
            }
        }
        return any;
    };
    while (!reaped) {
        if (std::chrono::steady_clock::now() >= deadline) {
            ::kill(pid, SIGKILL);
            r.timedOut = true;
            break;
        }
        pump(50);
        const pid_t w = ::waitpid(pid, &status, WNOHANG);
        if (w == pid) reaped = true;
    }
    if (reaped) {
        // The child is gone; take what is left in the pipes. A grandchild that inherited them may
        // keep them open, so stop once nothing arrives for 100 ms.
        while ((outOpen || errOpen) && pump(100)) {
        }
    } else {
        pid_t w;
        do {
            w = ::waitpid(pid, &status, 0);
        } while (w < 0 && errno == EINTR);
        reaped = w == pid;
    }
    ::close(outPipe[0]);
    ::close(errPipe[0]);
    if (reaped) {
        if (WIFEXITED(status)) {
            r.exited = true;
            r.exitCode = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            r.signaled = !r.timedOut;
            r.signal = WTERMSIG(status);
        }
    }
    return r;
}

// Runs registered scenario `name` in this process and returns its result (99 on an exception,
// 2 when there is no such scenario).
inline int runHere(const std::string& name) {
    auto it = registry().find(name);
    if (it == registry().end()) {
        std::fprintf(stderr, "ChildScenario: no scenario named '%s'\n", name.c_str());
        return 2;
    }
    int rc = 99;
    try {
        rc = it->second();
    } catch (const std::exception& e) {
        std::fprintf(stderr, "ChildScenario: '%s' threw: %s\n", name.c_str(), e.what());
    } catch (...) {
        std::fprintf(stderr, "ChildScenario: '%s' threw a non-std exception\n", name.c_str());
    }
    return rc;
}

// To be called first thing in main, after every scenario is registered. For
// `<self> --child <name>` it runs the scenario and leaves the process with its result (std::_Exit:
// no static destructors, no atexit handlers, as a crashed child would), with core dumps off.
// For `--list-scenarios` it prints the names and exits 0. Otherwise it returns and main continues.
inline void dispatch(int argc, char** argv) {
    if (argc >= 2 && std::strcmp(argv[1], "--list-scenarios") == 0) {
        for (const auto& kv : registry()) std::printf("%s\n", kv.first.c_str());
        std::fflush(stdout);
        std::_Exit(0);
    }
    if (argc >= 2 && std::strcmp(argv[1], "--child") == 0) {
        if (argc < 3) {
            std::fprintf(stderr, "usage: %s --child <scenario>\n", argv[0]);
            std::_Exit(2);
        }
        // A scenario may crash on purpose; never leave a core file behind.
        const rlimit noCore{0, 0};
        ::setrlimit(RLIMIT_CORE, &noCore);
        const int rc = runHere(argv[2]);
        std::fflush(nullptr);
        std::_Exit(rc);
    }
}

}  // namespace ChildScenario
