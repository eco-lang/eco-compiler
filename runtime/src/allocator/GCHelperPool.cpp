#include "GCHelperPool.hpp"
#include "GCFork.hpp"     // the one pthread_atfork registration
#include "TlaTrace.hpp"   // compiled-out hooks (trace builds only)

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if !defined(_WIN32)
#include <unistd.h>
#endif
#include <ctime>
#include <new>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <pthread.h>
#  if defined(__linux__)
#    include <sched.h>
#    include <sys/resource.h>
#    include <sys/syscall.h>
#  endif
#endif

namespace Elm::gc {

// Trace hooks for the TLA+ model M6, which models the pool's job protocol and the fork handlers. They compile to
// nothing unless ECO_TLA_TRACE is set, and in a trace build they log only while a harness for M6 sets tla_m6, so
// traces taken for the other models are unchanged. The names in the `// M6:` comments below are the model's
// actions that each event stands for. A job's state is logged as `serial * 4 + state`, where serial numbers the
// job's posts, so that no two writes of the state log the same value.
#if ECO_TLA_TRACE_ENABLED
/// Whether the M6 hooks log; set by an M6 trace harness.
bool tla_m6 = false;
/// A counter that orders the M6 events which carry it.
std::atomic<int64_t> tla_m6_tick{0};
/// Logs a trace event, as `ECO_TLA_TRACE` does, while `tla_m6` is set. Expands to a statement.
#define M6_TRACE(...) do { if (::Elm::gc::tla_m6) ECO_TLA_TRACE(__VA_ARGS__); } while (0)
/// Takes the next value of the M6 event counter.
#define M6_TICK ::Elm::gc::tla_m6_tick.fetch_add(1)
/// Builds the logged value of `job` in state `st`: the serial of its current post times 4, plus `st`.
#define M6_JV(job, st) (::Elm::tlatrace::bound(&(job), 6) * 4 + static_cast<int64_t>(st))
/// Builds the trace key that names `job`'s state.
#define M6_JKEY(job) ::Elm::tlatrace::key("J", &(job))
#else
#define M6_TRACE(...) ((void)0)
#endif

namespace {

/// Writes `msg` to stderr with the `[gc-helper]` prefix and aborts the process.
[[noreturn]] void poolAbort(const char* msg) {
    std::fprintf(stderr, "[gc-helper] %s\n", msg);
    std::fflush(stderr);
    std::abort();
}

/// Raises `a` to `v` if `v` is larger, with relaxed ordering.
void fetchMax(std::atomic<uint64_t>& a, uint64_t v) {
    uint64_t cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
    }
}

/// Advances the xorshift64 generator state `*s` and returns the new value. Used only for jitter delays.
uint64_t xorshift(uint64_t* s) {
    uint64_t x = *s;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *s = x;
    return x;
}

} // namespace

void HelperJob::resetForReuse() {
    const uint32_t s = state.load(std::memory_order_acquire);
    if (s != Done && s != Idle) poolAbort("resetForReuse: job is still posted or running");
    state.store(Idle, std::memory_order_relaxed);
    M6_TRACE("pool.reset", "job", ::Elm::tlatrace::obj(this), "rmw", M6_JKEY(*this),
             "old", M6_JV(*this, s), "new", M6_JV(*this, Idle));
    next = nullptr;
}

GCHelperPool& GCHelperPool::instance() {
    // Never destroyed, so the destructor of a joinable std::thread never runs at exit.
    static GCHelperPool* inst = new GCHelperPool();
    return *inst;
}

uint64_t GCHelperPool::nowNs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

uint64_t GCHelperPool::threadCpuNs() {
#if defined(_WIN32)
    FILETIME c, e, k, u;
    if (!GetThreadTimes(GetCurrentThread(), &c, &e, &k, &u)) return 0;
    auto f = [](const FILETIME& t) {
        return (static_cast<uint64_t>(t.dwHighDateTime) << 32) | t.dwLowDateTime;
    };
    return (f(k) + f(u)) * 100;
#else
    timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return 0;
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull +
           static_cast<uint64_t>(ts.tv_nsec);
#endif
}

void GCHelperPool::configure(HelperMode mode, unsigned threads, int pin_cpu,
                             unsigned jitter_us) {
    // Registered before m_ is taken: the first registration takes the C library's atfork
    // lock, which a concurrent fork holds while its prepare handlers wait for runtime locks.
    static const ForkHooks kPoolHooks{&GCHelperPool::atforkPrepare, &GCHelperPool::atforkParent,
                                      &GCHelperPool::atforkChild};
    registerForkLayer(kForkPool, kPoolHooks);
    std::lock_guard<std::mutex> lk(m_);
    if (configured_.load(std::memory_order_relaxed)) {
        if (mode != mode_ || threads != threads_ || pin_cpu != pin_cpu_ ||
            jitter_us != jitter_us_) {
            poolAbort("configure: the helper pool is already configured with "
                      "different settings (the first configuration wins)");
        }
        return;
    }
    if (threads == 0 || threads > 64) poolAbort("configure: threads must be in [1, 64]");
    mode_ = mode;
    threads_ = threads;
    pin_cpu_ = pin_cpu;
    jitter_us_ = jitter_us;
    configured_.store(true, std::memory_order_release);
}

