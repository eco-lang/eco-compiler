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
//   - the mutator collects by wait(), which blocks only if the job is not Done
//     yet (a "stall", accounted);
//   - publication is the pool mutex's release/acquire: no fences anywhere else.
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

} // namespace Elm::gc
