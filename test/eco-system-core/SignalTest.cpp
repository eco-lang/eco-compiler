// SignalService unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/Core/SignalService.cpp),
// next to the ones in EcoSystemCoreTest.cpp.
//
// SIG-03: `SignalService::addListener` subscribed first and then `push_back`ed; a throwing
//   `push_back` left `counts_` one too high, so the signal's previous disposition was never
//   restored. Fixed: the room is reserved before subscribing. Child scenario "signal/add-listener-push-back-oom" fills `listeners_` to a power-of-two capacity,
//   lowers RLIMIT_AS so that the next reallocation fails, and checks subscribers == listeners and
//   that SIG_IGN comes back once every listener is removed. (A RLIMIT_AS window instead of a
//   replacement global operator new, so this file defines no global symbol another file could
//   collide with.)
// SIG-04: `chainToPrevious` swapped the previous disposition in, raised, and swapped ours back; an
//   instance of the signal that arrived in that window went to the old disposition, not to Eco.
//   The in-process check makes the previous handler re-raise once (pending while it runs, so
//   delivered on return): before the fix it ran twice and nothing was queued. Fixed: a previous
//   handler is called directly with ours left installed, so the second instance is queued.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/ChildProcess/ChildProcess.hpp"
#include "eco-system/ChildProcess/ChildProcessManager.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/SignalService.hpp"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <thread>
#include <vector>

#include <dirent.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace Eco::System;

