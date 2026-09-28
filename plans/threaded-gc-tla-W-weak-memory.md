# Threaded GC: weak-memory companions W1–W5

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). Driver sketches syntax-checked only; no
checker has run. Every sketch in §5–§9 compiles with `g++ -std=c++20 -fsyntax-only -Wall -Wextra`
against the real headers in `runtime/src/allocator/`, with no warnings. No memory-model checker
has been installed or run. Claims about what the tools can do are marked **(spike)**: the Step 0
feasibility spike (§4.2) confirms or refutes them.

**Parents:** `plans/threaded-gc-tla-verification.md` (§1 link L3, §5.3, rule A4) and
`plans/threaded-gc-tla-primer.md` (§3.6).

**Consumers:** the TLA+ models M1–M5. Each model assumes sequential consistency (SC). Each
assumption a model makes about memory orders is listed in its A4 row and discharged here.

---

## 1. Why this exists

The TLA+ models run on a sequentially consistent machine: one global order of steps, where every
step sees every earlier one. The real code does not run there. It uses `relaxed`, `acquire`,
`release`, `acq_rel` and `seq_cst` atomics, stand-alone fences, and plain (non-atomic) memory
guarded by those atomics. On x86 most of this "just works"; on ARM (the macOS build) it does not.
The C++ standard allows the compiler to reorder relaxed operations on any machine.

So a model can be right while the C++ is wrong, in two ways:
1. **An ordering the argument needs is missing.** For example, a thief reads an entry before the
   owner's write of that entry is visible.
2. **A data race.** Two threads touch the same memory, at least one access is plain, and nothing
   orders them. This is undefined behaviour even if every observed value looks harmless (register
   CR-001, CR-002).

W1–W5 check these two failure kinds **on the real code** (or, for W4, on a pinned reduction of
it). They use a tool that knows the C11 memory model and explores every execution the model
allows, for a small bounded program.

| Id | Protocol | Code | Discharges an A4 assumption of |
|---|---|---|---|
| W1 | Chase–Lev work-stealing deque | `MarkWork.hpp:63-195` | M2, M3, M5 (the deque is linearizable and passes entry contents) |
| W2 | termination: publish → `goIdle` vs the decider | `MarkWork.hpp:246-395`, `OldGenSpace.cpp:3498` | M2 (a decider that saw `active == 0` also sees published work) |
| W3 | one mark byte, many writers | `OldGenSpace.cpp:3039`, `OldGenSpace.hpp:1822`, `BitmapScan.hpp:34/37`, `OldGenSpace.cpp:5360`, `OldGenTenure.cpp:177/214` | M1, M4 (indivisible `fetch_or`, byte ownership), and it reproduces CR-001/CR-002 |
| W4 | publishing a new old-gen block to background markers | `OldGenSpace.cpp:586-664, 1797`, `ReservedArray.hpp:110-174` | M1 (markers see complete block metadata) |
| W5 | claim → copy → publish (header word; 7c shadow word) | `MinorWork.hpp:51-75`, `TenureWork.hpp:73-95, 248-266` | M3, M5 (exactly one copy; a forward names a complete copy) |

---

## 2. The memory-model ideas needed, with examples

This section is short on purpose: just enough to read the drivers and the checker's output.

### 2.1 Modification order and coherence

Every atomic location has a single total order of all writes to it, its **modification order**.
All threads agree on it. **Coherence** says a thread never sees a location go backwards: once it
has read (or written) a value, its later reads return that value or a later one in modification
order.

Example: `region_end_` only grows during a mark cycle. A background marker loads it `relaxed` and
may get a stale value. Coherence plus the launch's happens-before (§2.2) guarantee it is at least
the value from t0, so it still covers every t0 block. W4 relies on exactly this.

### 2.2 Happens-before and synchronizes-with

**Happens-before (HB)** is the order C++ guarantees. It is built from two things:
- program order inside a thread;
- **synchronizes-with** edges between threads: a release store (or release RMW) read by an
  acquire load; a mutex unlock followed by the next lock of the same mutex; thread creation;
  thread join.

If write W happens-before read R of the same location, R sees W or something later. If two
accesses to one location are not ordered by HB, at least one writes, and at least one is plain,
that is a **data race** and the program's behaviour is undefined.

Message passing, the pattern behind W1, W4 and W5:
```cpp
// thread A                          // thread B
data = 42;                           if (flag.load(std::memory_order_acquire) == 1)
flag.store(1, std::memory_order_release);   assert(data == 42);   // always true
```
Make either side `relaxed` and the assert can fail. Worse, B's read of `data` becomes a data race.

### 2.3 Release sequences, and why "every write to the state word is an RMW" matters

A release store heads a **release sequence**: it and every later read-modify-write (RMW) on the
same location. In C++20, only RMWs extend it; plain stores end it. An acquire load that reads
from *any* write in the sequence synchronizes with the head.

`SliceControl::state` is written only by RMWs after construction (`fetch_sub` in `goIdle`, CAS in
`reactivate` and in the done decision). Say marker M does `goIdle` (acq_rel). Then marker R
reactivates (CAS) and goes idle again (`fetch_sub`). Decider D's acquire load still synchronizes
with M's `goIdle`, so everything M published before its `goIdle` is visible to D. W2 checks this.

### 2.4 Fences

`std::atomic_thread_fence(release)` followed by a relaxed store acts like a release store, for any
acquire load (or acquire fence) that reads that store. The Chase–Lev `push` uses exactly this: a
relaxed element store, a release fence, then a relaxed `bottom` store. A `seq_cst` fence also
takes part in the single total order of seq_cst operations; that is what `take` and `steal` use to
agree on who gets the last element.

**Why TSan misses stand-alone fences:** ThreadSanitizer models atomics operation by operation and
ignores `atomic_thread_fence`. With the paper's relaxed element store plus release fence, TSan sees
a relaxed store and a relaxed load and reports a false race on the entry's contents. Phase 6
therefore strengthened the element store to `release` and the steal's element load to `acquire`
(`MarkWork.hpp:83-88`). W1 checks both the code as written and the paper's original orders.

### 2.5 `relaxed`, and what it is still good for

A relaxed atomic gives indivisibility and coherence, and nothing else: no ordering with other
locations. That is enough for:
- the mark byte's `fetch_or`: two markers setting different bits of one byte both succeed;
- ticket pools, whose correctness argument is modification order on the pool itself.

It is **not** enough to make other memory visible.

### 2.6 Litmus tests, and what a stateless model checker does

