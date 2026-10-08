//===- IoReactor.hpp - The shared non-blocking IO event loop --------------===//
//
// plans/eco-system-sockets.md §3.3.1 (SD11). One leaky singleton (base plan
// §3.4) with one detached thread, started on first use (instance(), from the
// main thread in practice). All socket IO of eco/system runs here: one
// IoHandler per fd, no thread per socket. Results reach the main thread
// through the existing POD queues (channel results, socket events), whose
// drains run from the eco/system async source; the Scheduler is unchanged.
//
// Backends: epoll + eventfd (Linux); kqueue + EVFILT_USER/EV_CLEAR (macOS and
// the BSDs, untested like the rest of eco/system on macOS); Windows: a stub
// whose submit() drops work (Windows kernels fail ENOTSUP before reaching it).
//
// Rules (§3.3.1, each a review fix; §9 N1, N14):
//   1. Interest is level-triggered and demand-driven, and an fd with no
//      interest is NOT in the kernel set: setInterest(k, false, false) is
//      EPOLL_CTL_DEL (kqueue: EV_DELETE of both filters). epoll reports
//      EPOLLERR/EPOLLHUP even with no requested events, so an idle registered
//      fd that the peer resets would spin. EPOLLRDHUP is not requested (a
//      persistent RDHUP with write-only interest would spin too); a peer's
//      FIN shows up as readable (read() returns 0).
//   2. Event data is the 64-bit key (slot index | generation << 32), never
//      the fd. remove() bumps the slot's generation; an event whose
//      generation does not match is dropped (fd-number reuse, descriptions
//      duplicated into children, a handler removed earlier in the same
//      batch). Events are also masked by the slot's CURRENT interest, so a
//      handler never sees a direction it no longer asks for.
//   3. remove() before close(), always; only the handler closes its fd, on
//      the reactor thread.
//   4. Wake: submit() pushes under the command mutex, then writes the eventfd
//      / triggers EVFILT_USER. The loop resets the eventfd (kqueue: EV_CLEAR
//      on retrieval) BEFORE draining the command queue, so no submit is lost.
//   5. Loop: runOnce(timeout): timeout = the earliest timer deadline (a
//      min-heap) or infinite; wait; dispatch due timers (deadline order);
//      dispatch events (EPOLLIN -> readable, EPOLLOUT -> writable,
//      EPOLLERR|EPOLLHUP|EPOLLRDHUP -> errorOrHangup; kqueue EV_EOF/EV_ERROR
//      -> errorOrHangup); drain commands (submission order).
//   6. Lock order: command mutex -> channel-results queue / socket-events
//      queue -> Scheduler mutex. The reactor holds NO lock while calling a
//      handler or a command (the command queue is swapped out first), so a
//      handler may post results and a command may submit more commands.
//   7. Exit: std::exit may run while the thread is inside a handler; handlers
//      hold only POD and OS resources, so that is safe for plain sockets.
//      TLS registers an atexit hook that calls quiesce() (§3.6, N13).
//
// Handlers are shared_ptrs: the slot holds one, and dispatch holds another
// for the duration of each call, so a handler may remove itself (or any
// other handler) from inside onReady/onTimer/onCloseAll.
//
// Threading: submit/closeAll/quiesce/loopIterations from any thread; the
// rest from the reactor thread only (inside a handler or a submitted
// command). G1: nothing here touches the Elm heap.
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_IO_REACTOR_HPP
#define ECO_SYSTEM_CORE_IO_REACTOR_HPP

#include <cstdint>
#include <functional>
#include <memory>

