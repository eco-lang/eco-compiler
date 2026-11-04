//===- WsEvents.cpp - WebSocket results to the eco thread -----------------===//
//
// The queue is a leaky singleton: once `queue()` has returned it, it is never destroyed, so a late post from the
// reactor thread during `std::exit` never touches freed memory.
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsEvents.hpp"

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <atomic>
#include <cassert>
#include <deque>
#include <exception>
#include <mutex>
#include <vector>

namespace Eco::System {

namespace {

/// The queue of posted events, with the dispatch table and the requested work.
struct EventQueue {
    std::mutex m;
    std::deque<WsEvent> q;                   ///< Guarded by `m`.
    std::atomic<size_t> count{0};            ///< The length of `q`, readable without `m` by the ready predicate.
    std::atomic<bool> workPending{false};    ///< True once work is requested and until the drain takes it.
    Scheduler* sched;                        ///< The process-wide scheduler, which is never destroyed.
    // Eco thread only, unguarded.
    WsEventDispatchFn dispatch[WsEvent::kKinds] = {};
    std::vector<WsWorkFn> work;

    /// Creates an empty queue with no dispatch functions.
    EventQueue() : sched(&Scheduler::instance()) {}
};

/// Returns the queue, creating it on first use.
EventQueue& queue() {
    static auto* q = new EventQueue();   // leaked: see the file comment
    return *q;
}

/// Returns whether an event is queued or work is requested. The drain's ready predicate: it takes no lock.
bool wsEventsReady() {
    auto& q = queue();
    return q.count.load(std::memory_order_acquire) > 0 ||
           q.workPending.load(std::memory_order_acquire);
}

/// Moves the oldest queued event into `out` and returns true, or returns false if the queue is empty.
bool tryPop(WsEvent& out) {
    auto& q = queue();
    std::lock_guard<std::mutex> lk(q.m);
    if (q.q.empty()) return false;
    out = std::move(q.q.front());
    q.q.pop_front();
    q.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

/// Releases an orphan event: aborts its connection, if it carries one, on the reactor.
void releaseOrphan(WsEvent& ev) {
    if (ev.conn) {
        std::shared_ptr<Conn> c = std::move(ev.conn);
        IoReactor::instance().submit([c] { c->abort(false); });
    }
}

} // namespace

void ensureWsEvents() {
    (void)queue();
    static bool done = false;   // eco thread only
    if (done) return;
    done = true;
    ensureSocketEvents();
    addDrainSource(&wsEventsDrain, &wsEventsReady);
}

void postWsEvent(WsEvent ev) {
    auto& q = queue();
    {
        std::lock_guard<std::mutex> lk(q.m);
        q.q.push_back(std::move(ev));
        q.count.fetch_add(1, std::memory_order_acq_rel);
    }
    // Outside q.m, so that no other lock is taken under it.
    q.sched->notifyWorkAvailableFromAsync();
}

void setWsEventDispatch(WsEvent::Kind kind, WsEventDispatchFn fn) {
    assert(static_cast<int>(kind) < WsEvent::kKinds && "not a dispatchable kind");
    queue().dispatch[static_cast<int>(kind)] = fn;
}

void requestWsWork(WsWorkFn fn) {
    auto& q = queue();
    bool known = false;
    for (WsWorkFn f : q.work) known = known || f == fn;
    if (!known) q.work.push_back(fn);
    q.workPending.store(true, std::memory_order_release);
    q.sched->notifyWorkAvailableFromAsync();
}

void wsEventsDrain() {
    auto& q = queue();
    try {
        if (q.workPending.exchange(false, std::memory_order_acq_rel)) {
            std::vector<WsWorkFn> todo;
            todo.swap(q.work);
            for (WsWorkFn fn : todo) fn();
        }
        WsEvent ev;
        while (tryPop(ev)) {
            if (ev.gen != currentHeapGeneration()) {
                releaseOrphan(ev);
                continue;
            }
            WsEventDispatchFn fn = q.dispatch[static_cast<int>(ev.kind)];
            if (!fn) {
                releaseOrphan(ev);
                continue;
            }
            if (fn(ev)) Scheduler::instance().drain();
        }
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in the WebSocket event drain");
    }
}

} // namespace Eco::System
