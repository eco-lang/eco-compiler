//===- SocketEvents.cpp - Socket results to the main thread ---------------===//
//
// See SocketEvents.hpp (plans/eco-system-sockets.md §3.3.2, §3.3.9). Leaky
// singleton (base plan §3.4): never destroyed, so a late post from the
// reactor thread during std::exit never touches freed memory.
//
// Templates used: T8/G12 (drain), G10 (the dispatchers own every count).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/SocketEvents.hpp"

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
    std::deque<SocketEvent> q;
    std::atomic<size_t> count{0};
    std::atomic<bool> workPending{false};
    Scheduler* sched;
    // Main thread only.
    SocketEventDispatchFn dispatch[SocketEvent::kKinds] = {};
    std::vector<SocketWorkFn> work;

    EventQueue() : sched(&Scheduler::instance()) {}
};

// Constructed by ensureSocketEvents() on the main thread before any reactor
// object exists, so the reactor thread never binds the Scheduler.
EventQueue& queue() {
    static auto* q = new EventQueue();   // leaky (§3.4)
    return *q;
}

bool socketEventsReady() {
    auto& q = queue();
    return q.count.load(std::memory_order_acquire) > 0 ||
           q.workPending.load(std::memory_order_acquire);
}

bool tryPop(SocketEvent& out) {
    auto& q = queue();
    std::lock_guard<std::mutex> lk(q.m);
    if (q.q.empty()) return false;
    out = std::move(q.q.front());
    q.q.pop_front();
    q.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

// §3.3.9: embed stop (eco_app_stop) closes every reactor handler so the
// program's listeners and connections do not stay open in the host process.
void socketStopHook() { IoReactor::instance().closeAll(); }

// Releases the OS resources of an event that reached nobody (a dead heap,
// or no dispatcher): an orphaned connection is aborted.
void releaseOrphan(SocketEvent& ev) {
    if (ev.conn) {
        std::shared_ptr<Conn> c = std::move(ev.conn);
        IoReactor::instance().submit([c] { c->abort(false); });
    }
}

} // namespace

uint64_t currentHeapGeneration() { return Allocator::instance().heapGeneration(); }

void ensureSocketEvents() {
    (void)queue();
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    addDrainSource(&socketEventsDrain, &socketEventsReady);
    Scheduler::instance().addStopHook(&socketStopHook);
    (void)IoReactor::instance();   // start the reactor from the main thread
}

void postSocketEvent(SocketEvent ev) {
    auto& q = queue();
    {
        std::lock_guard<std::mutex> lk(q.m);
        q.q.push_back(std::move(ev));
        q.count.fetch_add(1, std::memory_order_acq_rel);
    }
    // Outside q.m: the Scheduler evaluates the ready predicate under its own
    // mutex, which notify takes too (lock order, §3.3.1 rule 6).
    q.sched->notifyWorkAvailableFromAsync();
}

void setSocketEventDispatch(SocketEvent::Kind kind, SocketEventDispatchFn fn) {
    queue().dispatch[static_cast<int>(kind)] = fn;
}

void requestSocketWork(SocketWorkFn fn) {
    auto& q = queue();
    for (SocketWorkFn f : q.work) {
        if (f == fn) {
            q.workPending.store(true, std::memory_order_release);
            return;
        }
    }
    q.work.push_back(fn);
    q.workPending.store(true, std::memory_order_release);
}

void socketEventsDrain() {
    auto& q = queue();
    try {
        if (q.workPending.exchange(false, std::memory_order_acq_rel)) {
            std::vector<SocketWorkFn> todo;
            todo.swap(q.work);
            for (SocketWorkFn fn : todo) fn();   // they drain() themselves
        }
        SocketEvent ev;
        while (tryPop(ev)) {
            if (ev.gen != currentHeapGeneration()) {
                releaseOrphan(ev);   // a dead heap's event: no resume, no count
                continue;
            }
            SocketEventDispatchFn fn = q.dispatch[static_cast<int>(ev.kind)];
            if (!fn) {
                releaseOrphan(ev);
                continue;
            }
            if (fn(ev)) Scheduler::instance().drain();   // G12
        }
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in the socket event drain");
    }
}

} // namespace Eco::System
