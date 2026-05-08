#include "Scheduler.hpp"
#include "TimerService.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include <cstdio>
#include <cstring>

using namespace Elm;
using namespace Elm::alloc;

namespace Elm::Platform {

// Encode/decode helpers (same as ExportHelpers but without kernel dependency)
static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

static inline bool isConstant(HPointer h) {
    return h.constant != 0;
}

static inline void* resolveHP(HPointer h) {
    if (isConstant(h)) return nullptr;
    return Allocator::instance().resolve(h);
}

// ============================================================================
// Singleton
// ============================================================================

Scheduler& Scheduler::instance() {
    static Scheduler sched;
    return sched;
}

Scheduler::Scheduler() {
    // Register external root scanner so the GC can trace processes in the run
    // queue AND the latest-process registry. Both hold encoded HPointers to
    // live Process values that must survive minor GC. The slow form is used
    // because the constructor may run before the calling thread has been
    // registered with `initThread()`.
    Allocator::instance().getRootSetSlow().addExternalRootScanner(
        [this](RootSet::EvacuateFn evacuate) {
            for (auto& rp : runQueue_) {
                evacuate(rp.encoded);
            }
            for (auto& [id, enc] : latestProc_) {
                evacuate(enc);
            }
            // Resume closures held by in-flight async ops. The lock
            // guards against concurrent register/take from other threads.
            std::lock_guard<std::mutex> lock(resumeMutex_);
            for (auto& [token, enc] : pendingResumes_) {
                evacuate(enc);
            }
        });
}

void Scheduler::registerLatestProcess(HPointer proc) {
    void* ptr = resolveHP(proc);
    if (!ptr) return;
    u32 id = static_cast<u32>(static_cast<Process*>(ptr)->id);
    latestProc_[id] = encodeHP(proc);
}

HPointer Scheduler::latestProcessById(u32 id) {
    auto it = latestProc_.find(id);
    if (it == latestProc_.end()) return listNil();
    return decodeHP(it->second);
}

u64 Scheduler::registerPendingResume(HPointer resume) {
    u64 token = nextResumeToken_.fetch_add(1);
    std::lock_guard<std::mutex> lock(resumeMutex_);
    pendingResumes_[token] = encodeHP(resume);
    return token;
}

HPointer Scheduler::takePendingResume(u64 token) {
    std::lock_guard<std::mutex> lock(resumeMutex_);
    auto it = pendingResumes_.find(token);
    if (it == pendingResumes_.end()) return listNil();
    HPointer hp = decodeHP(it->second);
    pendingResumes_.erase(it);
    return hp;
}

HPointer Scheduler::latestProcessByHPtr(HPointer originalHP) {
    void* ptr = resolveHP(originalHP);
    if (!ptr) return listNil();
    u32 id = static_cast<u32>(static_cast<Process*>(ptr)->id);
    return latestProcessById(id);
}

// ============================================================================
// Task Constructors
// ============================================================================

HPointer Scheduler::taskSucceed(HPointer value) {
    HPointer nil = listNil();
    return allocTask(Task_Succeed, value, nil, nil, nil);
}

HPointer Scheduler::taskSucceedKind(Unboxable value, u8 kind) {
    HPointer nil = listNil();
    if ((kind & 0x3) == 0) {
        // Caller asked for an unboxed payload but kind=0 means boxed; fall
        // through to the HPointer path so the value's `.p` is treated as a
        // pointer by the GC scanners.
        return allocTask(Task_Succeed, value.p, nil, nil, nil);
    }
    return allocTaskUnboxed(Task_Succeed, value, kind, nil, nil, nil);
}

HPointer Scheduler::taskFail(HPointer error) {
    HPointer nil = listNil();
    return allocTask(Task_Fail, error, nil, nil, nil);
}

HPointer Scheduler::taskBinding(HPointer callback) {
    HPointer nil = listNil();
    return allocTask(Task_Binding, nil, callback, nil, nil);
}

HPointer Scheduler::taskAndThen(HPointer callback, HPointer task) {
    HPointer nil = listNil();
    return allocTask(Task_AndThen, nil, callback, nil, task);
}

HPointer Scheduler::taskOnError(HPointer callback, HPointer task) {
    HPointer nil = listNil();
    return allocTask(Task_OnError, nil, callback, nil, task);
}

HPointer Scheduler::taskReceive(HPointer callback) {
    HPointer nil = listNil();
    return allocTask(Task_Receive, nil, callback, nil, nil);
}

// ============================================================================
// Closure Calling
// ============================================================================

HPointer Scheduler::callClosure1(HPointer closurePtr, HPointer arg) {
    // Encode argument as uint64_t to survive GC
    uint64_t argEnc = encodeHP(arg);
    HPtr closureHPtr = HPtr::fromBits(encodeHP(closurePtr));

    // Use eco_apply_closure which handles PAP/saturated correctly
    HPtr result = eco_apply_closure(closureHPtr, &argEnc, 1);
    return decodeHP(result.toBits());
}

HPointer Scheduler::callClosure2(HPointer closurePtr, HPointer arg1, HPointer arg2) {
    uint64_t args[2];
    args[0] = encodeHP(arg1);
    args[1] = encodeHP(arg2);
    HPtr closureHPtr = HPtr::fromBits(encodeHP(closurePtr));

    HPtr result = eco_apply_closure(closureHPtr, args, 2);
    return decodeHP(result.toBits());
}

HPointer Scheduler::callClosure4(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                  HPointer arg3, HPointer arg4) {
    uint64_t args[4];
    args[0] = encodeHP(arg1);
    args[1] = encodeHP(arg2);
    args[2] = encodeHP(arg3);
    args[3] = encodeHP(arg4);
    HPtr closureHPtr = HPtr::fromBits(encodeHP(closurePtr));

    HPtr result = eco_apply_closure(closureHPtr, args, 4);
    return decodeHP(result.toBits());
}

// ============================================================================
// Process value constructors (immutable replacement)
// ============================================================================

// `procWith*` allocate a new Process with all fields copied from `src`
// except the specified one. The Process heap object is logically immutable;
// every "mutation" is implemented as "allocate a new value, discard the old".
// This eliminates the old→young pointer that would otherwise arise when an
// old-gen Process has its stack/root/mailbox field overwritten with a fresh
// nursery HPointer — see the detailed report in test-fails.md.

HPointer Scheduler::procWithRoot(HPointer srcHP, HPointer newRoot) {
    void* srcPtr = resolveHP(srcHP);
    if (!srcPtr) return listNil();
    Process* src = static_cast<Process*>(srcPtr);
    u16 id = static_cast<u16>(src->id);
    HPointer oldStack = src->stack;
    HPointer oldMailbox = src->mailbox;
    // Root the by-value locals across allocProcess (see procWithStack).
    Elm::StackRootGuard guard(&newRoot, &oldStack, &oldMailbox);
    HPointer newHP = allocProcess(id, newRoot, oldStack, oldMailbox);
    Scheduler::instance().registerLatestProcess(newHP);
    return newHP;
}

HPointer Scheduler::procWithStack(HPointer srcHP, HPointer newStack) {
    void* srcPtr = resolveHP(srcHP);
    if (!srcPtr) return listNil();
    Process* src = static_cast<Process*>(srcPtr);
    u16 id = static_cast<u16>(src->id);
    HPointer oldRoot = src->root;
    HPointer oldMailbox = src->mailbox;
    // Root the by-value locals across allocProcess: the Process object
    // pointed to by srcHP is reachable via the scheduler scanner, but
    // these are independent HPointer locals to its fields and to the
    // caller-supplied newStack. allocProcess is a GC point.
    Elm::StackRootGuard guard(&oldRoot, &newStack, &oldMailbox);
    HPointer newHP = allocProcess(id, oldRoot, newStack, oldMailbox);
    Scheduler::instance().registerLatestProcess(newHP);
    return newHP;
}

HPointer Scheduler::procWithMailbox(HPointer srcHP, HPointer newMailbox) {
    void* srcPtr = resolveHP(srcHP);
    if (!srcPtr) return listNil();
    Process* src = static_cast<Process*>(srcPtr);
    u16 id = static_cast<u16>(src->id);
    HPointer oldRoot = src->root;
    HPointer oldStack = src->stack;
    HPointer newHP = allocProcess(id, oldRoot, oldStack, newMailbox);
    Scheduler::instance().registerLatestProcess(newHP);
    return newHP;
}

// ============================================================================
// Mailbox Helpers (Elm List as FIFO queue)
// ============================================================================

// Push message to back of mailbox. Returns a new Process HPointer with the
// updated mailbox; the old Process becomes garbage.
HPointer Scheduler::mailboxPushBack(HPointer procHP, HPointer msg) {
    // Read old mailbox (we keep its HPointer rooted via procHP in the caller).
    void* procPtr = resolveHP(procHP);
    if (!procPtr) return procHP;
    HPointer oldMailbox = static_cast<Process*>(procPtr)->mailbox;
    // cons() allocates — may GC. procHP is rooted (the caller's responsibility)
    // and oldMailbox is reachable via the old Process so survives evacuation.
    HPointer newCell = cons(boxed(msg), oldMailbox, true);
    // Build new Process with new mailbox.
    return procWithMailbox(procHP, newCell);
}

// Pop oldest message from mailbox. Returns { hasMessage, newProcHP, msg }.
Scheduler::MailboxPopResult Scheduler::mailboxPopFront(HPointer procHP) {
    void* procPtr = resolveHP(procHP);
    if (!procPtr) return {false, procHP, listNil()};
    Process* proc = static_cast<Process*>(procPtr);
    HPointer mailbox = proc->mailbox;
    if (alloc::isNil(mailbox)) return {false, procHP, listNil()};

    // Reverse the list to get FIFO order, then take the head.
    // procHP, mailbox, reversed, current all need to survive each cons() — any
    // of them can be moved by GC inside cons.
    HPointer reversed = listNil();
    HPointer current = mailbox;
    {
        Elm::StackRootGuard guard(&procHP, &mailbox, &reversed, &current);
        while (!alloc::isNil(current)) {
            void* ptr = resolveHP(current);
            if (!ptr) break;
            Cons* cell = static_cast<Cons*>(ptr);
            // Snapshot head/tail BEFORE cons allocates — `cell` becomes stale
            // afterwards.
            Unboxable head = cell->head;
            HPointer next = cell->tail;
            reversed = cons(head, reversed, true);
            current = next;
        }
    }

    // Take head of reversed (this is the oldest message).
    void* revPtr = resolveHP(reversed);
    if (!revPtr) return {false, procHP, listNil()};
    Cons* revCell = static_cast<Cons*>(revPtr);
    HPointer outMsg = revCell->head.p;

    // Rest of reversed becomes the new mailbox (re-reversed back to LIFO order).
    HPointer rest = revCell->tail;
    HPointer newMailbox = listNil();
    HPointer cur2 = rest;
    {
        Elm::StackRootGuard guard(&procHP, &outMsg, &newMailbox, &cur2);
        while (!alloc::isNil(cur2)) {
            void* p = resolveHP(cur2);
            if (!p) break;
            Cons* c = static_cast<Cons*>(p);
            Unboxable head = c->head;
            HPointer next = c->tail;
            newMailbox = cons(head, newMailbox, true);
            cur2 = next;
        }
    }
    HPointer newProcHP = procWithMailbox(procHP, newMailbox);
    return {true, newProcHP, outMsg};
}

// ============================================================================
// Stack Helpers (Elm List of StackFrame Custom objects)
// ============================================================================

HPointer Scheduler::pushStack(HPointer procHP, u64 expectedTag, HPointer callback) {
    // stackFrame() and procWithStack() both allocate and may trigger GC.
    // Even though `procHP`'s *target* (the Process object) is reachable
    // via the external scanner / runQueue, the by-value local copy of
    // `procHP` is NOT — it lives in this frame and the GC has no way to
    // find it. After the alloc, the local would still hold the
    // pre-evacuation address. Same for `callback`, which is held by-value
    // across stackFrame's GC point.
    Elm::StackRootGuard guard(&procHP, &callback);

    void* procPtr = resolveHP(procHP);
    if (!procPtr) return procHP;
    HPointer oldStack = static_cast<Process*>(procPtr)->stack;
    HPointer frame = stackFrame(expectedTag, callback, oldStack);
    return procWithStack(procHP, frame);
}

Scheduler::PopStackResult Scheduler::popStackMatching(HPointer procHP, u64 tag) {
    // Walk the stack looking for a frame whose expectedTag matches.
    // Pop non-matching frames as we go (like the JS version). This pure-read
    // walk does not allocate, so `procHP` stays valid throughout.
    void* procPtr = resolveHP(procHP);
    if (!procPtr) return {false, procHP, listNil()};
    HPointer curStack = static_cast<Process*>(procPtr)->stack;

    while (!alloc::isNil(curStack)) {
        void* ptr = resolveHP(curStack);
        if (!ptr) {
            // Walked off the stack list without a match — produce new Process
            // with empty stack so the caller's next attempt starts clean.
            HPointer nil = listNil();
            HPointer newProc = procWithStack(procHP, nil);
            return {false, newProc, listNil()};
        }
        // Stack is a linked list of StackFrame Custom objects.
        // StackFrame: Custom with ctor=CTOR_StackFrame
        //   values[0] = expectedTag (unboxed i64)
        //   values[1] = callback    (boxed HPointer)
        //   values[2] = rest        (boxed HPointer = next frame in stack)
        Custom* frame = static_cast<Custom*>(ptr);
        u64 frameTag = frame->values[0].i;
        HPointer frameCallback = frame->values[1].p;
        HPointer rest = frame->values[2].p;

        curStack = rest;

        if (frameTag == tag) {
            // procWithStack may GC; `rest` is still reachable from the source
            // Process's stack slot (unchanged), and `frameCallback` was read
            // out as a local HPointer value, but the Process object survives
            // via procHP so its stack chain (including our `rest` pointee)
            // is traced through. Since `rest` and `frameCallback` are local
            // HPointers, we root them explicitly around procWithStack.
            StackRootGuard g(&rest, &frameCallback);
            HPointer newProc = procWithStack(procHP, rest);
            return {true, newProc, frameCallback};
        }
        // Non-matching frame: continue with the rest.
    }
    // Empty stack — still produce a new Process with nil stack so callers see
    // a consistent "post-pop" Process even on the miss path.
    HPointer nil2 = listNil();
    HPointer newProc = procWithStack(procHP, nil2);
    return {false, newProc, listNil()};
}

// ============================================================================
// Process API
// ============================================================================

HPointer Scheduler::rawSpawn(HPointer rootTask) {
    u32 id = nextProcessId();
    HPointer nil = listNil();
    HPointer proc = allocProcess(static_cast<u16>(id), rootTask, nil, nil);

    // Register as the current-latest Process for this id so external holders
    // of the returned HPointer can find subsequent versions after drain.
    registerLatestProcess(proc);
    enqueue(proc);
    return proc;
}

// C function used as the evaluator for "resume" closures
// Captured value: args[0] = process HPointer (encoded)
// Argument: args[1] = new task HPointer (encoded)
//
// Produces a *new* Process with the given root and enqueues it. The old
// Process (captured when the resume closure was built) becomes garbage.
static void* resumeEvaluator(void* args[]) {
    uint64_t procEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t taskEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer procHP = decodeHP(procEnc);
    HPointer newTask = decodeHP(taskEnc);

    if (resolveHP(procHP)) {
        HPointer newProcHP = Scheduler::procWithRoot(procHP, newTask);
        Scheduler::instance().enqueue(newProcHP);
    }

    return reinterpret_cast<void*>(encodeHP(unit()));
}

HPointer Scheduler::spawnTask(HPointer rootTask) {
    // Returns a Task that, when run, spawns a process and succeeds with the Process handle
    // This is a binding task
    // But for simplicity, since spawn is synchronous, we can do it directly:
    // spawn creates a process and returns Task.succeed(process)
    HPointer proc = rawSpawn(rootTask);
    return taskSucceed(proc);
}

void Scheduler::rawSend(HPointer procHP, HPointer msg) {
    void* ptr = resolveHP(procHP);
    if (!ptr) return;
    // mailboxPushBack returns a new Process HPointer; we enqueue THAT (not
    // the stale procHP). The old Process becomes garbage once the run queue
    // stops referring to it.
    HPointer newProcHP = mailboxPushBack(procHP, msg);
    enqueue(newProcHP);
}

HPointer Scheduler::killTask(HPointer procHP) {
    // Kill returns Task.succeed(Unit) after attempting to kill the target
    // process's currently-active Task_Binding (if any). It does NOT mutate
    // the target Process. Since callers pass the old HPointer and nothing in
    // the scheduler's outstanding state tracks them, the effect is that any
    // future dequeue of the target continues to see the old root. This is a
    // best-effort kill — a full solution would need runQueue-side bookkeeping
    // per logical process id, which is outside the scope of this change.
    void* ptr = resolveHP(procHP);
    if (ptr) {
        Process* proc = static_cast<Process*>(ptr);
        void* rootPtr = resolveHP(proc->root);
        if (rootPtr) {
            Task* rootTask = static_cast<Task*>(rootPtr);
            if (rootTask->ctor == Task_Binding) {
                void* killPtr = resolveHP(rootTask->kill);
                if (killPtr) {
                    callClosure1(rootTask->kill, unit());
                }
            }
        }
    }
    return taskSucceed(unit());
}

// ============================================================================
// Run Queue
// ============================================================================

void Scheduler::enqueue(HPointer proc) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        RootedProc rp;
        rp.encoded = encodeHP(proc);
        runQueue_.push_back(rp);
    }
    eventCV_.notify_one();

    // If we're already inside drain() on the main thread, the newly enqueued
    // process will be picked up by drain's loop. Otherwise, the event loop
    // (runEventLoop) will wake up and call drain().
}

