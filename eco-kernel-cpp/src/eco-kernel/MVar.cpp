//===- MVar.cpp - MVar kernel module implementation -----------------------===//
//
// Each operation's Task is a Binding over a closure built here, and the closure's evaluator does all the
// work on the MVar when the scheduler steps the Task. A fiber parks by handing its resume closure to the
// scheduler with `parkResume`, which roots the closure, and queueing a `Waiter` holding the returned token.
// Waking it takes the closure back, calls it with a succeeding Task, and releases the hold. Values held here
// (slot values and putters' pending values) are rooted by the scanner `registerGcRootScanner` registers.
//
//===----------------------------------------------------------------------===//

#include "MVar.hpp"
#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/RootSet.hpp"
#include "platform/Scheduler.hpp"
#include <cassert>
#include <cstdint>
#include <deque>
#include <optional>
#include <unordered_map>

namespace Eco::Kernel::MVar {

using Elm::HPointer;
using namespace Elm::alloc;

// A fiber parked on one MVar queue.
struct Waiter {
    // The resume token `parkResume` returned; it keys both the parked closure and its hold.
    uint64_t token;
    // A putter's value to store; `listNil()` for readers and takers.
    HPointer pendingValue;
};

// One MVar: its value, present when full, and its three queues of parked fibers in arrival order.
struct MVarSlot {
    std::optional<HPointer> value;
    std::deque<Waiter> readers;
    std::deque<Waiter> takers;
    std::deque<Waiter> putters;
};

// Every live MVar, by id. After each evaluator returns, a full slot has no readers or takers and an empty
// slot has no putters.
static std::unordered_map<int64_t, MVarSlot> s_mvars;
// The id the next `newEmpty` hands out; it only increases.
static int64_t s_nextId = 1;

// ============================================================================
// Wake path
// ============================================================================

// Resumes the fiber parked under `token` with a Task that succeeds with `value`, and releases its hold. If no
// closure is parked under `token`, only releases the hold. `value` must be current; it is rooted here across
// the allocations.
static void wakeWaiter(uint64_t token, HPointer value) {
    auto& sched = Elm::Platform::Scheduler::instance();
    HPointer resumeClosure = sched.takePendingResume(token);
    if (isNil(resumeClosure)) {
        sched.releaseHold(token);
        return;
    }
    HPointer v = value;
    HPointer succeedTask = listNil();
    {
        Elm::StackRootGuard guard(&resumeClosure, &v, &succeedTask);
        succeedTask = sched.taskSucceed(v);
        Elm::Platform::Scheduler::callClosure1(resumeClosure, succeedTask);
    }
    sched.releaseHold(token);
}

// Delivers `v`, arriving at the empty `slot`: resumes every reader with it, then hands it to the first taker,
// leaving the slot empty, or stores it when there is no taker.
static void processPutArrival(MVarSlot& slot, HPointer v) {
    Elm::StackRootGuard guard(&v);
    while (!slot.readers.empty()) {
        Waiter w = slot.readers.front();
        slot.readers.pop_front();
        wakeWaiter(w.token, v);
    }
    if (!slot.takers.empty()) {
        Waiter w = slot.takers.front();
        slot.takers.pop_front();
        wakeWaiter(w.token, v);
    } else {
        slot.value = v;
    }
}

// Refills `slot`, just emptied, from its putters: resumes the first with unit and delivers its value as
// `processPutArrival` does, repeating while a taker consumed the value and putters remain.
static void processTakeDeparture(MVarSlot& slot) {
    while (!slot.value.has_value() && !slot.putters.empty()) {
        Waiter w = slot.putters.front();
        slot.putters.pop_front();
        HPointer pendingV = w.pendingValue;
        {
            Elm::StackRootGuard guard(&pendingV);
            wakeWaiter(w.token, unit());
            processPutArrival(slot, pendingV);
        }
    }
}

// Resumes `resumeHP` with a Task failing with the IO error tuple (tag 0, empty path, "MVar not found: <id>").
// An evaluator that found no MVar must call this; returning without resuming would leave the fiber stuck.
static void resumeNotFound(HPointer resumeHP, int64_t id) {
    HPointer failTask = listNil();
    {
        Elm::StackRootGuard guard(&resumeHP, &failTask);
        failTask = Export::decode(
            taskFailIO(0, "", "MVar not found: " + std::to_string(id)));
        Elm::Platform::Scheduler::callClosure1(resumeHP, failTask);
    }
}

// ============================================================================
// Binding callback evaluators
// ============================================================================
//
// The scheduler calls an evaluator each time it steps the Binding Task. `rawArgs` holds the captured values
// in capture order, then the resume closure. These evaluators are the only code that reads or writes MVar
// state for read, take and put. Each resumes the fiber or parks it, and returns encoded unit.

// Performs `read`. Captured: [0] the MVar id (PK_Int). Passed: [1] the resume closure.
//
// `eco_closure_call_saturated` delivers each capture in `combined_args[i]` as raw primitive bits when its
// `closure->unboxed[i]` kind is PK_Int / PK_Float / PK_Char, not as an HPointer to a boxed value. So the
// captured mvar id is the raw int64; only boxed arguments (here, the resume closure) go through
// Export::decode.
static void* readBindingEvaluator(void* rawArgs[]) {
    int64_t id = static_cast<int64_t>(reinterpret_cast<uint64_t>(rawArgs[0]));
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto& sched = Elm::Platform::Scheduler::instance();
    auto it = s_mvars.find(id);
    if (it == s_mvars.end()) {
        resumeNotFound(resumeHP, id);
        return reinterpret_cast<void*>(Export::encode(unit()));
    }
    if (it->second.value.has_value()) {
        HPointer v = it->second.value.value();
        Elm::StackRootGuard guard(&resumeHP, &v);
        HPointer succeedTask = sched.taskSucceed(v);
        Elm::StackRootGuard guard2(&succeedTask);
        Elm::Platform::Scheduler::callClosure1(resumeHP, succeedTask);
    } else {
        uint64_t token = sched.parkResume(resumeHP, Elm::Platform::HoldKind::Task, "MVar.wait");
        it->second.readers.push_back({token, listNil()});
    }
    return reinterpret_cast<void*>(Export::encode(unit()));
}

// Performs `take`. Captured: [0] the MVar id (PK_Int). Passed: [1] the resume closure. Arguments arrive as
// `readBindingEvaluator` describes.
static void* takeBindingEvaluator(void* rawArgs[]) {
    int64_t id = static_cast<int64_t>(reinterpret_cast<uint64_t>(rawArgs[0]));
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto& sched = Elm::Platform::Scheduler::instance();
    auto it = s_mvars.find(id);
    if (it == s_mvars.end()) {
        resumeNotFound(resumeHP, id);
        return reinterpret_cast<void*>(Export::encode(unit()));
    }
    if (it->second.value.has_value()) {
        HPointer v = it->second.value.value();
        it->second.value.reset();
        {
            Elm::StackRootGuard guard(&v, &resumeHP);
            processTakeDeparture(it->second);
            HPointer succeedTask = sched.taskSucceed(v);
            Elm::StackRootGuard guard2(&succeedTask);
            Elm::Platform::Scheduler::callClosure1(resumeHP, succeedTask);
        }
    } else {
        uint64_t token = sched.parkResume(resumeHP, Elm::Platform::HoldKind::Task, "MVar.wait");
        it->second.takers.push_back({token, listNil()});
    }
    return reinterpret_cast<void*>(Export::encode(unit()));
}

// Performs `put`. Captured: [0] the MVar id (PK_Int), [1] the value (boxed). Passed: [2] the resume closure.
// Arguments arrive as `readBindingEvaluator` describes.
static void* putBindingEvaluator(void* rawArgs[]) {
    int64_t id = static_cast<int64_t>(reinterpret_cast<uint64_t>(rawArgs[0]));
    uint64_t valueEnc  = reinterpret_cast<uint64_t>(rawArgs[1]);
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[2]);
    HPointer valueHP  = Export::decode(valueEnc);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto& sched = Elm::Platform::Scheduler::instance();
    auto it = s_mvars.find(id);
    if (it == s_mvars.end()) {
        resumeNotFound(resumeHP, id);
        return reinterpret_cast<void*>(Export::encode(unit()));
    }
    if (!it->second.value.has_value()) {
        {
            Elm::StackRootGuard guard(&valueHP, &resumeHP);
            processPutArrival(it->second, valueHP);
            HPointer succeedTask = sched.taskSucceed(unit());
            Elm::StackRootGuard guard2(&succeedTask);
            Elm::Platform::Scheduler::callClosure1(resumeHP, succeedTask);
        }
    } else {
        uint64_t token = sched.parkResume(resumeHP, Elm::Platform::HoldKind::Task, "MVar.wait");
        it->second.putters.push_back({token, valueHP});
    }
    return reinterpret_cast<void*>(Export::encode(unit()));
}