void GCHelperPool::startWorkersLocked() {
    started_ = true;
    stopping_ = false;
    workers_->reserve(threads_);
    for (unsigned i = 0; i < threads_; ++i) {
        workers_->emplace_back([this, i] { workerLoop(i); });
    }
}

void GCHelperPool::runJob(HelperJob& job, bool on_worker, uint64_t* rng) {
    if (on_worker && jitter_us_ > 0) {
        // A test that no decision depends on helper timing (GC_DET_001).
        const uint64_t us = xorshift(rng) % jitter_us_;
        std::this_thread::sleep_for(std::chrono::microseconds(us));
    }
    job.start_ns = nowNs();
    const uint64_t c0 = threadCpuNs();
    job.run(&job);
    const uint64_t cpu = threadCpuNs() - c0;
    job.end_ns = nowNs();
    ClientStats& cs = stats_.client[static_cast<size_t>(job.client)];
    cs.jobs.fetch_add(1, std::memory_order_relaxed);
    cs.bytes.fetch_add(job.bytes, std::memory_order_relaxed);
    (on_worker ? cs.cpu_ns : cs.inline_cpu_ns).fetch_add(cpu, std::memory_order_relaxed);
}

void GCHelperPool::post(HelperJob& job) {
    if (!configured_.load(std::memory_order_acquire) || mode_ == HelperMode::Off) {
        poolAbort("post: the helper pool is not configured (or is Off)");
    }
    if (mode_ == HelperMode::Sync) {
        uint32_t expect = HelperJob::Idle;
        if (!job.state.compare_exchange_strong(expect, HelperJob::Posted,
                                               std::memory_order_acq_rel)) {
            poolAbort("post: job is not Idle");
        }
        if (job.run == nullptr) poolAbort("post: job has no run function");
        stats_.posts.fetch_add(1, std::memory_order_relaxed);
        job.post_ns = nowNs();
        job.state.store(HelperJob::Running, std::memory_order_relaxed);
        runJob(job, /*on_worker=*/false, nullptr);
        job.state.store(HelperJob::Done, std::memory_order_release);
        return;
    }

    {
        // The Idle->Posted CAS and the enqueue are one m_ section, so a fork's prepare (which
        // drains and keeps m_) never sees a job that is Posted but in no queue.
        std::lock_guard<std::mutex> lk(m_);
        uint32_t expect = HelperJob::Idle;
        if (!job.state.compare_exchange_strong(expect, HelperJob::Posted,
                                               std::memory_order_acq_rel)) {
            poolAbort("post: job is not Idle");
        }
        // M6: the CAS under m_ (M_PostCas). The probe is a point where a harness may pause
        // this thread; it is inside m_, so such a pause must be bounded.
        // m6_old is read before bind() gives the post its serial, because the order in which
        // arguments are evaluated is unspecified.
        ECO_TLA_TRACE_ONLY(const int64_t m6_old = ::Elm::gc::tla_m6 ? M6_JV(job, HelperJob::Idle) : 0;)
        M6_TRACE("pool.cas", "job", ::Elm::tlatrace::obj(&job), "rmw", M6_JKEY(job),
                 "old", m6_old, "new", ::Elm::tlatrace::bind(&job, 6) * 4 + HelperJob::Posted);
        ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.post.cas");)
        if (job.run == nullptr) poolAbort("post: job has no run function");
        stats_.posts.fetch_add(1, std::memory_order_relaxed);
        job.post_ns = nowNs();
        if (!started_) startWorkersLocked();
        job.next = nullptr;
        if (tail_) tail_->next = &job; else head_ = &job;
        tail_ = &job;
        ++outstanding_;
        M6_TRACE("pool.enq", "job", ::Elm::tlatrace::obj(&job), "out", outstanding_, "clk", "m6", "tick", M6_TICK);
    }
    cv_work_.notify_one();
}

