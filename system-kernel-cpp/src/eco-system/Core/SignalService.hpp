//===- SignalService.hpp - Process signals as POD events ------------------===//
//
// A process signal can arrive at any moment, on any thread, while the code that wants to react to it runs only on
// the eco thread (the one thread that runs the Elm scheduler). This component carries each signal from the one to
// the other: SIGINT, SIGTERM, SIGWINCH, or any other catchable signal.
//
// Two terms are kept apart. A *subscription* to a signal means this component's handler is installed for it.
// Subscriptions are reference counted per signal: the first `subscribe` installs the handler and saves the
// disposition it replaces, and the last `unsubscribe` puts that disposition back. A *listener* is a callback for one
// signal; `addListener` takes one subscription for it and `removeListener` gives it back. While a signal is
// subscribed it loses its previous effect, so a subscribed SIGINT does not end the process. A listener that wants
// the previous effect asks for it with `chainToPrevious`.
//
// The signal travels through a self-pipe, a pipe the process writes to itself:
//   * the handler, installed with `SA_RESTART`, writes the signal number as one byte to the non-blocking write end
//     of a close-on-exec pipe, and does nothing else. A byte that finds the pipe full is dropped;
//   * a detached reader thread waits for the pipe to become readable, moves its bytes into a queue of signal
//     numbers, and wakes the scheduler loop;
//   * the scheduler's readiness check, `pollReady`, also empties the pipe into the queue itself, and on Linux also
//     takes subscribed signals that are pending but whose handler has not run yet. The loop does not go quiescent
//     while an async source is ready, so a signal already received when the loop checks is queued then, not left
//     to a reader thread that has not yet been scheduled;
//   * the signal drain, `signalDrain`, pops each queued signal on the eco thread and calls every listener of it.
//
// Nothing here takes a scheduler hold, so a subscription does not keep the program running.
//
// In embed mode (`Scheduler::embedMode()`) and on Windows, `subscribe` does nothing and returns false, so no
// handler is ever installed and the host's dispositions are left alone.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_SIGNAL_SERVICE_HPP
#define ECO_SYSTEM_CORE_SIGNAL_SERVICE_HPP

#include "eco-system/Core/Core.hpp"

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <vector>

namespace Eco::System {

/// The process's signal subscriptions, the queue of signals received, and the listeners they are delivered to.
///
/// There is one, obtained with `instance`, created on first use and never destroyed. It can be neither copied nor
/// constructed elsewhere. Subscriptions, listeners and dispatch must be used on the eco thread only: nothing
/// guards that state. `takeFromPipe`, `hasReady` and `tryPop` may be called from any thread.
class SignalService {
public:
    /// Returns the single service, creating it on the first call. The first call must be made on the eco thread,
    /// because the service binds `Scheduler::instance()` there.
    static SignalService& instance();

    /// Takes one subscription to `signo`, installing the handler if it is the first, and returns whether the
    /// subscription is held. Returns false, changing nothing, in embed mode, on Windows, for SIGKILL, SIGSTOP, a
    /// number outside 1..127 or not below `NSIG`, or when the pipe or reader thread cannot be set up.
    /// Also returns false when `sigaction` fails; a pipe and reader thread that were set up then stay set up.
    bool subscribe(int signo);
    /// Gives back one subscription to `signo`, and when none are left restores the disposition the first
    /// subscription replaced. Does nothing for a signal with no subscriptions.
    void unsubscribe(int signo);
    /// Returns how many subscriptions `signo` has, or 0 for a number outside 1..127.
    int subscribers(int signo) const;

    /// Removes the oldest queued signal into `signo` and returns true, or returns false, leaving `signo` alone,
    /// when the queue is empty. Does not wait for a signal.
    bool tryPop(int& signo);
    /// Returns whether any signal is queued.
    bool hasReady() const { return readyCount_.load(std::memory_order_acquire) > 0; }
    /// Returns whether any signal is queued. This is the ready predicate of the signal drain source.
    ///
    /// When the queue is empty and the service has started, it first queues every signal already received:
    /// written to the pipe by the handler but not yet taken by the reader thread or, on Linux, a subscribed signal
    /// pending with its handler not yet run. That step takes this service's two locks, which the reader thread
    /// also takes. It does not wait for a signal, and it never notifies the scheduler, because the scheduler calls
    /// it with its own lock held. Must be called on the eco thread.
    bool pollReady();

    // Listeners

    /// A callback for one signal, called on the eco thread by the signal drain with the signal number and the
    /// `ctx` it was added with. A *delivery* is one call of `dispatch` for the signal, which the drain makes once
    /// per queued signal number; signals that arrive together may be queued once, and a byte dropped on a full
    /// pipe is never queued.
    ///
    /// Listeners of one signal are called in the order they were added. A listener may add or remove listeners,
    /// itself included. One removed before its turn in a delivery is not called, and one added during a delivery
    /// is first called at the next one. What an exception that escapes a listener does is stated at `dispatch`
    /// and `signalDrain`.
    using Listener = void (*)(int signo, void* ctx);
    /// The identifier `addListener` gives a listener: an alias of `uint64_t`, not a distinct type. Identifiers
    /// count up from 1, and 0 means none.
    using ListenerId = uint64_t;

