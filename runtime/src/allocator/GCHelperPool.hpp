#pragma once

// The collector does some of its work on threads other than the mutator, and those threads need to be started,
// handed work, and waited for without ever touching a heap object or a heap lock. This component is that threading
// layer: three kinds of thread group, each with its own start-and-wait protocol.
//
// - `GCHelperPool` is a process-wide pool of workers that run independent jobs in FIFO order. A job is posted,
//   runs on whichever worker takes it, and is later collected by its owner. `HelperClient` names the kinds of
//   job it keeps statistics for.
// - `GCMarkGang` is a process-wide gang: a run starts N members at once, the caller being member 0, and returns
//   when all N have returned. A FIFO pool cannot do this, because it cannot start N jobs together and may have
//   other jobs queued ahead of them.
// - `GCBackgroundGang` is a gang owned by one heap, whose members run outside GC pauses until they finish or are
//   told to stop. A launch returns at once and a later join waits for the members.
//
// Four facts shape all three.
//
// Workers do collection work and never make decisions. The invariant GC_DET_001 requires every GC decision to be
// independent of how far helper threads have got. So the state of a job or a gang may be used to wait for it, and
// never to choose between two outcomes. `GCBackgroundGang::finishedApprox` is the one progress query offered, and
// it is a hint.
//
// What a worker wrote reaches the thread that waits for it through a release/acquire pair. For a pool job the
// pair is the worker's release store of Done and the owner's acquire load of the state, which `wait`, `isDone` and
// `isIdle` make outside the pool mutex. The mutex is not what publishes a job's effects. For both gangs the pair is
// the gang mutex, taken by the starter before the start and by the members before they report finishing.
//
// The groups must survive `fork()`. Each registers handlers with `GCFork` (`registerForkLayer`) that bring it to a
// quiet state before a fork and hold its locks across it. In the child only the forking thread exists, so the child
// handler abandons the parent's threads and rebuilds the locks, and the threads are started again on next use.
// The thread vectors are heap-allocated so that the child can abandon them without destroying joinable
// `std::thread` objects.
//
// Configuration is fixed for the life of the process. The first `configure` call wins, a later call with the same
// values does nothing, and a later call with different values aborts.
//
// The two files include no heap or allocator header (only `GCFork` and `TlaTrace`, which include none either), so
// a helper thread has no way to reach a heap object through them, and the pair builds on its own.
//
// Every misuse this component detects (a job posted twice, a wait for a job never posted, a configuration out of
// range) ends the process with a message on stderr, prefixed `[gc-helper]`.

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

namespace Elm::gc {

/// How the helper pool runs a posted job.
///
/// With `Off` no job may be posted, and `GCHelperPool::post` aborts. With `Sync` a job runs inline on the posting
/// thread and is Done when `post` returns. With `Concurrent` it is queued and run by a worker thread.
enum class HelperMode : uint8_t { Off = 0, Sync = 1, Concurrent = 2 };

/// The kind of work a helper job does, used only to keep separate statistics per kind.
///
/// `kCount` is the number of kinds, not a kind, and sizes `GCHelperPool::Stats::client`.
enum class HelperClient : uint8_t { Decommit = 0, Populate = 1, Test = 2, kCount = 3 };

/// Returns the lower-case name of `c` for statistics output, or "?" for a value that is not a kind.
inline const char* helperClientName(HelperClient c) {
    switch (c) {
        case HelperClient::Decommit: return "decommit";
        case HelperClient::Populate: return "populate";
        case HelperClient::Test:     return "test";
        default:                     return "?";
    }
}

/// One unit of work for the helper pool, owned by the code that posts it and reused from post to post.
///
/// A job moves through Idle, Posted, Running and Done, in that order. `GCHelperPool::post` takes it from Idle to
/// Posted, the thread that runs it moves it to Running and then Done, and only the owner moves it back to Idle, by
/// `resetForReuse`. The owner keeps the memory: the job must stay alive and unmoved from `post` until the owner has
/// seen it Done. While it is Posted the pool links it into its queue through `next`, and while it is Running the
/// thread running it writes its timestamps, so the owner must not touch it while it is Posted or Running.
///
/// The fields other than `state` are plain data. The owner fills `run`, `client` and `bytes` before posting.
/// `post` writes `post_ns` and the thread that runs the job writes the other two timestamps; the owner may read
/// them once it has seen Done, which the release/acquire pair on `state` makes visible.
///
/// GC_DET_001 applies to `state`: it may be read only to wait for the job, never to choose between two outcomes.
struct HelperJob {
    /// The job's states. The values are stored in `state`.
    enum : uint32_t { Idle = 0, Posted = 1, Running = 2, Done = 3 };