void GCHelperPool::workerLoop(unsigned index) {
    ECO_TLA_TRACE_ONLY(::Elm::tlatrace::nameThread("eco-gc", index);)   // names the thread in the trace
#if !defined(_WIN32)
    {
        char name[16];
        std::snprintf(name, sizeof name, "eco-gc-%u", index);
#  if defined(__APPLE__)
        pthread_setname_np(name);
#  else
        pthread_setname_np(pthread_self(), name);
#  endif
    }
#  if defined(__linux__)
    if (index == 0 && pin_cpu_ >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(pin_cpu_, &set);
        pthread_setaffinity_np(pthread_self(), sizeof set, &set);
    }
#  endif
#endif
    uint64_t rng = 0x9E3779B97F4A7C15ull ^ (static_cast<uint64_t>(index) + 1) * 0xBF58476D1CE4E5B9ull;
    for (;;) {
        HelperJob* job = nullptr;
        {
            std::unique_lock<std::mutex> lk(m_);
            cv_work_.wait(lk, [this] { return head_ != nullptr || stopping_; });
            if (head_ == nullptr) return;   // stopping, queue empty
            job = head_;
            head_ = job->next;
            if (head_ == nullptr) tail_ = nullptr;
            job->next = nullptr;
            if (job->state.load(std::memory_order_relaxed) != HelperJob::Posted) {
                poolAbort("worker: dequeued a job that is not Posted");
            }
            job->state.store(HelperJob::Running, std::memory_order_relaxed);
            M6_TRACE("pool.take", "job", ::Elm::tlatrace::obj(job), "rmw", M6_JKEY(*job),
                     "old", M6_JV(*job, HelperJob::Posted), "new", M6_JV(*job, HelperJob::Running),
                     "clk", "m6", "tick", M6_TICK);
        }
        runJob(*job, /*on_worker=*/true, &rng);
        {
            std::lock_guard<std::mutex> lk(m_);
            M6_TRACE("pool.done", "job", ::Elm::tlatrace::obj(job), "out", outstanding_ - 1, "rmw", M6_JKEY(*job),
                     "old", M6_JV(*job, HelperJob::Running), "new", M6_JV(*job, HelperJob::Done),
                     "clk", "m6", "tick", M6_TICK);
            job->state.store(HelperJob::Done, std::memory_order_release);
            --outstanding_;
        }
        cv_done_.notify_all();
    }
}

void GCHelperPool::noteStall(uint64_t dur_ns, bool in_pause) {
    stats_.stall_count.fetch_add(1, std::memory_order_relaxed);
    stats_.stall_ns.fetch_add(dur_ns, std::memory_order_relaxed);
    fetchMax(stats_.stall_max_ns, dur_ns);
    if (!in_pause) {
        stats_.stall_outside_pause.fetch_add(1, std::memory_order_relaxed);
        stats_.stall_outside_pause_ns.fetch_add(dur_ns, std::memory_order_relaxed);
    }
}

GCHelperPool::StallRecord GCHelperPool::wait(HelperJob& job, bool in_pause) {
    StallRecord rec;
    const uint32_t s = job.state.load(std::memory_order_acquire);
    M6_TRACE("pool.wfast", "job", ::Elm::tlatrace::obj(&job), "st", s, "rd", M6_JKEY(job), "val", M6_JV(job, s));
    if (s == HelperJob::Done) return rec;
    if (s == HelperJob::Idle) poolAbort("wait: job was never posted");
    rec.start_ns = nowNs();
    {
        std::unique_lock<std::mutex> lk(m_);
        cv_done_.wait(lk, [&] {
            // M6: every check of the predicate under m_ (WR_Lock; a re-check after a wake-up).
            ECO_TLA_TRACE_ONLY(const uint32_t m6_s = job.state.load(std::memory_order_acquire);)
            M6_TRACE("pool.wchk", "job", ::Elm::tlatrace::obj(&job), "st", m6_s, "rd", M6_JKEY(job),
                     "val", M6_JV(job, m6_s), "clk", "m6", "tick", M6_TICK);
            return job.state.load(std::memory_order_acquire) == HelperJob::Done;
        });
    }
    rec.dur_ns = nowNs() - rec.start_ns;
    rec.stalled = true;
    noteStall(rec.dur_ns, in_pause);
    return rec;
}

void GCHelperPool::drain() {
    if (mode_ != HelperMode::Concurrent) return;   // Sync jobs are Done at post
    std::unique_lock<std::mutex> lk(m_);
    cv_done_.wait(lk, [this] { return outstanding_ == 0; });
}

void GCHelperPool::atforkPrepare() {
    GCHelperPool& p = instance();
    // Drain and lock in one section: no job may be queued or running across the fork,
    // because the child has no worker to finish it. The wait releases m_, which is all a
    // worker needs to finish a Running job; the predicate is checked with m_ held, and m_
    // stays held, so no job can be posted between the drain and the fork.
    p.m_.lock();
    if (p.configured_.load(std::memory_order_acquire) && p.mode_ == HelperMode::Concurrent) {
        std::unique_lock<std::mutex> lk(p.m_, std::adopt_lock);
        p.cv_done_.wait(lk, [&] { return p.outstanding_ == 0; });
        lk.release();                     // m_ stays held across fork
    }
    M6_TRACE("pool.drained", "clk", "m6", "tick", M6_TICK);   // M6: F_Drain (m_ kept)
    // M6: a point where a harness may pause this thread, inside m_ (so the pause must be bounded).
    ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.pool.drained");)
    M6_TRACE("pool.plock", "clk", "m6", "tick", M6_TICK);    // M6: the same section (a check)
}

