// threaded-gc-03: GC helper-thread pool. See GCHelperPool.hpp and
// plans/threaded-gc-03-helper-threads.md P§3.1-3.4.

#include "GCHelperPool.hpp"

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

namespace {

[[noreturn]] void poolAbort(const char* msg) {
    std::fprintf(stderr, "[gc-helper] %s\n", msg);
    std::fflush(stderr);
    std::abort();
}

void fetchMax(std::atomic<uint64_t>& a, uint64_t v) {
    uint64_t cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
    }
}

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
    next = nullptr;
}

GCHelperPool& GCHelperPool::instance() {
    // Leaky singleton: the object (and any worker std::thread objects it
    // holds) is never destroyed, so no joinable-thread destructor ever runs
    // at exit. Workers parked in cv_work_ die with the process (POSIX); Win64
    // exits via TerminateProcess (eco_entry.cpp) for the same reason the
    // platform service threads need it.
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
#if !defined(_WIN32)
    static bool atfork_registered = false;
    if (!atfork_registered) {
        atfork_registered = true;
        pthread_atfork(&GCHelperPool::atforkPrepare, &GCHelperPool::atforkParent,
                       &GCHelperPool::atforkChild);
    }
#endif
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
        // Determinism probe (GC_DET_001): never read by any decision.
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
    uint32_t expect = HelperJob::Idle;
    if (!job.state.compare_exchange_strong(expect, HelperJob::Posted,
                                           std::memory_order_acq_rel)) {
        poolAbort("post: job is not Idle");
    }
    if (job.run == nullptr) poolAbort("post: job has no run function");
    stats_.posts.fetch_add(1, std::memory_order_relaxed);
    job.post_ns = nowNs();

    if (mode_ == HelperMode::Sync) {
        job.state.store(HelperJob::Running, std::memory_order_relaxed);
        runJob(job, /*on_worker=*/false, nullptr);
        job.state.store(HelperJob::Done, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(m_);
        if (!started_) startWorkersLocked();
        job.next = nullptr;
        if (tail_) tail_->next = &job; else head_ = &job;
        tail_ = &job;
        ++outstanding_;
    }
    cv_work_.notify_one();
}

void GCHelperPool::workerLoop(unsigned index) {
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
        }
        runJob(*job, /*on_worker=*/true, &rng);
        {
            std::lock_guard<std::mutex> lk(m_);
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
    if (s == HelperJob::Done) return rec;
    if (s == HelperJob::Idle) poolAbort("wait: job was never posted");
    rec.start_ns = nowNs();
    {
        std::unique_lock<std::mutex> lk(m_);
        cv_done_.wait(lk, [&] {
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
    // No job may be half-done across fork: the child could never finish it.
    if (p.configured_.load(std::memory_order_acquire)) p.drain();
    p.m_.lock();
}

void GCHelperPool::atforkParent() {
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
// threaded-gc-05b: GCMarkGang
// ===========================================================================

GCMarkGang& GCMarkGang::instance() {
    static GCMarkGang* g = new GCMarkGang();   // leaky, like the pool
    return *g;
}

void GCMarkGang::configure(unsigned members, unsigned jitter_us) {
    std::lock_guard<std::mutex> lk(m_);
    if (configured_.load(std::memory_order_relaxed)) {
        if (members != members_ || jitter_us != jitter_us_) {
            poolAbort("GCMarkGang::configure: already configured with different settings");
        }
        return;
    }
    if (members == 0 || members > 64) poolAbort("GCMarkGang::configure: members must be in [1, 64]");
#if !defined(_WIN32)
    static bool atfork_registered = false;
    if (!atfork_registered) {
        atfork_registered = true;
        pthread_atfork(&GCMarkGang::atforkPrepare, &GCMarkGang::atforkParent,
                       &GCMarkGang::atforkChild);
    }
#endif
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
        fn(ctx, index);
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
    }
    cv_start_.notify_all();
    stats_.runs.fetch_add(1, std::memory_order_relaxed);
    fn(ctx, 0);
    std::unique_lock<std::mutex> lk(m_);
    cv_done_.wait(lk, [&] { return finished_ == n - 1; });
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
    // Runs happen only inside a GC pause, fork only outside one (plan trap 12):
    // taking run_m_ waits out any run and keeps new ones from starting.
    g.run_m_.lock();
    g.m_.lock();
}

void GCMarkGang::atforkParent() {
    GCMarkGang& g = instance();
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
}

// ===========================================================================
// threaded-gc-05c: GCBackgroundGang
// ===========================================================================

namespace {
std::mutex& bgRegistryMutex() {
    static std::mutex* m = new std::mutex();    // leaky: used from atexit/atfork
    return *m;
}
std::vector<GCBackgroundGang*>& bgRegistry() {
    static auto* v = new std::vector<GCBackgroundGang*>();
    return *v;
}
bool bg_hooks_registered = false;               // guarded by bgRegistryMutex()
}  // namespace

GCBackgroundGang::GCBackgroundGang(const Options& opt) : opt_(opt) {
    if (opt_.members == 0 || opt_.members > 63) {
        poolAbort("GCBackgroundGang: members must be in [1, 63]");
    }
    std::lock_guard<std::mutex> lk(bgRegistryMutex());
    if (!bg_hooks_registered) {
        bg_hooks_registered = true;
#if !defined(_WIN32)
        pthread_atfork(&GCBackgroundGang::atforkPrepare, &GCBackgroundGang::atforkParent,
                       &GCBackgroundGang::atforkChild);
#endif
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
        std::snprintf(name, sizeof name, "eco-cmark-%u", index);
#  if defined(__APPLE__)
        pthread_setname_np(name);
#  else
        pthread_setname_np(pthread_self(), name);
#  endif
    }
#endif
#if defined(__linux__)
    const long tid = static_cast<long>(syscall(SYS_gettid));
    // One-way (plan F20): set once, never raised again.
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
        fn(ctx, index);
        stats_.member_cpu_ns.fetch_add(GCHelperPool::threadCpuNs() - c0, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> lk(m_);
            ++finished_;
            finished_pub_.store(finished_, std::memory_order_release);
            if (finished_ == opt_.members) cv_done_.notify_all();
        }
    }
}

void GCBackgroundGang::launch(Fn fn, void* ctx, std::atomic<bool>* stop) {
    {
        std::lock_guard<std::mutex> lk(m_);
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
    }
    cv_start_.notify_all();
    stats_.launches.fetch_add(1, std::memory_order_relaxed);
}

bool GCBackgroundGang::finishedApprox() const {
    return finished_pub_.load(std::memory_order_acquire) >= opt_.members;
}

void GCBackgroundGang::joinLocked(std::unique_lock<std::mutex>& lk, bool stopping) {
    const uint64_t t0 = GCHelperPool::nowNs();
    cv_done_.wait(lk, [&] { return finished_ >= opt_.members; });
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
    joinLocked(lk, true);
}

std::vector<long> GCBackgroundGang::memberTids() const {
    std::lock_guard<std::mutex> lk(m_);
    return tids_;
}

void GCBackgroundGang::stopAllForFork() {
    for (GCBackgroundGang* g : bgRegistry()) {
        if (g->running()) {
            g->stopAndJoin();
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
    stopAllForFork();
    // Hold every instance's mutex across fork so the child's copy is consistent.
    for (GCBackgroundGang* g : bgRegistry()) g->m_.lock();
}

void GCBackgroundGang::atforkParent() {
    for (GCBackgroundGang* g : bgRegistry()) g->m_.unlock();
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
        g->finished_ = 0;
        g->finished_pub_.store(0, std::memory_order_relaxed);
        g->running_.store(false, std::memory_order_relaxed);
        g->tids_.clear();
    }
    new (&bgRegistryMutex()) std::mutex();
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
