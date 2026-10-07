//===- SignalService.hpp - Process signals as POD events ------------------===//
//
// plans/eco-system-library.md §3.4: SIGINT, SIGTERM and SIGWINCH (any
// catchable signal, in fact; tests use SIGUSR1) reach Elm through a
// self-pipe:
//   * the sigaction handler (SA_RESTART) only writes the signal number, one
//     byte, to the non-blocking write end of an O_CLOEXEC pipe;
//   * one detached thread reads the pipe and queues `signo` events, then
//     wakes the scheduler loop;
//   * the main-thread signal drain hands each event to the callback
//     registered with setDispatch (the System / Terminal managers), which
//     delivers it with sendToApp + drain() per message (G12).
//
// Handlers are installed only while some subscription to that signal
// exists: subscribe/unsubscribe keep a reference count per signal, the
// first subscribe installs the handler (remembering the previous
// disposition) and the last unsubscribe restores it. There is no chaining
// to the previous handler: like Node, a listened-to signal no longer has
// its default effect.
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
#include <deque>
#include <mutex>

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

    // Main thread. The callback the drain hands each signal to.
    using DispatchFn = void (*)(int signo);
    void setDispatch(DispatchFn fn) { dispatch_ = fn; }
    DispatchFn dispatch() const { return dispatch_; }

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
    DispatchFn dispatch_ = nullptr;
};

// The signal drain (main thread). Runs from the eco/system async source;
// tests may call it directly. Does not call Scheduler::drain(): the
// dispatch callback follows G12 for each message it sends.
void signalDrain();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_SIGNAL_SERVICE_HPP
