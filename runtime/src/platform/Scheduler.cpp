#include "Scheduler.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
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

Scheduler::Scheduler() {}

// ============================================================================
// Task Constructors
// ============================================================================

HPointer Scheduler::taskSucceed(HPointer value) {
    HPointer nil = listNil();
    return allocTask(Task_Succeed, value, nil, nil, nil);
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
    uint64_t closureEnc = encodeHP(closurePtr);

    // Use eco_apply_closure which handles PAP/saturated correctly
    uint64_t result = eco_apply_closure(closureEnc, &argEnc, 1);
    return decodeHP(result);
}

HPointer Scheduler::callClosure2(HPointer closurePtr, HPointer arg1, HPointer arg2) {
    uint64_t args[2];
    args[0] = encodeHP(arg1);
    args[1] = encodeHP(arg2);
    uint64_t closureEnc = encodeHP(closurePtr);

    uint64_t result = eco_apply_closure(closureEnc, args, 2);
    return decodeHP(result);
}

HPointer Scheduler::callClosure4(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                  HPointer arg3, HPointer arg4) {
    uint64_t args[4];
    args[0] = encodeHP(arg1);
    args[1] = encodeHP(arg2);
    args[2] = encodeHP(arg3);
    args[3] = encodeHP(arg4);
    uint64_t closureEnc = encodeHP(closurePtr);

    uint64_t result = eco_apply_closure(closureEnc, args, 4);
    return decodeHP(result);
}

// ============================================================================
// Mailbox Helpers (Elm List as FIFO queue)
// ============================================================================

// Push message to back of mailbox (append to end of list)
// Mailbox is stored as a reversed list for O(1) push
void Scheduler::mailboxPushBack(Process* proc, HPointer msg) {
    // Simple: prepend to the mailbox list (acts as a stack)
    // We reverse on pop to get FIFO order
    // Actually, for simplicity use cons to prepend (LIFO).
    // The JS scheduler uses Array.push + Array.shift which is FIFO.
    // We'll use the simpler approach: mailbox is a list, push prepends,
    // but we need FIFO. So we'll just cons and reverse when needed.
    // Actually, let's just use cons for append (messages arrive in order of cons).
    // Pop from front = pop newest. That's wrong for FIFO.
    //
    // Correct approach: mailbox is an Elm list. Push appends to the END.
    // For an Elm list this is O(n). But in practice mailboxes are small.
    // Alternative: store mailbox reversed and reverse on read.
    //
    // Simplest correct approach: cons to front for push, but track that
    // mailbox is in reverse order. When we pop, we reverse first.
    // This gives amortized O(1) for both push and pop.
    //
    // For now, just cons to front. popFront will need to reverse.
    HPointer newCell = cons(boxed(msg), proc->mailbox, true);
    proc->mailbox = newCell;
}

bool Scheduler::mailboxPopFront(Process* proc, HPointer& outMsg) {
    HPointer mailbox = proc->mailbox;
    if (alloc::isNil(mailbox)) return false;

    // Reverse the list to get FIFO order, then take the head
    // Build reversed list
    HPointer reversed = listNil();
    HPointer current = mailbox;
    while (!alloc::isNil(current)) {
        void* ptr = resolveHP(current);
        if (!ptr) break;
        Cons* cell = static_cast<Cons*>(ptr);
        reversed = cons(cell->head, reversed, true);
        current = cell->tail;
    }

    // Take head of reversed (this is the oldest message)
    void* revPtr = resolveHP(reversed);
    if (!revPtr) return false;
    Cons* revCell = static_cast<Cons*>(revPtr);
    outMsg = revCell->head.p;

    // Rest of reversed becomes the new mailbox (but needs to be reversed back)
    HPointer rest = revCell->tail;
    HPointer newMailbox = listNil();
    HPointer cur2 = rest;
    while (!alloc::isNil(cur2)) {
        void* p = resolveHP(cur2);
        if (!p) break;
        Cons* c = static_cast<Cons*>(p);
        newMailbox = cons(c->head, newMailbox, true);
        cur2 = c->tail;
    }
    proc->mailbox = newMailbox;
    return true;
}

