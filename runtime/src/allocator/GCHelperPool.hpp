#pragma once

// threaded-gc-03 (plans/threaded-gc-03-helper-threads.md P§3.1-3.4, HEAP_058,
// GC_DET_001): the process-wide GC helper-thread pool.
//
// Deliberately standalone: this header and GCHelperPool.cpp include nothing
// from the allocator, so helper threads cannot reach heap objects through the
// include graph, and the pair compiles alone under g++ -fsanitize=thread
// (test/gc-helper-tsan; clang 14 here ships no TSan runtime).
//
// Protocol (mutator-initiated post/collect, report §3.2):
//   - the mutator posts a job at a slow path; in Sync mode the job runs inline
//     on the caller, in Concurrent mode on a worker;
//   - the owner collects by wait(), which blocks only if the job is not Done
//     yet (a "stall", accounted). The waiter is the mutator at an allocator
//     slow path or (threaded-gc-06/07, CR-026) a GCMarkGang member inside a
//     minor pause holding promo_mu_ (the parallel minor's and the pause tenure
//     engine's block acquisition, CR-007), whose stall is a pause stall
//     (GCMarkGang::onMemberRun, CR-025);
//   - publication: post() hands a job to a worker through the pool mutex; the
//     worker stores Done with release, and wait()'s fast path, isDone() and
//     isIdle() load it with acquire OUTSIDE the mutex, so a job's effects
//     reach the owner through that release/acquire pair, not through the
//     mutex (GenMC guard test/genmc/w_pool_done.cpp). No fences anywhere else.
// GC_DET_001: a job's state may be read only to WAIT for it, never to choose
// between two outcomes. Only GCHelperPool and PageWork read HelperJob::state.

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

namespace Elm::gc {

enum class HelperMode : uint8_t { Off = 0, Sync = 1, Concurrent = 2 };

enum class HelperClient : uint8_t { Decommit = 0, Populate = 1, Test = 2, kCount = 3 };

inline const char* helperClientName(HelperClient c) {
    switch (c) {
        case HelperClient::Decommit: return "decommit";
        case HelperClient::Populate: return "populate";
        case HelperClient::Test:     return "test";
        default:                     return "?";
    }
}

struct HelperJob {
    enum : uint32_t { Idle = 0, Posted = 1, Running = 2, Done = 3 };

    void (*run)(HelperJob*) = nullptr;   // executed by a worker, or inline in Sync
    HelperClient client = HelperClient::Test;
    // Idle -> Posted -> Running -> Done; the OWNER resets Done -> Idle
    // (resetForReuse) before posting the job again.
    std::atomic<uint32_t> state{Idle};
    HelperJob* next = nullptr;           // intrusive FIFO link; pool-owned while Posted
    uint64_t bytes = 0;                  // stats only
    // Timestamps (process-relative steady ns), written by whoever runs the
    // job, read by the owner after it observed Done. Stats/event log only.
    uint64_t post_ns = 0, start_ns = 0, end_ns = 0;

    bool isIdle() const { return state.load(std::memory_order_acquire) == Idle; }
    bool isDone() const { return state.load(std::memory_order_acquire) == Done; }
    void resetForReuse();                // requires Done (or Idle)
};

class GCHelperPool {
public:
    // Leaky process singleton (like TimerService): never destroyed.
    static GCHelperPool& instance();

    // First call wins. A later call with different values aborts: switching
    // modes mid-process would break the mode equivalence GC_DET_001 relies on.
    // Calling it again with identical values is a no-op.
    void configure(HelperMode mode, unsigned threads, int pin_cpu, unsigned jitter_us);
    bool configured() const { return configured_.load(std::memory_order_acquire); }
    HelperMode mode() const { return mode_; }
    unsigned threads() const { return threads_; }
    int pinCpu() const { return pin_cpu_; }
    unsigned jitterUs() const { return jitter_us_; }

    // Posts `job` (state must be Idle). Sync: runs it inline and returns with
    // it Done. Concurrent: enqueues it and wakes a worker (starting the
    // workers on first use).
    void post(HelperJob& job);

    // The outcome of one wait(): whether it blocked, and for how long.
    struct StallRecord { uint64_t start_ns = 0; uint64_t dur_ns = 0; bool stalled = false; };

    // Returns once `job` is Done. If it had to block, accounts a stall
    // (`in_pause` says whether the caller is inside a GC pause) and says so.
    StallRecord wait(HelperJob& job, bool in_pause);

    // Waits until every posted job is Done.
    void drain();

    struct ClientStats {
        std::atomic<uint64_t> jobs{0};
        std::atomic<uint64_t> bytes{0};
        std::atomic<uint64_t> cpu_ns{0};         // run on a worker
        std::atomic<uint64_t> inline_cpu_ns{0};  // run inline (Sync mode)
    };
    struct Stats {
        ClientStats client[static_cast<size_t>(HelperClient::kCount)];
        std::atomic<uint64_t> posts{0};
        std::atomic<uint64_t> stall_count{0};
        std::atomic<uint64_t> stall_ns{0};
        std::atomic<uint64_t> stall_max_ns{0};
        std::atomic<uint64_t> stall_outside_pause{0};
        std::atomic<uint64_t> stall_outside_pause_ns{0};
    };
    // Lock-free (relaxed atomics): safe from the signal-path stats print.
    const Stats& stats() const { return stats_; }

