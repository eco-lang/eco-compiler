//===- SysWorkPool.cpp - Worker pool for short blocking syscalls ----------===//
//
// Once constructed, the pool is never freed, and its workers are detached, so no destructor runs while a
// worker may still be using the pool. Two locks are used, never together: `jobsMutex_` for the job queue
// and `readyMutex_` for the result queue.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Core/AsyncSources.hpp"

#include <algorithm>
#include <cstdio>
#include <string>
#include <system_error>
#include <thread>
#include <type_traits>

namespace Eco::System {

namespace {

/// Returns whether the pool has a finished job; the ready predicate added with `poolDrain`.
bool poolReady() { return SysWorkPool::instance().hasReady(); }

static_assert(std::is_nothrow_move_constructible_v<PoolException> && sizeof(PoolException) <= 64,
              "PoolException must be held inline, so that exceptionResult's fallback cannot throw");

/// Returns the result a worker stores for a job whose `work` threw with message `what`. If copying the message
/// fails (`std::bad_alloc`), it holds a `PoolException` with an empty message instead, which allocates nothing:
/// the empty string does not, and the value is held inline. It never throws, so a worker's `catch` cannot.
PoolResult exceptionResult(const char* what) noexcept {
    try {
        return PoolResult::of(PoolException{what});
    } catch (...) {
        return PoolResult::of(PoolException{});
    }
}

#if ECO_TEST_HOOKS
// Armed by failNextSubmitForTest; the next submit clears it and throws.
std::atomic<bool> gFailNextSubmit{false};

// The default worker starter, what the constructor does without the hook.
void defaultStartWorker(std::function<void()> body) { std::thread(std::move(body)).detach(); }

// The worker starter the constructor uses; replaced by setWorkerStarterForTest.
std::atomic<SysWorkPool::StartWorkerFn> gStartWorker{&defaultStartWorker};
#endif

} // namespace

#if ECO_TEST_HOOKS
void SysWorkPool::failNextSubmitForTest() { gFailNextSubmit.store(true, std::memory_order_relaxed); }

SysWorkPool::StartWorkerFn SysWorkPool::setWorkerStarterForTest(StartWorkerFn fn) {
    return gStartWorker.exchange(fn ? fn : &defaultStartWorker);
}
#endif

SysWorkPool& SysWorkPool::instance() {
    static SysWorkPool* inst = new SysWorkPool();   // never freed
    return *inst;
}

SysWorkPool::SysWorkPool() {
    // Bound here, on the eco thread: a worker must never be the first to
    // call Scheduler::instance(), whose constructor touches the allocator.
    sched_ = &Scheduler::instance();
    unsigned hc = std::thread::hardware_concurrency();
    const size_t wanted = std::max<size_t>(1, std::min<size_t>(4, hc == 0 ? 1 : hc));
    // A worker that has started runs on `this` for ever, so once one has, the constructor must not throw: the
    // pool keeps the workers that started. With none started, nothing refers to `this` and the error is
    // rethrown; `instance()` then tries again on its next call.
    size_t started = 0;
    for (; started < wanted; ++started) {
        try {
#if ECO_TEST_HOOKS
            gStartWorker.load()([this] { workerLoop(); });
#else
            std::thread([this] { workerLoop(); }).detach();
#endif
        } catch (const std::system_error& e) {
            if (started == 0) throw;
            std::fprintf(stderr, "[eco-system] SysWorkPool: started %zu of %zu worker threads (%s)\n", started,
                         wanted, e.what());
            std::fflush(stderr);
            break;
        }
    }
    nThreads_ = started;
}

void SysWorkPool::submit(uint64_t token, std::function<PoolResult()> work,
                         CompleteFn complete, ErrShape shape) {
    submit(token, std::move(work), complete, shape, nullptr);
}

void SysWorkPool::submit(uint64_t token, std::function<PoolResult()> work,
                         CompleteFn complete, ErrShape shape, HandoffFn handoff) {
#if ECO_TEST_HOOKS
    if (gFailNextSubmit.exchange(false, std::memory_order_relaxed)) throw std::bad_alloc();
#endif
    static std::once_flag once;
    std::call_once(once, [] { addDrainSource(&poolDrain, &poolReady); });
    {
        std::lock_guard<std::mutex> lk(jobsMutex_);
        jobs_.push_back(Job{token, std::move(work), complete, shape, handoff});
    }
    jobsCV_.notify_one();
}

bool SysWorkPool::cancel(uint64_t token) {
    auto& p = instance();
    std::function<PoolResult()> dropped;   // destroyed outside the lock
    {
        std::lock_guard<std::mutex> lk(p.jobsMutex_);
        auto it = std::find_if(p.jobs_.begin(), p.jobs_.end(),
                               [token](const Job& j) { return j.token == token; });
        if (it == p.jobs_.end()) return false;   // running or finished
        dropped = std::move(it->work);
        p.jobs_.erase(it);
    }
    return true;
}

bool SysWorkPool::tryPop(Item& out) {
    std::lock_guard<std::mutex> lk(readyMutex_);
    if (ready_.empty()) return false;
    out = std::move(ready_.front());
    ready_.pop_front();
    readyCount_.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

void SysWorkPool::workerLoop() {
    while (true) {
        Job job;
        {
            std::unique_lock<std::mutex> lk(jobsMutex_);
            jobsCV_.wait(lk, [this] { return !jobs_.empty(); });
            job = std::move(jobs_.front());
            jobs_.pop_front();
        }
        Item item;
        item.token = job.token;
        item.complete = job.complete;
        item.shape = job.shape;
        item.handoff = job.handoff;
        try {
            item.result = job.work();
        } catch (const std::exception& e) {
            item.result = exceptionResult(e.what());
        } catch (...) {
            item.result = exceptionResult("unknown native exception in pool job");
        }
        job.work = nullptr;   // release captures on the worker
        try {
            std::lock_guard<std::mutex> lk(readyMutex_);
            ready_.push_back(std::move(item));
            readyCount_.fetch_add(1, std::memory_order_acq_rel);
        } catch (...) {
            // The deque's node allocation failed. Dropping the result would leave the task parked and its hold
            // held for ever, a silent hang, so the failure is fatal instead.
            ::Eco::Kernel::reportFatal("[eco-system] out of memory in SysWorkPool worker");
        }
        // Outside readyMutex_: the Scheduler evaluates hasReady() under its
        // own mutex, which notify takes too.
        sched_->notifyWorkAvailableFromAsync();
    }
}

void poolDrain() {
    auto& s = Scheduler::instance();
    auto& pool = SysWorkPool::instance();
    bool resumed = false;
    SysWorkPool::Item item;
    while (pool.tryPop(item)) {
        if (item.handoff) {
            bool taken = false;
            try {
                taken = item.handoff(item.token, item.result);
            } catch (const std::exception& e) {
                item.result = exceptionResult(e.what());
            } catch (...) {
                item.result = exceptionResult("unknown native exception in pool hand-off");
            }
            if (taken) {   // the resume and the hold now belong to the work the hand-off started
                item.result.reset();
                continue;
            }
        }
        // Released at the end of the iteration, after the resume has run, and on every path out of it.
        HoldRelease release(item.token);
        HPointer resume = s.takePendingResume(item.token);
        if (alloc::isNil(resume)) continue;         // killed: release only
        HPointer task = alloc::unit();
        Elm::StackRootGuard g(&resume, &task);
        if (item.result.holds<PoolException>()) {
            const std::string& what = item.result.as<PoolException>().what;
            // Empty: the worker could not copy the message (exceptionResult).
            task = detail::failureFor(item.shape, what.empty() ? "out of memory in kernel" : what.c_str());
        } else {
            try {
                task = item.complete(item.result);
            } catch (const std::exception& e) {
                task = detail::failureFor(item.shape, e.what());
            } catch (...) {
                task = detail::failureFor(item.shape, "unknown native exception in pool completion");
            }
        }
        Scheduler::callClosure1(resume, task);
        resumed = true;
        item.result.reset();
    }
    if (resumed) s.drain();
}

} // namespace Eco::System
