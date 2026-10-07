//===- SignalService.hpp - Process signals as POD events ------------------===//
//
// plans/eco-system-library.md §3.4: SIGINT, SIGTERM and SIGWINCH (any
// catchable signal, in fact; tests use SIGUSR1) reach Elm through a
// self-pipe:
//   * the sigaction handler (SA_RESTART) only writes the signal number, one
//     byte, to the non-blocking write end of an O_CLOEXEC pipe;
//   * one detached thread reads the pipe and queues `signo` events, then
//     wakes the scheduler loop;
//   * the main-thread signal drain hands each event to every LISTENER of
//     that signal (per-signal, multi-subscriber dispatch, Phase 5): the
//     System manager (SIGINT, SIGTERM), the Terminal manager (SIGWINCH) and
//     the Terminal kernel's internal raw-mode restore (SIGINT, SIGTERM).
//     A listener that sends to the app does sendToApp + drain() per message
//     (G12).
//
// Handlers are installed only while some subscription to that signal
// exists: subscribe/unsubscribe keep a reference count per signal, the
// first subscribe installs the handler (remembering the previous
// disposition) and the last unsubscribe restores it. addListener /
// removeListener subscribe / unsubscribe once per listener. There is no
// automatic chaining to the previous handler: like Node, a listened-to
// signal no longer has its default effect. A listener may chain explicitly
// with chainToPrevious (the raw-mode restore does, when it is the only
// listener).
//
// Disabled in embed mode (Scheduler::embedMode(), §3.7): subscribe is a
// no-op that returns false, so the host keeps its signal dispositions.
// Signal subscriptions do not hold pendingAsync (keep-alive rule, §3.4).
//
// Windows: subscribe is a no-op that returns false (§1).
//
// Templates used: none (POD only, G1).
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

class SignalService {
public:
    static SignalService& instance();

    // Main thread. Returns true if the subscription is active (the handler
    // is installed). False, with no effect, in embed mode, on Windows, for
    // an uncatchable or out-of-range signal, or if setup failed.
    bool subscribe(int signo);
    // Main thread. Undoes one successful subscribe; restores the previous
    // handler when the count reaches zero. Unmatched calls are ignored.
    void unsubscribe(int signo);
    // Main thread. Current reference count for `signo`.
    int subscribers(int signo) const;

    // Main thread (the drain, or a test). Non-blocking.
    bool tryPop(int& signo);
    bool hasReady() const { return readyCount_.load(std::memory_order_acquire) > 0; }

    // --- Listeners (main thread) -------------------------------------------
    //
    // A listener is called by the signal drain, on the main thread, for every
    // delivered `signo` it listens to; several listeners of one signal are
    // called in registration order. A listener may add or remove listeners
    // (including itself); one removed before its turn is not called.
    using Listener = void (*)(int signo, void* ctx);
    using ListenerId = uint64_t;

    // Subscribes `signo` once and records the listener. Returns its id, or 0
    // (nothing recorded) when subscribe() fails: embed mode, Windows, an
    // uncatchable or out-of-range signal, or setup failure.
    ListenerId addListener(int signo, Listener fn, void* ctx);
    // Removes the listener and unsubscribes its signal once. Unknown ids
    // (including 0) are ignored.
    void removeListener(ListenerId id);
    // Number of listeners currently registered for `signo`.
    int listenerCount(int signo) const;

    // Calls every listener of `signo` (what the drain does per event).
    void dispatch(int signo);

    // Gives `signo` the effect it would have had without our handler: the
    // previous disposition (saved by the first subscribe) is reinstated, the
    // signal is raised on this thread, and our handler is put back if the
    // process survives (SIG_IGN, or a previous handler that returns). For
    // SIGINT / SIGTERM with the default disposition this terminates the
    // process. A no-op when `signo` is not subscribed (or on Windows).
    void chainToPrevious(int signo);

    // Signal-reader thread only.
    void post(int signo);

private:
    SignalService();
    ~SignalService() = default;

    bool ensureStarted();   // main thread: pipe + reader thread

    static constexpr int kMaxSig = 128;

    Scheduler* sched_ = nullptr;
    bool started_ = false;
    int counts_[kMaxSig] = {};
    void* saved_[kMaxSig] = {};   // struct sigaction* of the previous disposition

    std::mutex readyMutex_;
    std::deque<int> ready_;
    std::atomic<size_t> readyCount_{0};

    struct ListenerRec {
        ListenerId id;
        int signo;
        Listener fn;
        void* ctx;
    };
    std::vector<ListenerRec> listeners_;   // main thread only
    ListenerId nextListenerId_ = 1;
};

// The signal drain (main thread). Runs from the eco/system async source;
// tests may call it directly. Pops every queued signal and dispatches it to
// its listeners. Does not call Scheduler::drain(): each listener follows G12
// for each message it sends.
void signalDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_SIGNAL_SERVICE_HPP
