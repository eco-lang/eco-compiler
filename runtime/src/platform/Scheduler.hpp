// The scheduler runs Elm's Tasks and processes, in the model elm/core defines, on the one thread that runs Elm
// code (the eco thread), and keeps the program alive while something it waits for is still to come.
//
// A Task is an immutable heap value describing work: `Succeed` or `Fail` with a value, `AndThen` or `OnError`
// with a callback and an inner Task, `Binding` (a callback given a resume closure, through which external work
// reports back), and `Receive` (a callback for the next mailbox message). A process runs one root Task. It is a
// heap `Process` value holding a 64-bit id, the root Task, a stack of pending `AndThen`/`OnError` frames and a
// mailbox. Stepping a process rewrites its root until it reaches a `Binding` (the process parks), a `Receive`
// with an empty mailbox (it blocks), or a `Succeed`/`Fail` that no frame handles (it finishes).
//
// Two facts shape the rest.
//
// The first is that a `Process` value is never changed. Every step allocates a new one (`procWith*`), so an
// HPointer to a process goes stale as soon as the process is stepped. The id does not: ids are never reused,
// and a registry maps each live process's id to its latest value. `latestProcessById` is how a holder finds
// the current version, and a process leaves the registry when it finishes or is killed. A run-queue entry may
// hold an older version; `stepProcess` steps the latest one, so a process is stepped as the one mutable process
// of Elm's JS scheduler would be.
//
// The second is that only the eco thread may touch the heap. The run queue, the process registry, the
// finished-process hand-over and the table of parked resume closures hold encoded HPointers, and one external
// root scanner (`RootSet::addExternalRootScanner`) keeps them alive and moving with the collector. The scanner
// reads the first three without `mutex_`, so they may change only on the eco thread. Other threads deal in
// plain data: a resume token, a hold, a wake-up.
//
// The event loop (`runEventLoop`) drains the run queue, then runs the ready async work, then either sleeps on a
// condition variable or exits, on a stop or when nothing can wake it. One thing that keeps it running is
// the hold, one unit of the pending-async count, whose rules `Liveness.hpp` states. Hosts that embed the
// runtime observe the loop through three hooks: quiescence listeners, stop hooks and an activity hook.

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
#include <unordered_set>
#include <utility>
#include <vector>

namespace Elm::Platform {

/**
 * The singleton that steps Elm processes and runs the event loop.
 *
 * It is obtained only from `instance`, and is never destroyed. Unless a function says otherwise, it must be
 * called on the eco thread, and every function that builds a Task or a Process allocates and may collect.
 */
class Scheduler {
public:
    // Returns the scheduler, creating it on first use.
    //
    // Creating it registers its root scanner with the `RootSet` of the calling thread's heap, initialising that
    // heap if the thread has none, so the first call must be made on the eco thread.
    static Scheduler& instance();

    // Task constructors. Each allocates a new Task.

    // Returns a Task that succeeds with `value`.
    HPointer taskSucceed(HPointer value);
    // Returns a Task that succeeds with an unboxed `value` of slot kind `kind` (1 Int, 2 Float, 3 Char; only the
    // low two bits are read). With kind 0, `value.p` is stored as a boxed HPointer, as `taskSucceed` does.
    HPointer taskSucceedKind(Unboxable value, u8 kind);
    // Returns a Task that fails with `error`.
    HPointer taskFail(HPointer error);
    // Returns a Binding Task. When stepped, `callback` is called with a resume closure, and its result is
    // kept as the kill handle `killTask` calls. Calling the resume closure with a Task makes that Task the
    // process's root and enqueues the process.
    HPointer taskBinding(HPointer callback);
    // Returns a Task that runs `task` and, if it succeeds, the Task that `callback` returns for its value.
    HPointer taskAndThen(HPointer callback, HPointer task);
    // Returns a Task that runs `task` and, if it fails, the Task that `callback` returns for its error.
    HPointer taskOnError(HPointer callback, HPointer task);
    // Returns a Task that waits for the process's next mailbox message and continues with the Task `callback`
    // returns for it.
    HPointer taskReceive(HPointer callback);