void GCHelperPool::atforkParent() {
    M6_TRACE("pool.parent", "clk", "m6", "tick", M6_TICK);   // M6: F_Fork, parent
    instance().m_.unlock();
}

void GCHelperPool::atforkChild() {
    GCHelperPool& p = instance();
    // The parent's workers were parked in cv_work_.wait() at fork: a
    // condition variable (or mutex) with waiters that no longer exist is not
    // safe to reuse. Re-construct all three in place (old state abandoned).
    new (&p.m_) std::mutex();
    new (&p.cv_work_) std::condition_variable();
    new (&p.cv_done_) std::condition_variable();
    // Only the forking thread exists in the child. Abandon (leak) the
    // parent's std::thread objects rather than destroying joinable ones, and
    // let the next post start fresh workers.
    p.workers_ = new std::vector<std::thread>();
    p.started_ = false;
    p.stopping_ = false;
    p.head_ = p.tail_ = nullptr;
    p.outstanding_ = 0;
    M6_TRACE("pool.child", "clk", "m6", "tick", M6_TICK);    // M6: F_Fork, child
}

void GCHelperPool::shutdownForTesting() {
    {
        std::lock_guard<std::mutex> lk(m_);
        if (outstanding_ != 0 || head_ != nullptr) {
            poolAbort("shutdownForTesting: jobs are still posted");
        }
        stopping_ = true;
    }
    cv_work_.notify_all();
    for (auto& t : *workers_) {
        if (t.joinable()) t.join();
    }
    std::lock_guard<std::mutex> lk(m_);
    workers_->clear();
    started_ = false;
    stopping_ = false;
    configured_.store(false, std::memory_order_release);
    mode_ = HelperMode::Off;
    for (auto& c : stats_.client) {
        c.jobs.store(0); c.bytes.store(0); c.cpu_ns.store(0); c.inline_cpu_ns.store(0);
    }
    stats_.posts.store(0);
    stats_.stall_count.store(0);
    stats_.stall_ns.store(0);
    stats_.stall_max_ns.store(0);
    stats_.stall_outside_pause.store(0);
    stats_.stall_outside_pause_ns.store(0);
}

// ===========================================================================
// GCMarkGang
// ===========================================================================

GCMarkGang& GCMarkGang::instance() {
    static GCMarkGang* g = new GCMarkGang();   // leaky, like the pool
    return *g;
}

void GCMarkGang::configure(unsigned members, unsigned jitter_us) {
    GCBackgroundGang::registerForkLayerOnce();   // before m_: registering may wait on a fork's prepare
    std::lock_guard<std::mutex> lk(m_);
    if (configured_.load(std::memory_order_relaxed)) {
        if (members != members_ || jitter_us != jitter_us_) {
            poolAbort("GCMarkGang::configure: already configured with different settings");
        }
        return;
    }
    if (members == 0 || members > 64) poolAbort("GCMarkGang::configure: members must be in [1, 64]");
    members_ = members;
    jitter_us_ = jitter_us;
    configured_.store(true, std::memory_order_release);
}

void GCMarkGang::startThreadsLocked() {
    if (started_) return;
    started_ = true;
    for (unsigned i = 1; i < members_; ++i) {
        threads_->emplace_back([this, i] { memberLoop(i); });
    }
}

