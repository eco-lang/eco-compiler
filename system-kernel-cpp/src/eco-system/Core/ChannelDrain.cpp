//===- ChannelDrain.cpp - Channel-results queue and its eco-thread drain --===//
//
// The queue is a deque guarded by a mutex, with an atomic copy of its length beside it. The count is changed
// only while the mutex is held, so it never disagrees with the deque once the lock is released, and the ready
// predicate can read it without taking the lock. A post wakes the scheduler, which takes the scheduler's mutex,
// only after releasing the queue mutex, so a post never holds both.
//
// The queue is created on first use and never destroyed, so a channel thread that posts while the process
// exits still finds it.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"

#include <atomic>
#include <cerrno>
#include <deque>
#include <mutex>

namespace Eco::System {

namespace {

/// The process-wide channel-results queue, with the scheduler it wakes and the callback its drain calls.
struct ChannelResults {
    std::mutex m;                  ///< Guards `q`, and is held whenever `count` changes.
    std::deque<ChannelResult> q;
    std::atomic<size_t> count{0};  ///< The length of `q`, readable without `m`.
    /// The scheduler a post wakes. Never null; the scheduler is never destroyed.
    Scheduler* sched;
    ChannelDispatchFn dispatch = nullptr;   ///< Read and written on the eco thread only; no lock.

    /// Creates an empty queue with no callback, bound to `Scheduler::instance()`.
    ChannelResults() : sched(&Scheduler::instance()) {}
};

/// Returns the queue, creating it on the first call. It is never destroyed.
///
/// The first call is made by the `ByteChannel` constructor on the eco thread, and no channel thread can post
/// before a channel exists, so `Scheduler::instance()` is first asked for from the eco thread.
ChannelResults& results() {
    static auto* r = new ChannelResults();
    return *r;
}

/// Returns whether the queue holds a result; the ready predicate registered alongside `channelDrain`.
bool channelReady() { return channelResultsReady(); }

/// The id the next `ByteChannel` constructed is given. Ids start at 1 and are never reused.
std::atomic<uint64_t> g_nextChannelId{1};

} // namespace

ByteChannel::ByteChannel() : id_(g_nextChannelId.fetch_add(1)) {
    (void)results();
    static std::once_flag once;
    std::call_once(once, [] { addDrainSource(&channelDrain, &channelReady); });
}

void ByteChannel::requestWriteTagged(uint64_t token, int64_t tag, bool, std::string bytes) {
    if (tag == 0) {
        requestWrite(token, std::move(bytes));
        return;
    }
    ChannelResult r;
    r.channelId = id();
    r.token = token;
    r.op = ChannelResult::Op::Write;
    r.err = ENOTSUP;
    postChannelResult(std::move(r));
}

std::string ByteChannel::encodeFailure(int err, const std::string& reason) const {
    if (isMarkedReason(reason)) return reason;
    if (reason.empty()) return errnoFailureReason(failureOrigin(), err != 0 ? err : EIO);
    return failureReason(failureOrigin(), err != 0 ? errnoName(err) : "", reason);
}

void postChannelResult(ChannelResult r) {
    auto& cr = results();
    {
        std::lock_guard<std::mutex> lk(cr.m);
        cr.q.push_back(std::move(r));
        cr.count.fetch_add(1, std::memory_order_acq_rel);
    }
    // Outside cr.m: the Scheduler evaluates channelResultsReady() under its
    // own mutex, which notify takes too.
    cr.sched->notifyWorkAvailableFromAsync();
}

bool tryPopChannelResult(ChannelResult& out) {
    auto& cr = results();
    std::lock_guard<std::mutex> lk(cr.m);
    if (cr.q.empty()) return false;
    out = std::move(cr.q.front());
    cr.q.pop_front();
    cr.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

bool channelResultsReady() {
    return results().count.load(std::memory_order_acquire) > 0;
}

void setChannelDispatch(ChannelDispatchFn fn) {
    results().dispatch = fn;
}

void channelDrain() {
    auto& cr = results();
    bool dispatched = false;
    ChannelResult r;
    while (tryPopChannelResult(r)) {
        ChannelDispatchFn fn = cr.dispatch;   // re-read: a callback may change it
        if (!fn) continue;                    // no callback: the result is dropped and its token never completed
        try {
            fn(r);
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());   // never unwind into the scheduler loop
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in channel dispatch");
        }
        dispatched = true;
    }
    if (dispatched) Scheduler::instance().drain();
}

} // namespace Eco::System
