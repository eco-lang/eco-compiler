// TLA+ model M6a's trace harness (plans/threaded-gc-tla-M6-lifecycle.md §8;
// test/tla/M6-lifecycle/TracePool.tla). The real GCHelperPool (Concurrent mode)
// with its M6 hooks compiled in, a scripted poster ("mut") that posts and waits
// for a few HelperJobs under a lock standing for Allocator::thread_mutex_ (as
// M6a's Mutator holds tm), and a fork:
//
//   gc-pool-trace <mode> <seed> <ops> <workers> <jobs> <jitter us>
//     mode none        no fork
//          host        another thread ("host") forks once at a random moment;
//                      the child _exits; the log is the parent's
//          mut-parent  the poster forks once between its operations; the child
//                      _exits; the log is the parent's
//          mut-child   the poster forks once; the child continues the script
//                      (its pool restarts workers at its first post) and writes
//                      the log: the parent's history up to the fork, then the
//                      child's (M6a's world = "child")
//
// Every operation mirrors one of M6a's M_Choose branches: post an Idle job, or
// wait for a non-Idle one and reap it (resetForReuse), under the lock. The
// header carries the constants TracePool.tla needs.
#include "GCFork.hpp"
#include "GCHelperPool.hpp"
#include "TlaTrace.hpp"

#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <random>
#include <string>
#include <thread>
#include <vector>

#if !ECO_TLA_TRACE_ENABLED
#error "pool_trace.cpp is a trace harness: build it with -DECO_TLA_TRACE=1"
#endif

namespace Elm::gc { extern bool tla_m6; }   // GCHelperPool.cpp: M6's hooks log while set

using namespace Elm::gc;