    // Processes

    // Creates a process with a fresh id that runs `rootTask`, enqueues it, and returns its first value. The
    // returned HPointer is stale once the process has been stepped; look it up again by id.
    HPointer rawSpawn(HPointer rootTask);
    // Returns a Task that, each time it is stepped, spawns a process running `rootTask` (as `rawSpawn`) and
    // succeeds with that process's first value. Creating the Task spawns nothing.
    HPointer spawnTask(HPointer rootTask);
    // Puts `msg` in the mailbox of `proc` and enqueues the result. Does nothing if `proc` is not a heap object.
    //
    // The new value is built from `proc` as given, not from the latest version registered for its id, and is
    // then registered as the latest version for that id.
    void rawSend(HPointer proc, HPointer msg);
    // Returns a Task that, each time it is stepped, tries to kill `proc` and succeeds with unit.
    //
    // The target is found by id through the process registry, so a stale `proc` names the latest version. If
    // that version's root is a Binding whose kill handle is a heap object, the handle is called with unit.
    // Nothing else happens to the target: it is not dequeued and keeps its mailbox. A finished target is left
    // alone.
    HPointer killTask(HPointer proc);

    // The run queue

    // Appends `proc` to the run queue and wakes the event loop.
    void enqueue(HPointer proc);
    // Steps queued processes until the run queue is empty, including any enqueued meanwhile. It may be called
    // from inside a step, in which case the inner call empties the queue.
    void drain();

    // Runs the program until it stops or can make no further progress, and returns.
    //
    // Each pass drains the run queue, returns if a stop was requested, runs `processReadyAsync`, and then
    // sleeps until there is work, a stop, a ready async source, a ready timer token, or no holds left. When
    // the run queue is empty, no hold is live and no async source is ready, the loop is quiescent. Outside
    // embed mode it then asks the quiescence listeners, and continues if one delivered; otherwise it returns.
    // On a stop it runs the stop hooks before returning.
    void runEventLoop();

    // Holds. A hold is defined, and the rules for owning one are stated, in `Liveness.hpp`.

    // Parks `resume` as `registerPendingResume` does, acquires a hold of kind `kind` keyed by the returned
    // resume token, and returns the token. `site` names the caller in census reports; census builds may read
    // the pointer after the hold is released, so it should stay valid for the rest of the run.
    u64 parkResume(HPointer resume, HoldKind kind, const char* site);
    // Acquires a free-standing hold of kind `kind` and returns its token. `site` is kept as for `parkResume`.
    // May be called from any thread.
    HoldToken acquireHold(HoldKind kind, const char* site);
    // Releases hold `t`, a token from `parkResume` or `acquireHold`, and wakes the event loop. May be called
    // from any thread, but not while holding the scheduler's lock: not from an async source's `ready`
    // predicate or from the activity hook.
    //
    // Census builds abort, naming the acquiring site where it is known, when `t` is `kNoHold`, a token never
    // acquired, or one already released. Other builds check nothing.
    void releaseHold(HoldToken t);
    // Writes the live holds, counted by kind and site, and any holdless parks to stderr, headed by `why`.
    // In builds without a census it writes only the pending-async count.
    //
    // When the `ECO_LIVENESS_REPORT` environment variable is set to anything but empty or `0`, the event loop
    // calls it after every 10 s of idle waiting and when it returns.
    void reportHolds(const char* why);
    // Returns whether this build keeps the hold census: builds without `NDEBUG`, or with `ECO_HEAP_VALIDATE`,
    // as Scheduler.cpp was compiled.
    bool holdCensusEnabled() const;
    // Returns the number of live holds in the census, or 0 when there is no census.
    size_t liveHoldCount();
    // Returns whether `t` names a live hold in the census, or false when there is no census.
    bool holdIsLive(HoldToken t);
    // Returns how many holds have been acquired, in either way, so far.
    u64 acquireSerial() const { return acquireSerial_.load(std::memory_order_relaxed); }
    // Returns how many times `enqueue` has been called so far.
    u64 enqueueSerial() const { return enqueueSerial_.load(std::memory_order_relaxed); }
    // Records that the async binding `binding` returned having neither enqueued anything nor acquired a hold.
    //
    // With `ECO_LIVENESS_STRICT` set to anything but empty or `0`, it aborts, in every build. Otherwise census
    // builds count the park against `binding`, compared by pointer, for `reportHolds`, so `binding` must stay
    // valid for the rest of the run; other builds do nothing.
    void noteHoldlessPark(const char* binding);
    // Returns the number of live holds.
    int pendingAsync() const { return pendingAsync_.load(); }
    // Returns how many calls to `drain` are in progress.
    int drainDepth() const { return drainDepth_; }