void Scheduler::drain() {
    working_ = true;

    while (true) {
        uint64_t procEnc;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (runQueue_.empty()) break;
            procEnc = runQueue_.front().encoded;
            runQueue_.pop_front();
        }
        stepProcess(procEnc);
    }

    working_ = false;
}

void Scheduler::runEventLoop() {
    while (true) {
        drain();               // run all queued work on main thread
        processReadyAsync();   // resolve any fired timers; may enqueue procs

        // If processReadyAsync produced new work, drain it before sleeping;
        // otherwise the predicate below would trivially pass and we'd take
        // an extra lap through wait+drain for no reason.
        if (!runQueue_.empty()) continue;

        std::unique_lock<std::mutex> lock(mutex_);
        if (runQueue_.empty() && pendingAsync_.load() == 0) break;
        // Also wake if the timer worker pushed a token after our last
        // processReadyAsync but before we took the lock — closes the
        // missed-wakeup window.
        eventCV_.wait(lock, [this] {
            return !runQueue_.empty()
                || pendingAsync_.load() == 0
                || TimerService::instance().hasReadyTokens();
        });
    }
}

void Scheduler::incrementPendingAsync() {
    pendingAsync_.fetch_add(1);
}

void Scheduler::decrementPendingAsync() {
    pendingAsync_.fetch_sub(1);
    eventCV_.notify_one();
}