// ============================================================================
// Public API
// ============================================================================

int64_t newEmpty() {
    int64_t id = s_nextId++;
    s_mvars[id] = MVarSlot{};
    return id;
}

// read, take and put only build the Binding; because no MVar state is read here, the Tasks they return are
// safe to share and to cache in memoized CAF slots.

uint64_t read(uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    // readBindingEvaluator returns a boxed word (encoded unit), so the result kind is PK_Boxed.
    HPointer cb = allocClosureK(
        reinterpret_cast<Elm::EvalFunction>(readBindingEvaluator), 2,
        Elm::PK_Boxed);
    if (void* clPtr = Elm::Allocator::instance().resolve(cb)) {
        closureCapture(clPtr, unboxedInt(mvarId), Elm::PK_Int);
    }
    HPointer task = Elm::Platform::Scheduler::instance().taskBinding(cb);
    return Export::encode(task);
}

uint64_t take(uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    // takeBindingEvaluator returns a boxed word (encoded unit), so the result kind is PK_Boxed.
    HPointer cb = allocClosureK(
        reinterpret_cast<Elm::EvalFunction>(takeBindingEvaluator), 2,
        Elm::PK_Boxed);
    if (void* clPtr = Elm::Allocator::instance().resolve(cb)) {
        closureCapture(clPtr, unboxedInt(mvarId), Elm::PK_Int);
    }
    HPointer task = Elm::Platform::Scheduler::instance().taskBinding(cb);
    return Export::encode(task);
}

