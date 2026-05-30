//===- MVar.cpp - MVar kernel module implementation -----------------------===//
//
// Single-threaded cooperative MVar. Blocking operations (read/take on empty,
// put on full) park the calling fiber via Task_Binding and are woken by the
// complementary operation. All state lives on the main scheduler thread; no
// locks beyond the scheduler's own pendingResumes mutex are needed.
//
// Three per-MVar waiter queues reflect the three distinct wake conditions:
//   * readers — read on empty; all woken together when a value arrives.
//   * takers  — take on empty; first in line consumes an arriving value.
//   * putters — put on full;  first in line fills the slot when it empties.
//
// A fiber parks by handing its resume closure to the scheduler's pending-
// resume registry (already GC-rooted) and pushing a Waiter{token, pendingV}
// onto the appropriate queue. pendingV is only used by putters.
//
//===----------------------------------------------------------------------===//

#include "MVar.hpp"
#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
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

struct Waiter {
    uint64_t token;
    // Only meaningful for putter waiters; listNil() for readers/takers.
    // Rooted by the external GC scanner registered below.
    HPointer pendingValue;
};

struct MVarSlot {
    std::optional<HPointer> value;
    std::deque<Waiter> readers;
    std::deque<Waiter> takers;
    std::deque<Waiter> putters;
};

// Invariants, restored after each public operation returns:
//   slot full  ⇒ readers empty ∧ takers empty
//   slot empty ⇒ putters empty
static std::unordered_map<int64_t, MVarSlot> s_mvars;
static int64_t s_nextId = 1;

// ============================================================================
// Wake path
// ============================================================================

// Re-enqueue a parked fiber, handing it `value` as its Task.succeed payload.
// Balances the incrementPendingAsync() that happened when the fiber parked.
// Callers must ensure `value` is reachable at call time; GC may run inside
// taskSucceed / callClosure1, but the StackRootGuard below keeps our local
// copy updated across those points.
static void wakeWaiter(uint64_t token, HPointer value) {
    auto& sched = Elm::Platform::Scheduler::instance();
    HPointer resumeClosure = sched.takePendingResume(token);
    if (isNil(resumeClosure)) {
        // Orphaned (shouldn't happen in single-threaded path, but defensive).
        sched.decrementPendingAsync();
        return;
    }
    HPointer v = value;
    HPointer succeedTask = listNil();
    {
        Elm::StackRootGuard guard(&resumeClosure, &v, &succeedTask);
        succeedTask = sched.taskSucceed(v);
        Elm::Platform::Scheduler::callClosure1(resumeClosure, succeedTask);
    }
    sched.decrementPendingAsync();
}

// A value `v` has just arrived at an empty slot. Wake all readers (each
// observes v; slot is conceptually full from their point of view), then
// hand v to the first taker if any (which consumes it, leaving the slot
// empty). If no taker consumes v, v is stored in the slot.
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
        // slot stays empty.
    } else {
        slot.value = v;
    }
}

// The slot has just been emptied by a take. If putters are parked, pop the
// first and treat its pending value as a freshly-arrived put. If waking
// intermediaries (readers + first taker) drains the slot again, cascade to
// the next putter.
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

// ============================================================================
// Binding callback evaluators
// ============================================================================
//
// Each evaluator is invoked by the scheduler when a Task_Binding is stepped.
// rawArgs layout mirrors the capture order in the kernel export: captured
// values first, resume closure last.

// Captured: [0]=unboxed Int (mvar id, PK_Int). Passed: [1]=resume closure (PK_Boxed HPointer).
//
// Per the Phase E typed-args convention (REP_ABI_001), `eco_closure_call_saturated`
// delivers each capture in `combined_args[i]` as raw primitive bits when its
// `closure->unboxed[i]` kind is PK_Int / PK_Float / PK_Char, NOT as an
// HPointer-to-boxed-prim. So the captured mvar id is the raw int64; only
// the resume closure (a true HPointer arg) goes through Export::decode.
static void* readBindingEvaluator(void* rawArgs[]) {
    int64_t id = static_cast<int64_t>(reinterpret_cast<uint64_t>(rawArgs[0]));
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto& sched = Elm::Platform::Scheduler::instance();
    auto it = s_mvars.find(id);
    if (it == s_mvars.end()) {
        // MVar was dropped between the read call and this callback. Abandon.
        return reinterpret_cast<void*>(Export::encode(unit()));
    }
    if (it->second.value.has_value()) {
        HPointer v = it->second.value.value();
        Elm::StackRootGuard guard(&resumeHP, &v);
        HPointer succeedTask = sched.taskSucceed(v);
        Elm::StackRootGuard guard2(&succeedTask);
        Elm::Platform::Scheduler::callClosure1(resumeHP, succeedTask);
    } else {
        uint64_t token = sched.registerPendingResume(resumeHP);
        sched.incrementPendingAsync();
        it->second.readers.push_back({token, listNil()});
    }
    return reinterpret_cast<void*>(Export::encode(unit()));
}