    /// The work, called with this job. `post` aborts if it is null. It runs on a worker thread in Concurrent mode
    /// and inline on the posting thread in Sync mode.
    void (*run)(HelperJob*) = nullptr;
    HelperClient client = HelperClient::Test;
    std::atomic<uint32_t> state{Idle};
    HelperJob* next = nullptr;           ///< The pool's queue link; meaningful only while Posted.
    uint64_t bytes = 0;                  ///< Bytes the job covers, added to its client's statistics only.
    /// When the job was posted, started and finished, in `GCHelperPool::nowNs` nanoseconds. For statistics only.
    uint64_t post_ns = 0, start_ns = 0, end_ns = 0;

    /// Returns whether the job is Idle. The load is an acquire.
    bool isIdle() const { return state.load(std::memory_order_acquire) == Idle; }
    /// Returns whether the job is Done. The load is an acquire, so once it returns true the job's effects are
    /// visible to the caller.
    bool isDone() const { return state.load(std::memory_order_acquire) == Done; }
    /// Returns a Done or Idle job to Idle so that it can be posted again, and clears `next`. Aborts if the job is
    /// Posted or Running.
    void resetForReuse();
};

/// The process's FIFO pool of helper threads, which run posted `HelperJob`s.
///
/// There is one pool, obtained by `instance`, and it is never destroyed. It must be configured before the first
/// `post`. In Concurrent mode the worker threads are started together at the first post, and they take jobs in the
/// order they were posted. The owner of a job collects it with `wait`, which returns at once if the job is Done and
/// otherwise blocks until it is. A wait that blocks is a stall, and is counted in the statistics; a stall is called
/// a pause stall when the caller says it is inside a GC pause, and a stall outside a pause otherwise.
///
/// `post`, `wait` and `drain` may be called from several threads. In Concurrent mode `post`, and `wait` and `drain`
/// when they block, take the pool mutex; apart from what a job's `run` does, workers take only that mutex. In
/// Concurrent mode a fork waits until no job is outstanding, so no queued or running job is copied into the child.
class GCHelperPool {
public:
    /// Returns the process's pool, creating it on the first call. The pool is never destroyed, so worker threads
    /// still parked at exit are not joined.
    static GCHelperPool& instance();

    /// Sets the mode, the number of worker threads, the CPU to pin the first worker to, and the jitter, if this is
    /// the first call. Otherwise does nothing if the values are the same, and aborts if they differ.
    ///
    /// `threads` must be in [1, 64]; the first call aborts otherwise. `pin_cpu` is a CPU index, or negative for no
    /// pinning, and is applied only on Linux. `jitter_us`, when non-zero, delays each job run on a worker by a
    /// pseudo-random number of microseconds below it, as a test that no decision depends on helper timing.
    ///
    /// The first call also installs the pool's fork handlers with `GCFork`, so it should be made with no runtime
    /// lock held.
    void configure(HelperMode mode, unsigned threads, int pin_cpu, unsigned jitter_us);
    /// Returns whether `configure` has been called (and `shutdownForTesting` has not since).
    bool configured() const { return configured_.load(std::memory_order_acquire); }
    /// Returns the configured mode, or `HelperMode::Off` before configuration.
    HelperMode mode() const { return mode_; }
    /// Returns the configured number of worker threads.
    unsigned threads() const { return threads_; }
    /// Returns the CPU the first worker is pinned to, or a negative value for none.
    int pinCpu() const { return pin_cpu_; }
    /// Returns the configured jitter bound in microseconds; 0 means none.
    unsigned jitterUs() const { return jitter_us_; }

