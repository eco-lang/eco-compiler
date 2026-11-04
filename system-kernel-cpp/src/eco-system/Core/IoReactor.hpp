//===- IoReactor.hpp - The shared non-blocking IO event loop --------------===//
//
// eco/system does all of its socket IO on one thread, so that it needs no thread per socket. This component is that
// thread's event loop, the reactor.
//
// The reactor is one object, `IoReactor::instance()`, created on first use and never destroyed, with one detached
// thread, the reactor thread, that runs `runOnce` forever. Work reaches the reactor thread in two ways:
//
//   * A handler, an `IoHandler`, owns one file descriptor (or none, for a handler that only uses a timer). It is
//     registered with `add`, which returns its key, and the reactor calls it when its fd is ready or its timer is due.
//   * A command is a function passed to `submit` from any thread. It runs on the reactor thread, and is how any other
//     thread asks for anything to be done to a handler.
//
// `add`, and everything that takes a key (`setInterest`, `setTimer`, `remove`), may be called only on the reactor
// thread, that is from inside a handler call or a command. Nothing here touches the Elm heap.
//
// A key is a 64-bit number, the handler's slot index in the low 32 bits and the slot's generation in the high 32.
// `remove` bumps the generation, so an event or a call carrying an old key is ignored: the fd number may have been
// reused, or the handler removed by an earlier event of the same batch. Key 0 is never a handler's key.
//
// Interest is which directions, read and write, a handler wants to hear about. It is level-triggered and starts
// empty, and a handler with no interest is not in the kernel's event set at all, because epoll reports errors and
// hangups on any fd in its set, wanted or not, and an idle fd whose peer reset it would wake the loop forever. For the
// same reason a peer's half close is not requested separately; it shows up as readable, with `read` returning 0. Each
// event is masked by the interest the handler holds when the event is dispatched, so a handler never hears about a
// direction it has dropped.
//
// One iteration of the loop checks for a quiesce, waits for the earliest timer or an event or a wake, fires the due
// timers in deadline order, dispatches the events, and runs the queued commands in submission order. `submit` wakes
// the loop after queueing, and the loop consumes the wake before it takes the command queue, so no command waits for a
// later wake. No lock is held while a handler or a command runs, so a handler may submit commands and a command may
// submit more.
//
// An exception escaping a handler or a command is printed to stderr and dropped, and the loop carries on.
//
// To quiesce is to stop the reactor for good: once the reactor thread sees a `quiesce` request it starts no further
// handler or command and blocks forever. Process exit can run while the reactor thread is inside a handler, and
// quiescing first keeps that thread from entering any handler after the request; one already running is not stopped.
//
// Backends: epoll with an eventfd for the wake on Linux, kqueue with an `EVFILT_USER` event on macOS and the BSDs. On
// Windows the reactor is a stub that never starts: `submit` drops its command and `closeAll` and `quiesce` return at
// once.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_IO_REACTOR_HPP
#define ECO_SYSTEM_CORE_IO_REACTOR_HPP

#include <cstdint>
#include <functional>
#include <memory>

namespace Eco::System {

class IoReactor;

/// An object that owns the IO of one file descriptor, or a timer with no fd, and is driven by the reactor.
///
/// An implementation is held by `std::shared_ptr`. Once `IoReactor::add` registers it, the reactor holds a reference
/// until `IoReactor::remove`, and holds another for the length of each call it makes, so a handler may remove itself
/// or another handler from inside any of its callbacks. Every callback runs on the reactor thread. The handler owns its
/// fd: it must call `IoReactor::remove` before it closes the fd, and the reactor never closes it. A callback that
/// throws has its exception printed to stderr and dropped.
class IoHandler : public std::enable_shared_from_this<IoHandler> {
public:
    virtual ~IoHandler() = default;
    /// Reports that the fd is ready. `readable` and `writable` are reported only for directions the handler has
    /// interest in when the call is made, and no call is made while it has none. `errorOrHangup` reports an error or
    /// hangup, and with kqueue also end of file (with epoll a peer's half close arrives as readable only); the handler
    /// learns which from its own system calls. With kqueue, read and write readiness arrive as separate events, so
    /// one loop iteration may call this twice for the same fd.
    virtual void onReady(bool readable, bool writable, bool errorOrHangup) = 0;
    /// Reports that the deadline set with `IoReactor::setTimer` has passed. The timer is cleared before the call, so
    /// the override may set a new one. The default does nothing.
    virtual void onTimer() {}
    /// Asks the handler to shut down now, from `IoReactor::closeAll`. An override is expected to remove itself and
    /// close its fd; the reactor does not check that it does.
    virtual void onCloseAll() = 0;
    /// Returns the handler's key, or 0 when it is not registered (before `IoReactor::add` and after
    /// `IoReactor::remove`). It is written on the reactor thread, unsynchronised, so it must be read there.
    uint64_t key() const { return key_; }

private:
    friend class IoReactor;
    uint64_t key_ = 0;
};

/// The process's one event loop for eco/system IO, and the thread that runs it.
///
/// The reactor is created by the first call to `instance` and is never destroyed, so its own state is never destroyed
/// under its thread at process exit. If the backend cannot be created or the thread cannot be started, a message is
/// printed to stderr and the reactor stays unstarted: `submit` drops every command, and `closeAll` and `quiesce` return
/// at once.
class IoReactor {
public:
    /// Returns the reactor, creating it and starting its thread on the first call.
    static IoReactor& instance();