void GCMarkGang::memberLoop(unsigned index) {
#if !defined(_WIN32)
    {
        char name[16];
        std::snprintf(name, sizeof name, "eco-mark-%u", index);
#  if defined(__APPLE__)
        pthread_setname_np(name);
#  else
        pthread_setname_np(pthread_self(), name);
#  endif
    }
#endif
    ECO_TLA_TRACE_ONLY(::Elm::tlatrace::nameThread("eco-mark", index);)
    uint64_t seen = 0;
    uint64_t rng = 0xD1B54A32D192ED03ull ^ (static_cast<uint64_t>(index) * 0x9E3779B97F4A7C15ull);
    for (;;) {
        Fn fn;
        void* ctx;
        uint64_t post;
        unsigned n;
        {
            std::unique_lock<std::mutex> lk(m_);
            cv_start_.wait(lk, [&] { return stopping_ || generation_ != seen; });
            if (stopping_) return;
            seen = generation_;
            if (index >= running_n_) continue;       // not part of this run
            fn = fn_;
            ctx = ctx_;
            post = post_ns_;
            n = running_n_;
        }
        const uint64_t wake = GCHelperPool::nowNs() - post;
        stats_.wake_ns_total.fetch_add(wake, std::memory_order_relaxed);
        uint64_t prev = stats_.wake_ns_max.load(std::memory_order_relaxed);
        while (wake > prev &&
               !stats_.wake_ns_max.compare_exchange_weak(prev, wake, std::memory_order_relaxed)) {
        }
        if (jitter_us_ != 0) {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
            std::this_thread::sleep_for(std::chrono::microseconds(rng % (jitter_us_ + 1)));
        }
        const uint64_t c0 = GCHelperPool::threadCpuNs();
        ECO_TLA_TRACE("gang.start", "gang", ::Elm::tlatrace::key("F", this), "gen", seen, "m", index,
                      "get", ::Elm::tlatrace::key("R", this, static_cast<int64_t>(seen)));
        tl_member_run_ = true;    // read by onMemberRun()
        fn(ctx, index);
        tl_member_run_ = false;
        ECO_TLA_TRACE("gang.exit", "gang", ::Elm::tlatrace::key("F", this), "gen", seen, "m", index,
                      "put", ::Elm::tlatrace::key("RX", this, static_cast<int64_t>(seen)));
        stats_.member_cpu_ns.fetch_add(GCHelperPool::threadCpuNs() - c0, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> lk(m_);
            if (++finished_ == n - 1) cv_done_.notify_one();
        }
    }
}

void GCMarkGang::run(Fn fn, void* ctx, unsigned n) {
    if (n <= 1) {
        fn(ctx, 0);
        return;
    }
    std::lock_guard<std::mutex> run_lk(run_m_);
    if (!configured_.load(std::memory_order_acquire) || n > members_) {
        poolAbort("GCMarkGang::run: not configured for this many members");
    }
    {
        std::lock_guard<std::mutex> lk(m_);
        startThreadsLocked();
        fn_ = fn;
        ctx_ = ctx;
        running_n_ = n;
        finished_ = 0;
        post_ns_ = GCHelperPool::nowNs();
        ++generation_;
        ECO_TLA_TRACE("gang.run", "gang", ::Elm::tlatrace::key("F", this), "gen", generation_, "members", n,
                      "put", ::Elm::tlatrace::key("R", this, static_cast<int64_t>(generation_)));
    }
    cv_start_.notify_all();
    stats_.runs.fetch_add(1, std::memory_order_relaxed);
    fn(ctx, 0);
    std::unique_lock<std::mutex> lk(m_);
    cv_done_.wait(lk, [&] { return finished_ == n - 1; });
    ECO_TLA_TRACE("gang.runEnd", "gang", ::Elm::tlatrace::key("F", this), "gen", generation_,
                  "get", ::Elm::tlatrace::key("RX", this, static_cast<int64_t>(generation_)));
}

void GCMarkGang::shutdownForTesting() {
    std::lock_guard<std::mutex> run_lk(run_m_);
    {
        std::lock_guard<std::mutex> lk(m_);
        stopping_ = true;
    }
    cv_start_.notify_all();
    for (std::thread& t : *threads_) {
        if (t.joinable()) t.join();
    }
    threads_->clear();
    std::lock_guard<std::mutex> lk(m_);
    stopping_ = false;
    started_ = false;
    generation_ = 0;
    running_n_ = finished_ = 0;
    members_ = 1;
    jitter_us_ = 0;
    stats_.runs.store(0);
    stats_.member_cpu_ns.store(0);
    stats_.wake_ns_total.store(0);
    stats_.wake_ns_max.store(0);
    configured_.store(false, std::memory_order_release);
}

void GCMarkGang::atforkPrepare() {
    GCMarkGang& g = instance();
    // Taking run_m_ waits out any run and keeps new ones from starting. This runs after
    // the background gangs' prepare and before the allocator layer takes thread_mutex_,
    // the order GCFork's ForkLayer sets.
    g.run_m_.lock();
    g.m_.lock();
    M6_TRACE("fork.mprep", "clk", "m6", "tick", M6_TICK);    // M6: G_Mark1 / G_RunM
}

void GCMarkGang::atforkParent() {
    GCMarkGang& g = instance();
    M6_TRACE("fork.mparent", "clk", "m6", "tick", M6_TICK);  // M6: G_Fork, parent
    g.m_.unlock();
    g.run_m_.unlock();
}

void GCMarkGang::atforkChild() {
    GCMarkGang& g = instance();
    new (&g.run_m_) std::mutex();
    new (&g.m_) std::mutex();
    new (&g.cv_start_) std::condition_variable();
    new (&g.cv_done_) std::condition_variable();
    g.threads_ = new std::vector<std::thread>();   // abandon the parent's
    g.started_ = false;
    g.stopping_ = false;
    g.running_n_ = g.finished_ = 0;
    M6_TRACE("fork.mchild", "clk", "m6", "tick", M6_TICK);   // M6: G_Fork, child
}