    // Test-only: stops and joins the workers and returns the pool to the
    // unconfigured state (stats are zeroed). Legal only with nothing posted.
    void shutdownForTesting();

    // std::chrono::steady_clock ns since its epoch (convert to process-relative
    // time by subtracting the process start on the same clock).
    static uint64_t nowNs();
    // CPU time of the calling thread, ns.
    static uint64_t threadCpuNs();

private:
    GCHelperPool() = default;
    void startWorkersLocked();
    void workerLoop(unsigned index);
    void runJob(HelperJob& job, bool on_worker, uint64_t* rng);
    void noteStall(uint64_t dur_ns, bool in_pause);

    std::atomic<bool> configured_{false};
    HelperMode mode_ = HelperMode::Off;
    unsigned threads_ = 1;
    int pin_cpu_ = -1;
    unsigned jitter_us_ = 0;

    std::mutex m_;
    std::condition_variable cv_work_;
    std::condition_variable cv_done_;
    HelperJob* head_ = nullptr;          // FIFO, guarded by m_
    HelperJob* tail_ = nullptr;
    uint64_t outstanding_ = 0;           // posted and not Done, guarded by m_
    bool started_ = false;               // guarded by m_
    bool stopping_ = false;              // guarded by m_
    // Heap-allocated so a forked child can abandon the parent's (non-existent
    // in the child) threads without destroying joinable std::thread objects.
    std::vector<std::thread>* workers_ = new std::vector<std::thread>();

    // fork() safety (pthread_atfork, registered at the first configure): the
    // parent drains and holds m_ across fork; the child forgets its workers
    // (only the forking thread survives) and restarts them on its next post.
    static void atforkPrepare();
    static void atforkParent();
    static void atforkChild();

    Stats stats_;
};

// ---------------------------------------------------------------------------
// threaded-gc-05b (plans/threaded-gc-05b-parallel-marking.md P§3.5, HEAP_064):
// the mark gang. Gang scheduling: run() executes fn(ctx, i) for i in [0, n) at
// once -- i = 0 on the caller, 1..n-1 on parked gang threads -- and returns
// when all n returned. Start and join are mutex release/acquire pairs, which
// publish everything written before run() to the members and everything the
// members wrote to the caller. Runs happen only inside a GC pause (HEAP_058
// amended): the pool's FIFO cannot start N jobs together, and may have a
// decommit queued first.
// ---------------------------------------------------------------------------
class GCMarkGang {
public:
    using Fn = void (*)(void* ctx, unsigned member);
    static GCMarkGang& instance();

    // First call wins (as GCHelperPool::configure); `members` includes the
    // caller, in [1, 64]. A later call with different values aborts.
    void configure(unsigned members, unsigned jitter_us);
    bool configured() const { return configured_.load(std::memory_order_acquire); }
    unsigned members() const { return members_; }
    unsigned jitterUs() const { return jitter_us_; }

    // n <= members(). n == 1 calls fn(ctx, 0) inline. Concurrent callers
    // (several heaps) are serialised.
    void run(Fn fn, void* ctx, unsigned n);

    struct Stats {
        std::atomic<uint64_t> runs{0};
        std::atomic<uint64_t> member_cpu_ns{0};     // gang threads only (collector CPU)
        std::atomic<uint64_t> wake_ns_total{0};
        std::atomic<uint64_t> wake_ns_max{0};
    };
    const Stats& stats() const { return stats_; }

    // Test-only: joins the threads and returns to unconfigured (stats zeroed).
    void shutdownForTesting();

    // CR-025: true on a gang member thread while it runs a job (member >= 1;
    // member 0 is the caller, whose own heap state applies). Every run is
    // inside a GC pause, so a helper-job wait made here is a pause stall
    // (Allocator::callerInPause: a member thread has no ThreadLocalHeap).
    static bool onMemberRun() { return tl_member_run_; }

private:
    static inline thread_local bool tl_member_run_ = false;
    GCMarkGang() = default;
    void memberLoop(unsigned index);
    void startThreadsLocked();
    static void atforkPrepare();
    static void atforkParent();
    static void atforkChild();