    // Asks the event loop to return, and wakes it. The loop returns once the drain in progress, if any, has
    // finished. The request is never withdrawn. May be called from any thread.
    void requestStop();
    // Returns whether `requestStop` has been called.
    bool stopRequested() const { return stopRequested_.load(); }

    // Turns embed mode on or off. In embed mode the event loop does not call quiescence listeners, and so returns
    // at the first quiescent point.
    void setEmbedMode(bool on) { embedMode_.store(on); }
    // Returns whether embed mode is on.
    bool embedMode() const { return embedMode_.load(); }

    // A function the event loop calls at a quiescent point, with the `ctx` it was registered with. It returns
    // whether it delivered anything; if any listener did, the loop runs on, and otherwise it returns.
    //
    // It is called on the eco thread without the scheduler's lock held, so it may enqueue, drain, allocate and
    // start async work. The scheduler keeps no record of whether a listener is due, so a listener with nothing
    // to deliver must return false, or the loop never returns.
    using QuiescenceListener = bool (*)(void* ctx);
    // Registers `fn` to be called with `ctx` at every quiescent point. All listeners are called, in
    // registration order; one registered during a round is first called in the next.
    void addQuiescenceListener(QuiescenceListener fn, void* ctx);
    // Removes every registration of `fn` with `ctx`.
    void removeQuiescenceListener(QuiescenceListener fn, void* ctx);

    // A function the event loop calls, on the eco thread, when it returns because a stop was requested, to
    // release what a library holds for the program outside the heap. It must not call Elm code or touch the
    // heap.
    using StopHook = void (*)();
    // Registers `fn` as a stop hook, for the rest of the run. Hooks run in registration order, and registering
    // the same function again does nothing.
    void addStopHook(StopHook fn);

    // Wakes the event loop so that it rechecks its ready async sources and timer tokens. May be called from any
    // thread; it neither allocates nor touches the heap.
    void notifyWorkAvailableFromAsync();

    // A function an embedding host registers to learn whether the program is busy, called with `busy` and
    // the `user` pointer it was registered with.
    //
    // Before it sleeps, the event loop reports busy when the live holds outnumber the Host holds, where a Host
    // hold from `acquireHold` is counted until it is released and one from `parkResume` is counted for the rest
    // of the run, even after release; after every wake it reports true. The hook is called on the eco thread,
    // only when the answer changes, and with false when the loop returns. It may be called with the
    // scheduler's lock held, so it must not call back into the scheduler.
    using ActivityHook = void (*)(bool busy, void* user);
    // Registers `hook`, replacing any previous one, to be called with `user`; a null `hook` registers none.
    // `user` is kept and must stay valid while the hook may be called. Set it before the event loop starts.
    void setActivityHook(ActivityHook hook, void* user) {
        activityHook_ = hook;
        activityUser_ = user;
    }

    // Closure calls. Each runs Elm code, which may allocate and collect, so HPointers the caller holds across
    // the call must be rooted.