// ===========================================================================
// GCBackgroundGang
// ===========================================================================

namespace {
/// Returns the mutex that guards the registry of background gangs. Never destroyed, because
/// the atexit and fork handlers use it.
std::mutex& bgRegistryMutex() {
    static std::mutex* m = new std::mutex();    // leaky: used from atexit/atfork
    return *m;
}
/// Returns the registry: every background gang constructed and not yet destroyed. Guarded by
/// bgRegistryMutex(). Never destroyed.
std::vector<GCBackgroundGang*>& bgRegistry() {
    static auto* v = new std::vector<GCBackgroundGang*>();
    return *v;
}
bool bg_hooks_registered = false;               // atexit done; guarded by bgRegistryMutex()
}  // namespace

GCBackgroundGang::GCBackgroundGang(const Options& opt) : opt_(opt) {
    if (opt_.members == 0 || opt_.members > 63) {
        poolAbort("GCBackgroundGang: members must be in [1, 63]");
    }
    registerForkLayerOnce();                    // before the registry lock: may wait on a fork's prepare
    std::lock_guard<std::mutex> lk(bgRegistryMutex());
    if (!bg_hooks_registered) {
        bg_hooks_registered = true;
        std::atexit(&GCBackgroundGang::stopAllAtExit);
    }
    bgRegistry().push_back(this);
}

GCBackgroundGang::~GCBackgroundGang() {
    stopAndJoin();
    {
        std::lock_guard<std::mutex> lk(m_);
        stopping_ = true;
    }
    cv_start_.notify_all();
    for (std::thread& t : *threads_) {
        if (t.joinable()) t.join();
    }
    delete threads_;
    std::lock_guard<std::mutex> lk(bgRegistryMutex());
    auto& reg = bgRegistry();
    for (size_t i = 0; i < reg.size(); ++i) {
        if (reg[i] == this) { reg.erase(reg.begin() + static_cast<std::ptrdiff_t>(i)); break; }
    }
}

void GCBackgroundGang::startThreadsLocked() {
    if (started_) return;
    started_ = true;
    tids_.assign(opt_.members, 0);
    for (unsigned i = 0; i < opt_.members; ++i) {
        threads_->emplace_back([this, i] { memberLoop(i); });
    }
}

void GCBackgroundGang::memberLoop(unsigned index) {
#if !defined(_WIN32)
    {
        char name[16];
        std::snprintf(name, sizeof name, "%.10s-%u", opt_.name ? opt_.name : "eco-cmark", index);
#  if defined(__APPLE__)
        pthread_setname_np(name);
#  else
        pthread_setname_np(pthread_self(), name);
#  endif
    }
#endif
#if defined(__linux__)
    const long tid = static_cast<long>(syscall(SYS_gettid));
    // Set once, at thread start, and never changed.
    if (opt_.priority >= 1 && opt_.priority <= 19) {
        (void)setpriority(PRIO_PROCESS, static_cast<id_t>(tid), opt_.priority);
    } else if (opt_.priority == 20) {
        sched_param sp{};
        sp.sched_priority = 0;
        (void)pthread_setschedparam(pthread_self(), SCHED_IDLE, &sp);
    }
    {
        std::lock_guard<std::mutex> lk(m_);
        if (index < tids_.size()) tids_[index] = tid;
    }
#endif
    ECO_TLA_TRACE_ONLY(::Elm::tlatrace::nameThread(opt_.name ? opt_.name : "eco-cmark", index);)
    uint64_t seen = 0;
    uint64_t rng = 0xA0761D6478BD642Full ^ (static_cast<uint64_t>(index + 1) * 0x9E3779B97F4A7C15ull);
    for (;;) {
        Fn fn;
        void* ctx;
        {
            std::unique_lock<std::mutex> lk(m_);
            cv_start_.wait(lk, [&] { return stopping_ || generation_ != seen; });
            if (stopping_) return;
            seen = generation_;
            fn = fn_;
            ctx = ctx_;
        }
        if (opt_.jitter_us != 0) {
            std::this_thread::sleep_for(
                std::chrono::microseconds(xorshift(&rng) % (opt_.jitter_us + 1)));
        }
        const uint64_t c0 = GCHelperPool::threadCpuNs();
        ECO_TLA_TRACE("gang.start", "gang", ::Elm::tlatrace::key("B", this), "gen", seen, "m", index,
                      "get", ::Elm::tlatrace::key("L", this, static_cast<int64_t>(seen)));
        fn(ctx, index);
        ECO_TLA_TRACE("gang.exit", "gang", ::Elm::tlatrace::key("B", this), "gen", seen, "m", index,
                      "put", ::Elm::tlatrace::key("X", this, static_cast<int64_t>(seen)));
        stats_.member_cpu_ns.fetch_add(GCHelperPool::threadCpuNs() - c0, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> lk(m_);
            ++finished_;
            finished_pub_.store(finished_, std::memory_order_release);
            if (finished_ == opt_.members) cv_done_.notify_all();
        }
    }
}