    std::atomic<bool> configured_{false};
    unsigned members_ = 1;
    unsigned jitter_us_ = 0;
    std::mutex run_m_;                 // one run at a time
    std::mutex m_;
    std::condition_variable cv_start_;
    std::condition_variable cv_done_;
    uint64_t generation_ = 0;          // guarded by m_
    unsigned running_n_ = 0;           // guarded by m_
    unsigned finished_ = 0;            // guarded by m_
    Fn fn_ = nullptr;                  // guarded by m_
    void* ctx_ = nullptr;              // guarded by m_
    uint64_t post_ns_ = 0;             // guarded by m_
    bool started_ = false;             // guarded by m_
    bool stopping_ = false;            // guarded by m_
    std::vector<std::thread>* threads_ = new std::vector<std::thread>();
    Stats stats_;
};

// ---------------------------------------------------------------------------
// threaded-gc-05c (plans/threaded-gc-05c-concurrent-marking.md P§3.4, HEAP_065):
// a per-heap BACKGROUND gang. launch() starts fn(ctx, j), j < members, on parked
// threads and returns at once; the members run outside GC pauses (concurrent
// marking) until they return by themselves (the mark terminated) or observe the
// episode's stop flag. join() waits for them. Launch and join are mutex
// release/acquire pairs: everything the owner wrote before launch() is visible
// to the members, and everything they wrote is visible after join().
//
// Priority is applied ONCE by each thread to itself at thread start: an
// unprivileged process cannot raise it again (plan F20), so these threads are
// never used for work that must run at normal priority.
//
// One instance per OldGenSpace (not a singleton: a background episode lasts
// seconds and must not serialise other heaps' in-pause GCMarkGang runs).
// fork(): atforkPrepare stops and joins every running instance (the owner
// relaunches at its next cycle step); the child abandons its threads and
// restarts them lazily. Process exit: stopAllAtExit (std::atexit) runs before
// static destructors could unmap a heap. It and the atfork handlers are
// registered once, by the first GCBackgroundGang's constructor (not at a first
// launch), so a gang that was built but never launched is covered too (CR-024).
// ---------------------------------------------------------------------------
class GCBackgroundGang {
public:
    using Fn = void (*)(void* ctx, unsigned member);
    struct Options {
        unsigned members = 1;     // [1, 63]
        int priority = 0;         // 0 inherit, 1..19 nice, 20 SCHED_IDLE (Linux)
        unsigned jitter_us = 0;   // determinism probe: random start delay per member
        const char* name = "eco-cmark";   // thread name prefix (threaded-gc-07: "eco-tenure")
    };
    explicit GCBackgroundGang(const Options& opt);
    ~GCBackgroundGang();          // stopAndJoin(), joins the threads, unregisters
    GCBackgroundGang(const GCBackgroundGang&) = delete;
    GCBackgroundGang& operator=(const GCBackgroundGang&) = delete;

    unsigned members() const { return opt_.members; }
    const Options& options() const { return opt_; }
    // Precondition: !running(). `stop` is the episode's stop flag (set by
    // stopAndJoin and by the fork hook). Returns immediately.
    void launch(Fn fn, void* ctx, std::atomic<bool>* stop);
    // Launched and not yet joined (a fork-prepare stop also joins).
    bool running() const { return running_.load(std::memory_order_acquire); }
    // Every member of the current launch returned. A HINT for the owner's
    // bookkeeping only (GC_DET_001: never a decision input).
    bool finishedApprox() const;
    // Blocks until every member returned; no-op when not running.
    void join();
    // *stop = true, then join(). No-op when not running.
    void stopAndJoin();

    struct Stats {
        std::atomic<uint64_t> launches{0};
        std::atomic<uint64_t> member_cpu_ns{0};
        std::atomic<uint64_t> join_wait_ns_total{0};
        std::atomic<uint64_t> join_wait_ns_max{0};
        std::atomic<uint64_t> stop_wait_ns_max{0};
        std::atomic<uint64_t> fork_stops{0};
    };
    const Stats& stats() const { return stats_; }

    static void stopAllForFork();
    static void stopAllAtExit();
    // Test helper: the kernel thread ids of the started members (Linux; empty elsewhere).
    std::vector<long> memberTids() const;

private:
    void memberLoop(unsigned index);
    void startThreadsLocked();
    void joinLocked(std::unique_lock<std::mutex>& lk, bool stopping);
    static void atforkPrepare();
    static void atforkParent();
    static void atforkChild();

    Options opt_;
    mutable std::mutex m_;
    std::condition_variable cv_start_;
    std::condition_variable cv_done_;
    uint64_t generation_ = 0;          // guarded by m_
    unsigned finished_ = 0;            // guarded by m_
    std::atomic<unsigned> finished_pub_{0};
    std::atomic<bool> running_{false};
    bool started_ = false;             // guarded by m_
    bool stopping_ = false;            // guarded by m_ (destruction)
    Fn fn_ = nullptr;                  // guarded by m_
    void* ctx_ = nullptr;              // guarded by m_
    std::atomic<bool>* stop_ = nullptr;
    std::vector<std::thread>* threads_ = new std::vector<std::thread>();
    std::vector<long> tids_;           // guarded by m_
    Stats stats_;
};

// threaded-gc-05b P§3.9: CPUs this process may run on -- the affinity mask,
// capped by a cgroup v2 cpu.max quota when one is set. Never
// hardware_concurrency (which ignores both). At least 1.
unsigned availableCpus();

} // namespace Elm::gc