    /// Queues `fn` to run on the reactor thread, after every command submitted before it. May be called from any
    /// thread. `fn` is dropped without running when it is empty or the reactor is unstarted, and is never run once the
    /// reactor has quiesced. It runs later, on the reactor thread, with no lock held, so it must not capture anything
    /// that may be destroyed before it runs, nor touch the Elm heap.
    void submit(std::function<void()> fn);

    // --- Reactor thread only ------------------------------------------------

    /// Registers `h` as the handler for `fd`, with no interest and no timer, and returns its key, which `h->key()`
    /// also returns until `remove`. `fd` may be -1 for a handler that uses only a timer. Returns 0, and registers
    /// nothing, when `h` is null or already registered.
    uint64_t add(std::shared_ptr<IoHandler> h, int fd);
    /// Sets the handler's interest to `read` and `write`, and returns 0 or the errno of the failed kernel call.
    ///
    /// Clearing both takes the fd out of the kernel's event set. A key that is not registered, a handler with no fd,
    /// or an interest equal to the current one does nothing and returns 0. On epoll a failure leaves the interest
    /// unchanged. On kqueue each direction is changed by its own call, so when the write change fails the read change
    /// has already been made.
    int setInterest(uint64_t key, bool read, bool write);
    /// Sets the handler's one timer to fire at `deadlineMonoMs` on the `nowMs` clock, replacing any earlier deadline;
    /// 0 cancels the timer. A deadline already passed fires at the next loop iteration. A key that is not registered
    /// is ignored.
    void setTimer(uint64_t key, int64_t deadlineMonoMs);
    /// Unregisters the handler with key `key`: takes its fd out of the kernel's event set, cancels its timer, and
    /// makes `key` stale, so that events already collected for it are dropped and its `key()` returns 0. The fd is
    /// not closed; the handler closes it after this call. The reactor's reference to the handler is dropped, which
    /// may destroy it. A key that is not registered is ignored.
    void remove(uint64_t key);
    /// Returns the time on a steady clock, in milliseconds. May be called from any thread.
    int64_t nowMs() const;

    // --- Any thread -------------------------------------------------------

    /// Calls `onCloseAll` on every handler registered when the calls begin, except one that an earlier `onCloseAll`
    /// removed, and returns when that is done. A handler registered meanwhile is not called.
    ///
    /// Called on the reactor thread, it runs the calls itself. Called on another thread, it submits them as a command
    /// and blocks until they finish, or until the reactor is asked to quiesce, in which case it returns without
    /// waiting further. It returns at once if the reactor is unstarted or a quiesce has been requested.
    void closeAll();

    /// Stops the reactor for good, and returns whether it is known to have stopped.
    ///
    /// The reactor thread sees the request before it next starts a handler or a command, or at once if it is waiting
    /// for events, and from then on runs nothing and blocks forever. Called on another thread, this wakes the reactor
    /// and waits at most `timeoutMs` (a negative value is taken as 0) for it to acknowledge, returning whether it did;
    /// a handler that runs longer than that makes it return false. Called on the reactor thread, it returns true at
    /// once, and nothing is started after the current call returns. It returns true if the reactor is unstarted.
    /// Queued commands and registered handlers are abandoned, not run or closed.
    bool quiesce(int64_t timeoutMs);

    // --- Internal / tests ---------------------------------------------------

    /// Runs one iteration of the loop, as the file comment describes. It waits for at most `timeoutMs`, and no longer
    /// than until the earliest timer; a negative `timeoutMs` waits for the earliest timer, or for ever if there is
    /// none. Reactor thread only; the reactor thread calls it in a loop for its whole life.
    void runOnce(int64_t timeoutMs);
    /// Returns how many times `runOnce` has been entered. May be called from any thread.
    uint64_t loopIterations() const;
    /// Returns whether the calling thread is the reactor thread.
    static bool onReactorThread();
    /// Dispatches a synthetic event for `key` as though the backend had reported it, with the same stale-key check
    /// and interest masking. Reactor thread only.
    void injectEventForTest(uint64_t key, bool readable, bool writable, bool errorOrHangup);

    IoReactor(const IoReactor&) = delete;
    IoReactor& operator=(const IoReactor&) = delete;

    /// The reactor's state, defined in the source file.
    struct Impl;

private:
    // Creates the backend and starts the thread, or prints to stderr and leaves the reactor unstarted.
    IoReactor();
    ~IoReactor() = default;   // never runs (leaky singleton)

    Impl* impl_;   // never null; allocated by the constructor and never freed
};

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_IO_REACTOR_HPP