bool GCBackgroundGang::launch(Fn fn, void* ctx, std::atomic<bool>* stop) {
    {
        std::lock_guard<std::mutex> lk(m_);
        // While a fork's prepare holds the gang, a launch is refused rather than blocked: a
        // blocked launch could stall its caller while the forking thread waits for a lock
        // that caller holds.
        if (fork_hold_) {
            stats_.fork_refusals.fetch_add(1, std::memory_order_relaxed);
            ECO_TLA_TRACE("gang.refuse", "gang", ::Elm::tlatrace::key("B", this), "gen", generation_);
            return false;
        }
        if (running_.load(std::memory_order_relaxed)) {
            poolAbort("GCBackgroundGang::launch: already running");
        }
        startThreadsLocked();
        fn_ = fn;
        ctx_ = ctx;
        stop_ = stop;
        finished_ = 0;
        finished_pub_.store(0, std::memory_order_relaxed);
        ++generation_;
        running_.store(true, std::memory_order_release);
        ECO_TLA_TRACE("gang.launch", "gang", ::Elm::tlatrace::key("B", this), "gen", generation_,
                      "put", ::Elm::tlatrace::key("L", this, static_cast<int64_t>(generation_)));
    }
    cv_start_.notify_all();
    cv_done_.notify_all();   // wakes a stopAndJoin still waiting on the previous generation
    stats_.launches.fetch_add(1, std::memory_order_relaxed);
    return true;
}

bool GCBackgroundGang::finishedApprox() const {
    return finished_pub_.load(std::memory_order_acquire) >= opt_.members;
}

void GCBackgroundGang::joinLocked(std::unique_lock<std::mutex>& lk, bool stopping) {
    const uint64_t t0 = GCHelperPool::nowNs();
    cv_done_.wait(lk, [&] { return finished_ >= opt_.members; });
    ECO_TLA_TRACE("gang.join", "gang", ::Elm::tlatrace::key("B", this), "gen", generation_, "stop", stopping,
                  "get", ::Elm::tlatrace::key("X", this, static_cast<int64_t>(generation_)));
    running_.store(false, std::memory_order_release);
    const uint64_t d = GCHelperPool::nowNs() - t0;
    stats_.join_wait_ns_total.fetch_add(d, std::memory_order_relaxed);
    fetchMax(stats_.join_wait_ns_max, d);
    if (stopping) fetchMax(stats_.stop_wait_ns_max, d);
}

void GCBackgroundGang::join() {
    std::unique_lock<std::mutex> lk(m_);
    if (!running_.load(std::memory_order_relaxed)) return;
    joinLocked(lk, false);
}

void GCBackgroundGang::stopAndJoin() {
    std::unique_lock<std::mutex> lk(m_);
    if (!running_.load(std::memory_order_relaxed)) return;
    if (stop_ != nullptr) stop_->store(true, std::memory_order_release);
    // Wait only for the generation this call stopped. Another thread may join it and
    // relaunch while we wait (launch notifies cv_done_); the new episode is then not ours
    // to wait out, nor to mark not running.
    const uint64_t my_gen = generation_;
    // M6: SJ_Lock (the stop, under m_). The probe tells a harness the stop is set.
    M6_TRACE("gang.stop", "gang", ::Elm::tlatrace::key("B", this), "gen", generation_, "clk", "m6", "tick", M6_TICK);
    ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.stopset");)
    const uint64_t t0 = GCHelperPool::nowNs();
    cv_done_.wait(lk, [&] { return generation_ != my_gen || finished_ >= opt_.members; });
    if (generation_ == my_gen) {                     // we join our own episode
        ECO_TLA_TRACE("gang.join", "gang", ::Elm::tlatrace::key("B", this), "gen", generation_, "stop", true,
                      "get", ::Elm::tlatrace::key("X", this, static_cast<int64_t>(generation_)));
        running_.store(false, std::memory_order_release);
    }   // else the owner joined my_gen and relaunched: never clear the new episode's running_
    const uint64_t d = GCHelperPool::nowNs() - t0;
    stats_.join_wait_ns_total.fetch_add(d, std::memory_order_relaxed);
    fetchMax(stats_.join_wait_ns_max, d);
    fetchMax(stats_.stop_wait_ns_max, d);
}

std::vector<long> GCBackgroundGang::memberTids() const {
    std::lock_guard<std::mutex> lk(m_);
    return tids_;
}

