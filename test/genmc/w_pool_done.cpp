// w_pool_done: a helper-pool job's Done, published by a release store made
// INSIDE the pool mutex and read by acquire loads OUTSIDE it
// (plans/threaded-gc-tla-verification.md §5.3, the "proposed" row;
// plans/threaded-gc-tla-W-weak-memory.md §10.1, "pool job state"; M6 and M7
// A4; register CR-026, whose guard this is).
//
// The REAL HelperJob (GCHelperPool.hpp: the state word, isIdle(), isDone()).
// Copies, pinned by the canary (the functions live in GCHelperPool.cpp, which
// needs std::thread and std::mutex):
//   post()'s Concurrent path    GCHelperPool.cpp:150-179 (CAS Idle -> Posted
//                               acq_rel, then enqueue under m_)
//   one workerLoop iteration    :202-224 (dequeue under m_, Running relaxed,
//                               runJob OUTSIDE m_, then Done RELEASE under m_)
//   wait()                      :237-253 (fast path: acquire load, no m_; else
//                               the cv wait under m_, an assumption here)
//   PageWork's collectors       PageWork.cpp:78-106: reapDone() (isIdle(),
//                               isDone()), awaitSlot() (wait(), then reap),
//                               reap() (reads the runner's outputs, then
//                               WRITES the job and resetForReuse, :59-64)
// Property: once the owner has observed Done by either route, it sees every
// write the runner made (failures, the end timestamp), and its own writes to
// the job come after the runner's reads of it: no race, correct values.
//
// Variants: -DPOOL_REAPDONE (collect with reapDone() first, as takeSlot()
// does, then awaitSlot() if the job was not Done yet).
// Driver mutants: MUTANT_POOL_RELAXED_DONE (the Done store :220 relaxed),
// MUTANT_POOL_RELAXED_FASTPATH (wait()'s load :239 relaxed),
// MUTANT_POOL_RELAXED_CAS (post's CAS relaxed: expected to PASS, the post half
// is published by the mutex). Header mutant: POOL_RELAXED_ISDONE
// (GCHelperPool.hpp:57, through mutate.sh).
#include <atomic>
#include "GCHelperPool.hpp"
#include "wdriver.hpp"               // last: it redefines assert

using Elm::gc::HelperJob;

#ifdef MUTANT_POOL_RELAXED_DONE
constexpr std::memory_order kDoneStore = std::memory_order_relaxed;
#else
constexpr std::memory_order kDoneStore = std::memory_order_release;     // GCHelperPool.cpp:220
#endif
#ifdef MUTANT_POOL_RELAXED_FASTPATH
constexpr std::memory_order kFastLoad = std::memory_order_relaxed;
#else
constexpr std::memory_order kFastLoad = std::memory_order_acquire;      // GCHelperPool.cpp:239
#endif
#ifdef MUTANT_POOL_RELAXED_CAS
constexpr std::memory_order kPostCas = std::memory_order_relaxed;
#else
constexpr std::memory_order kPostCas = std::memory_order_acq_rel;       // GCHelperPool.cpp:155-156
#endif

// PageWork::PageJob's shape (PageWork.hpp:135-143): inputs the owner writes
// before post, an output the runner writes, read after Done.
struct Job : HelperJob {
    int kind = 0;               // input (Discard / Populate)
    uint64_t input = 0;         // input (the extent)
    uint64_t failures = 0;      // "written by the runner, read after Done"
};

static Job job;
static WMutex m;                // GCHelperPool::m_
static HelperJob* head;         // GCHelperPool::head_ (guarded by m)
static unsigned outstanding;    // GCHelperPool::outstanding_ (guarded by m)
static int reaped;              // written by the owner only

static void runPageJob(HelperJob* j) {                 // PageWork::runJob (PageWork.cpp:50-63)
    Job* s = static_cast<Job*>(j);
    s->failures = 0;
    if (s->kind == 1 && s->input != 7) ++s->failures;   // "ops.discard failed"
    if (s->kind == 1) s->failures += 10;                 // an output the owner must see
}

static void post(HelperJob& j) {                        // GCHelperPool::post, Concurrent mode
    uint32_t expect = HelperJob::Idle;
    const bool ok = j.state.compare_exchange_strong(expect, HelperJob::Posted, kPostCas);
    assert(ok);
    j.post_ns = 1;
    m.lock();
    j.next = nullptr;
    head = &j;
    ++outstanding;
    m.unlock();
}

static void* worker(void*) {                            // one workerLoop iteration
    m.lock();
    m.await([] { return head != nullptr; });            // cv_work_.wait(lk, head_ != nullptr)
    HelperJob* j = head;
    head = j->next;
    j->next = nullptr;
    assert(j->state.load(std::memory_order_relaxed) == HelperJob::Posted);
    j->state.store(HelperJob::Running, std::memory_order_relaxed);
    m.unlock();
    j->start_ns = 2;                                    // runJob (:133-148), outside m_
    j->run(j);
    j->end_ns = 3;
    m.lock();
    j->state.store(HelperJob::Done, kDoneStore);        // :220
    --outstanding;
    m.unlock();
    return nullptr;
}

static void waitDone(HelperJob& j) {                    // GCHelperPool::wait
    const uint32_t s = j.state.load(kFastLoad);
    if (s == HelperJob::Done) return;                   // the fast path: no m_
    assert(s != HelperJob::Idle);
    m.lock();                                           // cv_done_.wait(lk, Done)
    m.await([&j] { return j.state.load(std::memory_order_acquire) == HelperJob::Done; });
    m.unlock();
}

static void reap(Job& s) {                              // PageWork::reap
    // "Caller has observed Done (acquire): the runner's writes are visible."
    assert(s.failures == 10);
    assert(s.end_ns == 3);
    s.kind = 0;                                         // the owner rewrites the job
    s.input = 0;
    const uint32_t st = s.state.load(std::memory_order_acquire);   // resetForReuse (:59-64)
    assert(st == HelperJob::Done || st == HelperJob::Idle);
    s.state.store(HelperJob::Idle, std::memory_order_relaxed);
    s.next = nullptr;
    reaped = 1;
}

static void* owner(void*) {                             // PageWork: fill a slot, post, collect
    job.kind = 1;
    job.input = 7;
    job.run = &runPageJob;
    job.bytes = 64;
    post(job);
#ifdef POOL_REAPDONE
    if (!job.isIdle() && job.isDone()) reap(job);       // reapDone (PageWork.cpp:97-100)
    if (reaped) return nullptr;
#endif
    if (job.isIdle()) return nullptr;                   // awaitSlot (PageWork.cpp:103-111)
    waitDone(job);
    reap(job);
    return nullptr;
}

int main() {
    wthread w = spawn(worker), o = spawn(owner);
    join(w);
    join(o);
    assert(reaped == 1);
    return 0;
}
