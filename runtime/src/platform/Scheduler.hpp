#ifndef ECO_PLATFORM_SCHEDULER_HPP
#define ECO_PLATFORM_SCHEDULER_HPP

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "platform/Liveness.hpp"
#include <deque>
#include <mutex>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <unordered_map>
#include <utility>
#include <vector>

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

    // ---- Hold API (plans/program-liveness-rule.md §5.1) ----
    // Registers `resume` (as registerPendingResume does) and acquires a hold
    // whose token is the returned resume token. Eco thread only.
    u64 parkResume(HPointer resume, HoldKind kind, const char* site);
    // Acquires a free-standing hold (bit 63 set). Any thread.
    HoldToken acquireHold(HoldKind kind, const char* site);
    // Releases hold `t` (a resume token from parkResume, or a token from
    // acquireHold): decrements pendingAsync_, then notifies eventCV_ under
    // mutex_. Any thread. Census builds abort on kNoHold, an unknown token or
    // a second release, naming the acquiring site.
    void releaseHold(HoldToken t);
    // Census (ECO_LIVENESS_REPORT=1 at exit / on a 10 s idle wait): prints
    // live holds by kind and site to stderr. Prints "census off" in builds
    // that keep no census.
    void reportHolds(const char* why);
    // True iff this build keeps the per-hold census (!NDEBUG || ECO_HEAP_VALIDATE
    // as compiled into Scheduler.cpp).
    bool holdCensusEnabled() const;
    // Census queries (0 / false when the census is off).
    size_t liveHoldCount();
    bool holdIsLive(HoldToken t);
    // Monotonic count of hold acquires and of
    // enqueues. Used by the §6.1 binding check in TaskBinding.hpp.
    u64 acquireSerial() const { return acquireSerial_.load(std::memory_order_relaxed); }
    u64 enqueueSerial() const { return enqueueSerial_.load(std::memory_order_relaxed); }
    // §6.1 check failure: an async-park binding returned without resuming
    // and without acquiring a hold. Recorded in the census report; aborts
    // only when ECO_LIVENESS_STRICT=1 (parks that legitimately hold nothing
    // exist: in-memory streams, X9, and Detached children, X4).
    void noteHoldlessPark(const char* binding);
    // Current pendingAsync_ (tests and census).
    int pendingAsync() const { return pendingAsync_.load(); }
    // Nesting depth of drain() on the eco thread (LIVE_004 test, PS9).
    int drainDepth() const { return drainDepth_; }

    // Cooperative shutdown for embedded hosts (eco_app_stop): sets a stop
    // flag and wakes the event loop, which exits after finishing the
    // current drain. Safe to call from any thread. Sticky for the process
    // lifetime (one app per process).
    void requestStop();
    bool stopRequested() const { return stopRequested_.load(); }

    // Embed mode (eco_embed.cpp): the host owns process-level concerns, so
    // the loop never exits on quiescence, signal handlers and std::exit are
    // off limits to kernels (plans/eco-system-library.md §3.4, §3.7).
    // Set once before the loop starts; read from any thread.
    void setEmbedMode(bool on) { embedMode_.store(on); }
    bool embedMode() const { return embedMode_.load(); }

    // Quiescence hook (Node `beforeExit` semantics; plans/eco-system-library.md
    // §3.7, plans/program-liveness-rule.md §7, LIVE_005). Listeners are called
    // at every quiescent point (run queue empty, pendingAsync_ == 0, no ready
    // async source, no stop requested; never in embed mode), with mutex_
    // released, on the eco thread, in registration order; the loop continues
    // iff some listener returned true (it delivered something), and exits
    // otherwise. The Scheduler keeps no armed bit: whether a listener is due
    // is the listener's own state (SystemManager's emptyLoopArmed), so a
    // listener that has nothing to deliver must return false or the loop
    // spins. Listeners may sendToApp/drain/allocate (mutex_ is not held) but
    // must run on, and are only called from, the eco thread. Registration
    // must happen on the eco thread.
    using QuiescenceListener = bool (*)(void* ctx);  // true iff it delivered
    void addQuiescenceListener(QuiescenceListener fn, void* ctx);
    // Removes every registration of (fn, ctx). Eco thread. Used by unit tests.
    void removeQuiescenceListener(QuiescenceListener fn, void* ctx);

    // Stop hooks (embed teardown, plans/eco-system-sockets.md §3.3.9): run
    // on the eco thread, in registration order, when runEventLoop exits
    // because a stop was requested (eco_app_stop, or an embed-mode exit).
    // They release process-level resources a library holds for the program
    // (eco/system closes its sockets so they do not stay bound in the host
    // process). A hook must not call Elm or touch the heap; it may block
    // briefly. Registration is permanent and idempotent per function, and
    // must happen on the eco thread.
    using StopHook = void (*)();
    void addStopHook(StopHook fn);

    // Called by helper threads (e.g. TimerService worker) to wake the main
    // event loop when new async work is ready. Must not allocate or touch GC.
    void notifyWorkAvailableFromAsync();

    // Activity hook: notifies an embedder (e.g. the N-API addon) when the
    // worker transitions between "has real work in flight" and "idle,
    // waiting for external input", so a host event loop (Node) can keep
    // itself alive exactly while the Elm program is busy — matching the JS
    // target, where pending Elm work pins the loop but an idle worker does
    // not. Fired on the scheduler (eco) thread, only on a state change. The
    // hook must be quick, non-blocking, and must not re-enter the scheduler.
    // "Real work" = a non-empty run queue OR a hold that is not a Host hold
    // (pendingAsync_ - hostHolds_ > 0: the embed layer's lifetime hold is
    // not work, plans/program-liveness-rule.md §8, L11). Null by default
    // (the standalone executable runtime registers none).
    using ActivityHook = void (*)(bool busy, void* user);
    void setActivityHook(ActivityHook hook, void* user) {
        activityHook_ = hook;
        activityUser_ = user;
    }

    // Closure calling helper: calls a 1-arg Elm closure, returns result
    static HPointer callClosure1(HPointer closurePtr, HPointer arg);
    // Calls a 2-arg Elm closure
    static HPointer callClosure2(HPointer closurePtr, HPointer arg1, HPointer arg2);
    // Calls a 3-arg Elm closure (for onSelfMsg: router, selfMsg, state)
    static HPointer callClosure3(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                 HPointer arg3);
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

    // Register an external async completion source (e.g. the HTTP worker).
    // `drain` is invoked on the main scheduler thread during processReadyAsync
    // and must do all HPointer/GC work there; `ready` is a non-blocking
    // predicate folded into the event loop's wait condition so a completion
    // posted from a worker thread reliably wakes the loop. Both are stored for
    // the lifetime of the process. Safe to call once at kernel init.
    void registerAsyncSource(std::function<void()> drain, std::function<bool()> ready);

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

    // Mark a process id as an effect-manager self-process. When such a
    // process receives a mailbox message, the step loop runs `handler(msg)`
    // (which performs onSelfMsg(router,msg,state) + state write-back) instead
    // of the generic 1-arg callback dispatch, then auto re-arms the
    // Task_Receive loop so the process blocks for the next message (Q-H).
    // Keyed by the stable logical process id (the Process *value* changes on
    // every step since Process is immutable, but the id is stable).
    void registerSelfProcess(u32 procId, std::function<void(HPointer msg)> handler);

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
    // Effect-manager self-processes: logical process id → message handler.
    // The handler captures no HPointers (it reads manager state from
    // PlatformRuntime by home), so this map needs no GC scanning. Populated
    // once per manager during setupEffects.
    std::unordered_map<u32, std::function<void(HPointer)>> selfMsgHandlers_;
    // External async completion sources (HTTP, etc). Drained on the main
    // thread in processReadyAsync; their `ready` predicates feed the wait
    // condition. Registered on the main thread, possibly lazily from inside a
    // drain (a binding stepped by a drain may register a new source), so the
    // loops over this container iterate by index with the size re-read each
    // step, and it is a deque: push_back never moves existing elements, so a
    // drain that registers a source does not destroy the std::function that
    // is running.
    std::deque<std::pair<std::function<void()>, std::function<bool()>>> asyncSources_;
    bool working_ = false;
    std::mutex mutex_;
    std::condition_variable eventCV_;
    std::atomic<int> pendingAsync_{0};
    // The raw liveness counter (LIVE_006): private; called only by the hold
    // API (noteAcquire / releaseHold), so every change of pendingAsync_ is a
    // hold with a token and, in census builds, a census entry.
    void incrementPendingAsync();
    void decrementPendingAsync();
    // Hold census (plans/program-liveness-rule.md §5.1). Always declared (the
    // class layout must not depend on NDEBUG: TUs differ); populated only when
    // holdCensusEnabled(). holdsMutex_ is a leaf lock: never taken while
    // holding mutex_, never held while calling out.
    std::mutex holdsMutex_;
    std::unordered_map<HoldToken, std::pair<HoldKind, const char*>> holds_;
    std::vector<std::pair<const char*, u64>> holdlessParks_;
    std::atomic<u64> nextHoldId_{1};
    std::atomic<int> hostHolds_{0};
    std::atomic<u64> acquireSerial_{0};
    std::atomic<u64> enqueueSerial_{0};
    int drainDepth_ = 0;
    void noteAcquire(HoldToken t, HoldKind kind, const char* site);
    // Host-liveness activity hook (see setActivityHook). activityHook_ may be
    // read/written across threads but is only set once before the loop runs;
    // lastActivityBusy_ is touched only on the eco thread in runEventLoop.
    ActivityHook activityHook_ = nullptr;
    void* activityUser_ = nullptr;
    bool lastActivityBusy_ = true;  // assume busy until the loop first idles
    void fireActivity(bool busy);
    std::atomic<u32> nextProcId_{0};
    std::atomic<bool> stopRequested_{false};
    std::atomic<bool> embedMode_{false};
    // Quiescence hook listeners (see addQuiescenceListener), guarded by mutex_.
    std::vector<std::pair<QuiescenceListener, void*>> quiescenceListeners_;
    // Stop hooks (see addStopHook); eco thread only.
    std::vector<StopHook> stopHooks_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_SCHEDULER_HPP