    // Applies the closure `closurePtr` to `arg` and returns the result.
    static HPointer callClosure1(HPointer closurePtr, HPointer arg);
    // Applies the closure `closurePtr` to `arg1` and `arg2` and returns the result.
    static HPointer callClosure2(HPointer closurePtr, HPointer arg1, HPointer arg2);
    // Applies the closure `closurePtr` to `arg1`, `arg2` and `arg3` and returns the result.
    static HPointer callClosure3(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                 HPointer arg3);
    // Applies the closure `closurePtr` to `arg1` through `arg4` and returns the result.
    static HPointer callClosure4(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                 HPointer arg3, HPointer arg4);

    // Returns a new process id. Ids count up from 0 and are never handed out twice, so an id names at most one
    // process for the life of the program. May be called from any thread.
    u64 nextProcessId() { return nextProcId_.fetch_add(1); }

    // Keeps the closure `resume` alive, and moving with the collector, until `takePendingResume` is called with
    // the returned token. Tokens count up from 1 and have bit 63 clear. Acquires no hold; `parkResume` does
    // both. The token is plain data and may be passed to another thread and back, but both calls must be made
    // on the eco thread.
    u64 registerPendingResume(HPointer resume);
    // Removes the closure parked under `token` and returns its current HPointer, or `listNil()` if the token
    // is unknown or was already taken.
    HPointer takePendingResume(u64 token);

    // Registers an async source: work that other threads complete and the eco thread finishes, for the rest of
    // the run.
    //
    // `drain` is called on the eco thread on every pass of the event loop, ready or not, and is where all heap
    // work for the source is done; it must release the holds of the work it finishes. `ready` must not block.
    // It is called with the scheduler's lock held, while the loop decides whether to sleep, and its returning
    // true wakes or keeps the loop running. A source registered during a drain is drained in the same pass.
    void registerAsyncSource(std::function<void()> drain, std::function<bool()> ready);

    // Process values. Each `procWith*` returns a new Process with the id and fields of `srcHP` except the one
    // it names, and registers it as the latest version for its id. The caller must use the returned value in
    // place of `srcHP`. Each returns `listNil()` if `srcHP` is not a heap object.

    // Returns a copy of process `srcHP` whose root Task is `newRoot`.
    static HPointer procWithRoot(HPointer srcHP, HPointer newRoot);
    // Returns a copy of process `srcHP` whose stack is `newStack`.
    static HPointer procWithStack(HPointer srcHP, HPointer newStack);
    // Returns a copy of process `srcHP` whose mailbox is `newMailbox`.
    static HPointer procWithMailbox(HPointer srcHP, HPointer newMailbox);

    // Returns the latest version of the process `originalHP` is a version of, or `listNil()` if the process
    // has finished or `originalHP` is not a heap object. `originalHP` must still point at a Process, so it
    // must have been kept rooted.
    HPointer latestProcessByHPtr(HPointer originalHP);
    // Returns the latest version of the process with id `id`, or `listNil()` if there is no live process
    // with that id.
    HPointer latestProcessById(u64 id);

    // Asks that process `id`'s final value be kept when it finishes, for `takeFinishedProcess` to collect.
    void keepResultOnFinish(u64 id);
    // Returns the final value of process `id` kept by `keepResultOnFinish`, or `listNil()` if it has not
    // finished. Either way the request ends: a later finish is not kept, and nothing stays rooted.
    HPointer takeFinishedProcess(u64 id);

    // Records `proc` as the latest version of the process with its id. Does nothing if `proc` is not a heap
    // object. Used for a new process; `procWith*` use `updateLatestProcess`.
    void registerLatestProcess(HPointer proc);
    // Records `proc` as the latest version of its process if that process is live (registered), and does
    // nothing otherwise, so that a version made after a kill or finish (a late resume) does not revive it.
    void updateLatestProcess(HPointer proc);
    // Ends process `id` at a kill: removes its registry entry and self-message handler, so it takes no
    // further step (stepProcess drops a run-queue entry with no latest version) and gets no messages.
    void processKilled(u64 id);
    // Returns whether `stepProcess` is stepping process `id` right now (a process running Process.kill on
    // itself).
    bool isStepping(u64 id) const { return steppingDepth_ > 0 && steppingId_ == id; }
    // Counts a resume (the resume closure's evaluator calls it), so `stepProcess` can tell a Binding
    // callback that resumed synchronously.
    void noteResumed() { ++resumeSerial_; }