uint64_t put(uint64_t id, uint64_t value) {
    int64_t mvarId = static_cast<int64_t>(id);
    HPointer valueHP = Export::decode(value);
    Elm::StackRootGuard guard(&valueHP);
    // putBindingEvaluator returns a boxed word (encoded unit), so the result kind is PK_Boxed.
    HPointer cb = allocClosureK(
        reinterpret_cast<Elm::EvalFunction>(putBindingEvaluator), 3,
        Elm::PK_Boxed);
    if (void* clPtr = Elm::Allocator::instance().resolve(cb)) {
        closureCapture(clPtr, unboxedInt(mvarId), Elm::PK_Int);
        closureCapture(clPtr, boxed(valueHP), true);
    }
    HPointer task = Elm::Platform::Scheduler::instance().taskBinding(cb);
    return Export::encode(task);
}

// Performs `drop` and returns a Task succeeding with unit. `captured` is the Tuple2 `drop` builds: the id
// unboxed in field `a` (mask 0x1), unit in `b`.
static HPointer dropBody(HPointer captured) {
    Tuple2* tup =
        static_cast<Tuple2*>(Elm::Allocator::instance().resolve(captured));
    int64_t mvarId = tup->a.i;
    auto it = s_mvars.find(mvarId);
    if (it != s_mvars.end()) {
        // Taking each closure lets it be collected; releasing each hold lets the event loop go quiescent.
        auto& sched = Elm::Platform::Scheduler::instance();
        auto abandon = [&](std::deque<Waiter>& q) {
            while (!q.empty()) {
                Waiter w = q.front();
                q.pop_front();
                (void)sched.takePendingResume(w.token);
                sched.releaseHold(w.token);
            }
        };
        abandon(it->second.readers);
        abandon(it->second.takers);
        abandon(it->second.putters);
        s_mvars.erase(it);
    }
    return Export::decode(taskSucceedUnit());
}

uint64_t drop(uint64_t id) {
    HPointer payload = tuple2(
        unboxedInt(static_cast<int64_t>(id)), boxed(unit()), 0x1);
    return Export::encode(Eco::Kernel::makeBinding<dropBody>(payload));
}

void registerGcRootScanner() {
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        [](Elm::RootSet::EvacuateFn evacuate) {
            auto evacField = [&](HPointer& field) {
                uint64_t enc = Export::encode(field);
                evacuate(enc);
                field = Export::decode(enc);
            };
            for (auto& [id, slot] : s_mvars) {
                if (slot.value.has_value()) {
                    HPointer v = slot.value.value();
                    evacField(v);
                    slot.value = v;
                }
                // Readers' and takers' `pendingValue` is the nil constant, and their closures are rooted
                // by the scheduler.
                for (auto& w : slot.putters) {
                    evacField(w.pendingValue);
                }
            }
        });
}

} // namespace Eco::Kernel::MVar
