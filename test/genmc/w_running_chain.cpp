// w_running_chain: a job's state reaches its owner through a FOREIGN join
// (plans/threaded-gc-tla-verification.md §5.3, the "proposed" row;
// plans/threaded-gc-tla-W-weak-memory.md §10.1, "gang and episode hints",
// review R21; M6 A4 (2), which M5 uses through LaunchJoin).
//
// tenureJoin's orphan test (NurseryTenure.cpp:611-615; also the L3 branch,
// :584-585) acts on `!g->running()` WITHOUT joining: it reads the job's state
// (J.st, the deques) and finishes the job itself. When a foreign thread did the
// join (fork prepare's stopAllForFork, or stopAllAtExit, running stopAndJoin),
// the member's writes reach the owner only through the chain
//     member --(m_)--> foreign joiner --(running_ release / acquire)--> owner.
//
// A pinned REDUCTION of GCBackgroundGang (GCHelperPool.cpp, which needs
// std::thread and std::mutex): memberLoop's finish (:603-610), stopAndJoin
// (:657-662) with joinLocked (:639-649), join (:651-655), stopAllForFork's
// `if (g->running())` (:669-677), running() (GCHelperPool.hpp:258), and
// SerialEngine::run's stop check between items (TenureWork.hpp:218).
// Property: the owner sees the member's final job state, and its own writes
// to it come after the member's: no race, and owner_seen == member_final.
//
// Driver mutants: MUTANT_RUNNING_RELAXED_STORE (joinLocked's running_ store
// relaxed, :644), MUTANT_RUNNING_RELAXED_LOAD (running()'s load relaxed,
// hpp:258), MUTANT_RUNNING_JOIN_EARLY (joinLocked stores running_ = false
// BEFORE waiting for the members: the chain's first link is gone).
#include <atomic>
#include "wdriver.hpp"               // last: it redefines assert

#ifdef MUTANT_RUNNING_RELAXED_STORE
constexpr std::memory_order kRunningStore = std::memory_order_relaxed;
#else
constexpr std::memory_order kRunningStore = std::memory_order_release;   // GCHelperPool.cpp:644
#endif
#ifdef MUTANT_RUNNING_RELAXED_LOAD
constexpr std::memory_order kRunningLoad = std::memory_order_relaxed;
#else
constexpr std::memory_order kRunningLoad = std::memory_order_acquire;    // GCHelperPool.hpp:258
#endif

static WMutex m;                               // GCBackgroundGang::m_
static unsigned finished;                      // finished_ (guarded by m)
static std::atomic<unsigned> finished_pub{0};  // finished_pub_ (a hint)
static std::atomic<bool> running_{false};      // running_
static std::atomic<bool> stop{false};          // the episode's stop flag (TenureJob::stop)
static uint64_t job_next;                      // the job's progress (J.st: plain)
static uint64_t member_final;                  // written by the member only
static uint64_t owner_seen;                    // written by the owner only
static int owner_orphan;                       // written by the owner only

static bool running() { return running_.load(kRunningLoad); }            // GCHelperPool.hpp:258

static void joinLocked() {                     // :639-649, called with m held
#ifdef MUTANT_RUNNING_JOIN_EARLY
    running_.store(false, kRunningStore);
    m.await([] { return finished >= 1; });     // cv_done_.wait(lk, finished_ >= members)
#else
    m.await([] { return finished >= 1; });     // cv_done_.wait(lk, finished_ >= members)
    running_.store(false, kRunningStore);
#endif
}
static void stopAndJoin() {                    // :657-662
    m.lock();
    if (running_.load(std::memory_order_relaxed)) {
        stop.store(true, std::memory_order_release);
        joinLocked();
    }
    m.unlock();
}
static void joinGang() {                       // join(), :651-655
    m.lock();
    if (running_.load(std::memory_order_relaxed)) joinLocked();
    m.unlock();
}

static void* member(void*) {                   // fn(ctx, 0): the exact engine, two items
    for (int item = 0; item < 2; ++item) {
        if (stop.load(std::memory_order_relaxed)) break;   // SerialEngine::run, TenureWork.hpp:218
        job_next = static_cast<uint64_t>(item) + 1;        // one item's writes to J.st
    }
    member_final = job_next;
    m.lock();                                  // memberLoop's finish (:603-610)
    ++finished;
    finished_pub.store(finished, std::memory_order_release);
    m.unlock();
    return nullptr;
}

static void* foreignJoiner(void*) {            // fork prepare: stopAllForFork (:669-677)
    if (running()) stopAndJoin();
    return nullptr;
}

static void* owner(void*) {                    // tenureJoin, J.state == Running (:611-631)
    if (!running()) {                          // "fork / orphan: treat as stopped" (:614-615)
        owner_orphan = 1;
    } else {
        joinGang();                            // tenure_help == 0: g->join() (:617-620)
    }
    owner_seen = job_next;                     // finish_here = !J.st.done() ...
    if (owner_seen < 2) job_next = 2;          // ... and runJobExact finishes the job
    return nullptr;
}

int main() {
    running_.store(true, std::memory_order_relaxed);   // launch (:614-633): before the threads
    wthread a = spawn(member), f = spawn(foreignJoiner), o = spawn(owner);
    join(a);
    join(f);
    join(o);
    assert(owner_seen == member_final);        // the owner continues from the member's state
    return 0;
}