namespace Eco::System {

class IoReactor;

// Reactor-thread object owning one fd's IO. Never touches the heap (G1).
class IoHandler : public std::enable_shared_from_this<IoHandler> {
public:
    virtual ~IoHandler() = default;
    // Reactor thread. Only directions with current interest are reported;
    // errorOrHangup only while some interest is set (rule 1). The handler
    // learns the details from its syscalls.
    virtual void onReady(bool readable, bool writable, bool errorOrHangup) = 0;
    // Reactor thread: the deadline set with setTimer passed (the timer is
    // cleared before the call, so the handler may set a new one).
    virtual void onTimer() {}
    // Reactor thread: embed stop / exit quiesce: close now (remove + close).
    virtual void onCloseAll() = 0;
    // slot | generation << 32, set by add(); 0 when not registered (before
    // add, after remove). Reactor thread only.
    uint64_t key() const { return key_; }

private:
    friend class IoReactor;
    uint64_t key_ = 0;
};

class IoReactor {
public:
    static IoReactor& instance();

    // Any thread. Runs fn on the reactor thread, in submission order. fn may
    // capture only POD and shared_ptrs to reactor-side state (G1).
    void submit(std::function<void()> fn);

    // --- Reactor thread only ------------------------------------------------

    // Registers `h` for `fd` with NO interest (the fd is not in the kernel set
    // yet). `fd` may be -1 for a timer-only handler. Returns the key (never 0;
    // also stored in h->key()), or 0 if `h` is null or already registered.
    uint64_t add(std::shared_ptr<IoHandler> h, int fd);
    // Demand-driven interest (rule 1). (false, false) removes the fd from the
    // kernel set; anything else adds or modifies it. A stale key, a timer-only
    // handler or an unchanged interest is a no-op returning 0. Returns 0 or
    // the errno of a failed epoll_ctl/kevent (the interest is then unchanged).
    int setInterest(uint64_t key, bool read, bool write);
    // One timer per handler, on the nowMs() clock: a new deadline replaces
    // the old one; 0 cancels. A deadline already passed fires on the next
    // loop iteration. Stale keys are ignored.
    void setTimer(uint64_t key, int64_t deadlineMonoMs);
    // Removes the handler: EPOLL_CTL_DEL / EV_DELETE if registered, cancels
    // its timer, bumps the slot generation, clears h->key(). The caller closes
    // the fd AFTER this (rule 3). Stale keys are ignored.
    void remove(uint64_t key);
    // Steady clock, milliseconds. Any thread.
    int64_t nowMs() const;

    // --- Main thread (any non-reactor thread) -----------------------------

    // Calls onCloseAll() on every registered handler (embed stop, §3.3.9) and
    // waits until that is done. Handlers added meanwhile by onCloseAll are not
    // closed. Called on the reactor thread it runs inline (no deadlock).
    // Returns at once if the reactor is quiesced or failed to start.
    void closeAll();

    // Stops dispatching handlers and commands for good (TLS atexit, §3.6):
    // the reactor thread acknowledges at its next dispatch point (or at
    // once when idle) and then parks forever. Waits at most `timeoutMs` for
    // the acknowledgement; true if acknowledged (or the reactor never ran).
    // Called on the reactor thread: no further dispatch after the current
    // handler returns; returns true. Irreversible.
    bool quiesce(int64_t timeoutMs);

    // --- Internal / tests ---------------------------------------------------

    // One loop iteration (rule 5); the reactor thread calls it forever.
    // timeoutMs < 0: wait for the earliest timer or forever. A later
    // Scheduler integration would call this (§8). Reactor thread only.
    void runOnce(int64_t timeoutMs);
    // Number of runOnce iterations so far (test-only busy-loop check).
    uint64_t loopIterations() const;
    // True on the reactor thread.
    static bool onReactorThread();
    // Runs the normal dispatch path for a synthetic event (test-only check of
    // the generation rule). Reactor thread only.
    void injectEventForTest(uint64_t key, bool readable, bool writable, bool errorOrHangup);

    IoReactor(const IoReactor&) = delete;
    IoReactor& operator=(const IoReactor&) = delete;

    struct Impl;

private:
    IoReactor();
    ~IoReactor() = default;   // never runs (leaky singleton)

    Impl* impl_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_IO_REACTOR_HPP