namespace {

void (*currentHandler(int signo))(int) {
    struct sigaction sa {};
    ::sigaction(signo, nullptr, &sa);
    return sa.sa_handler;
}

bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

// ---------------------------------------------------------------------------
// SIG-03
// ---------------------------------------------------------------------------

void noopListener(int, void*) {}

// Pages of address space this process has mapped (/proc/self/statm, first field).
long mappedPages() {
    FILE* f = std::fopen("/proc/self/statm", "r");
    if (!f) return -1;
    long pages = -1;
    if (std::fscanf(f, "%ld", &pages) != 1) pages = -1;
    std::fclose(f);
    return pages;
}

int scenarioAddListenerPushBackOom() {
    initCoreRuntime();
    auto& svc = SignalService::instance();
    struct sigaction ign {};
    ign.sa_handler = SIG_IGN;
    sigemptyset(&ign.sa_mask);
    ::sigaction(SIGUSR2, &ign, nullptr);

    // 32768 listeners: libstdc++/libc++ grow by doubling from empty, so `listeners_` (the only
    // ones in this fresh process) is now exactly full, and the next push_back reallocates 2 MiB.
    constexpr size_t kFill = 32768;
    std::vector<SignalService::ListenerId> ids;
    ids.reserve(kFill + 100000);   // no allocation of ours inside the window
    for (size_t i = 0; i < kFill; ++i) {
        auto id = svc.addListener(SIGUSR2, &noopListener, nullptr);
        if (id == 0) {
            std::printf("SIG-03 precondition: addListener %zu returned 0\n", i);
            return 1;
        }
        ids.push_back(id);
    }

    // Leave 512 KiB of address space: small allocations still succeed, the 2 MiB growth cannot.
    struct rlimit saved {};
    if (::getrlimit(RLIMIT_AS, &saved) != 0) return 1;
    const long pages = mappedPages();
    if (pages <= 0) {
        std::printf("SIG-03 precondition: cannot read /proc/self/statm\n");
        return 1;
    }
    struct rlimit tight = saved;
    tight.rlim_cur = static_cast<rlim_t>(pages) * static_cast<rlim_t>(::sysconf(_SC_PAGESIZE)) + 512 * 1024;
    if (saved.rlim_max != RLIM_INFINITY && tight.rlim_cur > saved.rlim_max) tight.rlim_cur = saved.rlim_max;
    if (::setrlimit(RLIMIT_AS, &tight) != 0) {
        std::printf("SIG-03 precondition: setrlimit failed: %s\n", std::strerror(errno));
        return 1;
    }
    bool threw = false;
    size_t extra = 0;
    for (size_t i = 0; i < 100000; ++i) {
        try {
            auto id = svc.addListener(SIGUSR2, &noopListener, nullptr);
            if (id == 0) break;
            ids.push_back(id);
            ++extra;
        } catch (const std::bad_alloc&) {
            threw = true;
            break;
        }
    }
    ::setrlimit(RLIMIT_AS, &saved);

    const int subs = svc.subscribers(SIGUSR2);
    const int listeners = svc.listenerCount(SIGUSR2);
    // Remove from the newest: each removal then erases the vector's last element.
    for (size_t i = ids.size(); i-- > 0;) svc.removeListener(ids[i]);
    const bool restored = currentHandler(SIGUSR2) == SIG_IGN;
    std::printf("SIG-03 threw=%d extra=%zu subscribers=%d listeners=%d restored=%d left=%d\n", threw ? 1 : 0,
                extra, subs, listeners, restored ? 1 : 0, svc.subscribers(SIGUSR2));
    std::fflush(stdout);
    return 0;
}

void testAddListenerPushBackOom() {
    std::printf("signal/add-listener-push-back-throw-leaks-no-subscription\n");
    auto r = ChildScenario::runChildScenario("signal/add-listener-push-back-oom", {}, 60000);
    CHECK_MSG(r.ok(), r.describe() + "; stdout: " + r.out + "; stderr: " + r.err);
    if (!r.ok()) return;
    const size_t at = r.out.find("SIG-03 threw=");
    CHECK_MSG(at != std::string::npos, "stdout: " + r.out);
    if (at == std::string::npos) return;
    std::string line = r.out.substr(at, r.out.find('\n', at) - at);
    // Precondition: the push_back did throw inside addListener.
    CHECK_MSG(contains(line, "threw=1 "), line);
    if (!contains(line, "threw=1 ")) return;
    CHECK_MSG(contains(line, "restored=1"),
              "SIG-03 " + line + " (subscribers > listeners and SIG_IGN not restored = the subscription leaked)");
}

// ---------------------------------------------------------------------------
// SIG-04
// ---------------------------------------------------------------------------

std::atomic<int> g_reraiseHits{0};
// The "previous" SIGUSR2 handler: on its first call it raises SIGUSR2 again. SIGUSR2 is blocked
// while it runs, so the second instance stays pending and is delivered as soon as it returns,
// while chainToPrevious still has this handler installed.
extern "C" void prevHandlerReraise(int) {
    if (g_reraiseHits.fetch_add(1) == 0) ::raise(SIGUSR2);
}

void testChainToPreviousSecondInstance() {
    std::printf("signal/chain-to-previous-queues-a-signal-arriving-in-the-window\n");
    auto& svc = SignalService::instance();
    int stray;
    while (svc.tryPop(stray)) {}

    struct sigaction prev {};
    prev.sa_handler = &prevHandlerReraise;
    sigemptyset(&prev.sa_mask);
    ::sigaction(SIGUSR2, &prev, nullptr);
    g_reraiseHits.store(0);
    auto lid = svc.addListener(SIGUSR2, &noopListener, nullptr);
    CHECK(lid != 0);
    if (lid == 0) return;

    svc.chainToPrevious(SIGUSR2);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    const int hits = g_reraiseHits.load();
    const bool queued = svc.hasReady();
    int popped = 0;
    while (svc.tryPop(stray)) ++popped;
    svc.removeListener(lid);
    CHECK(currentHandler(SIGUSR2) == &prevHandlerReraise);   // restored on removal

    struct sigaction dfl {};
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    ::sigaction(SIGUSR2, &dfl, nullptr);

    const std::string how = "previous handler ran " + std::to_string(hits) + "x, Eco queue got " +
                            std::to_string(popped) + " (the second instance should go to Eco)";
    CHECK_MSG(hits >= 1, how);   // precondition: chaining ran the previous handler
    CHECK_MSG(hits == 1 && queued, "SIG-04 " + how);
}

}  // namespace

void runSignalTests() {
    testAddListenerPushBackOom();
    testChainToPreviousSecondInstance();
}

void registerSignalScenarios() {
    ChildScenario::add("signal/add-listener-push-back-oom", scenarioAddListenerPushBackOom);
}