    /// Posts `job`, which must be Idle and have a `run` function.
    ///
    /// In Sync mode the job runs inline and is Done when this returns. In Concurrent mode it is queued and a worker
    /// is woken; the first post starts the workers. Aborts if the pool is unconfigured or Off, if `job` is not
    /// Idle, or if it has no `run`. The pool keeps a reference to `job` until it is Done.
    void post(HelperJob& job);

    /// What one `wait` call did: whether it blocked, and if it did, when it started blocking and for how long, in
    /// `nowNs` nanoseconds. Both times are 0 when it did not block.
    struct StallRecord { uint64_t start_ns = 0; uint64_t dur_ns = 0; bool stalled = false; };

    /// Returns once `job` is Done, after which the job's effects are visible to the caller.
    ///
    /// If the job was not already Done, the call blocks and counts a stall, as a pause stall if `in_pause` is true
    /// and as a stall outside a pause otherwise. Aborts if `job` is Idle, that is, never posted.
    StallRecord wait(HelperJob& job, bool in_pause);

    /// Blocks until no posted job is outstanding. Returns at once unless the mode is Concurrent.
    void drain();

    /// The statistics kept for one `HelperClient`.
    struct ClientStats {
        std::atomic<uint64_t> jobs{0};
        std::atomic<uint64_t> bytes{0};
        std::atomic<uint64_t> cpu_ns{0};         ///< Thread CPU time of the jobs run on workers.
        std::atomic<uint64_t> inline_cpu_ns{0};  ///< Thread CPU time of the jobs run inline, in Sync mode.
    };
    /// The pool's statistics. Every counter is updated with relaxed atomics, so a reader sees each value on its
    /// own and no consistent snapshot of several.
    struct Stats {
        ClientStats client[static_cast<size_t>(HelperClient::kCount)];
        std::atomic<uint64_t> posts{0};
        std::atomic<uint64_t> stall_count{0};             ///< Waits that blocked, in or outside a pause.
        std::atomic<uint64_t> stall_ns{0};
        std::atomic<uint64_t> stall_max_ns{0};
        std::atomic<uint64_t> stall_outside_pause{0};     ///< The part of `stall_count` outside a pause.
        std::atomic<uint64_t> stall_outside_pause_ns{0};
    };
    /// Returns the statistics. Reading them takes no lock.
    const Stats& stats() const { return stats_; }

    /// Stops and joins the workers, zeroes the statistics, and returns the pool to unconfigured, for tests. Aborts
    /// if any job is outstanding.
    void shutdownForTesting();

    /// Returns `std::chrono::steady_clock` nanoseconds since that clock's epoch. Subtract another reading of the
    /// same clock to get an interval.
    static uint64_t nowNs();
    /// Returns the CPU time the calling thread has used, in nanoseconds, or 0 if the system cannot report it.
    static uint64_t threadCpuNs();

private:
    GCHelperPool() = default;
    /// Starts `threads_` workers. Called with `m_` held.
    void startWorkersLocked();
    /// Takes queued jobs and runs them, in order, until the pool is stopping and the queue is empty.
    void workerLoop(unsigned index);
    /// Runs `job` and adds its CPU time and size to the statistics. On a worker (`on_worker`) it first sleeps for
    /// the configured jitter, drawn from `rng`; inline, `rng` is not used and may be null.
    void runJob(HelperJob& job, bool on_worker, uint64_t* rng);
    /// Adds a stall of `dur_ns` to the statistics, and to the outside-pause counters unless `in_pause`.
    void noteStall(uint64_t dur_ns, bool in_pause);