    // Makes `handler` the self-message handler of process `procId`, replacing any previous one.
    //
    // When that process, blocked on a Receive, takes a message from its mailbox, `handler` is called with the
    // message in place of the Receive's callback, and the process stays on the same Receive for the next
    // message. The registration ends when the process finishes. `handler` must hold no HPointers: it is not
    // scanned by the collector.
    void registerSelfProcess(u64 procId, std::function<void(HPointer msg)> handler);

private:
    // Creates the scheduler and registers its root scanner.
    Scheduler();

    // Steps the process whose encoded HPointer is `procEncoded` until it parks, blocks or finishes.
    void stepProcess(uint64_t procEncoded);

    // Ends the registration of finished process `proc`: removes its registry entry and self-message handler,
    // and, if `keepResultOnFinish` asked for it, puts it in the finished hand-over.
    void processFinished(HPointer proc);

    // Runs the async work that is ready: for each fired timer token, calls its parked resume closure with
    // `Task.succeed ()` and releases the token's hold (also when the resume was already withdrawn); then calls
    // every async source's `drain`.
    void processReadyAsync();

    // Returns a copy of process `procHP` with `msg` added to its mailbox, registered as the latest version for
    // its id, or `procHP` itself if it is not a heap object.
    //
    // A mailbox is an Elm list with the newest message first.
    static HPointer mailboxPushBack(HPointer procHP, HPointer msg);

    /**
     * The result of taking the oldest message from a mailbox.
     */
    struct MailboxPopResult {
        bool hasMessage;
        HPointer newProcHP;  // The process with the message removed; `procHP` unchanged when there was none.
        HPointer msg;        // `listNil()` when there was no message.
    };
    // Takes the oldest message from the mailbox of process `procHP`. The whole mailbox is copied, so the cost is
    // linear in its length.
    static MailboxPopResult mailboxPopFront(HPointer procHP);

    // Returns a copy of process `procHP` with a frame on top of its stack that handles a Task whose
    // constructor is `expectedTag` (`Task_Succeed` or `Task_Fail`) by calling `callback`. Returns `procHP`
    // itself if it is not a heap object.
    static HPointer pushStack(HPointer procHP, u64 expectedTag, HPointer callback);

    /**
     * The result of popping stack frames up to the first that handles a given constructor.
     */
    struct PopStackResult {
        bool matched;
        HPointer newProcHP;  // The process with the frames popped.
        HPointer callback;   // The matching frame's callback; `listNil()` when none matched.
    };
    // Pops frames from the stack of process `procHP` until one with tag `tag` has been popped, and returns that
    // frame's callback. With no match, the stack is emptied. `newProcHP` is `procHP` itself only when `procHP` is
    // not a heap object.
    static PopStackResult popStackMatching(HPointer procHP, u64 tag);

    /**
     * A run-queue entry: a Process HPointer, encoded as a word the root scanner can update in place.
     */
    struct RootedProc {
        uint64_t encoded;
    };