A **litmus test** is a tiny concurrent program (2–4 threads, a handful of accesses) plus a
question: "can this final state happen?". The drivers below are litmus tests built from the real
functions.

- **TSan** watches *one* execution: whatever the scheduler and hardware did in that run.
- **A stateless model checker** (GenMC; CDSChecker and C11Tester are related tools) enumerates
  *every* execution of a small, bounded program that the memory model allows. That includes
  executions where a relaxed load returns an old value that x86 hardware would practically never
  produce. It reports:
  - assertion failures, with the execution that caused them;
  - data races (plain accesses unordered by HB);
  - optionally, memory errors.

  **(spike)** GenMC's documentation describes it as exhaustive for RC11 (and IMM), with the
  program compiled to LLVM IR.

Example output shape (illustrative; the spike records GenMC's real format):
```
Error detected: Safety violation!
Event (2, 7) in graph:
  thread 1: push(7) ... fetch_sub(state) [acq_rel]
  thread 2: fetch_sub(state), load(state) [acquire] reads (1,5), load(bottom) [relaxed] reads INIT
Assertion violation: !(decided && !dqM->emptyApprox())
```
Reading it: thread 2's relaxed load of `bottom` read the initial value, although thread 1's push
happened-before thread 1's `fetch_sub`, which thread 2 read. That is only possible if the
synchronizes-with edge is missing, which is the W2 mutant of §6.

---

## 3. What the drivers look like

Every driver is a stand-alone C++ file in `test/genmc/`:
- it `#include`s the real std-only header (`MarkWork.hpp`, `MinorWork.hpp`, `TenureWork.hpp`,
  `BitmapScan.hpp`) with `-I runtime/src/allocator`;
- it uses **plain pthreads**, because model checkers intercept `pthread_create` and `pthread_join`,
  while `std::thread` lives in precompiled libstdc++ **(spike)**;
- it bounds every loop by construction: no backoff loops, and a waiting spin is written as
  `VERIFIER_ASSUME(cond)` (`__VERIFIER_assume` in GenMC **(spike)**);
- it states the property as `assert`s after `pthread_join`, plus the checker's built-in data-race
  detection.

The common header:

```cpp
// test/genmc/wdriver.hpp
#pragma once
#include <pthread.h>
#include <cassert>
#ifndef VERIFIER_ASSUME
#define VERIFIER_ASSUME(c) do { if (!(c)) return nullptr; } while (0)   // tool: __VERIFIER_assume
#endif
inline pthread_t spawn(void* (*f)(void*), void* arg = nullptr) {
    pthread_t t; pthread_create(&t, nullptr, f, arg); return t;
}
inline void join(pthread_t t) { pthread_join(t, nullptr); }
```

**Mutants.** Each driver has one or more mutants. A mutant is a copy of the code under test with
one memory order weakened (or one lock removed), selected by `-DMUTANT_<NAME>`, and the checker
**must** flag it. The W1–W5 mutants patch the header's text through a small sed-driven copy step
(`test/genmc/mutate.sh`, which writes `build/genmc/<name>/MarkWork.hpp`). The pinned header in the
tree is never edited. A mutant that the checker does not flag means the driver is too small to
exercise the order it claims to test, and fails `genmc-check` (parent plan §2 rule A6).

---

## 4. Tool choice and the Step 0 spike

### 4.1 Candidates

| Tool | What it is | Pro | Con / to verify |
|---|---|---|---|
| **GenMC** (first choice) | stateless model checker over LLVM IR for RC11/IMM/SC; exhaustive for bounded programs | explores all executions; reports races and assertion failures with the execution graph | **(spike)** supported LLVM versions (ours is 21; GenMC pins its own); C++ support is partial: does it accept `std::atomic_ref` (C++20) on plain objects, templates, `new`/`delete`, `std::vector::push_back` (used by `grow()`'s `retired_`)? |
| **C11Tester** | dynamic tester: an instrumenting LLVM pass plus a runtime that controls scheduling and weak-memory reads | handles bigger programs; C++ friendly **(spike)** | random exploration, not exhaustive: it can miss a bad execution, so a pass is weaker evidence |
| **herd7** (litmus, RC11 `.cat` model) | exhaustive enumeration of hand-written litmus tests | the reference semantics; tiny tests are exact | tests are hand-derived from the code, so drift is only caught by the canary regions (§11) |
| CDSChecker, Dartagnan | older exhaustive C11 checker / bounded model checker for weak memory | alternatives if the above fail | not evaluated |

### 4.2 The spike (plan Step 0, before any W is written)

Goal: one working W1 run and one flagged W1 mutant, reproducible in the dev image.

1. **Build GenMC in its own Docker stage** (`docker/genmc.Dockerfile`, a new file) with the LLVM
   release GenMC supports, and copy `/opt/genmc` into the dev image, like `/opt/llvm-mlir`. Pin
   the GenMC commit and LLVM version with SHAs. Do not try to build it against our LLVM 21.
2. Run `w1_deque.cpp` (§5.4) unmodified.
   - If GenMC rejects the header (C++20, `std::atomic_ref`, `<chrono>`/`<thread>` includes,
     `new[]`, `std::vector`), try `-std=c++17` with `std::atomic_ref` provided by a GenMC-side
     shim (`genmc_atomic_ref.hpp`, mapping `atomic_ref<T>` onto `__atomic_*` builtins on the
     object).
   - If the header still fails, fall back to a **transliteration**: a shim copy of the tested
     functions with `std::vector` replaced by fixed arrays. Each transliterated function carries a
     `TLA-REGION`-style canary pin of the original (§11), so drift fails the build.
3. Check that the **mutants are flagged** (§5.5). A checker that passes everything proves nothing.
4. Record in the parent plan §3:
   - the GenMC commit and LLVM version;
   - whether the real headers compile or a shim is needed;
   - the command line, e.g. `genmc --rc11 --check-liveness=false -- -std=c++20 -I... w1_deque.cpp`
     **(spike)**;
   - the time per driver.
5. If GenMC cannot be made to work in a reasonable effort, use **C11Tester** for W1–W5, with a high
   iteration count and a fixed seed list (a pass is then "no violation in N random executions"),
   **plus herd7 litmus tests** for the core of each W (§5.3, §6.3, …). herd7 alone is the last
   resort.

---

## 5. W1: the Chase–Lev deque

### 5.1 Code under test (`MarkWork.hpp`, current tree)

| Operation | Lines | Orders as written | PPoPP'13 fig. 1 |
|---|---|---|---|
| `push` | 76-91 | `bottom` relaxed load; `top` **acquire** load; array relaxed; element store **release**; fence **release**; `bottom` relaxed store | element store relaxed |
| `take` | 94-115 | `bottom` relaxed load/store; fence **seq_cst**; `top` relaxed; element relaxed; last element: CAS `top` seq_cst/relaxed | same |
| `steal` | 118-132 | `top` acquire; fence **seq_cst**; `bottom` acquire; array acquire; element **acquire**; CAS `top` seq_cst/relaxed | array consume, element relaxed |
| `grow` | 176-188 | copy `[t, b)` relaxed load → release store; old array pushed onto owner-only `retired_`; `array_` release store | same |
| `emptyApprox` | 135-137 | relaxed loads (a hint) | — |

### 5.2 Property

1. Every pushed entry is returned **exactly once**, by `take` or by `steal`. No entry is returned
   twice, and none is lost.
2. **Message passing:** if a thief steals entry `i`, it sees everything the owner wrote before
   `push(i)`. The phase 6 minor needs this: a thief scans a copy that another worker just wrote
   (`MarkWork.hpp:83-88`).
3. No data race, including across `grow()`: a thief may read the *old* array, which is only retired
   (never freed) during the run.

### 5.3 Driver

```cpp
// test/genmc/w1_deque.cpp
#include "wdriver.hpp"
#include "MarkWork.hpp"
using Elm::markwork::WorkStealingDeque;
using Elm::markwork::kEmpty;
using Elm::markwork::kAbort;

static WorkStealingDeque* dq;
static uint64_t payload[4];                 // NON-atomic, written before the push
static int got_owner[4], got_thief[4];      // each written by one thread only

static void* owner(void*) {
    for (uint64_t i = 1; i <= 3; ++i) {     // 3 pushes into 2 slots: forces grow()
        payload[i] = i * 10;
        dq->push(i);
    }
    for (int k = 0; k < 2; ++k) {
        const uint64_t e = dq->take();
        if (e != kEmpty) { assert(payload[e] == e * 10); ++got_owner[e]; }
    }
    return nullptr;
}
static void* thief(void*) {
    const uint64_t e = dq->steal();
    if (e != kEmpty && e != kAbort) { assert(payload[e] == e * 10); ++got_thief[e]; }
    return nullptr;
}
int main() {
    dq = new WorkStealingDeque(/*log_initial=*/1);
    pthread_t a = spawn(owner), b = spawn(thief);
    join(a); join(b);
    for (;;) { const uint64_t e = dq->take(); if (e == kEmpty) break; ++got_owner[e]; }
    for (int i = 1; i <= 3; ++i) assert(got_owner[i] + got_thief[i] == 1);
    delete dq;
    return 0;
}
```

Variants, each a separate compile:
- `w1_deque_2thieves`: two thieves and one owner `take`. This is the case where the owner's take
  and a steal race for the last element.
- `w1_deque_paper`: the paper's orders (element store/load relaxed). **Expected to pass**; it shows
  the phase 6 strengthening was for TSan, not for correctness.
- The herd7 fallback: the three-event core "push(e) ∥ steal() ∥ take()" on a one-element deque.

**Must be impossible:**
- `got_owner[i] + got_thief[i] != 1`: a lost or duplicated entry;
- a thief reading a stale `payload`;
- a data race report on `payload`, `buf` or `array_`.

### 5.4 Mutants

| Mutant | Change | Bad execution the checker must show |
|---|---|---|
| `W1_NO_TAKE_FENCE` | remove the `seq_cst` fence in `take` (line 98) | the owner decrements `bottom`, the thief reads the old `bottom` and the same `top`; both see one element, the thief's CAS succeeds and the owner's `t == b` path is not taken because its `top` load is stale. **Both return entry 1** (`got == 2`) |
| `W1_RELAXED_PUBLISH` | element store `relaxed` **and** no release fence in `push` (lines 88-89) | the thief reads `bottom` (acquire) from the owner's relaxed store, but nothing orders `payload[i] = …` before it. The thief's read of `payload[i]` is a **data race** or returns 0 |
| `W1_STEAL_RELAXED_BOTTOM` | `bottom` load in `steal` relaxed (line 121) with the paper's relaxed element load | the thief sees the new `bottom` without synchronizing, and reads an element slot not yet written (0 = `kEmpty` in a live slot) or a stale payload **(spike: confirm it is reachable at this size)** |

### 5.5 Pass criteria

The as-written and paper variants pass with no race. `W1_NO_TAKE_FENCE` and `W1_RELAXED_PUBLISH`
are flagged. `W1_STEAL_RELAXED_BOTTOM` is recorded either way, with a note.

---

## 6. W2: termination (publish → `goIdle` vs the decider)

### 6.1 Code under test

| Piece | Location | Orders |
|---|---|---|
| `goIdle` | `MarkWork.hpp:246` | `state.fetch_sub(1, acq_rel)` |
| `reactivate` | `MarkWork.hpp:248-257` | CAS `acq_rel` / `acquire` |
| decider | `MarkWork.hpp:369-395` (`idleUntilWorkOrDone`) | `state.load(acquire)`; `budget.load(acquire)`; `env.anyWork()`; done-CAS `acq_rel` |
| `ParallelEnv::anyWork` | `OldGenSpace.cpp:3498-3504` | per slot: `deque.emptyApprox()` (two relaxed loads), `priv.load(relaxed)` |
| publishing | `OldGenSpace::publishAll` (`OldGenSpace.hpp:977`), `pushGrey` (`:983`) | deque `push` (§5); `priv.store(relaxed)` |
| exit order | `MarkWork.hpp:464-466, 476-478` | `publishAll` → `returnTickets` (relaxed `fetch_add`) → `goIdle` |

### 6.2 Property

**Question:** can a decider see `active == 0` (acquire) and still miss work that a marker published
before its `goIdle`?

**Expected answer:** no. The decider's acquire load reads from the release sequence headed by that
marker's `goIdle` (§2.3). That makes the marker's `push` (its `bottom` store) and its
`returnTickets` happen-before the decider's relaxed `anyWork` loads and its `budget` load. By
coherence, those loads return the published values or later ones. The M2 model assumes exactly
this.

### 6.3 Driver

```cpp
// test/genmc/w2_termination.cpp
#include "wdriver.hpp"
#include "MarkWork.hpp"
using namespace Elm::markwork;

static SliceControl* c;
static WorkStealingDeque* dqM;              // M's deque
static std::atomic<uint64_t> privM{0};      // M's published private size
static int decided;                          // written by D only

static void* marker(void*) {                // M: publish its last entry, then go idle
    dqM->push(7);                            // publishAll (one entry)
    c->goIdle();                             // fetch_sub(acq_rel)
    return nullptr;
}
static void* decider(void*) {               // D: already has nothing; goes idle, decides once
    c->goIdle();
    const uint64_t s = c->state.load(std::memory_order_acquire);
    if ((s & SliceControl::kActiveMask) == 0) {
        const bool work = c->budget.load(std::memory_order_acquire) > 0 &&
                          (!dqM->emptyApprox() ||
                           privM.load(std::memory_order_relaxed) != 0);
        uint64_t expect = s;
        if (!work && c->state.compare_exchange_strong(expect, s | SliceControl::kDone,
                                                      std::memory_order_acq_rel,
                                                      std::memory_order_acquire))
            decided = 1;
    }
    return nullptr;
}
int main() {
    c = new SliceControl(/*budget=*/8, /*members=*/2, /*jitter=*/0, /*active=*/2);
    dqM = new WorkStealingDeque(1);
    pthread_t m = spawn(marker), d = spawn(decider);
    join(m); join(d);
    assert(!(decided && !dqM->emptyApprox()));   // done with work left: impossible
    return 0;
}
```

The decider body is a straight-line copy of one round of `idleUntilWorkOrDone`, because the real
loop spins. If the spike shows GenMC handles the real loop with `__VERIFIER_assume`-style
spin-assumption **(spike)**, add `w2_real_loop.cpp`. It runs `runMarkerLoop` itself with a
two-entry synthetic Env (the shape of `mark_harness.cpp`'s `SynthEnv`) and two members.

Variants:
- `w2_priv`: M's last entry is **private** (`privM.store(1, relaxed)` instead of `push`) and M goes
  idle without publishing. This is the "goIdle before publishAll" order (M2's `idle_before_publish`
  mutant). **Expected to pass** in the mark environment, because `priv` is visible through the same
  synchronizes-with. That is the weak-memory half of M2's answer to 05c trap 5.
- `w2_reactivate`: a third thread R that is idle, sees work and reactivates. Assert that `decided`
  and R's successful `reactivate` never both happen. This is pure RMW atomicity on `state`, but
  cheap to include.
- `w2_returned_tickets`: M holds tickets and returns them (`budget.fetch_add(relaxed)`) before
  `goIdle`. The decider must see `budget > 0`.

### 6.4 Mutants

| Mutant | Change | Bad execution |
|---|---|---|
| `W2_RELAXED_GOIDLE` | `fetch_sub(1, relaxed)` (line 246) | D reads `active == 0` from M's relaxed RMW, but no synchronizes-with edge exists. D's relaxed loads of `bottom`/`top` return the initial values, so the deque looks empty, D decides, and the assert fails: **work left after done** |
| `W2_RELAXED_DECIDER_LOAD` | `state.load(relaxed)` (line 372) | same outcome from the other side |
| `W2_PUBLISH_AFTER_IDLE_MINOR` | `w2_priv` with the minor environment's `anyWork` (deques only) | D decides while M's entry is private; M then publishes into a finished run. This is also an SC bug, so M2 catches it too; W2 confirms nothing weaker rescues it |

---

## 7. W3: one mark byte, many writers (and CR-001 / CR-002)

### 7.1 Code under test

| Writer | Location | Access to the mark byte |
|---|---|---|
| background / parallel marker | `testAndSetMark<ParallelMark>`, `OldGenSpace.cpp:3039` | `atomic_ref<uint8_t>` load relaxed, then `fetch_or(mask, relaxed)` |
| allocate-black on a non-cursor path | `setMarkBitAtomic`, `OldGenSpace.hpp:1822`; callers `initObjectHeaderWithSize` (`OldGenSpace.cpp:487`), `finalizePoppedCellW` (`:1083`) | `fetch_or(mask, relaxed)` |
| mutator cursor / worker cursor | `finalizeBitmapCell` (`:820`), `finalizeBitmapCellW` (`:1131`) via `bitscan::setBit` (`BitmapScan.hpp:34`) | **plain** `|=` on a block the cursor owns (post-t0 by IM13) |
| 7c grant (exact engine / L3 members) | `grantAllocate` (`OldGenTenure.cpp:177`), `grantAllocateShared` (`:214`) | **plain** `setBit` on granted, post-t0 blocks. L3 members own chunks of ≥ 1,024 bits, which is whole bytes |
| gap sweep | `lazySweep`, `OldGenSpace.cpp:5360` (`bitscan::clearBit`, `BitmapScan.hpp:37`) | **plain** `&=` under `promo_mu_` when inside a parallel minor |
| `gc_phase_` (not a mark byte; same race shape) | write `OldGenSpace.cpp:5247` (under `promo_mu_`); unlocked reads `:1075`, `:1135` | **plain** field |

### 7.2 Properties

- **W3a:** a marker and an allocate-black writer on the same byte: both bits end set, no race.
- **W3b:** a marker on a t0 block's byte and a cursor's plain `setBit` on another block's byte: no
  race. This is IM13's claim: the cursor never owns a t0 block, so it never shares a byte with a
  marker.
- **W3c (CR-002):** the gap sweep's plain `clearBit` and a stashed cell's `fetch_or` on the **same**
  byte. The finalize runs outside the lock, after a pop made in an *earlier* lock hold. **Expected:
  a data race.** This reproduces CR-002 at the memory-model level.
- **W3d (CR-001):** `lazySweep`'s plain write of `gc_phase_` under the lock vs another worker's
  unlocked plain read. **Expected: a data race.**
- **W3e:** two 7c L3 members' plain `setBit`s in adjacent grant chunks never touch the same byte.

### 7.3 Driver

```cpp
// test/genmc/w3_markbyte.cpp
#include <atomic>
#include <cstdint>
#include "wdriver.hpp"
#include "BitmapScan.hpp"
#include "MinorWork.hpp"             // minorwork::SpinMutex == promo_mu_'s type

alignas(64) static uint8_t bits[2];         // byte 0: a t0 mixed block; byte 1: another block
static Elm::minorwork::SpinMutex promo_mu;
static int phase_idle;                       // stands for OldGenSpace::gc_phase_ (plain)

// Verbatim shapes of the real helpers.
static bool markerTAS(uint8_t* b, uint8_t mask) {           // testAndSetMark<ParallelMark>
    std::atomic_ref<uint8_t> r(*b);
    if (r.load(std::memory_order_relaxed) & mask) return true;
    return (r.fetch_or(mask, std::memory_order_relaxed) & mask) != 0;
}
static void allocateBlack(uint8_t* b, uint8_t mask) {        // setMarkBitAtomic
    std::atomic_ref<uint8_t>(*b).fetch_or(mask, std::memory_order_relaxed);
}

// W3a: marker (bit 0) and allocate-black (bit 1) on the same byte: both bits end set.
static void* w3a_marker(void*) { markerTAS(&bits[0], 0x01); return nullptr; }
static void* w3a_alloc(void*)  { allocateBlack(&bits[0], 0x02); return nullptr; }

// W3b: marker on byte 0, cursor plain setBit on byte 1 (IM13): no race.
static void* w3b_cursor(void*) { Elm::bitscan::setBit(bits, 8 + 3); return nullptr; }

// W3c (register CR-002): the gap sweep plain-clears a live object's bit under the
// lock while a stashed cell's allocate-black fetch_or on the SAME byte runs
// outside it (the cell was popped in an earlier lock hold).
static void* w3c_sweeper(void*) {
    promo_mu.lock();
    Elm::bitscan::clearBit(bits, 4);         // bitscan::clearBit(gbits, nb)
    promo_mu.unlock();
    return nullptr;
}
static void* w3c_finalizer(void*) {
    promo_mu.lock();                         // batch pop into the stash
    promo_mu.unlock();
    allocateBlack(&bits[0], 0x01);           // finalizePoppedCellW, outside the lock
    return nullptr;
}

// W3d (register CR-001): lazySweep writes gc_phase_ under the lock; another
// worker reads it without the lock (finalizePoppedCellW / finalizeBitmapCellW).
static void* w3d_sweeper(void*) { promo_mu.lock(); phase_idle = 1; promo_mu.unlock(); return nullptr; }
static void* w3d_reader(void*)  { const int p = phase_idle; (void)p; return nullptr; }

int main() {
    { pthread_t a = spawn(w3a_marker), b = spawn(w3a_alloc); join(a); join(b);
      assert(bits[0] == 0x03); }
    bits[0] = 0; bits[1] = 0;
    { pthread_t a = spawn(w3a_marker), b = spawn(w3b_cursor); join(a); join(b); }
    bits[0] = 0x10;                          // the live object's bit (4) is set
    { pthread_t a = spawn(w3c_sweeper), b = spawn(w3c_finalizer); join(a); join(b); }
    { pthread_t a = spawn(w3d_sweeper), b = spawn(w3d_reader); join(a); join(b); }
    return 0;
}
```

**Split this into one file per case for the real harness** (`w3a.cpp` … `w3e.cpp`). A checker
stops at the first race, and W3c/W3d are *expected* to race while W3a/W3b must not. W3e follows the
W3b shape: two threads, `setBit` on bits 0 and 1024 of one bitmap array (expected: no race), plus
its mutant with a 4-cell chunk (bits 0 and 4 in one byte).

The two helpers are copies of the real ones: `testAndSetMark`'s parallel branch and
`setMarkBitAtomic`'s non-large branch. The canary pins those regions (§11). The `SpinMutex` is the
real type.

### 7.4 What each case must show

| Case | Expected | Meaning |
|---|---|---|
| W3a | pass, `bits[0] == 0x03` | relaxed `fetch_or` is enough for byte sharing between markers and allocate-black (05c H1) |
| W3b | pass, no race | IM13's byte separation makes the cursor's plain `setBit` legal |
| W3c | **race reported** on `bits[0]` between `clearBit` and `fetch_or` | CR-002 is a real C11 data race: status → Reproduced |
| W3d | **race reported** on `phase_idle` | CR-001's first half is a real C11 data race: status → Reproduced |
| W3e | pass | 7c L3 chunk ownership is whole bytes (07 plan §10.18 item 1) |

### 7.5 Mutants

| Mutant | Change | Bad execution |
|---|---|---|
| `W3_PLAIN_ALLOCATE_BLACK` | `allocateBlack` as a plain `*b |= mask` (the 05c negative control `test_plain_allocate_black_`) | race with the marker's `fetch_or`. The worst case loses the marker's bit, so a live object is freed by the sweep (05c H1) |
| `W3_CURSOR_ON_T0_BYTE` | W3b's cursor writes bit 3 of **byte 0** (IM13 violated) | race, and a lost marker bit |
| `W3_SMALL_CHUNK` | W3e with 4-cell chunks | race between L3 members |

After a fix for CR-001/CR-002 lands, W3c/W3d become pass-expected, and the pre-fix shape stays as
a must-fail mutant. That gives the register's Guarded status its negative control.

---

## 8. W4: publishing a new block to background markers

### 8.1 Code under test

| Step | Location | Access |
|---|---|---|
| `blocks_.add` writes `BlockInfo` | `BlockTable.hpp:158`; `materializeBlock`, `OldGenSpace.cpp:657-664` | plain, into a `ReservedArray` slot |
| `mark_.assign` zeroes the slot and writes `len_` | `BlockTable.hpp:310-318` | plain |
| page index commit | `ReservedArray::ensureCommitted`, `ReservedArray.hpp:110-136` | `committed_.store(release)` after the commit syscall |
| owner word | `assignPageIndexForBlock`, `OldGenSpace.cpp:586-625`; `storeOwner`, `OldGenSpace.hpp:446-448` | `atomic_ref<uint32_t>::store(release)` |
| region bounds | `setRegionBase/End`, `OldGenSpace.hpp:412-413` | relaxed stores; "grow-only during a cycle" (IM5) |
| marker lookup | `blockIdFor`, `OldGenSpace.cpp:1797-1816` | region bounds relaxed; `committed()` acquire (`ReservedArray.hpp:174`); `loadOwner` acquire (`OldGenSpace.hpp:449-451`); then **plain** reads of `BlockInfo` and `mark_.len` |
| promotion workers (W4b) | `startVirginBlockShared` (`:1249`) → `publishShared` (`:1201`, release store of the shared word) vs `claimChunkW` (`:1171`, acquire load, then plain `blocks_.info(id)` and `mark_.slot(id)`) | release/acquire on `PromoCtx::shared[cls]` |

### 8.2 Properties

1. A marker that decodes an owner id sees the complete `BlockInfo` and `mark_.len` the mutator
   wrote before the owner store: no race and no stale `start`/`end`.
2. A marker's lookup of a **t0** object never fails while the mutator grows the region. This holds
   by coherence plus the launch's HB (§2.1); a relaxed stale bound still covers every t0 block.
3. **W4b:** a promotion worker that claims a chunk of a block another worker just materialized
   sees that block's `BlockInfo` and bitmap slot.

### 8.3 Driver (a pinned reduction)

`OldGenSpace` cannot be instantiated in a litmus test: it drags in the allocator, platform and
mmap. W4 therefore uses a **reduction**:
- the exact accesses and orders of the functions above, over small static arrays;
- `storeOwner`/`loadOwner`/region-bound accessors copied verbatim.

The canary pins the originals (§11). A change to any of them fails the build until W4 is re-audited.

```cpp
// test/genmc/w4_publication.cpp
#include <atomic>
#include <cstdint>
#include <cstring>
#include "wdriver.hpp"

struct BlockInfo { char* start; char* end; };
static char heap[4 * 64];                    // 4 "pages" of 64 bytes
static BlockInfo info[2];                    // BlockTable::info_ (plain)
static uint32_t mark_len[2];                 // MarkBitArena::len_ (plain)
static uint8_t mark_slot[2][8];              // MarkBitArena slots (plain)
struct PageOwners { uint32_t primary, secondary; };
static PageOwners page_index[4];             // page_index_ (owner words atomic_ref)
static std::atomic<size_t> committed{2};     // page_index_.committed_
static char* region_base; static char* region_end;

static void storeOwner(uint32_t& w, uint32_t v) {
    std::atomic_ref<uint32_t>(w).store(v, std::memory_order_release);
}
static uint32_t loadOwner(const uint32_t& w) {
    return std::atomic_ref<uint32_t>(const_cast<uint32_t&>(w)).load(std::memory_order_acquire);
}
static char* regionEnd() { return std::atomic_ref<char*>(region_end).load(std::memory_order_relaxed); }
static char* regionBase() { return std::atomic_ref<char*>(region_base).load(std::memory_order_relaxed); }

static int blockIdFor(const char* p) {       // returns id or -1
    if (p < regionBase() || p >= regionEnd()) return -1;
    const size_t page = static_cast<size_t>(p - heap) / 64;
    if (page < committed.load(std::memory_order_acquire)) {
        const uint32_t a = loadOwner(page_index[page].primary);
        if (a != 0 && p >= info[a - 1].start && p < info[a - 1].end) return static_cast<int>(a - 1);
        const uint32_t b = loadOwner(page_index[page].secondary);
        if (b != 0 && p >= info[b - 1].start && p < info[b - 1].end) return static_cast<int>(b - 1);
    }
    return -1;
}
// The mutator materializes block 1 = pages [2, 4) while a marker runs.
static void* mutator(void*) {
    info[1] = BlockInfo{heap + 128, heap + 256};       // blocks_.add
    std::memset(mark_slot[1], 0, 8); mark_len[1] = 8;  // mark_.assign
    committed.store(4, std::memory_order_release);     // page_index_.ensureCommitted
    storeOwner(page_index[2].primary, 2);              // assignPageIndexForBlock
    storeOwner(page_index[3].primary, 2);
    std::atomic_ref<char*>(region_end).store(heap + 256, std::memory_order_relaxed);
    return nullptr;
}
// A background marker: looks up a t0 object (block 0), and probes block 1.
static void* marker(void*) {
    assert(blockIdFor(heap + 8) == 0);                 // t0 lookups never fail
    const int id = blockIdFor(heap + 130);
    if (id >= 0) { assert(id == 1); (void)mark_len[id]; }   // new block: full BlockInfo seen
    return nullptr;
}
int main() {
    info[0] = BlockInfo{heap, heap + 128}; mark_len[0] = 8;   // t0 block 0 = pages [0, 2)
    page_index[0].primary = 1; page_index[1].primary = 1;
    region_base = heap; region_end = heap + 128;
    pthread_t m = spawn(mutator), k = spawn(marker);          // launch = mutex (HB)
    join(m); join(k);
    return 0;
}
```

Notes for the implementer:
- `main`'s set-up before `pthread_create` is the model of "everything written before the episode's
  launch", which the launch mutex publishes (`GCBackgroundGang::launch`, `GCHelperPool.cpp:599`).
  Thread creation gives the same HB edge.
- **W4b** (`w4b_shared_chunk.cpp`), same style. Worker A (under a `SpinMutex`) materializes block 1
  (plain `info[1]`, bitmap zeroing) and does `shared.store((1+1) << 32, release)`. Worker B does
  `claimChunkW`'s `load(acquire)`, CAS `acq_rel`, then reads `info[1]` and a bitmap byte of its
  claimed chunk. Expected: pass.
- **Out of scope for any C11 tool:** whether memory beyond `committed_` is *mapped*. mmap and page
  faults are kernel behaviour, not part of the memory model. W4 checks only that the count's
  release/acquire orders the plain writes that follow the commit.

### 8.4 Mutants

| Mutant | Change | Bad execution |
|---|---|---|
| `W4_RELAXED_OWNER` | `storeOwner` relaxed (`OldGenSpace.hpp:447`) | the marker decodes owner 2 but reads `info[1]` unordered with the mutator's write: **race**, and a stale `start`/`end` (0/0) makes the lookup fail or misattribute |
| `W4_RELAXED_SHARED` | `publishShared`'s store relaxed (W4b) | worker B reads `info[1]` / the bitmap before A's writes: race |
| `W4_REGION_SHRINK` | the mutator *lowers* `region_end` below block 0's end (IM5 violated: a release during a cycle) | `assert(blockIdFor(heap + 8) == 0)` fails. This is a logic mutant: it shows the relaxed-bounds argument really rests on IM5 |

---

## 9. W5: claim → copy → publish

### 9.1 Code under test

| Piece | Location | Orders |
|---|---|---|
| header word load | `MinorWork.hpp:54` `loadHeader` | acquire |
| claim | `MinorWork.hpp:58-61` | CAS `acq_rel` / `acquire` |
| publish | `MinorWork.hpp:63-65` | release store of the forward word |
| wait out BUSY | `MinorWork.hpp:69-75` | acquire loads in a backoff loop |
| copy | `NurseryParallel.cpp:250` `copyClaimed` | plain `memcpy` of body, then header from the **saved** word |
| reader | `NurseryParallel.cpp:315` `evacuateP`; `spineRunP` (`:397`) | acquire load; installs the address (reads nothing through it during the drain) |
| 7c shadow | `TenureWork.hpp:73` `lookup` (acquire), `:79` `claim` (CAS from the **observed** word, `acq_rel`/`acquire`), `:84` `publish` (release), `:89` `waitPublished` | as listed |
| 7c exact engine | `TenureWork.hpp:248-266` `SerialEngine::tenure` | **relaxed** load, plain copy, release `publish`, **no claim** (it is the only writer while it runs) |
| 7c help | `NurseryTenure.cpp:969` `TenureParEnv::tenure`, after `tenureJoin` (`:575`; `join()`/`stopAndJoin()` at `:587-590`, `:618-625`) | full claim protocol |
| join | `GCBackgroundGang::memberLoop` finish (`GCHelperPool.cpp:590-595`), `joinLocked` (`:622`) | mutex; `finished_pub_` release |

### 9.2 Properties

1. **Exactly one copy** per object: the claim CAS.
2. **A published forward names a complete copy:** a reader that acquires the forward word and reads
   through it sees the copy's header and body. Phase 6's readers do not read through during the
   drain today. But `MinorWork.hpp:62` documents "release: orders the copy before the address",
   and the 7c STW major's `majorRedirect` and the merge rely on the same shape after the join. So W5
   verifies the documented contract, not just today's usage.
3. **7c, exact engine then help:**
   - the collector publishes without claiming;
   - the mutator joins the gang, then help claims whatever is not yet forwarded;
   - no object is tenured twice, the help thread sees the collector's copies, and a **stale** entry
     from an earlier generation is treated as unvisited and claimed by comparing against the
     observed word (07 plan trap 11).

### 9.3 Driver

```cpp
// test/genmc/w5_forwarding.cpp
#include "wdriver.hpp"
#include "MinorWork.hpp"
#include "TenureWork.hpp"
#include <mutex>
namespace mw = Elm::minorwork;
namespace tw = Elm::tenurework;

struct Obj { uint64_t header; uint64_t f1, f2; };   // header = 8-byte header word
alignas(8) static Obj from{/*tag Cons=*/3, 11, 22};
alignas(8) static Obj copies[2];                    // each worker's to-space cell
static int copied[2];

static void* evac(void* arg) {                       // evacuateP's claim loop
    const int me = static_cast<int>(reinterpret_cast<intptr_t>(arg));
    uint64_t hw = mw::loadHeader(&from);
    for (;;) {
        if (mw::isForwardWord(hw)) {
            if (hw == mw::kBusy) { hw = mw::loadHeader(&from); VERIFIER_ASSUME(hw != mw::kBusy); continue; }
            const Obj* d = reinterpret_cast<const Obj*>(mw::fwdAddr(hw));
            assert(d->f1 == 11 && d->f2 == 22);      // reading through: the copy is complete
            return nullptr;
        }
        if (mw::claim(&from, hw)) break;
    }
    Obj& dst = copies[me];                           // copyClaimed: plain body copy,
    dst.f1 = from.f1; dst.f2 = from.f2;              // then the header from the SAVED word
    dst.header = hw;
    copied[me] = 1;
    mw::publish(&from, &dst, mw::colorOf(hw));
    return nullptr;
}

// (b) 7c: the exact engine on the collector, then join, then help (parallel claim).
alignas(8) static Obj tA{3, 1, 2}, tB{3, 3, 4};
alignas(8) static Obj gA[2], gB[2];
static uint64_t shadow[2] = {tw::make(&gA[1], tw::kStateFwd, /*stale gen*/1), 0};
static const uint32_t kGen = 2;
static std::mutex gang_m; static int finished;   // GCBackgroundGang m_ / finished_
static int copiesA, copiesB;

static void* collector(void*) {                 // SerialEngine::tenure on A: no claim
    uint64_t e = tw::ref(&shadow[0]).load(std::memory_order_relaxed);
    if (tw::fwdOf(e, kGen) == nullptr) {
        gA[0] = tA; ++copiesA;
        tw::publish(&shadow[0], &gA[0], kGen);
    }
    { std::lock_guard<std::mutex> g(gang_m); ++finished; }   // memberLoop's finish
    return nullptr;
}
static void helpTenure(uint64_t* w, Obj& src, Obj& dst, int& count) {   // TenureParEnv::tenure
    uint64_t e = tw::ref(w).load(std::memory_order_acquire);
    for (;;) {
        if (tw::fwdOf(e, kGen) != nullptr) return;
        if (tw::genOf(e) == kGen && tw::stateOf(e) == tw::kStateBusy) {
            e = tw::ref(w).load(std::memory_order_acquire); continue;
        }
        if (tw::claim(w, e, kGen)) break;
    }
    dst = src; ++count;
    tw::publish(w, &dst, kGen);
}
static void* mutator(void*) {                   // tenureJoin: join, then help
    for (;;) { std::lock_guard<std::mutex> g(gang_m); if (finished == 1) break; }
    helpTenure(&shadow[0], tA, gA[1], copiesA);
    helpTenure(&shadow[1], tB, gB[1], copiesB);
    return nullptr;
}
int main() {
    { pthread_t a = spawn(evac, reinterpret_cast<void*>(0)), b = spawn(evac, reinterpret_cast<void*>(1));
      join(a); join(b); assert(copied[0] + copied[1] == 1); }
    { pthread_t c = spawn(collector), m = spawn(mutator); join(c); join(m);
      assert(copiesA == 1 && copiesB == 1); }
    return 0;
}
```

Implementer notes:
- The `mutator`'s "join" is a lock-and-poll loop so that it stays bounded. The real `joinLocked`
  waits on a condition variable; replace the loop with `pthread_cond_wait` if the spike shows GenMC
  models condvars **(spike)**, or with `VERIFIER_ASSUME(finished == 1)` under the lock.
- (b) initialises `shadow[0]` to a **stale** FWD entry (generation 1) pointing at `gA[1]`. The
  collector must treat it as unvisited: `fwdOf(e, 2) == nullptr`. So must help's claim, which
  compares against the observed stale word.
- A three-thread variant `w5_parallel_tenure.cpp` has two L3 members plus help on one object, all
  using `helpTenure` (the full claim protocol with a BUSY wait). Expected: one copy.

### 9.4 Mutants

| Mutant | Change | Bad execution |
|---|---|---|
| `W5_RELAXED_PUBLISH` | `publish` relaxed (`MinorWork.hpp:64`) | the loser sees the forward word but reads `d->f1 == 0`: **race** on the copy's body (the documented copy-before-address contract broken) |
| `W5_RELAXED_CLAIM_FAIL` | CAS failure order `relaxed` (`MinorWork.hpp:60`) | the loser observes FWD through a failed CAS without acquiring, then reads through it: race. **(spike: confirm; the loop's next `loadHeader` is acquire, but the loser in this driver reads through right after the failed CAS)** |
| `W5_HELP_WITHOUT_JOIN` | the mutator starts help after `finished_pub_.load(relaxed)` instead of the mutex join | help runs while the exact engine (no claim) is still copying A: `copiesA == 2` (a **double tenure**), and a race on `gA[0]`. This is the reason `tenureJoin` must `join()` before help (`NurseryTenure.cpp:587-590, 618-625`) |
| `W5_SHADOW_RELAXED_PUBLISH` | `tw::publish` relaxed (`TenureWork.hpp:85`) in the 3-thread variant | a member reads through another member's FWD and sees an incomplete copy |

---

## 10. How results feed back

- **Register** (`plans/threaded-gc-concurrency-register.md`). W3c and W3d move CR-002 and CR-001
  to **Reproduced** (C11 level). Their mutant form stays in `genmc-check` as the **Guard's**
  negative control once a fix lands. Any new race or assertion failure becomes a new `CR-` entry,
  with the checker's execution graph as evidence.
- **Model assumptions.** Each TLA+ model's MAPPING.md has an "A4 assumptions" table. Each row names
  the W case that discharges it and that case's status:

  | Model | Assumption | Discharged by |
  |---|---|---|
  | M2 | deque operations are linearizable and pass entry contents | W1 |
  | M2 | a decider that reads `active == 0` sees all work published before those `goIdle`s | W2 |
  | M2 | the `priv` path makes private work visible (trap 5, mark env only) | W2 `w2_priv` |
  | M1 | allocate-black and marker bits never erase each other | W3a |
  | M1, M4 | cursor and grant plain `setBit`s never share a byte with a marker or another member | W3b, W3e |
  | M1 | markers see complete metadata for any block they look up; t0 lookups never fail | W4 |
  | M4 | a chunk claimed from a freshly published shared block is fully visible | W4b |
  | M3 | one copy per object; a forward names a complete copy | W5 (a) |
  | M5 | the exact engine's claim-free publish is safe because help starts after the join | W5 (b) |

  If a W case fails, the model's assumption is void: the model's MAPPING.md says so, and the
  register gets the defect.
- **Plan premises.** A W result that contradicts a phase plan's memory-order argument (a 05c
  H-row, 06 P§3.3, 07 P§3.10) goes into that plan's as-built section and into the model's AUDIT.md.

## 11. Build and canary wiring

- **Layout:** `test/genmc/` holds `wdriver.hpp`, `w1_deque.cpp` … `w5_forwarding.cpp` (one file
  per case where a checker stops at the first report, as in W3), `mutate.sh`, and `drivers.txt`
  (the runner's registry).
  - One line per driver or mutant: `name  file  defines  expected`, where expected is `pass`,
    `race`, or `assert`.
  - `race` and `assert` rows name the variable or assertion that must be reported, so a mutant that
    fails for a different reason does not count (primer §5).
- **Target:** `genmc-check` in `test/genmc/CMakeLists.txt` (under `test/`, which is
  `EXCLUDE_FROM_ALL`).
  - It finds the tool with `find_program(GENMC genmc PATHS /opt/genmc/bin)` and fails with a clear
    message when it is missing (`-DECO_GENMC=OFF` to leave it undefined).
  - It runs every `drivers.txt` row through `run_drivers.py` (the shape of `test/tla/run_models.py`)
    with a per-driver timeout.
  - Budget: ≤ 10 minutes total (parent §6.1). It runs at each model's close-out and nightly, not
    in `check`/`full`.
- **Canary** (`test/tla/manifest.txt`, parent §7). W1–W5 appear as "models" in the manifest's
  model column:
  - `file` lines: `MarkWork.hpp` (W1, W2, M2), `MinorWork.hpp` (W5, M3), `TenureWork.hpp` (W5, M5),
    `BitmapScan.hpp` (W3);
  - `region` lines for code the drivers copy or reduce:
    - `testAndSetMark` parallel branch, `setMarkBitAtomic`, `lazySweep`'s gap-sweep loop and phase
      change, `finalizePoppedCellW`, `finalizeBitmapCellW`, `grantAllocateShared` (W3);
    - `materializeBlock`, `assignPageIndexForBlock`, `blockIdFor`, `storeOwner`/`loadOwner`, the
      region-bound accessors, `ReservedArray::ensureCommitted`/`committed`, `publishShared`,
      `claimChunkW` (W4);
    - `ParallelEnv::anyWork` (W2);
    - `GCBackgroundGang::memberLoop`'s finish and `joinLocked`, and `tenureJoin`'s join branches
      (W5b);
  - a W's AUDIT entry (in `test/genmc/AUDIT.md`) is what `--update` checks for, as for the TLA+
    models.

## 12. Implementation steps

1. **Step 0, the spike** (§4.2): the GenMC Docker stage, W1 as written, W1's two main mutants
   flagged. Record the tool facts in the parent plan §3. If GenMC fails, switch to C11Tester plus
   herd7 and rewrite §4.1's row.
2. **W1**, including the paper variant and the two-thief variant.
3. **W2**, including `w2_priv` and `w2_reactivate`. Cross-check against M2's
   `idle_before_publish` result.
4. **W5** (a) and (b), plus the 3-thread shadow variant.
5. **W3**, one file per case. Expect W3c/W3d to report races. Move CR-001/CR-002 to Reproduced with
   the execution graphs attached.
6. **W4** and W4b, with the reduction pinned in the manifest.
7. **Wiring:** `drivers.txt`, `run_drivers.py`, `genmc-check`, the manifest lines, AUDIT.md first
   entries, and the MAPPING.md A4 tables of M1–M5 filled in with W statuses.

## 13. Open questions

1. **(spike)** Does GenMC handle `std::atomic_ref` on a non-atomic object, and C++ templates with
   `new[]`/`std::vector` (`WorkStealingDeque::grow`)? If not, how thin can the shim be while still
   compiling the real functions' bodies?
2. **(spike)** How does GenMC treat a location accessed both through `atomic_ref` (atomic) and
   plainly (W3c)? It must report the mixed access as a race, not silently treat the location as
   atomic or plain throughout.
3. **(spike)** Spin loops: can `idleUntilWorkOrDone` and `waitPublished` be checked as written with
   spin-assumption, or must every driver straight-line them, as the sketches above do?
4. `W1_STEAL_RELAXED_BOTTOM` and `W5_RELAXED_CLAIM_FAIL`: are they reachable at these sizes? If not,
   they are not valid negative controls. Either enlarge the driver or drop the mutant, with a note.
5. W4 cannot see mmap. Is there any path where a marker reads a page-index slot beyond what the
   kernel has mapped, despite `committed_`? That is a question for the M1 audit (HEAP_049), not for
   a C11 tool.