void Scheduler::notifyWorkAvailableFromAsync() {
    // Taking mutex_ is cheap and mirrors the enqueue/decrementPendingAsync
    // pattern; it closes the missed-wakeup window where the predicate could
    // observe empty state just before a worker's ready-queue push.
    std::lock_guard<std::mutex> lk(mutex_);
    eventCV_.notify_one();
}

void Scheduler::processReadyAsync() {
    std::uint64_t token;
    while (TimerService::instance().tryPopReadyToken(token)) {
        HPointer resumeClosure = takePendingResume(token);
        if (alloc::isNil(resumeClosure)) {
            decrementPendingAsync();
            continue;
        }
        // Root resumeClosure and succeedTask across taskSucceed +
        // callClosure1, both of which may trigger GC inside the callee.
        HPointer succeedTask = listNil();
        {
            StackRootGuard guard(&resumeClosure, &succeedTask);
            succeedTask = taskSucceed(unit());
            callClosure1(resumeClosure, succeedTask);
        }
        decrementPendingAsync();
    }
}

// ============================================================================
// Step Loop
// ============================================================================

namespace {

struct EncodedStackRootGuard {
    size_t saved_;
    EncodedStackRootGuard(uint64_t* slot) {
        saved_ = eco_gc_stack_range_point();
        eco_gc_push_stack_range(slot, 1, /*hpointer_mask=*/1);
    }
    ~EncodedStackRootGuard() {
        eco_gc_restore_stack_range_point(saved_);
    }
    EncodedStackRootGuard(const EncodedStackRootGuard&) = delete;
    EncodedStackRootGuard& operator=(const EncodedStackRootGuard&) = delete;
};

} // namespace