    // The heap roots. `runQueue_`, `latestProc_`, `finishedProc_` and `pendingResumes_` hold encoded HPointers
    // and are walked by the root scanner; the other members here are not. Only `pendingResumes_` is guarded, by
    // `resumeMutex_`; the other three change on the eco thread only.
    std::deque<RootedProc> runQueue_;  // Changed under `mutex_` as well, for the event loop's wait.
    // Live process id to its latest Process value.
    std::unordered_map<u64, uint64_t> latestProc_;
    // Ids whose final value is to be kept, and the kept values awaiting `takeFinishedProcess`.
    std::unordered_set<u64> keepResult_;
    std::unordered_map<u64, uint64_t> finishedProc_;
    // Resume token to parked resume closure.
    std::unordered_map<u64, uint64_t> pendingResumes_;
    std::atomic<u64> nextResumeToken_{1};
    std::mutex resumeMutex_;
    // Process id to self-message handler. Not scanned; handlers hold no HPointers.
    std::unordered_map<u64, std::function<void(HPointer)>> selfMsgHandlers_;
    // Registered async sources as (drain, ready). Loops over it go by index and re-read the size on every step,
    // because a drain may register another source; a deque, because `push_back` does not move the elements, so
    // the `std::function` that is running survives a registration.
    std::deque<std::pair<std::function<void()>, std::function<bool()>>> asyncSources_;
    bool working_ = false;  // Set while `drain` runs; nothing reads it.
    // Resumes so far (noteResumed); eco thread only.
    u64 resumeSerial_ = 0;
    // The process `stepProcess` is stepping, while `steppingDepth_` > 0 (a step can nest: a kernel callback
    // may drain). Eco thread only.
    u64 steppingId_ = 0;
    int steppingDepth_ = 0;
    // Records the process being stepped for the scope of one `stepProcess`.
    struct SteppingScope {
        Scheduler& s;
        u64 prevId;
        SteppingScope(Scheduler& sch, u64 id) : s(sch), prevId(sch.steppingId_) {
            s.steppingId_ = id;
            ++s.steppingDepth_;
        }
        ~SteppingScope() {
            s.steppingId_ = prevId;
            --s.steppingDepth_;
        }
    };
    // Guards the run queue against the event loop's wait, and the quiescence listeners. Taken briefly before
    // every notification of `eventCV_`, so that a wake-up cannot fall between the loop's check and its wait.
    std::mutex mutex_;
    std::condition_variable eventCV_;
    // The number of live holds.
    std::atomic<int> pendingAsync_{0};
    // Adds one live hold. Called only by `noteAcquire`, so that every hold has a token.
    void incrementPendingAsync();
    // Removes one live hold and wakes the event loop. Called only by `releaseHold`.
    void decrementPendingAsync();
    // The hold census, declared in every build so that the class layout does not depend on `NDEBUG`, and filled
    // only when `holdCensusEnabled()`. `holdsMutex_` guards `holds_` and `holdlessParks_`. It is a leaf lock:
    // nothing else is taken while it is held, and it is never taken under `mutex_`.
    std::mutex holdsMutex_;
    std::unordered_map<HoldToken, std::pair<HoldKind, const char*>> holds_;  // Token to (kind, site).
    std::vector<std::pair<const char*, u64>> holdlessParks_;                // Binding name to count.
    std::atomic<u64> nextHoldId_{1};
    // Free-standing Host holds, which do not count as busy. Also counts resume-keyed Host holds, which are
    // never subtracted.
    std::atomic<int> hostHolds_{0};
    std::atomic<u64> acquireSerial_{0};
    std::atomic<u64> enqueueSerial_{0};
    int drainDepth_ = 0;
    // Counts the acquisition of hold `t` of kind `kind` from `site`: in the census, in the Host count, and in
    // the number of live holds. Census builds abort if `t` is already live.
    void noteAcquire(HoldToken t, HoldKind kind, const char* site);
    // The activity hook. Plain members, so they must be set before the loop runs. `activityUser_` is the
    // embedder's, may be null, and is passed through unread. `lastActivityBusy_` is the last state reported,
    // touched only by the eco thread; it starts true, so the first report is an idle one.
    ActivityHook activityHook_ = nullptr;
    void* activityUser_ = nullptr;
    bool lastActivityBusy_ = true;
    // Calls the activity hook with `busy` if it differs from the last state reported.
    void fireActivity(bool busy);
    std::atomic<u64> nextProcId_{0};
    std::atomic<bool> stopRequested_{false};
    std::atomic<bool> embedMode_{false};
    // Guarded by `mutex_`.
    std::vector<std::pair<QuiescenceListener, void*>> quiescenceListeners_;
    // Eco thread only.
    std::vector<StopHook> stopHooks_;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_SCHEDULER_HPP