namespace {

[[noreturn]] void die(const char* w) {
    std::fprintf(stderr, "pool_trace FAIL: %s\n", w);
    std::fflush(stderr);
    _exit(1);
}

constexpr int kMaxJobs = 4;
HelperJob g_jobs[kMaxJobs];
int g_njobs = 2;
unsigned g_jitter = 0;

int64_t jobId(const void* p) {
    for (int i = 0; i < g_njobs; ++i)
        if (p == &g_jobs[i]) return i + 1;
    return -1;
}

void jobBody(HelperJob*) {
    if (g_jitter > 0) {
        static thread_local std::mt19937 rng(std::random_device{}());
        std::this_thread::sleep_for(std::chrono::microseconds(rng() % g_jitter));
    }
}

std::mutex g_tm;    // stands for Allocator::thread_mutex_

// ... and, like the real one, GCFork's allocator layer holds it across fork()
// (HEAP_075: before the pool's prepare; M6a F_Tm), the child re-creates it.
void tmForkPrepare() { g_tm.lock(); }
void tmForkParent() { g_tm.unlock(); }
void tmForkChild() { new (&g_tm) std::mutex(); }
const ForkHooks kTmHooks{&tmForkPrepare, &tmForkParent, &tmForkChild};

// Waits (without logging) until no job is Posted or Running: the workers are
// then parked, and the log can be written.
void quiesce() {
    for (;;) {
        bool busy = false;
        for (int i = 0; i < g_njobs; ++i)
            if (!g_jobs[i].isIdle() && !g_jobs[i].isDone()) busy = true;
        if (!busy) return;
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 7) {
        std::fprintf(stderr, "usage: %s <none|host|mut-parent|mut-child> <seed> <ops> <workers> <jobs> <jitter us>\n",
                     argv[0]);
        return 2;
    }
    const std::string mode = argv[1];
    const uint64_t seed = std::strtoull(argv[2], nullptr, 10);
    const int ops = std::atoi(argv[3]);
    const unsigned workers = static_cast<unsigned>(std::atoi(argv[4]));
    g_njobs = std::atoi(argv[5]);
    g_jitter = static_cast<unsigned>(std::atoi(argv[6]));
    if (g_njobs < 1 || g_njobs > kMaxJobs || workers < 1 || workers > 2 || ops < 1) die("bad arguments");
    if (mode != "none" && mode != "host" && mode != "mut-parent" && mode != "mut-child") die("bad mode");
    const bool host = mode == "host";
    const bool mutfork = mode == "mut-parent" || mode == "mut-child";
    for (int i = 0; i < g_njobs; ++i) g_jobs[i].run = &jobBody;

    registerForkLayer(kForkAllocator, kTmHooks);
    GCHelperPool& pool = GCHelperPool::instance();
    pool.configure(HelperMode::Concurrent, workers, -1, 0);
    std::mt19937_64 rng(seed);
    const int fork_at = mutfork ? static_cast<int>(rng() % static_cast<uint64_t>(ops)) : -1;

    Elm::tlatrace::setObjId(&jobId);
    Elm::tlatrace::nameThread("mut", -1);
    char hdr[256];
    std::snprintf(hdr, sizeof hdr,
                  "{\"harness\":\"gc-pool-trace\",\"mode\":\"%s\",\"seed\":%llu,\"jobs\":%d,\"workers\":%u,"
                  "\"forker\":\"%s\",\"side\":\"%s\"}",
                  mode.c_str(), static_cast<unsigned long long>(seed), g_njobs, workers,
                  host ? "host" : (mutfork ? "mut" : "none"), mode == "mut-child" ? "child" : "parent");
    Elm::tlatrace::begin(hdr, "pool.");
    tla_m6 = true;

    // The host thread: one fork at a random moment of the script.
    std::thread host_th;
    pid_t host_child = -1;
    if (host) {
        const unsigned delay_us = static_cast<unsigned>(rng() % 4000);
        host_th = std::thread([&, delay_us] {
            Elm::tlatrace::nameThread("host", -1);
            std::this_thread::sleep_for(std::chrono::microseconds(delay_us));
            std::fflush(stdout);
            const pid_t pid = fork();
            if (pid < 0) die("fork");
            if (pid == 0) _exit(0);
            host_child = pid;
        });
    }

    bool in_child = false;
    pid_t mut_child = -1;
    for (int k = 0; k < ops; ++k) {
        if (k == fork_at) {                      // M_Choose's fork branch (between operations)
            std::fflush(stdout);
            const pid_t pid = fork();
            if (pid < 0) die("fork");
            if (pid == 0) {
                if (mode == "mut-parent") _exit(0);
                in_child = true;                 // mut-child: the child goes on
            } else {
                mut_child = pid;
                if (mode == "mut-child") break;  // the parent stops; the child writes the log
            }
            continue;
        }
        std::vector<int> idle, busy;
        for (int i = 0; i < g_njobs; ++i) (g_jobs[i].isIdle() ? idle : busy).push_back(i);
        const bool do_post = !idle.empty() && (busy.empty() || rng() % 2 == 0);
        std::lock_guard<std::mutex> lk(g_tm);
        if (do_post) {
            pool.post(g_jobs[idle[rng() % idle.size()]]);
        } else {
            HelperJob& j = g_jobs[busy[rng() % busy.size()]];
            (void)pool.wait(j, false);
            j.resetForReuse();
        }
        if (g_jitter > 0) std::this_thread::sleep_for(std::chrono::microseconds(rng() % g_jitter));
    }

    if (mode == "mut-child" && !in_child) {
        // The parent: the child writes the log. Wait for it.
        int st = 0;
        if (waitpid(mut_child, &st, 0) != mut_child || !WIFEXITED(st) || WEXITSTATUS(st) != 0) die("child");
        std::printf("pool trace %s PASS (child)\n", mode.c_str());
        return 0;
    }
    if (host) {
        host_th.join();
        int st = 0;
        if (host_child > 0) waitpid(host_child, &st, 0);
    }
    if (mutfork && !in_child && mut_child > 0) {
        int st = 0;
        waitpid(mut_child, &st, 0);
    }
    quiesce();
    tla_m6 = false;
    if (!Elm::tlatrace::end(nullptr)) die("writing the trace");
    std::printf("pool trace %s PASS%s\n", mode.c_str(), in_child ? " (child log)" : "");
    std::fflush(stdout);
    if (in_child) _exit(0);
    return 0;
}