// Captured: [0]=unboxed Int (mvar id, PK_Int). Passed: [1]=resume closure (PK_Boxed HPointer).
// See readBindingEvaluator for the typed-args convention rationale.
static void* takeBindingEvaluator(void* rawArgs[]) {
    int64_t id = static_cast<int64_t>(reinterpret_cast<uint64_t>(rawArgs[0]));
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[1]);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto& sched = Elm::Platform::Scheduler::instance();
    auto it = s_mvars.find(id);
    if (it == s_mvars.end()) {
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
        uint64_t token = sched.registerPendingResume(resumeHP);
        sched.incrementPendingAsync();
        it->second.takers.push_back({token, listNil()});
    }
    return reinterpret_cast<void*>(Export::encode(unit()));
}

// Captured: [0]=unboxed Int (mvar id, PK_Int), [1]=value HPointer (PK_Boxed).
// Passed:   [2]=resume closure (PK_Boxed HPointer).
// See readBindingEvaluator for the typed-args convention rationale.
static void* putBindingEvaluator(void* rawArgs[]) {
    int64_t id = static_cast<int64_t>(reinterpret_cast<uint64_t>(rawArgs[0]));
    uint64_t valueEnc  = reinterpret_cast<uint64_t>(rawArgs[1]);
    uint64_t resumeEnc = reinterpret_cast<uint64_t>(rawArgs[2]);
    HPointer valueHP  = Export::decode(valueEnc);
    HPointer resumeHP = Export::decode(resumeEnc);

    auto& sched = Elm::Platform::Scheduler::instance();
    auto it = s_mvars.find(id);
    if (it == s_mvars.end()) {
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
        uint64_t token = sched.registerPendingResume(resumeHP);
        sched.incrementPendingAsync();
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

uint64_t read(uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    if (it == s_mvars.end()) {
        // Recoverable rather than a fatal abort (IO_ERR_002 / D6): surface a
        // neutral IO error tuple so Eco.MVar.{read,take,put} fails with IOError.
        return taskFailIO(0, "", "MVar not found: " + std::to_string(mvarId));
    }
    if (it->second.value.has_value()) {
        return taskSucceed(it->second.value.value());
    }
    // readBindingEvaluator returns a boxed Task HPtr → K = PK_Boxed.
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
    auto it = s_mvars.find(mvarId);
    if (it == s_mvars.end()) {
        // Recoverable rather than a fatal abort (IO_ERR_002 / D6): surface a
        // neutral IO error tuple so Eco.MVar.{read,take,put} fails with IOError.
        return taskFailIO(0, "", "MVar not found: " + std::to_string(mvarId));
    }
    if (it->second.value.has_value()) {
        HPointer v = it->second.value.value();
        it->second.value.reset();
        {
            Elm::StackRootGuard guard(&v);
            processTakeDeparture(it->second);
        }
        return taskSucceed(v);
    }
    // takeBindingEvaluator returns a boxed Task HPtr → K = PK_Boxed.
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
    auto it = s_mvars.find(mvarId);
    if (it == s_mvars.end()) {
        // Recoverable rather than a fatal abort (IO_ERR_002 / D6): surface a
        // neutral IO error tuple so Eco.MVar.{read,take,put} fails with IOError.
        return taskFailIO(0, "", "MVar not found: " + std::to_string(mvarId));
    }
    HPointer valueHP = Export::decode(value);
    if (!it->second.value.has_value()) {
        {
            Elm::StackRootGuard guard(&valueHP);
            processPutArrival(it->second, valueHP);
        }
        return taskSucceedUnit();
    }
    Elm::StackRootGuard guard(&valueHP);
    // putBindingEvaluator returns a boxed Task HPtr → K = PK_Boxed.
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

uint64_t drop(uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    if (it != s_mvars.end()) {
        // Elm.MVar.drop docs: "Any pending waiters are abandoned." Release
        // each waiter's resume closure from the scheduler's registry (so it
        // may be GC'd) and balance the pendingAsync counter so the event
        // loop can exit. The closures are never invoked; those fibers are
        // silently dropped.
        auto& sched = Elm::Platform::Scheduler::instance();
        auto abandon = [&](std::deque<Waiter>& q) {
            while (!q.empty()) {
                Waiter w = q.front();
                q.pop_front();
                (void)sched.takePendingResume(w.token);
                sched.decrementPendingAsync();
            }
        };
        abandon(it->second.readers);
        abandon(it->second.takers);
        abandon(it->second.putters);
        s_mvars.erase(it);
    }
    return taskSucceedUnit();
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
                // Putter waiters carry the value they're waiting to store.
                // Reader/taker waiters only carry a token (resume closure
                // is already rooted by the scheduler's pendingResumes_).
                for (auto& w : slot.putters) {
                    evacField(w.pendingValue);
                }
            }
        });
}

} // namespace Eco::Kernel::MVar