// ============================================================================
// Stack Helpers (Elm List of StackFrame Custom objects)
// ============================================================================

void Scheduler::pushStack(Process* proc, u64 expectedTag, HPointer callback) {
    HPointer frame = stackFrame(expectedTag, callback, proc->stack);
    proc->stack = frame;
}

bool Scheduler::popStackMatching(Process* proc, u64 tag, HPointer& outCallback) {
    // Walk the stack looking for a frame whose expectedTag matches
    // Pop non-matching frames as we go (like the JS version)
    while (!alloc::isNil(proc->stack)) {
        void* ptr = resolveHP(proc->stack);
        if (!ptr) {
            proc->stack = listNil();
            return false;
        }
        // Stack is a linked list of StackFrame Custom objects
        // StackFrame: Custom with ctor=CTOR_StackFrame
        //   values[0] = expectedTag (unboxed i64)
        //   values[1] = callback (boxed HPointer)
        //   values[2] = rest (boxed HPointer = next frame in stack)
        Custom* frame = static_cast<Custom*>(ptr);
        u64 frameTag = frame->values[0].i;
        HPointer frameCallback = frame->values[1].p;
        HPointer rest = frame->values[2].p;

        proc->stack = rest;

        if (frameTag == tag) {
            outCallback = frameCallback;
            return true;
        }
        // Non-matching frame: skip it (popped already)
    }
    return false;
}

// ============================================================================
// Process API
// ============================================================================

HPointer Scheduler::rawSpawn(HPointer rootTask) {
    u32 id = nextProcessId();
    HPointer nil = listNil();
    HPointer proc = allocProcess(static_cast<u16>(id), rootTask, nil, nil);

    // Register as GC root and enqueue
    enqueue(proc);
    return proc;
}