void Scheduler::stepProcess(uint64_t procEncoded) {
    // Root procEncoded as an encoded HPointer stack value so GC updates it
    // in place when the Process is evacuated out of the nursery.
    EncodedStackRootGuard root_guard(&procEncoded);

    // Helper lambdas to re-resolve proc from the GC-rooted procEncoded.
    // After any GC point (allocation, closure call), all raw pointers and
    // HPointers read from heap objects are potentially stale. Re-read
    // everything from the rooted procEncoded.
    auto currentProcHP = [&]() -> HPointer { return decodeHP(procEncoded); };
    auto resolveProc = [&]() -> Process* {
        HPointer hp = currentProcHP();
        void* ptr = resolveHP(hp);
        return ptr ? static_cast<Process*>(ptr) : nullptr;
    };
    auto resolveRoot = [&](Process* proc) -> Task* {
        if (!proc) return nullptr;
        HPointer rootHP = proc->root;
        if (alloc::isNil(rootHP) || isConstant(rootHP)) return nullptr;
        void* ptr = resolveHP(rootHP);
        return ptr ? static_cast<Task*>(ptr) : nullptr;
    };

    // Replace the stepped Process with a new one that has the given root.
    // The OLD Process becomes garbage immediately after this returns; any
    // captured/rooted references outside this function (e.g. runQueue
    // entries queued by earlier resumeEvaluator calls) see their *own*
    // Process version, not this one.
    auto setRoot = [&](HPointer newRoot) {
        HPointer newHP = Scheduler::procWithRoot(currentProcHP(), newRoot);
        procEncoded = encodeHP(newHP);
    };

    if (!resolveProc()) return;

    while (true) {
        Process* proc = resolveProc();
        if (!proc) break;

        Task* task = resolveRoot(proc);
        if (!task) break;
        u16 ctor = task->ctor;

        if (ctor == Task_Succeed || ctor == Task_Fail) {
            u64 searchTag = (ctor == Task_Succeed) ? Task_Succeed : Task_Fail;

            // popStackMatching returns a new Process with the popped stack;
            // update procEncoded so every subsequent resolveProc sees the
            // post-pop Process, not the pre-pop one.
            PopStackResult popRes = popStackMatching(currentProcHP(), searchTag);
            procEncoded = encodeHP(popRes.newProcHP);

            if (popRes.matched) {
                proc = resolveProc();
                if (!proc) break;
                task = resolveRoot(proc);
                if (!task) break;
                // Closure ABI takes a boxed HPointer arg; re-box if Task.value
                // was carried unboxed. The saving is upstream — no boxed
                // primitive lived across the andThen chain or any GCs in
                // between — we only pay the alloc here, at dispatch.
                HPointer taskValue;
                u8 valKind = static_cast<u8>(task->header.unboxed & 0x3);
                if (valKind == 0) {
                    taskValue = task->value.p;
                } else {
                    Unboxable v = task->value;
                    switch (valKind) {
                        case 1:
                            taskValue = eco_alloc_int(v.i).toHPointer();
                            break;
                        case 2:
                            taskValue = eco_alloc_float(v.f).toHPointer();
                            break;
                        default:
                            taskValue = eco_alloc_char(static_cast<uint32_t>(v.c)).toHPointer();
                            break;
                    }
                }
                HPointer callback = popRes.callback;

                HPointer newTask = callClosure1(callback, taskValue);
                setRoot(newTask);
                continue;
            } else {
                // No matching handler — process finished (Task_Succeed) or
                // failed unhandled (Task_Fail).
                if (ctor == Task_Fail) {
                    std::fprintf(stderr,
                        "[eco-runtime] unhandled top-level Task.fail "
                        "(no surrounding Task.onError) — failure value dropped\n");
                    std::fflush(stderr);
                }
                break;
            }
        }
        else if (ctor == Task_AndThen) {
            // Snapshot the callback and the inner task BEFORE any allocation,
            // since pushStack / procWith* may trigger GC and move `task`.
            // innerTask must remain rooted across pushStack so the GC updates
            // it to its post-evacuation location before setRoot reads it.
            HPointer callback = task->callback;
            HPointer innerTask = task->task;
            Elm::StackRootGuard guard(&innerTask);

            // Push the Task_Succeed continuation, then replace the root
            // with the inner task. Two steps, each producing a new Process.
            HPointer afterPush = pushStack(currentProcHP(), Task_Succeed, callback);
            procEncoded = encodeHP(afterPush);
            setRoot(innerTask);
            continue;
        }
        else if (ctor == Task_OnError) {
            HPointer callback = task->callback;
            HPointer innerTask = task->task;
            Elm::StackRootGuard guard(&innerTask);

            HPointer afterPush = pushStack(currentProcHP(), Task_Fail, callback);
            procEncoded = encodeHP(afterPush);
            setRoot(innerTask);
            continue;
        }
        else if (ctor == Task_Binding) {
            // allocClosure can trigger GC — snapshot the bind callback first
            // and root it across allocClosure.
            HPointer bindCallback = task->callback;
            Elm::StackRootGuard guard(&bindCallback);

            HPointer resumeClosure = allocClosure(
                reinterpret_cast<EvalFunction>(resumeEvaluator), 2);
            void* clPtr = resolveHP(resumeClosure);
            if (clPtr) {
                // The resume closure captures *this snapshot* of the Process
                // HPointer. Once user code invokes the resume closure, a new
                // Process will be built from that snapshot via
                // procWithRoot — any updates we made here between now and
                // the resume running are ignored (but for a fresh binding
                // we've made no updates, so this is equivalent).
                closureCapture(clPtr, boxed(currentProcHP()), true);
            }

            HPointer killHandle = callClosure1(bindCallback, resumeClosure);

            // Re-resolve; the user's bind callback may have enqueued tasks
            // of its own (which walk through their own setRoot sequence).
            proc = resolveProc();
            if (!proc) break;

            // Install killHandle onto the current root if it's still a
            // Task_Binding. Task heap objects ARE still allowed to be
            // mutated in-place — only Process is logically immutable in
            // this change — because tasks are one-shot and don't share the
            // long-lived-root problem. (See test-fails.md root-cause report.)
            void* newRootPtr = resolveHP(proc->root);
            if (newRootPtr) {
                Task* currentTask = static_cast<Task*>(newRootPtr);
                if (currentTask->ctor == Task_Binding) {
                    currentTask->kill = killHandle;
                }
            }

            // Process suspends here; it will be re-enqueued (with a fresh
            // Process value) by resumeEvaluator when the async op completes.
            break;
        }
        else if (ctor == Task_Receive) {
            MailboxPopResult popRes = mailboxPopFront(currentProcHP());
            procEncoded = encodeHP(popRes.newProcHP);
            if (popRes.hasMessage) {
                proc = resolveProc();
                if (!proc) break;
                task = resolveRoot(proc);
                if (!task) break;
                HPointer recvCallback = task->callback;

                HPointer newTask = callClosure1(recvCallback, popRes.msg);
                setRoot(newTask);
                continue;
            } else {
                // No messages - block
                break;
            }
        }
        else {
            // Unknown task ctor
            break;
        }
    }
}

} // namespace Elm::Platform
