// W2: termination -- publish -> goIdle vs the decider
// (plans/threaded-gc-tla-W-weak-memory.md §6). The REAL SliceControl
// (goIdle, reactivate, returnTickets) and WorkStealingDeque from MarkWork.hpp.
//
// The decider is a straight-line COPY of one round of idleUntilWorkOrDone
// (MarkWork.hpp:370-395; the real loop spins through backoff(), which the
// checker cannot run). It keeps BOTH of the round's work checks (:375 and
// :382) and omits only the stopRequested() read (§6.3, trap 11). Driver
// mutants patch this copy; header mutants patch MarkWork.hpp (mutate.sh).
//
// Variants (drivers.txt):
//   default                  M publishes one entry, then goIdle (MarkWork.hpp:464-466)
//   -DW2_PRIV                M's entry stays private (priv = 1), M goes idle
//   -DW2_IDLE_BEFORE_PUBLISH M goes idle BEFORE publishing (M2's idle_before_publish)
//   -DW2_ONE_SCAN            the decider without the round's first check
//   -DW2_MINOR_ANYWORK       anyWork reads the deques only (the minor envs)
//   -DW2_REACTIVATE          a third, idle participant R sees M's entry,
//                            reactivates and steals it
//   -DW2_RETURNED_TICKETS    the budget starts at 0; M returns its tickets
//                            (returnTickets) before goIdle
// Driver mutants: MUTANT_W2_RELAXED_DECIDER_LOAD (the copy's state load
// relaxed), MUTANT_W2_DONE_STORE (with W2_REACTIVATE: the done decision as a
// check-then-store instead of the CAS from the observed word; the negative
// control of w2_reactivate).
#include "MarkWork.hpp"
#include "wdriver.hpp"               // last: it redefines assert

using namespace Elm::markwork;

#ifdef MUTANT_W2_RELAXED_DECIDER_LOAD
constexpr std::memory_order kStateLoad = std::memory_order_relaxed;
#else
constexpr std::memory_order kStateLoad = std::memory_order_acquire;   // MarkWork.hpp:372
#endif

static SliceControl* c;
alignas(WorkStealingDeque) static unsigned char dq_mem[sizeof(WorkStealingDeque)];
static WorkStealingDeque* dqM;                 // M's deque
static std::atomic<uint64_t> privM{0};         // M's MarkWorker::priv
static int decided;                            // written by D only
#ifdef W2_REACTIVATE
static int reactivated;                        // written by R only
static uint64_t stolen;                        // written by R only
#endif

static void* marker(void*) {
#if defined(W2_PRIV)                           // the entry stays private (test_leave_private_on_exit_)
    privM.store(1, std::memory_order_relaxed);     // pushGrey, OldGenSpace.hpp:989
    c->goIdle();
#elif defined(W2_IDLE_BEFORE_PUBLISH)          // goIdle, THEN publishAll
    privM.store(1, std::memory_order_relaxed);
    c->goIdle();
    dqM->push(7);                              // publishAll, OldGenSpace.hpp:977-982
    privM.store(0, std::memory_order_relaxed);
#elif defined(W2_RETURNED_TICKETS)
    MarkerCounters w;
    w.tickets = 5;                             // claimed and unconsumed
    dqM->push(7);                              // publishAll
    returnTickets(w, *c);                      // budget.fetch_add(5, relaxed), MarkWork.hpp:298-304
    c->goIdle();
#else                                          // the code's exit order, MarkWork.hpp:464-466
    dqM->push(7);                              // publishAll (one entry)
    c->goIdle();                               // fetch_sub(acq_rel)
#endif
    return nullptr;
}

// ParallelEnv::anyWork (OldGenSpace.cpp:3498-3504), M's slot: deque first, then priv.
static bool anyWorkM() {
#ifdef W2_MINOR_ANYWORK                        // MinorEnv/RegionEnv/TenureParEnv: deques only
    return !dqM->emptyApprox();
#else
    return !dqM->emptyApprox() || privM.load(std::memory_order_relaxed) != 0;
#endif
}

static void* decider(void*) {                  // D: nothing to publish; goes idle, decides once
    c->goIdle();
    const uint64_t s = c->state.load(kStateLoad);                                  // :372
    if (s & SliceControl::kDone) return nullptr;                                   // :373
#ifndef W2_ONE_SCAN
    if (c->budget.load(std::memory_order_acquire) > 0 && anyWorkM()) return nullptr;   // :375 (reactivate)
#endif
    if ((s & SliceControl::kActiveMask) == 0) {                                    // :379
        const bool work = c->budget.load(std::memory_order_acquire) > 0 && anyWorkM();   // :382
#ifdef MUTANT_W2_DONE_STORE                    // the done decision as check-then-store, no CAS
        if (!work && c->state.load(std::memory_order_acquire) == s) {
            c->state.store(s | SliceControl::kDone, std::memory_order_release);
            decided = 1;
        }
#else
        uint64_t expect = s;
        if (!work && c->state.compare_exchange_strong(expect, s | SliceControl::kDone,
                                                      std::memory_order_acq_rel,
                                                      std::memory_order_acquire))  // :385-387
            decided = 1;
#endif
    }
    return nullptr;
}

#ifdef W2_REACTIVATE
// R: an idle member (not counted active) that runs one round of its own idle
// loop: it sees M's entry, reactivates (the REAL reactivate: CAS, epoch bump)
// and steals the entry.
static void* rival(void*) {
    if (c->budget.load(std::memory_order_acquire) > 0 && anyWorkM()) {            // :375
        if (c->reactivate()) {                                                     // :376
            reactivated = 1;
            stolen = dqM->steal();
        }
    }
    return nullptr;
}
#endif

int main() {
#if defined(W2_RETURNED_TICKETS)
    const int64_t budget = 0;                  // M holds the only tickets
#else
    const int64_t budget = 8;
#endif
    // Members M and D are active at the start (R, when present, is idle).
    c = new SliceControl(budget, /*members=*/2, /*jitter=*/0, /*active=*/2);
    dqM = new (dq_mem) WorkStealingDeque(1);
    wthread m = spawn(marker), d = spawn(decider);
#ifdef W2_REACTIVATE
    wthread r = spawn(rival);
    join(r);
#endif
    join(m);
    join(d);
    const bool left = !dqM->emptyApprox() || privM.load(std::memory_order_relaxed) != 0;
    assert(!(decided && left));                // done with work left: impossible
#ifdef W2_REACTIVATE
    assert(!(decided && reactivated));         // done while a reactivated member holds work
    assert(!reactivated || stolen == 7 || stolen == kAbort);
#endif
    return 0;
}