// C function used as the evaluator for "resume" closures
// Captured value: args[0] = process HPointer (encoded)
// Argument: args[1] = new task HPointer (encoded)
static void* resumeEvaluator(void* args[]) {
    uint64_t procEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t taskEnc = reinterpret_cast<uint64_t>(args[1]);

    HPointer procHP = decodeHP(procEnc);
    HPointer newTask = decodeHP(taskEnc);

    void* procPtr = resolveHP(procHP);
    if (procPtr) {
        Process* proc = static_cast<Process*>(procPtr);
        proc->root = newTask;
        Scheduler::instance().enqueue(procHP);
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
    Process* proc = static_cast<Process*>(ptr);
    mailboxPushBack(proc, msg);
    enqueue(procHP);
}

HPointer Scheduler::killTask(HPointer procHP) {
    // Kill returns Task.succeed(Unit) after attempting to kill
    void* ptr = resolveHP(procHP);
    if (ptr) {
        Process* proc = static_cast<Process*>(ptr);
        // If process has a binding task with a kill handle, invoke it
        void* rootPtr = resolveHP(proc->root);
        if (rootPtr) {
            Task* rootTask = static_cast<Task*>(rootPtr);
            if (rootTask->ctor == Task_Binding) {
                void* killPtr = resolveHP(rootTask->kill);
                if (killPtr) {
                    // Call the kill closure with Unit
                    callClosure1(rootTask->kill, unit());
                }
            }
        }
        // Null out the process root
        HPointer nil = listNil();
        proc->root = nil;
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
        drain();  // Process all queued work on main thread

        std::unique_lock<std::mutex> lock(mutex_);
        // Exit when no queued work AND no pending async operations
        if (runQueue_.empty() && pendingAsync_.load() == 0) {
            break;
        }
        // Block until something is enqueued or all async work finishes
        eventCV_.wait(lock, [this] {
            return !runQueue_.empty() || pendingAsync_.load() == 0;
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

// ============================================================================
// Step Loop
// ============================================================================

void Scheduler::stepProcess(uint64_t procEncoded) {
    HPointer procHP = decodeHP(procEncoded);
    void* procPtr = resolveHP(procHP);
    if (!procPtr) return;

    Process* proc = static_cast<Process*>(procPtr);

    while (true) {
        // Re-resolve proc after any closure call (GC may have moved it)
        procPtr = resolveHP(procHP);
        if (!procPtr) return;
        proc = static_cast<Process*>(procPtr);

        HPointer rootHP = proc->root;
        if (alloc::isNil(rootHP) || isConstant(rootHP)) return;

        void* rootPtr = resolveHP(rootHP);
        if (!rootPtr) return;

        Task* task = static_cast<Task*>(rootPtr);
        u16 ctor = task->ctor;

        if (ctor == Task_Succeed || ctor == Task_Fail) {
            HPointer taskValue = task->value;
            u64 searchTag = (ctor == Task_Succeed) ? Task_Succeed : Task_Fail;

            HPointer callback;
            // Re-resolve proc
            procPtr = resolveHP(procHP);
            if (!procPtr) return;
            proc = static_cast<Process*>(procPtr);

            if (popStackMatching(proc, searchTag, callback)) {
                // Call the callback with the task value
                HPointer newTask = callClosure1(callback, taskValue);

                // Re-resolve proc after closure call (GC!)
                procPtr = resolveHP(procHP);
                if (!procPtr) return;
                proc = static_cast<Process*>(procPtr);
                proc->root = newTask;
                continue;
            } else {
                // Process finished - no matching handler
                // Leave proc->root as the final Task_Succeed/Task_Fail
                // so callers can inspect the result value
                return;
            }
        }
        else if (ctor == Task_AndThen) {
            HPointer callback = task->callback;
            HPointer innerTask = task->task;

            // Push stack frame: looking for Succeed
            pushStack(proc, Task_Succeed, callback);

            // Re-resolve proc after pushStack allocation
            procPtr = resolveHP(procHP);
            if (!procPtr) return;
            proc = static_cast<Process*>(procPtr);
            proc->root = innerTask;
            continue;
        }
        else if (ctor == Task_OnError) {
            HPointer callback = task->callback;
            HPointer innerTask = task->task;

            // Push stack frame: looking for Fail
            pushStack(proc, Task_Fail, callback);

            // Re-resolve proc
            procPtr = resolveHP(procHP);
            if (!procPtr) return;
            proc = static_cast<Process*>(procPtr);
            proc->root = innerTask;
            continue;
        }
        else if (ctor == Task_Binding) {
            HPointer bindCallback = task->callback;

            // Create a "resume" closure that captures this process
            HPointer resumeClosure = allocClosure(
                reinterpret_cast<EvalFunction>(resumeEvaluator), 2);
            void* clPtr = resolveHP(resumeClosure);
            if (clPtr) {
                closureCapture(clPtr, boxed(procHP), true);
            }

            // Call the binding callback with the resume closure
            // The binding callback returns a kill handle (or Unit)
            HPointer killHandle = callClosure1(bindCallback, resumeClosure);

            // Store the kill handle on the task
            // Re-resolve everything after closure call
            procPtr = resolveHP(procHP);
            if (!procPtr) return;
            proc = static_cast<Process*>(procPtr);

            void* newRootPtr = resolveHP(proc->root);
            if (newRootPtr) {
                Task* currentTask = static_cast<Task*>(newRootPtr);
                if (currentTask->ctor == Task_Binding) {
                    currentTask->kill = killHandle;
                }
            }

            // Process suspends - binding callback will resume it via the resume closure
            return;
        }
        else if (ctor == Task_Receive) {
            HPointer recvCallback = task->callback;

            HPointer msg;
            // Re-resolve
            procPtr = resolveHP(procHP);
            if (!procPtr) return;
            proc = static_cast<Process*>(procPtr);

            if (mailboxPopFront(proc, msg)) {
                HPointer newTask = callClosure1(recvCallback, msg);

                procPtr = resolveHP(procHP);
                if (!procPtr) return;
                proc = static_cast<Process*>(procPtr);
                proc->root = newTask;
                continue;
            } else {
                // No messages - block
                return;
            }
        }
        else {
            // Unknown task ctor
            return;
        }
    }
}

} // namespace Elm::Platform
