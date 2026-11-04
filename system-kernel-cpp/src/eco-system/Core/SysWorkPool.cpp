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
#include <thread>

namespace Eco::System {

namespace {

/// Returns whether the pool has a finished job; the ready predicate added with `poolDrain`.
bool poolReady() { return SysWorkPool::instance().hasReady(); }

} // namespace

SysWorkPool& SysWorkPool::instance() {
    static SysWorkPool* inst = new SysWorkPool();   // never freed
    return *inst;
}

SysWorkPool::SysWorkPool() {
    // Bound here, on the eco thread: a worker must never be the first to
    // call Scheduler::instance(), whose constructor touches the allocator.
    sched_ = &Scheduler::instance();
    unsigned hc = std::thread::hardware_concurrency();
    nThreads_ = std::max<size_t>(1, std::min<size_t>(4, hc == 0 ? 1 : hc));
    for (size_t i = 0; i < nThreads_; ++i) {
        std::thread([this] { workerLoop(); }).detach();
    }
}

void SysWorkPool::submit(uint64_t token, std::function<PoolResult()> work,
                         CompleteFn complete, ErrShape shape) {
    static std::once_flag once;
    std::call_once(once, [] { addDrainSource(&poolDrain, &poolReady); });
    {
        std::lock_guard<std::mutex> lk(jobsMutex_);
        jobs_.push_back(Job{token, std::move(work), complete, shape});
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
        try {
            item.result = job.work();
        } catch (const std::exception& e) {
            item.result = PoolResult::of(PoolException{e.what()});
        } catch (...) {
            item.result = PoolResult::of(PoolException{"unknown native exception in pool job"});
        }
        job.work = nullptr;   // release captures on the worker
        {
            std::lock_guard<std::mutex> lk(readyMutex_);
            ready_.push_back(std::move(item));
            readyCount_.fetch_add(1, std::memory_order_acq_rel);
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
        // Released at the end of the iteration, after the resume has run, and on every path out of it.
        HoldRelease release(item.token);
        HPointer resume = s.takePendingResume(item.token);
        if (alloc::isNil(resume)) continue;         // killed: release only
        HPointer task = alloc::unit();
        Elm::StackRootGuard g(&resume, &task);
        if (item.result.holds<PoolException>()) {
            task = detail::failureFor(item.shape,
                                      item.result.as<PoolException>().what.c_str());
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