    // The configuration, written under m_ by the first configure before configured_ is published (and reset by
    // shutdownForTesting).
    std::atomic<bool> configured_{false};
    HelperMode mode_ = HelperMode::Off;
    unsigned threads_ = 1;
    int pin_cpu_ = -1;
    unsigned jitter_us_ = 0;

    std::mutex m_;
    std::condition_variable cv_work_;
    std::condition_variable cv_done_;
    HelperJob* head_ = nullptr;          // FIFO, guarded by m_; null when the queue is empty
    HelperJob* tail_ = nullptr;          // guarded by m_; null when the queue is empty
    uint64_t outstanding_ = 0;           // posted and not Done, guarded by m_
    bool started_ = false;               // guarded by m_
    bool stopping_ = false;              // guarded by m_
    // Heap-allocated so a forked child can abandon the parent's (non-existent in the child) threads without
    // destroying joinable std::thread objects.
    std::vector<std::thread>* workers_ = new std::vector<std::thread>();

    // The pool's fork handlers, installed as GCFork's innermost layer, kForkPool. In Concurrent mode the prepare
    // waits until no job is outstanding; it keeps m_ held across the fork. The parent handler releases m_. The child
    // handler rebuilds m_ and the condition variables, forgets the workers, and leaves the next post to start new ones.
    static void atforkPrepare();
    static void atforkParent();
    static void atforkChild();

    Stats stats_;
};

/// The process's gang of mark threads, which run one function on N threads at once, inside a GC pause.
///
/// There is one gang, obtained by `instance`, and it is never destroyed. A run executes `fn(ctx, i)` for every `i`
/// in [0, n) at the same time: member 0 on the calling thread, members 1 to n-1 on parked gang threads, which are
/// started together at the first run that needs them. `run` returns when all n have returned. Starting a run and
/// waiting for its end both take the gang mutex, so everything the caller wrote before `run` is visible to the
/// members, and everything the members wrote is visible to the caller after it.
///
/// Runs are meant to happen only inside a GC pause, which is what `onMemberRun` reports; nothing here checks it.
class GCMarkGang {
public:
    /// The function a run executes: called once per member with the run's `ctx` and the member's index.
    using Fn = void (*)(void* ctx, unsigned member);
    /// Returns the process's gang, creating it on the first call. The gang is never destroyed.
    static GCMarkGang& instance();

    /// Sets the number of members, counting the caller, and the jitter, if this is the first call. Otherwise does
    /// nothing if the values are the same, and aborts if they differ. `members` must be in [1, 64]; the first call
    /// aborts otherwise. `jitter_us`, when non-zero, delays each gang thread's start of a run by a pseudo-random
    /// number of microseconds up to it. The first call also installs the gangs' fork handlers with `GCFork`, so it
    /// should be made with no runtime lock held.
    void configure(unsigned members, unsigned jitter_us);
    /// Returns whether `configure` has been called (and `shutdownForTesting` has not since).
    bool configured() const { return configured_.load(std::memory_order_acquire); }
    /// Returns the configured number of members, counting the caller.
    unsigned members() const { return members_; }
    /// Returns the configured jitter bound in microseconds; 0 means none.
    unsigned jitterUs() const { return jitter_us_; }

    /// Runs `fn(ctx, i)` for each `i` in [0, `n`) at once and returns when all have returned.
    ///
    /// For `n` of 0 or 1 this calls `fn(ctx, 0)` on the caller and nothing else, even if the gang is unconfigured.
    /// Otherwise the gang must be configured with at least `n` members, or the call aborts. Calls from several
    /// threads are serialised: a second caller blocks until the first run ends.
    void run(Fn fn, void* ctx, unsigned n);

    /// The gang's statistics, updated with relaxed atomics.
    struct Stats {
        std::atomic<uint64_t> runs{0};                ///< Runs with more than one member.
        std::atomic<uint64_t> member_cpu_ns{0};       ///< CPU time of members 1 and up; the caller's is not included.
        std::atomic<uint64_t> wake_ns_total{0};       ///< Time from a run's start to each gang thread's wake-up.
        std::atomic<uint64_t> wake_ns_max{0};
    };
    /// Returns the statistics. Reading them takes no lock.
    const Stats& stats() const { return stats_; }

