//===- WsEvents.cpp - WebSocket results to the main thread ----------------===//
//
// See WsEvents.hpp (plans/eco-system-websockets.md §3.6; the sockets plan
// §3.3.2 pattern of SocketEvents.cpp). Leaky singleton (base plan §3.4):
// never destroyed, so a late post from the reactor thread during std::exit
// never touches freed memory.
//
// Templates used: T8/G12 (drain), G10 (the dispatchers own every count).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsEvents.hpp"

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <atomic>
#include <deque>
#include <exception>
#include <mutex>
#include <vector>

namespace Eco::System {

namespace {

struct EventQueue {
    std::mutex m;
    std::deque<WsEvent> q;
    std::atomic<size_t> count{0};
    std::atomic<bool> workPending{false};
    Scheduler* sched;
    // Main thread only.
    WsEventDispatchFn dispatch[WsEvent::kKinds] = {};
    std::vector<WsWorkFn> work;

    EventQueue() : sched(&Scheduler::instance()) {}
};

// Constructed by ensureWsEvents() on the main thread before any reactor
// object posts, so the reactor thread never binds the Scheduler.
EventQueue& queue() {
    static auto* q = new EventQueue();   // leaky (§3.4)
    return *q;
}

bool wsEventsReady() {
    auto& q = queue();
    return q.count.load(std::memory_order_acquire) > 0 ||
           q.workPending.load(std::memory_order_acquire);
}

bool tryPop(WsEvent& out) {
    auto& q = queue();
    std::lock_guard<std::mutex> lk(q.m);
    if (q.q.empty()) return false;
    out = std::move(q.q.front());
    q.q.pop_front();
    q.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

// An event nobody takes: an orphaned connection is aborted.
void releaseOrphan(WsEvent& ev) {
    if (ev.conn) {
        std::shared_ptr<Conn> c = std::move(ev.conn);
        IoReactor::instance().submit([c] { c->abort(false); });
    }
}

} // namespace

void ensureWsEvents() {
    (void)queue();
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    ensureSocketEvents();       // the reactor, the embed stop hook (sockets plan §3.3.9)
    addDrainSource(&wsEventsDrain, &wsEventsReady);
}

void postWsEvent(WsEvent ev) {
    auto& q = queue();
    {
        std::lock_guard<std::mutex> lk(q.m);
        q.q.push_back(std::move(ev));
        q.count.fetch_add(1, std::memory_order_acq_rel);
    }
    // Outside q.m (lock order, sockets plan §3.3.1 rule 6).
    q.sched->notifyWorkAvailableFromAsync();
}

void setWsEventDispatch(WsEvent::Kind kind, WsEventDispatchFn fn) {
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
            for (WsWorkFn fn : todo) fn();   // they drain() themselves
        }
        WsEvent ev;
        while (tryPop(ev)) {
            if (ev.gen != currentHeapGeneration()) {
                releaseOrphan(ev);   // a dead heap's event: no resume, no count
                continue;
            }
            WsEventDispatchFn fn = q.dispatch[static_cast<int>(ev.kind)];
            if (!fn) {
                releaseOrphan(ev);
                continue;
            }
            if (fn(ev)) Scheduler::instance().drain();   // G12
        }
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in the WebSocket event drain");
    }
}

} // namespace Eco::System
