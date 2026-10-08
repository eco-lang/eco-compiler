//===- ChannelDrain.cpp - Channel-results queue and its main-thread drain -===//
//
// See ByteChannel.hpp. One process-wide queue of POD ChannelResults, filled
// by channel threads and drained on the main thread, which hands each result
// to the registered dispatch callback (the StreamTable) and then calls
// Scheduler::drain() once (T9). Leaky singleton (§3.4).
//
// Templates used: T9 (drain side).
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

struct ChannelResults {
    std::mutex m;
    std::deque<ChannelResult> q;
    std::atomic<size_t> count{0};
    Scheduler* sched;
    ChannelDispatchFn dispatch = nullptr;   // main thread only

    ChannelResults() : sched(&Scheduler::instance()) {}
};

// First touched on the main thread (ByteChannel's constructor), so the
// Scheduler is bound there, never on a channel thread.
ChannelResults& results() {
    static auto* r = new ChannelResults();   // leaky (§3.4)
    return *r;
}

bool channelReady() { return channelResultsReady(); }

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
        if (!fn) continue;                    // nobody to resume: drop
        try {
            fn(r);
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in channel dispatch");
        }
        dispatched = true;
    }
    if (dispatched) Scheduler::instance().drain();
}

} // namespace Eco::System
