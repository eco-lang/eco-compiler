// W1: the Chase-Lev work-stealing deque, as written in MarkWork.hpp:63-195
// (plans/threaded-gc-tla-W-weak-memory.md §5). The REAL WorkStealingDeque.
//
// One owner pushes three entries into a two-slot array (so grow() runs unless
// a steal came first) and takes twice; W1_THIEVES thieves steal once each;
// main drains what is left after the joins. Every entry must come out exactly
// once, a thief must see the owner's plain payload write that preceded the
// push, and nothing may race (payload, Array::mask / Array::buf written
// plainly by grow()'s Array::make).
//
// Variants (drivers.txt): -DW1_THIEVES=2 (the smallest shape in which a stale
// top in take() can duplicate an entry, §2.4); the paper's orders and the
// mutants patch the header through mutate.sh.
#include "MarkWork.hpp"
#include "wdriver.hpp"               // last: it redefines assert

using Elm::markwork::WorkStealingDeque;
using Elm::markwork::kAbort;
using Elm::markwork::kEmpty;

#ifndef W1_THIEVES
#define W1_THIEVES 1
#endif

// Placement new into a static buffer: the deque's alignas(64) members would
// otherwise need the aligned operator new.
alignas(WorkStealingDeque) static unsigned char dq_mem[sizeof(WorkStealingDeque)];
static WorkStealingDeque* dq;
static uint64_t payload[4];                            // NON-atomic, written before the push
static int got_owner[4], got_thief[W1_THIEVES][4];    // each row written by one thread only

static void* owner(void*) {
    for (uint64_t i = 1; i <= 3; ++i) {                // 3 pushes into 2 slots
        payload[i] = i * 10;
        dq->push(i);
    }
    for (int k = 0; k < 2; ++k) {
        const uint64_t e = dq->take();
        if (e != kEmpty) {
            assert(payload[e] == e * 10);
            ++got_owner[e];
        }
    }
    return nullptr;
}

static void* thief(void* arg) {
    const int me = intOf(arg);
    const uint64_t e = dq->steal();
    if (e != kEmpty && e != kAbort) {
        assert(e >= 1 && e <= 3);                      // a real entry, not a stale slot
        assert(payload[e] == e * 10);                  // message passing
        ++got_thief[me][e];
    }
    return nullptr;
}

int main() {
    dq = new (dq_mem) WorkStealingDeque(/*log_initial=*/1);
    wthread a = spawn(owner);
    wthread t[W1_THIEVES];
    for (int j = 0; j < W1_THIEVES; ++j) t[j] = spawn(thief, argOf(j));
    join(a);
    for (int j = 0; j < W1_THIEVES; ++j) join(t[j]);
    for (int k = 0; k < 3; ++k) {                      // drain (at most 3 entries remain)
        const uint64_t e = dq->take();
        if (e == kEmpty) break;
        assert(e >= 1 && e <= 3);
        ++got_owner[e];
    }
    assert(dq->take() == kEmpty);
    for (int i = 1; i <= 3; ++i) {
        int n = got_owner[i];
        for (int j = 0; j < W1_THIEVES; ++j) n += got_thief[j][i];
        assert(n == 1);                                // exactly once: none lost, none duplicated
    }
    dq->~WorkStealingDeque();
    return 0;
}