void GCBackgroundGang::stopAllForFork() {
    for (GCBackgroundGang* g : bgRegistry()) {
        if (g->running()) {
            g->stopAndJoin();
            ECO_TLA_TRACE("stop", "gang", ::Elm::tlatrace::key("B", g));   // records a fork stopping this gang
            g->stats_.fork_stops.fetch_add(1, std::memory_order_relaxed);
        }
    }
}

void GCBackgroundGang::stopAllAtExit() {
    std::lock_guard<std::mutex> lk(bgRegistryMutex());
    for (GCBackgroundGang* g : bgRegistry()) g->stopAndJoin();
}

void GCBackgroundGang::atforkPrepare() {
    bgRegistryMutex().lock();
    M6_TRACE("fork.bgreg", "clk", "m6", "tick", M6_TICK);    // M6: G_Reg
    // The hold comes before the stops, so no launch can start an episode between
    // stopAllForFork and the m_ locks below: a launch is refused from here on.
    for (GCBackgroundGang* g : bgRegistry()) {
        std::lock_guard<std::mutex> lk(g->m_);
        g->fork_hold_ = true;
    }
    M6_TRACE("fork.bghold", "clk", "m6", "tick", M6_TICK);   // M6: G_Hold
    stopAllForFork();
    // M6: a point where a harness may pause after the stops and before the m_ locks; a
    // launch made during the pause is refused because of the hold.
    ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.bg.stopped");)
    // Hold every instance's mutex across fork so the child's copy is consistent.
    for (GCBackgroundGang* g : bgRegistry()) g->m_.lock();
    M6_TRACE("fork.bglock", "clk", "m6", "tick", M6_TICK);   // M6: G_Lock1 (and G_Lock2)
}

void GCBackgroundGang::atforkParent() {
    M6_TRACE("fork.bparent", "clk", "m6", "tick", M6_TICK);  // M6: G_Fork, parent
    for (GCBackgroundGang* g : bgRegistry()) {
        g->fork_hold_ = false;                    // still under g->m_
        g->m_.unlock();
    }
    bgRegistryMutex().unlock();
}

void GCBackgroundGang::atforkChild() {
    for (GCBackgroundGang* g : bgRegistry()) {
        new (&g->m_) std::mutex();
        new (&g->cv_start_) std::condition_variable();
        new (&g->cv_done_) std::condition_variable();
        g->threads_ = new std::vector<std::thread>();   // abandon the parent's
        g->started_ = false;
        g->stopping_ = false;
        g->fork_hold_ = false;
        g->finished_ = 0;
        g->finished_pub_.store(0, std::memory_order_relaxed);
        g->running_.store(false, std::memory_order_relaxed);
        g->tids_.clear();
    }
    new (&bgRegistryMutex()) std::mutex();
    M6_TRACE("fork.bchild", "clk", "m6", "tick", M6_TICK);   // M6: G_Fork, child
}

void GCBackgroundGang::forkGangsPrepare() {
    GCBackgroundGang::atforkPrepare();
    GCMarkGang::atforkPrepare();
}
void GCBackgroundGang::forkGangsParent() {
    GCMarkGang::atforkParent();
    GCBackgroundGang::atforkParent();
}
void GCBackgroundGang::forkGangsChild() {
    GCMarkGang::atforkChild();
    GCBackgroundGang::atforkChild();
}
void GCBackgroundGang::registerForkLayerOnce() {
    static const ForkHooks kGangsHooks{&GCBackgroundGang::forkGangsPrepare,
                                       &GCBackgroundGang::forkGangsParent,
                                       &GCBackgroundGang::forkGangsChild};
    registerForkLayer(kForkGangs, kGangsHooks);
}

unsigned availableCpus() {
    unsigned n = 0;
#if defined(__linux__)
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof set, &set) == 0) n = static_cast<unsigned>(CPU_COUNT(&set));
    if (FILE* f = std::fopen("/sys/fs/cgroup/cpu.max", "r")) {
        char quota[32] = {0};
        unsigned long long period = 0;
        if (std::fscanf(f, "%31s %llu", quota, &period) == 2 && period > 0 &&
            std::strcmp(quota, "max") != 0) {
            const unsigned long long q = std::strtoull(quota, nullptr, 10);
            if (q > 0) {
                const unsigned cg = static_cast<unsigned>((q + period - 1) / period);
                if (n == 0 || cg < n) n = cg;
            }
        }
        std::fclose(f);
    }
#elif defined(_WIN32)
    n = static_cast<unsigned>(GetActiveProcessorCount(ALL_PROCESSOR_GROUPS));
#else
    const long v = sysconf(_SC_NPROCESSORS_ONLN);
    if (v > 0) n = static_cast<unsigned>(v);
#endif
    return n == 0 ? 1 : n;
}

} // namespace Elm::gc