    /// Joins the gang threads, zeroes the statistics, and returns the gang to unconfigured, for tests.
    void shutdownForTesting();

    /// Returns whether the calling thread is a gang thread running its part of a run, that is, member 1 or above.
    ///
    /// It is false on the thread that called `run`, which is member 0. Because runs happen inside a GC pause, a
    /// caller can treat true as meaning the thread is inside a pause even though it has no heap of its own.
    static bool onMemberRun() { return tl_member_run_; }

private:
    friend class GCBackgroundGang;     // GCFork's gangs layer runs this gang's handlers
    /// Whether this thread is a gang thread inside `fn`; set and cleared around each member call.
    static inline thread_local bool tl_member_run_ = false;
    GCMarkGang() = default;
    /// Waits for each run and, if `index` is below the run's member count, takes part in it, until stopping.
    void memberLoop(unsigned index);
    /// Starts the gang threads, members 1 to `members_` - 1, if they are not running. Called with `m_` held.
    void startThreadsLocked();
    // The gang's fork handlers, run inside the background gangs' layer. The prepare takes `run_m_`, which waits
    // out any run and keeps a new one from starting, then `m_`. The parent handler releases both. The child
    // handler rebuilds them and the condition variables and abandons the parent's threads.
    static void atforkPrepare();
    static void atforkParent();
    static void atforkChild();

    // The configuration, written under m_ by the first configure before configured_ is published (and reset by
    // shutdownForTesting).
    std::atomic<bool> configured_{false};
    unsigned members_ = 1;
    unsigned jitter_us_ = 0;
    std::mutex run_m_;                 // one run at a time
    std::mutex m_;
    std::condition_variable cv_start_;
    std::condition_variable cv_done_;
    // The current run. A run is announced by incrementing generation_; each thread compares it with the last it
    // saw. finished_ counts the gang threads (not the caller) that have returned from the run.
    uint64_t generation_ = 0;          // guarded by m_
    unsigned running_n_ = 0;           // guarded by m_
    unsigned finished_ = 0;            // guarded by m_
    Fn fn_ = nullptr;                  // guarded by m_
    void* ctx_ = nullptr;              // guarded by m_; not owned
    uint64_t post_ns_ = 0;             // guarded by m_
    bool started_ = false;             // guarded by m_
    bool stopping_ = false;            // guarded by m_
    // Heap-allocated so that a forked child can abandon it (see GCHelperPool::workers_).
    std::vector<std::thread>* threads_ = new std::vector<std::thread>();
    Stats stats_;
};

/// A gang of threads owned by one heap, whose members run outside GC pauses until they finish or are stopped.
///
/// It is not a singleton: each owner creates its own, and gangs share no lock with each other or with
/// `GCMarkGang` while they run, so a long episode holds up no other gang. A launch starts one episode:
/// `fn(ctx, j)` for every member `j`, on the gang's threads, which are started together at the first launch. The
/// episode lasts until every member returns, either because its work is done or because it saw the episode's stop
/// flag set. `join` waits for that; `stopAndJoin` sets the flag first. Launch and join both take the gang mutex, so
/// everything the owner wrote before `launch` is visible to the members, and everything they wrote is visible
/// after a join returns.
///
/// Every gang is entered in a process-wide registry when it is constructed and removed when it is destroyed. The
/// first construction registers `stopAllAtExit` with `std::atexit`, and every construction makes sure the gangs'
/// fork handlers are installed, so a gang that was never launched is covered by both.
///
/// Before a fork, the gangs' prepare handler marks every gang held, so that a `launch` made then is refused rather
/// than blocked, stops and joins every running episode, and keeps every gang's mutex across the fork. The parent
/// handler releases the hold; the child handler rebuilds the gangs' locks and abandons their threads, which the next
/// launch starts again. An episode stopped by a fork is not relaunched here.
///
/// A gang cannot be copied or moved, because the registry and its own threads refer to it by address. The
/// destructor stops and joins any running episode, ends and joins the gang's threads, and removes it from the
/// registry.
class GCBackgroundGang {
public:
    /// The function a launch executes: called once per member with the launch's `ctx` and the member's index.
    using Fn = void (*)(void* ctx, unsigned member);
    /// How a gang's threads are set up.
    struct Options {
        unsigned members = 1;     ///< In [1, 63]; the constructor aborts otherwise.
        /// The scheduling priority each member sets for itself once, when its thread starts: 0 leaves it as
        /// inherited, 1 to 19 is a nice value, 20 is `SCHED_IDLE`. Applied on Linux only; other values are
        /// ignored. The priority is set only at thread start and never changed afterwards.
        int priority = 0;
        /// When non-zero, each member delays its start of an episode by a pseudo-random number of microseconds up
        /// to this, as a test that no decision depends on background timing.
        unsigned jitter_us = 0;
        /// The thread-name prefix; except on Windows a thread is named `<prefix>-<index>`, the prefix cut to 10
        /// characters. Kept, not copied, so it must live as long as the gang; a string literal in practice. Null
        /// means `eco-cmark`.
        const char* name = "eco-cmark";
    };
    /// Creates a gang with the options `opt`, starting no threads, and enters it in the registry.
    explicit GCBackgroundGang(const Options& opt);
    ~GCBackgroundGang();
    GCBackgroundGang(const GCBackgroundGang&) = delete;
    GCBackgroundGang& operator=(const GCBackgroundGang&) = delete;

