#ifndef ECO_PLATFORM_SCHEDULER_HPP
#define ECO_PLATFORM_SCHEDULER_HPP

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include <deque>
#include <mutex>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <unordered_map>

namespace Elm::Platform {

class Scheduler {
public:
    static Scheduler& instance();

    // Task constructors - allocate heap Task objects
    HPointer taskSucceed(HPointer value);
    // Variant carrying an unboxed primitive payload (kind 1=Int, 2=Float, 3=Char).
    HPointer taskSucceedKind(Unboxable value, u8 kind);
    HPointer taskFail(HPointer error);
    HPointer taskBinding(HPointer callback);
    HPointer taskAndThen(HPointer callback, HPointer task);
    HPointer taskOnError(HPointer callback, HPointer task);
    HPointer taskReceive(HPointer callback);

    // Process API
    HPointer rawSpawn(HPointer rootTask);
    HPointer spawnTask(HPointer rootTask);
    void rawSend(HPointer proc, HPointer msg);
    HPointer killTask(HPointer proc);

    // Run queue management
    void enqueue(HPointer proc);
    void drain();

    // Event loop for single-threaded Elm execution
    void runEventLoop();
    void incrementPendingAsync();
    void decrementPendingAsync();

    // Called by helper threads (e.g. TimerService worker) to wake the main
    // event loop when new async work is ready. Must not allocate or touch GC.
    void notifyWorkAvailableFromAsync();

    // Closure calling helper: calls a 1-arg Elm closure, returns result
    static HPointer callClosure1(HPointer closurePtr, HPointer arg);
    // Calls a 2-arg Elm closure
    static HPointer callClosure2(HPointer closurePtr, HPointer arg1, HPointer arg2);
    // Calls a 4-arg Elm closure (for onEffects: router, cmds, subs, state)
    static HPointer callClosure4(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                 HPointer arg3, HPointer arg4);

    u32 nextProcessId() { return nextProcId_.fetch_add(1); }

    // Register a resume-closure HPointer as a GC root while an async
    // operation (e.g. sleep timer, HTTP callback) is pending. Returns an
    // opaque token; use `takePendingResume` to retrieve the (post-GC,
    // possibly-evacuated) HPointer and remove the root when the async op
    // completes. Safe to call from any thread.
    u64 registerPendingResume(HPointer resume);
    HPointer takePendingResume(u64 token);

    // Process is logically immutable: every mutation is implemented by
    // allocating a new Process with replaced fields. `procWith*` are the
    // only way to produce a Process value with updated state. The caller
    // must replace its own HPointer (runQueue entry, rooted stack slot,
    // etc.) with the returned value; the old Process is then garbage.
    static HPointer procWithRoot(HPointer srcHP, HPointer newRoot);
    static HPointer procWithStack(HPointer srcHP, HPointer newStack);
    static HPointer procWithMailbox(HPointer srcHP, HPointer newMailbox);

    // Look up the current (post-drain) HPointer for a process, using either
    // a still-valid original HPointer or the logical id. Since Process is
    // immutable, external holders of an HPointer become stale as soon as
    // the scheduler steps the process; this registry is how they find the
    // current version. Returns listNil() if the process is not live.
    HPointer latestProcessByHPtr(HPointer originalHP);
    HPointer latestProcessById(u32 id);

    // Registry updater — scheduler internals call this every time they
    // produce a new Process value. Exposed publicly (instead of `private`)
    // so the resume closure evaluator can also update it.
    void registerLatestProcess(HPointer proc);

private:
    Scheduler();

    void stepProcess(uint64_t procEncoded);

    // Drain TimerService's ready-token queue: for each token, resolve the
    // corresponding resume closure from pendingResumes_, allocate
    // Task.succeed(unit), invoke callClosure1, and decrement pendingAsync_.
    // Runs only on the main scheduler thread.
    void processReadyAsync();

    // Mailbox helpers (Elm List as queue).
    // These allocate a new Process with the updated mailbox and return its
    // HPointer. Callers must replace their own reference to the Process.
    static HPointer mailboxPushBack(HPointer procHP, HPointer msg);

    struct MailboxPopResult {
        bool hasMessage;
        HPointer newProcHP;  // new Process HPointer after popping (only valid if hasMessage).
        HPointer msg;
    };
    static MailboxPopResult mailboxPopFront(HPointer procHP);

    // Stack helpers (Elm List of StackFrame Custom objects).
    // pushStack allocates a new Process with the updated stack and returns its HPointer.
    static HPointer pushStack(HPointer procHP, u64 expectedTag, HPointer callback);

    struct PopStackResult {
        bool matched;
        HPointer newProcHP;  // new Process HPointer after popping.
        HPointer callback;
    };
    static PopStackResult popStackMatching(HPointer procHP, u64 tag);

    struct RootedProc {
        uint64_t encoded;  // HPointer encoded as uint64_t for GC root registration
    };

    std::deque<RootedProc> runQueue_;
    // Maps a logical Process id to the encoded HPointer of its current (latest)
    // immutable Process value. Updated by every scheduler helper that produces
    // a new Process; scanned by the external GC root scanner (values are
    // evacuated like any other HPointer).
    std::unordered_map<u32, uint64_t> latestProc_;
    // Pending-resume registry: tokens → encoded HPointers of resume
    // closures held alive while the owning async op is in flight. The
    // external root scanner walks this map so closures survive GC until
    // the async op fires or is cancelled.
    std::unordered_map<u64, uint64_t> pendingResumes_;
    std::atomic<u64> nextResumeToken_{1};
    std::mutex resumeMutex_;
    bool working_ = false;
    std::mutex mutex_;
    std::condition_variable eventCV_;
    std::atomic<int> pendingAsync_{0};
    std::atomic<u32> nextProcId_{0};
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_SCHEDULER_HPP
