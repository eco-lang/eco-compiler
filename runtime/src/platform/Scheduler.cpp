#include "Scheduler.hpp"
#include "TaskBinding.hpp"
#include "TimerService.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

using namespace Elm;
using namespace Elm::alloc;

namespace Elm::Platform {

// Returns the 64-bit word of `h`, the form in which this file keeps HPointers in containers and roots.
static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

// Returns the HPointer whose word is `val`; the inverse of `encodeHP`.
static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

// Returns whether `h` is an embedded constant rather than a heap object.
static inline bool isConstant(HPointer h) {
    return h.ptr_ind != 0;
}

// Returns the address of the heap object `h` points to, or null if `h` is an embedded constant.
static inline void* resolveHP(HPointer h) {
    if (isConstant(h)) return nullptr;
    return Allocator::instance().resolve(h);
}

// ============================================================================
// Singleton
// ============================================================================

Scheduler& Scheduler::instance() {
    // Leaked on purpose: the eco thread may still be running when the process
    // exits (a host calling exit()), and a static destructor freeing scheduler
    // state under a live thread would be a use-after-free.
    static Scheduler* sched = new Scheduler();
    return *sched;
}

Scheduler::Scheduler() {
    // The slow form initialises the calling thread's heap if it has none yet.
    Allocator::instance().getRootSetSlow().addExternalRootScanner(
        [this](RootSet::EvacuateFn evacuate) {
            for (auto& rp : runQueue_) {
                evacuate(rp.encoded);
            }
            for (auto& [id, enc] : latestProc_) {
                evacuate(enc);
            }
            for (auto& [id, enc] : finishedProc_) {
                evacuate(enc);
            }
            // Only the resume table can change on another thread.
            std::lock_guard<std::mutex> lock(resumeMutex_);
            for (auto& [token, enc] : pendingResumes_) {
                evacuate(enc);
            }
        });
}

void Scheduler::registerLatestProcess(HPointer proc) {
    void* ptr = resolveHP(proc);
    if (!ptr) return;
    u64 id = static_cast<Process*>(ptr)->id;
    latestProc_[id] = encodeHP(proc);
}

void Scheduler::updateLatestProcess(HPointer proc) {
    void* ptr = resolveHP(proc);
    if (!ptr) return;
    auto it = latestProc_.find(static_cast<Process*>(ptr)->id);
    if (it != latestProc_.end()) it->second = encodeHP(proc);
}

void Scheduler::processKilled(u64 id) {
    latestProc_.erase(id);
    selfMsgHandlers_.erase(id);
}

HPointer Scheduler::latestProcessById(u64 id) {
    auto it = latestProc_.find(id);
    if (it == latestProc_.end()) return listNil();
    return decodeHP(it->second);
}

void Scheduler::processFinished(HPointer proc) {
    void* ptr = resolveHP(proc);
    if (!ptr) return;
    u64 id = static_cast<Process*>(ptr)->id;
    latestProc_.erase(id);
    selfMsgHandlers_.erase(id);
    if (keepResult_.erase(id)) finishedProc_[id] = encodeHP(proc);
}

void Scheduler::keepResultOnFinish(u64 id) {
    keepResult_.insert(id);
}

HPointer Scheduler::takeFinishedProcess(u64 id) {
    keepResult_.erase(id);
    auto it = finishedProc_.find(id);
    if (it == finishedProc_.end()) return listNil();
    HPointer hp = decodeHP(it->second);
    finishedProc_.erase(it);
    return hp;
}

void Scheduler::registerSelfProcess(u64 procId,
                                    std::function<void(HPointer)> handler) {
    selfMsgHandlers_[procId] = std::move(handler);
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

void Scheduler::registerAsyncSource(std::function<void()> drain,
                                    std::function<bool()> ready) {
    asyncSources_.emplace_back(std::move(drain), std::move(ready));
}

HPointer Scheduler::latestProcessByHPtr(HPointer originalHP) {
    void* ptr = resolveHP(originalHP);
    if (!ptr) return listNil();
    return latestProcessById(static_cast<Process*>(ptr)->id);
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

HPointer Scheduler::callClosure3(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                  HPointer arg3) {
    uint64_t args[3];
    args[0] = encodeHP(arg1);
    args[1] = encodeHP(arg2);
    args[2] = encodeHP(arg3);
    HPtr closureHPtr = HPtr::fromBits(encodeHP(closurePtr));

    HPtr result = eco_apply_closure(closureHPtr, args, 3);
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

// A Process is replaced, never written, so no old-generation Process is ever
// made to point at a young object; there is no write barrier to catch that.

HPointer Scheduler::procWithRoot(HPointer srcHP, HPointer newRoot) {
    void* srcPtr = resolveHP(srcHP);
    if (!srcPtr) return listNil();
    Process* src = static_cast<Process*>(srcPtr);
    u64 id = src->id;
    HPointer oldStack = src->stack;
    HPointer oldMailbox = src->mailbox;
    // Root the by-value locals across allocProcess (see procWithStack).
    Elm::StackRootGuard guard(&newRoot, &oldStack, &oldMailbox);
    HPointer newHP = allocProcess(id, newRoot, oldStack, oldMailbox);
    Scheduler::instance().updateLatestProcess(newHP);
    return newHP;
}

HPointer Scheduler::procWithStack(HPointer srcHP, HPointer newStack) {
    void* srcPtr = resolveHP(srcHP);
    if (!srcPtr) return listNil();
    Process* src = static_cast<Process*>(srcPtr);
    u64 id = src->id;
    HPointer oldRoot = src->root;
    HPointer oldMailbox = src->mailbox;
    // Root the by-value locals across allocProcess: the Process object
    // pointed to by srcHP is reachable via the scheduler scanner, but
    // these are independent HPointer locals to its fields and to the
    // caller-supplied newStack. allocProcess is a GC point.
    Elm::StackRootGuard guard(&oldRoot, &newStack, &oldMailbox);
    HPointer newHP = allocProcess(id, oldRoot, newStack, oldMailbox);
    Scheduler::instance().updateLatestProcess(newHP);
    return newHP;
}

HPointer Scheduler::procWithMailbox(HPointer srcHP, HPointer newMailbox) {
    void* srcPtr = resolveHP(srcHP);
    if (!srcPtr) return listNil();
    Process* src = static_cast<Process*>(srcPtr);
    u64 id = src->id;
    HPointer oldRoot = src->root;
    HPointer oldStack = src->stack;
    HPointer newHP = allocProcess(id, oldRoot, oldStack, newMailbox);
    Scheduler::instance().updateLatestProcess(newHP);
    return newHP;
}

// ============================================================================
// Mailbox Helpers (Elm List as FIFO queue)
// ============================================================================

HPointer Scheduler::mailboxPushBack(HPointer procHP, HPointer msg) {
    void* procPtr = resolveHP(procHP);
    if (!procPtr) return procHP;
    HPointer oldMailbox = static_cast<Process*>(procPtr)->mailbox;
    // cons() may collect. procHP is reused below, so it is rooted here; a
    // guard in the caller roots only the caller's own copy. cons roots its
    // own arguments.
    Elm::StackRootGuard guard(&procHP);
    HPointer newCell = cons(boxed(msg), oldMailbox, true);
    return procWithMailbox(procHP, newCell);
}

Scheduler::MailboxPopResult Scheduler::mailboxPopFront(HPointer procHP) {
    void* procPtr = resolveHP(procHP);
    if (!procPtr) return {false, procHP, listNil()};
    Process* proc = static_cast<Process*>(procPtr);
    HPointer mailbox = proc->mailbox;
    if (alloc::isNil(mailbox)) return {false, procHP, listNil()};

    // The mailbox is newest first: reverse it, take the head, and reverse the
    // rest back. Every local below crosses a cons(), which may collect.
    //
    // Mailboxes are built only by this file's cons() calls, so they are plain
    // Cons cells and the raw walks below need no chunked-list handling.
    HPointer reversed = listNil();
    HPointer current = mailbox;
    HPointer next = listNil();
    {
        Elm::StackRootGuard guard({&procHP, &mailbox, &reversed, &current, &next});
        while (!alloc::isNil(current)) {
            void* ptr = resolveHP(current);
            if (!ptr) break;
            Cons* cell = static_cast<Cons*>(ptr);
            // Snapshot head/tail BEFORE cons allocates — `cell` becomes stale
            // afterwards.
            Unboxable head = cell->head;
            next = cell->tail;
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
    HPointer next2 = listNil();
    {
        // next2 (the tail snapshot advancing cur2) crosses each cons GC
        // point, so it is rooted alongside the other loop state.
        Elm::StackRootGuard guard({&procHP, &outMsg, &newMailbox, &cur2, &next2});
        while (!alloc::isNil(cur2)) {
            void* p = resolveHP(cur2);
            if (!p) break;
            Cons* c = static_cast<Cons*>(p);
            Unboxable head = c->head;
            next2 = c->tail;
            newMailbox = cons(head, newMailbox, true);
            cur2 = next2;
        }
    }
    HPointer newProcHP = procWithMailbox(procHP, newMailbox);
    return {true, newProcHP, outMsg};
}

// ============================================================================
// Stack Helpers (Elm List of StackFrame Custom objects)
// ============================================================================

HPointer Scheduler::pushStack(HPointer procHP, u64 expectedTag, HPointer callback) {
    // stackFrame() and procWithStack() may collect. The Process may be
    // reachable from the scanner, but these by-value locals are not, so they
    // are rooted to be updated if their objects move.
    Elm::StackRootGuard guard(&procHP, &callback);

    void* procPtr = resolveHP(procHP);
    if (!procPtr) return procHP;
    HPointer oldStack = static_cast<Process*>(procPtr)->stack;
    HPointer frame = stackFrame(expectedTag, callback, oldStack);
    return procWithStack(procHP, frame);
}

Scheduler::PopStackResult Scheduler::popStackMatching(HPointer procHP, u64 tag) {
    // Non-matching frames are dropped, as in elm/core's JavaScript scheduler:
    // a Succeed skips OnError frames and a Fail skips AndThen frames. The
    // walk allocates nothing until a result is built.
    void* procPtr = resolveHP(procHP);
    if (!procPtr) return {false, procHP, listNil()};
    HPointer curStack = static_cast<Process*>(procPtr)->stack;

    while (!alloc::isNil(curStack)) {
        void* ptr = resolveHP(curStack);
        if (!ptr) {
            // A stack that ends in something other than Nil: treat it as
            // exhausted.
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
            // procWithStack may collect; these locals must follow their
            // objects if they move.
            StackRootGuard g(&rest, &frameCallback);
            HPointer newProc = procWithStack(procHP, rest);
            return {true, newProc, frameCallback};
        }
        // Non-matching frame: continue with the rest.
    }
    HPointer nil2 = listNil();
    HPointer newProc = procWithStack(procHP, nil2);
    return {false, newProc, listNil()};
}

// ============================================================================
// Process API
// ============================================================================

HPointer Scheduler::rawSpawn(HPointer rootTask) {
    u64 id = nextProcessId();
    HPointer nil = listNil();
    HPointer proc = allocProcess(id, rootTask, nil, nil);

    registerLatestProcess(proc);
    enqueue(proc);
    return proc;
}

// The evaluator of a resume closure. `args[0]` is the captured Process, as it
// was when it parked; `args[1]` is the Task to continue with. Enqueues a copy
// of that Process with the Task as its root, and returns unit. A captured
// value that is not a heap object resumes nothing.
static void* resumeEvaluator(void* args[]) {
    uint64_t procEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t taskEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer procHP = decodeHP(procEnc);
    HPointer newTask = decodeHP(taskEnc);

    if (resolveHP(procHP)) {
        Scheduler::instance().noteResumed();
        HPointer newProcHP = Scheduler::procWithRoot(procHP, newTask);
        Scheduler::instance().enqueue(newProcHP);
    }

    return reinterpret_cast<void*>(encodeHP(unit()));
}

// Spawns a process running `capturedTask` and returns a Task succeeding with
// it. As the body of spawnTask's binding it runs each time the binding is
// stepped, as elm/core's `spawn = binding (\cb -> cb (succeed (rawSpawn task)))`
// does, so a Task value shared between several fulfilments spawns once per
// fulfilment.
static HPointer spawnBindingBody(HPointer capturedTask) {
    auto& sched = Scheduler::instance();
    HPointer proc = sched.rawSpawn(capturedTask);
    return sched.taskSucceed(proc);
}

HPointer Scheduler::spawnTask(HPointer rootTask) {
    return makeBinding<spawnBindingBody>(rootTask);
}

void Scheduler::rawSend(HPointer procHP, HPointer msg) {
    void* ptr = resolveHP(procHP);
    if (!ptr) return;
    HPointer newProcHP = mailboxPushBack(procHP, msg);
    enqueue(newProcHP);
}

// Makes the kill attempt killTask describes on `targetProcHP`, and returns a
// Task succeeding with unit. As the body of killTask's binding it runs each
// time the binding is stepped.
//
// The lookup by id matters: the HPointer spawn returned is usually stale by
// the time it is killed, and its root is the Task the process started with,
// not the parked Binding that carries the kill handle.
static HPointer killBindingBody(HPointer targetProcHP) {
    auto& sched = Scheduler::instance();
    void* ptr = resolveHP(targetProcHP);
    u64 id = 0;
    bool haveId = false;
    if (ptr) {
        id = static_cast<Process*>(ptr)->id;
        haveId = true;
        ptr = resolveHP(sched.latestProcessById(id));
    }
    if (ptr) {
        Process* proc = static_cast<Process*>(ptr);
        void* rootPtr = resolveHP(proc->root);
        if (rootPtr) {
            Task* rootTask = static_cast<Task*>(rootPtr);
            if (rootTask->ctor == Task_Binding) {
                void* killPtr = resolveHP(rootTask->kill);
                if (killPtr) {
                    Scheduler::callClosure1(rootTask->kill, unit());
                }
            }
        }
    }
    // As elm/core's `_Scheduler_kill` sets the process's root to null: the process takes no further step,
    // whether it was parked or queued to run. A process killing itself is not stopped, as in JS, where the
    // kill binding's own callback gives it a root again.
    if (haveId && !sched.isStepping(id)) sched.processKilled(id);
    return sched.taskSucceed(unit());
}

HPointer Scheduler::killTask(HPointer procHP) {
    return makeBinding<killBindingBody>(procHP);
}

// ============================================================================
// Run Queue
// ============================================================================

void Scheduler::enqueue(HPointer proc) {
    enqueueSerial_.fetch_add(1, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        RootedProc rp;
        rp.encoded = encodeHP(proc);
        runQueue_.push_back(rp);
    }
    eventCV_.notify_one();
}

// ============================================================================
// Liveness holds
// ============================================================================

// Whether this build keeps the hold census: every live hold's kind and site,
// recently released tokens, and holdless parks.
#if !defined(NDEBUG) || defined(ECO_HEAP_VALIDATE)
static constexpr bool kHoldCensus = true;
#else
static constexpr bool kHoldCensus = false;
#endif

// The position of the HoldKind in a free-standing token. Such a token is
// bit 63 set, the kind in bits 56-62, so that a release can tell a Host hold
// without the census, and a serial in bits 0-55.
static constexpr int kHoldKindShift = 56;
// Returns the kind carried by free-standing token `t`.
static inline HoldKind freeHoldKind(HoldToken t) {
    return static_cast<HoldKind>((t >> kHoldKindShift) & 0x7f);
}

const char* holdKindName(HoldKind k) noexcept {
    switch (k) {
    case HoldKind::Task: return "Task";
    case HoldKind::Subscription: return "Subscription";
    case HoldKind::Item: return "Item";
    case HoldKind::Host: return "Host";
    case HoldKind::Port: return "Port";
    }
    return "?";
}

// Returns whether environment variable `name` is set to anything but empty
// or "0". Reads the environment on every call.
static bool envFlag(const char* name) {
    const char* v = std::getenv(name);
    return v && *v && std::strcmp(v, "0") != 0;
}

// Returns whether ECO_LIVENESS_REPORT is on, read once on the first call.
static bool livenessReportEnabled() {
    static const bool on = envFlag("ECO_LIVENESS_REPORT");
    return on;
}

// The most recently released holds with their acquiring sites, so that a
// second release can name the site. Census builds only; guarded by
// holdsMutex_. A second release older than the last N releases is reported
// as a release of an unknown hold.
namespace {
struct ReleasedRing {
    // The number of releases remembered.
    static constexpr size_t N = 1024;
    std::pair<HoldToken, const char*> e[N] = {};
    size_t next = 0;
    // Records the release of `t`, overwriting the oldest entry.
    void push(HoldToken t, const char* site) { e[next] = {t, site}; next = (next + 1) % N; }
    // Returns the site recorded for `t`, or null if it is not remembered.
    const char* find(HoldToken t) const {
        for (size_t i = 0; i < N; ++i) if (e[i].first == t && t != kNoHold) return e[i].second;
        return nullptr;
    }
};
ReleasedRing g_releasedHolds;
} // namespace

// Writes a liveness error naming `what`, the token and, if known, the
// acquiring site to stderr, and aborts.
[[noreturn]] static void holdFatal(const char* what, HoldToken t, const char* site) {
    std::fprintf(stderr, "eco: liveness: %s (token 0x%llx%s%s)\n", what,
                 static_cast<unsigned long long>(t), site ? ", acquired at " : "",
                 site ? site : "");
    std::fflush(stderr);
    std::abort();
}

void Scheduler::drain() {
    working_ = true;
    ++drainDepth_;

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

    --drainDepth_;
    working_ = false;
}

void Scheduler::runEventLoop() {
    while (true) {
        drain();

        // Checked only between drains, so no process step is abandoned.
        if (stopRequested_.load()) break;

        processReadyAsync();

        if (!runQueue_.empty()) continue;

        std::unique_lock<std::mutex> lock(mutex_);
        if (stopRequested_.load()) break;
        if (runQueue_.empty() && pendingAsync_.load() == 0) {
            // A source may have work that holds no hold, such as a received
            // signal. Run it before deciding the loop is quiescent, or it is
            // lost.
            bool sourceReady = false;
            for (size_t i = 0; i < asyncSources_.size() && !sourceReady; ++i) {
                sourceReady = asyncSources_[i].second();
            }
            if (sourceReady) {
                lock.unlock();
                continue;   // drain + processReadyAsync at the top
            }
            // Quiescent. Listeners run with mutex_ released, because they may
            // enqueue, drain and start async work.
            if (!embedMode_.load() && !quiescenceListeners_.empty()) {
                // Copy: a listener may register another listener.
                auto listeners = quiescenceListeners_;
                lock.unlock();
                bool delivered = false;
                for (auto& [fn, ctx] : listeners) {
                    delivered |= fn(ctx);
                }
                lock.lock();
                if (delivered) continue;
            }
            break;
        }
        // About to sleep. runQueue_ is empty here; it is tested only so the
        // expression matches the definition of busy.
        fireActivity(!runQueue_.empty() ||
                     pendingAsync_.load() - hostHolds_.load() > 0);
        // A timer token pushed after processReadyAsync but before the lock
        // was taken is caught here rather than missed.
        auto ready = [this] {
            if (stopRequested_.load()
                || !runQueue_.empty()
                || pendingAsync_.load() == 0
                || TimerService::instance().hasReadyTokens()) {
                return true;
            }
            for (size_t i = 0; i < asyncSources_.size(); ++i) {
                if (asyncSources_[i].second()) return true;
            }
            return false;
        };
        if (livenessReportEnabled()) {
            // reportHolds takes holdsMutex_, never under mutex_, so the lock
            // is dropped around it.
            while (!eventCV_.wait_for(lock, std::chrono::seconds(10), ready)) {
                lock.unlock();
                reportHolds("idle 10 s");
                lock.lock();
            }
        } else {
            eventCV_.wait(lock, ready);
        }
        // Reported busy even on a stop or an empty wake, so the host stays
        // alive across the coming drain.
        fireActivity(true);
    }
    // Copied: a hook may register another hook.
    if (stopRequested_.load()) {
        auto hooks = stopHooks_;
        for (StopHook h : hooks) h();
    }
    if (livenessReportEnabled()) reportHolds("exit");
    fireActivity(false);
}

void Scheduler::addStopHook(StopHook fn) {
    for (StopHook h : stopHooks_) {
        if (h == fn) return;
    }
    stopHooks_.push_back(fn);
}

void Scheduler::fireActivity(bool busy) {
    if (busy == lastActivityBusy_)
        return;
    lastActivityBusy_ = busy;
    if (activityHook_)
        activityHook_(busy, activityUser_);
}

void Scheduler::incrementPendingAsync() {
    pendingAsync_.fetch_add(1);
}

void Scheduler::addQuiescenceListener(QuiescenceListener fn, void* ctx) {
    std::lock_guard<std::mutex> lk(mutex_);
    quiescenceListeners_.emplace_back(fn, ctx);
}

void Scheduler::removeQuiescenceListener(QuiescenceListener fn, void* ctx) {
    std::lock_guard<std::mutex> lk(mutex_);
    std::erase_if(quiescenceListeners_,
                  [&](const std::pair<QuiescenceListener, void*>& e) {
                      return e.first == fn && e.second == ctx;
                  });
}

void Scheduler::decrementPendingAsync() {
    pendingAsync_.fetch_sub(1);
    // Taking mutex_ orders the decrement against the event loop's predicate
    // check, so the loop cannot test the old count and then sleep through the
    // notify.
    { std::lock_guard<std::mutex> lk(mutex_); }
    eventCV_.notify_one();
}

void Scheduler::requestStop() {
    stopRequested_.store(true);
    // As in decrementPendingAsync, the brief lock closes the missed-wakeup
    // window.
    { std::lock_guard<std::mutex> lk(mutex_); }
    eventCV_.notify_all();
}

void Scheduler::notifyWorkAvailableFromAsync() {
    // Notifying under mutex_ closes the missed-wakeup window, as in
    // decrementPendingAsync.
    std::lock_guard<std::mutex> lk(mutex_);
    eventCV_.notify_one();
}

void Scheduler::processReadyAsync() {
    std::uint64_t token;
    while (TimerService::instance().tryPopReadyToken(token)) {
        HPointer resumeClosure = takePendingResume(token);
        if (alloc::isNil(resumeClosure)) {
            releaseHold(token);
            continue;
        }
        HPointer succeedTask = listNil();
        {
            StackRootGuard guard(&resumeClosure, &succeedTask);
            succeedTask = taskSucceed(unit());
            callClosure1(resumeClosure, succeedTask);
        }
        releaseHold(token);   // after the resume, so the hold outlasts the publication of the result
    }

    // By index, re-reading the size: a drain can register a new source, and
    // a range-for over a deque that grows is undefined.
    for (size_t i = 0; i < asyncSources_.size(); ++i) {
        asyncSources_[i].first();
    }
}

// ============================================================================
// Step Loop
// ============================================================================

namespace {

// The call layouts for applying a continuation to an unboxed Task value,
// indexed by slot kind (1 Int, 2 Float, 3 Char; entry 0 is not used, since
// boxed values go through callClosure1). Each describes one argument of that
// kind and a boxed result.
static constexpr EvalParamLayoutN<1> one_arg_layouts[4] = {
    makeEvalParamLayout<1>(0, {0}),  // PK_Boxed (unused — boxed-value dispatch keeps callClosure1)
    makeEvalParamLayout<1>(0, {1}),  // PK_Int
    makeEvalParamLayout<1>(0, {2}),  // PK_Float
    makeEvalParamLayout<1>(0, {3}),  // PK_Char
};

// A scope guard that roots one encoded HPointer on the shadow range stack,
// so the collector updates the word in place, and restores the stack when the
// scope ends. It must be destroyed in LIFO order with other shadow-stack
// guards.
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
    // procEncoded always holds this step's current Process and is rooted.
    // After any allocation or closure call, every raw pointer and HPointer
    // read from the heap may be stale, so everything is re-read from it.
    EncodedStackRootGuard root_guard(&procEncoded);

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

    // Makes the current Process a copy with root `newRoot`. Other holders of
    // older versions, such as run-queue entries, keep those versions.
    auto setRoot = [&](HPointer newRoot) {
        HPointer newHP = Scheduler::procWithRoot(currentProcHP(), newRoot);
        procEncoded = encodeHP(newHP);
    };

    if (!resolveProc()) return;

    // Step the process's latest version, not necessarily the one this run-queue entry holds. Elm's JS scheduler
    // has one mutable process; here every change makes a new version, and each `rawSend` or resume queues its
    // own, so an entry may be stale. The latest version holds everything an older one did (its mailbox
    // included), so stepping it consumes every message once, and a second entry for the same process finds
    // nothing left. An id with no latest version has finished or been killed: the entry is dropped. A stale entry
    // whose latest version is parked on a Binding is dropped too: that process runs again only when resumed.
    {
        Process* p = resolveProc();
        const u64 id = p->id;
        HPointer latest = latestProcessById(id);
        if (alloc::isNil(latest)) return;
        const uint64_t latestEnc = encodeHP(latest);
        if (latestEnc != procEncoded) {
            void* lp = resolveHP(latest);
            Task* lroot = lp ? resolveRoot(static_cast<Process*>(lp)) : nullptr;
            if (lroot && lroot->ctor == Task_Binding) return;
            procEncoded = latestEnc;
        }
    }
    const u64 steppingId = resolveProc()->id;
    SteppingScope stepping(*this, steppingId);

    while (true) {
        Process* proc = resolveProc();
        if (!proc) break;

        Task* task = resolveRoot(proc);
        if (!task) {
            // No root Task: nothing can ever run this process again.
            processFinished(currentProcHP());
            break;
        }
        u16 ctor = task->ctor;

        if (ctor == Task_Succeed || ctor == Task_Fail) {
            u64 searchTag = (ctor == Task_Succeed) ? Task_Succeed : Task_Fail;

            PopStackResult popRes = popStackMatching(currentProcHP(), searchTag);
            procEncoded = encodeHP(popRes.newProcHP);

            if (popRes.matched) {
                proc = resolveProc();
                if (!proc) break;
                task = resolveRoot(proc);
                if (!task) break;
                u8 valKind = static_cast<u8>(task->header.unboxed & 0x3);
                HPointer newTask;
                if (valKind == 0) {
                    HPointer taskValue = task->value.p;
                    newTask = callClosure1(popRes.callback, taskValue);
                } else {
                    // An unboxed value is passed as raw bits with its kind,
                    // so a continuation that takes the primitive unboxed gets
                    // it without boxing; eco_apply_closure_eval boxes it for
                    // one that does not.
                    Unboxable v = task->value;
                    int64_t typed_arg;
                    switch (valKind) {
                        case 1:
                            typed_arg = v.i;
                            break;
                        case 2: {
                            double d = v.f;
                            std::memcpy(&typed_arg, &d, sizeof(int64_t));
                            break;
                        }
                        default:
                            typed_arg = static_cast<int64_t>(v.c);
                            break;
                    }
                    HPtr resultBits = HPtr::fromBits(0);
                    HPtr callbackHPtr =
                        HPtr::fromBits(encodeHP(popRes.callback));
                    eco_apply_closure_eval(
                        callbackHPtr, &typed_arg, /*num_args=*/1,
                        asLayout(&one_arg_layouts[valKind]),
                        &resultBits, /*desired_kind=*/0);
                    newTask = decodeHP(resultBits.toBits());
                }
                setRoot(newTask);
                continue;
            } else {
                if (ctor == Task_Fail) {
                    std::fprintf(stderr,
                        "[eco-runtime] unhandled top-level Task.fail "
                        "(no surrounding Task.onError) — failure value dropped\n");
                    std::fflush(stderr);
                }
                processFinished(currentProcHP());
                break;
            }
        }
        else if (ctor == Task_AndThen) {
            // Read before pushStack, which may collect and move `task`, and
            // rooted so that both still name their objects afterwards.
            HPointer callback = task->callback;
            HPointer innerTask = task->task;
            Elm::StackRootGuard guard(&innerTask, &callback);

            HPointer afterPush = pushStack(currentProcHP(), Task_Succeed, callback);
            procEncoded = encodeHP(afterPush);
            setRoot(innerTask);
            continue;
        }
        else if (ctor == Task_OnError) {
            HPointer callback = task->callback;
            HPointer innerTask = task->task;
            Elm::StackRootGuard guard(&innerTask, &callback);

            HPointer afterPush = pushStack(currentProcHP(), Task_Fail, callback);
            procEncoded = encodeHP(afterPush);
            setRoot(innerTask);
            continue;
        }
        else if (ctor == Task_Binding) {
            HPointer bindCallback = task->callback;
            Elm::StackRootGuard guard(&bindCallback);

            HPointer resumeClosure = allocClosure(
                reinterpret_cast<EvalFunction>(resumeEvaluator), 2);
            void* clPtr = resolveHP(resumeClosure);
            if (clPtr) {
                // The resume closure captures this version of the Process,
                // and resuming builds from it. Later versions, including the
                // one with the kill handle below and any whose mailbox grew
                // while parked, are not what it resumes.
                closureCapture(clPtr, boxed(currentProcHP()), true);
            }

            const u64 resumesBefore = resumeSerial_;
            HPointer killHandle = callClosure1(bindCallback, resumeClosure);

            // The callback may have collected.
            proc = resolveProc();
            if (!proc) break;

            // A callback that resumed synchronously has already queued the resumed version and made it the
            // latest; registering a parked copy now would hide it (a kill would find the parked Binding, and
            // the stale-entry rule above would skip the resumed version).
            if (resumeSerial_ != resumesBefore &&
                encodeHP(latestProcessById(proc->id)) != procEncoded)
                break;

            // The kill handle goes on a copy of the Binding made for this
            // process, never into the Task itself: a Task is an immutable
            // value that may be shared and fulfilled many times. killTask
            // reads the handle from the copy.
            void* newRootPtr = resolveHP(proc->root);
            if (newRootPtr) {
                Task* currentTask = static_cast<Task*>(newRootPtr);
                if (currentTask->ctor == Task_Binding) {
                    HPointer cbHP = currentTask->callback;
                    HPointer newRoot = listNil();
                    Elm::StackRootGuard guard2(&cbHP, &killHandle, &newRoot);
                    HPointer nil = listNil();
                    newRoot = allocTask(Task_Binding, nil, cbHP, killHandle, nil);
                    setRoot(newRoot);
                }
            }

            break;
        }
        else if (ctor == Task_Receive) {
            MailboxPopResult popRes = mailboxPopFront(currentProcHP());
            procEncoded = encodeHP(popRes.newProcHP);
            if (popRes.hasMessage) {
                proc = resolveProc();
                if (!proc) break;

                // A self-message handler replaces the Receive callback. The
                // root is still the Receive, so continuing waits for the next
                // message.
                u64 procId = proc->id;
                auto selfIt = selfMsgHandlers_.find(procId);
                if (selfIt != selfMsgHandlers_.end()) {
                    HPointer selfMsg = popRes.msg;
                    auto handler = selfIt->second;  // copy: handler re-enters drain
                    Elm::StackRootGuard guard(&selfMsg);
                    handler(selfMsg);
                    continue;
                }

                task = resolveRoot(proc);
                if (!task) break;
                HPointer recvCallback = task->callback;
                // Neither local is otherwise rooted across the Elm call.
                Elm::StackRootGuard guard(&recvCallback, &popRes.msg);

                HPointer newTask = callClosure1(recvCallback, popRes.msg);
                setRoot(newTask);
                continue;
            } else {
                break;
            }
        }
        else {
            // Unknown task ctor: nothing can ever run this process again.
            processFinished(currentProcHP());
            break;
        }
    }
}

// ============================================================================
// Liveness holds (continued; helpers are above Scheduler::drain)
// ============================================================================

bool Scheduler::holdCensusEnabled() const { return kHoldCensus; }

void Scheduler::noteAcquire(HoldToken t, HoldKind kind, const char* site) {
    acquireSerial_.fetch_add(1, std::memory_order_relaxed);
    if (kind == HoldKind::Host) hostHolds_.fetch_add(1);
    if (kHoldCensus) {
        std::lock_guard<std::mutex> g(holdsMutex_);
        if (!holds_.emplace(t, std::make_pair(kind, site)).second)
            holdFatal("hold token acquired twice", t, site);
    }
    incrementPendingAsync();
}

u64 Scheduler::parkResume(HPointer resume, HoldKind kind, const char* site) {
    u64 token = registerPendingResume(resume);
    noteAcquire(token, kind, site);
    return token;
}

HoldToken Scheduler::acquireHold(HoldKind kind, const char* site) {
    u64 serial = nextHoldId_.fetch_add(1) & ((1ull << kHoldKindShift) - 1);
    HoldToken t = kFreeHoldBit
        | (static_cast<u64>(static_cast<uint8_t>(kind)) << kHoldKindShift) | serial;
    noteAcquire(t, kind, site);
    return t;
}

void Scheduler::releaseHold(HoldToken t) {
    if (kHoldCensus) {
        std::lock_guard<std::mutex> g(holdsMutex_);
        if (t == kNoHold) holdFatal("releaseHold(kNoHold)", t, nullptr);
        auto it = holds_.find(t);
        if (it != holds_.end()) {
            g_releasedHolds.push(t, it->second.second);
            holds_.erase(it);
        } else if (const char* site = g_releasedHolds.find(t)) {
            holdFatal("second release of a hold", t, site);
        } else {
            holdFatal("release of an unknown hold", t, nullptr);
        }
    }
    if ((t & kFreeHoldBit) && freeHoldKind(t) == HoldKind::Host) hostHolds_.fetch_sub(1);
    decrementPendingAsync();
}

size_t Scheduler::liveHoldCount() {
    if (!kHoldCensus) return 0;
    std::lock_guard<std::mutex> g(holdsMutex_);
    return holds_.size();
}

bool Scheduler::holdIsLive(HoldToken t) {
    if (!kHoldCensus) return false;
    std::lock_guard<std::mutex> g(holdsMutex_);
    return holds_.count(t) != 0;
}

void Scheduler::noteHoldlessPark(const char* binding) {
    if (envFlag("ECO_LIVENESS_STRICT"))
        holdFatal("async binding parked without a hold or a resume", kNoHold, binding);
    if (!kHoldCensus) return;
    std::lock_guard<std::mutex> g(holdsMutex_);
    for (auto& [name, n] : holdlessParks_) {
        if (name == binding) { ++n; return; }
    }
    holdlessParks_.emplace_back(binding, 1);
}

void Scheduler::reportHolds(const char* why) {
    if (!kHoldCensus) {
        std::fprintf(stderr, "eco: liveness report (%s): pendingAsync=%d (census off in this build)\n",
                     why, pendingAsync_.load());
        return;
    }
    std::map<std::pair<int, std::string>, int> bySite;
    std::vector<std::pair<const char*, u64>> parks;
    {
        std::lock_guard<std::mutex> g(holdsMutex_);
        for (auto& [t, ks] : holds_)
            bySite[{static_cast<int>(ks.first), ks.second ? ks.second : "?"}]++;
        parks = holdlessParks_;
    }
    std::fprintf(stderr, "eco: liveness report (%s): pendingAsync=%d, holds=%zu\n",
                 why, pendingAsync_.load(), static_cast<size_t>(
                     [&] { size_t n = 0; for (auto& [k, c] : bySite) n += c; return n; }()));
    for (auto& [k, c] : bySite)
        std::fprintf(stderr, "  %-12s %-40s %d\n", holdKindName(static_cast<HoldKind>(k.first)),
                     k.second.c_str(), c);
    for (auto& [name, n] : parks)
        std::fprintf(stderr, "  holdless park: %s x%llu\n", name,
                     static_cast<unsigned long long>(n));
    std::fflush(stderr);
}

LivenessHold LivenessHold::acquire(HoldKind kind, const char* site) {
    return LivenessHold(Scheduler::instance().acquireHold(kind, site));
}

LivenessHold LivenessHold::adopt(HoldToken t) noexcept { return LivenessHold(t); }

LivenessHold::LivenessHold(LivenessHold&& o) noexcept : t_(o.t_) { o.t_ = kNoHold; }

LivenessHold& LivenessHold::operator=(LivenessHold&& o) noexcept {
    if (this != &o) {
        release();
        t_ = o.t_;
        o.t_ = kNoHold;
    }
    return *this;
}

LivenessHold::~LivenessHold() { release(); }

void LivenessHold::release() noexcept {
    if (t_ == kNoHold) return;
    HoldToken t = t_;
    t_ = kNoHold;
    Scheduler::instance().releaseHold(t);
}

HoldToken LivenessHold::detach() noexcept {
    HoldToken t = t_;
    t_ = kNoHold;
    return t;
}

HoldRelease::~HoldRelease() {
    if (t_ != kNoHold) Scheduler::instance().releaseHold(t_);
}

} // namespace Elm::Platform