    /// Takes one subscription to `signo` and adds `fn` as a listener of it, returning the new identifier. Returns
    /// 0, adding nothing, when `fn` is null or `subscribe` fails. If making room for the listener throws
    /// (`std::bad_alloc`), it throws before subscribing, so nothing is left subscribed.
    ///
    /// `ctx` is kept and passed to `fn`; whatever it points to must outlive the listener.
    ListenerId addListener(int signo, Listener fn, void* ctx);
    /// Removes listener `id` and gives back its subscription. Does nothing for an unknown id, 0 included.
    void removeListener(ListenerId id);
    /// Returns how many listeners `signo` has.
    int listenerCount(int signo) const;

    /// Calls every listener of `signo`, as one delivery, in the order and with the add/remove rules `Listener`
    /// states. Exceptions thrown by a listener propagate from here; only `signalDrain` turns them into a fatal
    /// error.
    void dispatch(int signo);

    /// Gives `signo` the effect it would have had without this service's handler.
    ///
    /// What it does depends on the disposition saved by the first subscription. A previous handler is called
    /// directly on the calling thread, with `signo` (unless `SA_NODEFER`) and the handler's own `sa_mask` blocked
    /// around the call, while this service's handler stays installed, so an instance of the signal that arrives
    /// meanwhile is still queued for the listeners. A `SA_SIGINFO` handler gets a `siginfo_t` made up for a
    /// signal the process sent itself (`SI_USER`, this pid and uid) and a null context, so a handler that reads
    /// the context must not be chained. A saved `SA_RESETHAND` makes the saved disposition the default one
    /// afterwards. An ignoring disposition does nothing, and so does the default one of a signal ignored by
    /// default (SIGCHLD, SIGCONT, SIGURG, SIGWINCH). For any other default disposition the saved one is
    /// reinstated, the signal is raised on the calling thread, and this service's handler is put back if the
    /// process survives; for SIGINT or SIGTERM the process ends, and an instance arriving in that window gets the
    /// default action too. Does nothing for a signal with no subscriptions, when the saved disposition cannot be
    /// reinstated, or on Windows. Must be called on the eco thread, outside a signal handler.
    void chainToPrevious(int signo);

    /// Moves everything now in the pipe into the queue, and returns whether anything was moved. Never notifies the
    /// scheduler, and returns false on Windows or before the pipe exists.
    ///
    /// The reader thread and `pollReady` both call it. It holds a lock from each read until the bytes read are
    /// queued, so the other caller never sees an empty pipe while a byte read from it is not yet in the queue.
    bool takeFromPipe();

private:
    /// Creates the service and binds `Scheduler::instance()`, the one process-wide scheduler. Creating the scheduler
    /// registers its root scanner with the calling thread's heap, which is why `instance` must first be called on
    /// the eco thread.
    SignalService();
    ~SignalService() = default;

    /// Creates the pipe, starts the reader thread and adds the signal drain source, the first time it succeeds,
    /// and returns whether all of that is in place. On failure nothing is left behind. Eco thread only.
    bool ensureStarted();
    /// Appends `signo` to the queue. Takes `readyMutex_`; never notifies.
    void queue(int signo);
    /// Queues every subscribed signal that is pending with its handler not yet run, dequeuing it so the handler
    /// will not also see it. Linux only; does nothing elsewhere. Eco thread only.
    void takePending();

    /// One more than the highest signal number this service accepts; it is also the size of the per-signal tables.
    static constexpr int kMaxSig = 128;

    Scheduler* sched_ = nullptr;   ///< The scheduler bound by the constructor; the reader thread wakes it.
    bool started_ = false;
    int counts_[kMaxSig] = {};
    /// For each signal, a heap `struct sigaction` holding the disposition its first subscription replaced, or
    /// null if never subscribed. Allocated once per signal and never freed.
    void* saved_[kMaxSig] = {};

    int readFd_ = -1;            ///< Non-blocking read end of the pipe; set before the reader thread starts.
    std::mutex pipeMutex_;       ///< Held by `takeFromPipe` from its first read until its bytes are queued.
    std::mutex readyMutex_;      ///< Guards `ready_`. Lock order: `pipeMutex_`, then `readyMutex_`.
    std::deque<int> ready_;      ///< Queued signal numbers, oldest first. Guarded by `readyMutex_`.
    std::atomic<size_t> readyCount_{0};   ///< The length of `ready_`, readable without the lock.

    /// One listener as `addListener` recorded it.
    struct ListenerRec {
        ListenerId id;
        int signo;
        Listener fn;
        void* ctx;   ///< Passed to `fn`; not owned.
    };
    std::vector<ListenerRec> listeners_;   ///< Every listener added and not yet removed. Eco thread only.
    ListenerId nextListenerId_ = 1;
};

/// Pops every queued signal and calls its listeners, as `SignalService::dispatch` does. This is the drain of the
/// signal drain source, and must be called on the eco thread.
///
/// An exception escaping a listener ends the process through `Eco::Kernel::reportFatal`. It does not call
/// `Scheduler::drain()`.
void signalDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_SIGNAL_SERVICE_HPP
