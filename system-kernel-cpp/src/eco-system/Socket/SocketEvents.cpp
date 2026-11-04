//===- SocketEvents.cpp - Socket results to the eco thread ----------------===//
//
// The queue is a singleton that is never destroyed, so a post from the reactor thread during process exit does not
// touch freed memory. The event deque is guarded by its mutex; `count` and `workPending` are atomics so the ready
// predicate needs no lock. The dispatch table and the work list are touched on the eco thread only and are not
// locked.
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
// The queue's state. `sched` caches `Scheduler::instance()`, the process-wide scheduler, so a post need not look it up.
// The queue's state. `sched` is bound once, on the thread that first calls `queue()`.
struct EventQueue {
    std::mutex m;
    std::deque<SocketEvent> q;
    std::atomic<size_t> count{0};          // the size of `q`, readable without `m`
    std::atomic<bool> workPending{false};  // set by requestSocketWork, cleared by the drain
    Scheduler* sched;
    // Eco thread only.
    SocketEventDispatchFn dispatch[SocketEvent::kKinds] = {};
    std::vector<SocketWorkFn> work;

    EventQueue() : sched(&Scheduler::instance()) {}
};

// Returns the queue, creating it on the first call. ensureSocketEvents() makes that first call on the eco thread,
// before any reactor object exists.
EventQueue& queue() {
    static auto* q = new EventQueue();   // never deleted
    return *q;
}

// The drain's ready predicate: true if an event is queued or socket work is requested. Takes no lock.
bool socketEventsReady() {
    auto& q = queue();
    return q.count.load(std::memory_order_acquire) > 0 ||
           q.workPending.load(std::memory_order_acquire);
}

// Moves the oldest queued event into `out` and returns true, or returns false if the queue is empty.
bool tryPop(SocketEvent& out) {
    auto& q = queue();
    std::lock_guard<std::mutex> lk(q.m);
    if (q.q.empty()) return false;
    out = std::move(q.q.front());
    q.q.pop_front();
    q.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

// The scheduler stop hook: closes every reactor handler, so the program's listeners and connections do not stay
// open after the scheduler loop stops.
void socketStopHook() { IoReactor::instance().closeAll(); }

// Releases the OS resources of an orphan: its connection, if any, is aborted on the reactor thread.
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
    static bool done = false;   // eco thread only
    if (done) return;
    done = true;
    addDrainSource(&socketEventsDrain, &socketEventsReady);
    Scheduler::instance().addStopHook(&socketStopHook);
    (void)IoReactor::instance();   // start the reactor from the eco thread
}

void postSocketEvent(SocketEvent ev) {
    auto& q = queue();
    {
        std::lock_guard<std::mutex> lk(q.m);
        q.q.push_back(std::move(ev));
        q.count.fetch_add(1, std::memory_order_acq_rel);
    }
    // Outside q.m, so q.m is never held while the Scheduler's mutex is taken.
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
            if (fn(ev)) Scheduler::instance().drain();
        }
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());   // never unwind into the scheduler loop
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in the socket event drain");
    }
}

} // namespace Eco::System