    /// Returns the number of members each episode runs.
    unsigned members() const { return opt_.members; }
    /// Returns the options the gang was created with; the reference is valid while the gang exists.
    const Options& options() const { return opt_; }
    /// Starts an episode running `fn(ctx, j)` on every member, and returns at once.
    ///
    /// Returns true when the episode was started. Returns false, starting nothing, when a fork's prepare handler
    /// holds the gang; the caller should treat that as an episode that was stopped. The gang must not be running;
    /// the call aborts if it is.
    ///
    /// `stop` is the episode's stop flag, set by `stopAndJoin` and by the fork handler. It is not passed to `fn`,
    /// which must reach it through `ctx` to see it. It may be null, in which case nothing can stop the episode
    /// early. It is kept, so it must stay valid until the episode has been joined.
    bool launch(Fn fn, void* ctx, std::atomic<bool>* stop);
    /// Returns whether an episode has been launched and not yet joined.
    bool running() const { return running_.load(std::memory_order_acquire); }
    /// Returns whether every member of the latest episode has returned, without waiting.
    ///
    /// It is a hint only. Under GC_DET_001 it must not decide anything: use `join` to know the episode is over.
    /// It stays true after the episode is joined, until the next launch.
    bool finishedApprox() const;
    /// Blocks until every member of the current episode has returned, and marks the gang not running. Returns at
    /// once if it is not running.
    void join();
    /// Sets the current episode's stop flag, then blocks until every member of that episode has returned and
    /// marks the gang not running. Returns at once if it is not running.
    ///
    /// It waits only for the episode it stopped. If another thread joins that episode and launches a new one
    /// while this call waits, the call returns without waiting for, or marking, the new one.
    void stopAndJoin();

    /// The gang's statistics, updated with relaxed atomics.
    struct Stats {
        std::atomic<uint64_t> launches{0};
        std::atomic<uint64_t> member_cpu_ns{0};
        std::atomic<uint64_t> join_wait_ns_total{0};   ///< Time spent in `join` and `stopAndJoin` waiting.
        std::atomic<uint64_t> join_wait_ns_max{0};
        std::atomic<uint64_t> stop_wait_ns_max{0};     ///< The longest wait in `stopAndJoin`.
        std::atomic<uint64_t> fork_stops{0};           ///< Episodes stopped by a fork's prepare handler.
        std::atomic<uint64_t> fork_refusals{0};        ///< Launches refused while a fork held the gang.
    };
    /// Returns the statistics, valid while the gang exists. Reading them takes no lock.
    const Stats& stats() const { return stats_; }

