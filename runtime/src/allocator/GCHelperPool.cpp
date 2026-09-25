// threaded-gc-03: GC helper-thread pool. See GCHelperPool.hpp and
// plans/threaded-gc-03-helper-threads.md P§3.1-3.4.

#include "GCHelperPool.hpp"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
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

} // namespace Elm::gc