    /// Sets or clears the hold a fork's prepare handler sets, for tests: while it is set, `launch` is refused
    /// without any fork taking place. A real fork's parent handler clears the hold.
    void setForkHoldForTesting(bool on) {
        std::lock_guard<std::mutex> lk(m_);
        fork_hold_ = on;
    }
    /// Stops and joins the running episode of every registered gang. It reads the registry without locking it, so the
    /// caller must hold the registry's mutex, as the fork prepare handler does.
    static void stopAllForFork();
    /// Stops and joins every registered gang's running episode. Registered with `std::atexit` by the first
    /// construction, so it runs at normal process exit.
    static void stopAllAtExit();
    /// Installs the gangs' fork handlers (the background gangs, then the mark gang) as `GCFork`'s first layer,
    /// `kForkGangs`. Installing again has no further effect. Call it with no runtime lock held.
    static void registerForkLayerOnce();
    /// Returns the kernel thread ids of the gang's started members, for tests. On Linux an entry is 0 until its
    /// thread has started; elsewhere every entry is 0. Empty before the first launch.
    std::vector<long> memberTids() const;

private:
    /// Waits for each episode and runs this member's part of it, until the gang is destroyed.
    void memberLoop(unsigned index);
    /// Starts the member threads if they are not running. Called with `m_` held.
    void startThreadsLocked();
    /// Waits, with `lk` holding `m_`, until every member has returned, marks the gang not running, and records the
    /// wait, also as a stop wait if `stopping`.
    void joinLocked(std::unique_lock<std::mutex>& lk, bool stopping);
    // The background gangs' own fork handlers. The prepare takes the registry mutex, holds every gang, stops
    // every running episode, and then takes every gang's `m_`. The parent handler clears the holds and releases
    // the locks. The child handler rebuilds each gang's locks and state and abandons its threads.
    static void atforkPrepare();
    static void atforkParent();
    static void atforkChild();
    // GCFork's gangs layer: the background gangs' handler and the mark gang's, prepare in that order, parent
    // and child in the reverse.
    static void forkGangsPrepare();
    static void forkGangsParent();
    static void forkGangsChild();

    Options opt_;
    mutable std::mutex m_;
    std::condition_variable cv_start_;
    std::condition_variable cv_done_;
    // The current episode. An episode is announced by incrementing generation_; each member compares it with the
    // last it saw. finished_ counts the members that have returned from it.
    uint64_t generation_ = 0;          // guarded by m_
    unsigned finished_ = 0;            // guarded by m_
    // A copy of finished_, stored under m_ and read without it by finishedApprox.
    std::atomic<unsigned> finished_pub_{0};
    std::atomic<bool> running_{false};
    bool started_ = false;             // guarded by m_
    bool stopping_ = false;            // guarded by m_ (destruction)
    bool fork_hold_ = false;           // guarded by m_: a fork's prepare holds the gang (launch refuses)
    Fn fn_ = nullptr;                  // guarded by m_
    void* ctx_ = nullptr;              // guarded by m_; not owned
    // The current episode's stop flag, written by launch and read by stopAndJoin, both under m_. Not owned; null
    // when the launch passed none.
    std::atomic<bool>* stop_ = nullptr;
    // Heap-allocated so that a forked child can abandon it (see GCHelperPool::workers_).
    std::vector<std::thread>* threads_ = new std::vector<std::thread>();
    std::vector<long> tids_;           // guarded by m_
    Stats stats_;
};

/// Returns how many CPUs this process may use, at least 1.
///
/// On Linux it is the number of CPUs in the process's affinity mask, lowered to the cgroup v2 quota in
/// `/sys/fs/cgroup/cpu.max` (rounded up) when that file sets one. On Windows it is the number of active processors
/// in all groups, and on other systems the number of online processors; neither of those looks at affinity or a
/// quota.
unsigned availableCpus();

} // namespace Elm::gc
