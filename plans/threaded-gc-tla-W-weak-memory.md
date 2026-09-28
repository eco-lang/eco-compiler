# Threaded GC: weak-memory companions W1–W5

**Status:** IMPLEMENTATION-READY PLAN (2026-09-28). **Adversarial review on 2026-09-28 against the
current tree** (§14): four negative controls that could not fire were fixed, W4's reduction was
reordered to the code's order, and a coverage census (§10.1) was added. Driver sketches are
syntax-checked only; no checker has run. Every sketch in §5–§9, and every `-D` variant and mutant
of it named in the tables, compiles with `g++ -std=c++20 -fsyntax-only -Wall -Wextra` (g++ 12.2)
and `clang++` 14 with the same flags, against the real headers in `runtime/src/allocator/`, with
no warnings. No memory-model checker has been installed or run (none is in the container). Claims
about what the tools can do are marked **(spike)**: the Step 0 feasibility spike (§4.2) confirms
or refutes them.

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
| W3 | one mark byte, many writers; `promo_mu_` as a lock | `OldGenSpace.cpp:3067-3068` (`testAndSetMark`), `OldGenSpace.hpp:1822`, `BitmapScan.hpp:25/34/37`, `OldGenSpace.cpp:5339/5360`, `OldGenTenure.cpp:177/214`, `MinorWork.hpp:85-113` | M1, M4, M7 (indivisible `fetch_or`, byte and word ownership, `SpinMutex` gives happens-before), and it classifies the CR-001/CR-002 access patterns as C11 races |
| W4 | publishing a new old-gen block to background markers | `OldGenSpace.cpp:586-664, 1797`, `:2765-2776`, `:874-877`, `:561`; `ReservedArray.hpp:110-174` | M1 (markers see complete block metadata; t0 lookups never fail) |
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
takes part in the single total order of seq_cst operations. The two fences (`take` line 98,
`steal` line 120) stop a store-buffering outcome: the owner's `take` storing the new `bottom` and
then reading a **stale** `top`, while a thief reads the new `top` and the **old** `bottom`. Without
them the owner takes index `b` without a CAS (it thinks two or more entries are left) while a thief
steals the same index. The last element is different: there both sides CAS `top`, and the CAS alone
picks one winner. So the fence bug needs two successful steals (one to make the owner's `top`
stale, one to take the duplicate), which is why W1's fence mutant runs with two thieves (§5.4).

**Why TSan misses stand-alone fences:** ThreadSanitizer models atomics operation by operation and
ignores `atomic_thread_fence`. With the paper's relaxed element store plus release fence, TSan sees
a relaxed store and a relaxed load and reports a false race on the entry's contents. Phase 6
therefore strengthened the element store to `release` and the steal's element load to `acquire`
(`MarkWork.hpp:83-88`); `grow()`'s copy store (`:181-182`) is `release` too. W1 checks both the
code as written and the paper's original orders.

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
Assertion violation: !(decided && left)
```
Reading it: thread 2's relaxed load of `bottom` read the initial value, although thread 1's push
happened-before thread 1's `fetch_sub`, which thread 2 read. That is only possible if the
synchronizes-with edge is missing, which is the W2 mutant of §6.

---

## 3. What the drivers look like

Every driver is a stand-alone C++ file in `test/genmc/`:
- it `#include`s the real std-only header (`MarkWork.hpp`, `MinorWork.hpp`, `TenureWork.hpp`,
  `BitmapScan.hpp`) with `-I runtime/src/allocator`;
- it uses **plain pthreads** (and `pthread_mutex_t` for a mutex), because model checkers intercept
  `pthread_create`, `pthread_join` and the pthread mutex calls, while `std::thread` lives in
  precompiled libstdc++ and `std::mutex` goes through libstdc++'s gthread layer **(spike)**;
- it bounds every loop by construction: no backoff loops, and a waiting spin is written as
  `VERIFIER_ASSUME(cond)` (`__VERIFIER_assume` in GenMC **(spike)**). Where the real code takes a
  `pause` callback (`waitPublished`), the driver passes one that assumes `false`, so the **real**
  wait loop runs with the spin pruned;
- it never calls code that spins through `backoff()`/`cpuRelax()` or `SpinMutex::lock()`: those
  compile to `llvm.x86.sse2.pause`, `sched_yield` and `nanosleep` (checked in the clang IR of the
  first W3 sketch), which a checker's interpreter is unlikely to accept **(spike)**. The lock is
  taken with the real `try_lock()` under `VERIFIER_ASSUME` instead;
- it states the property as `assert`s after `pthread_join`, plus the checker's built-in data-race
  detection.

The common header:

```cpp
// test/genmc/wdriver.hpp
#pragma once
#include <pthread.h>
#include <cassert>
#ifndef VERIFIER_ASSUME
// Stand-in for syntax checks and native smoke runs. Under the checker this is
// __VERIFIER_assume(c) (spike). A function, so it works in lambdas and void helpers.
inline void wassume(bool c) { if (!c) pthread_exit(nullptr); }
#define VERIFIER_ASSUME(c) wassume(c)
#endif
inline pthread_t spawn(void* (*f)(void*), void* arg = nullptr) {
    pthread_t t; pthread_create(&t, nullptr, f, arg); return t;
}
inline void join(pthread_t t) { pthread_join(t, nullptr); }
```

**Mutants.** Each driver has one or more mutants. A mutant is a copy of the code under test with
one memory order weakened (or one lock removed), and the checker **must** flag it. There are two
kinds, and each mutant table says which:
- **header mutants** patch a real header's text through a small sed-driven copy step
  (`test/genmc/mutate.sh`, which writes e.g. `build/genmc/<name>/MarkWork.hpp`). The pinned header
  in the tree is never edited. `mutate.sh` fails unless its pattern matched exactly once, so a
  mutant cannot silently become the unmutated code;
- **driver mutants** (`-DMUTANT_<NAME>`) weaken code the driver **copies** (the W2 decider round,
  the W3 helpers, the W4 reduction, the W5 claim loops and join). Patching the header would not
  reach a copy.

A mutant that the checker does not flag means the driver is too small to exercise the order it
claims to test, and fails `genmc-check` (parent plan §2 rule A6).

---

## 4. Tool choice and the Step 0 spike

### 4.1 Candidates

| Tool | What it is | Pro | Con / to verify |
|---|---|---|---|
| **GenMC** (first choice) | stateless model checker over LLVM IR for RC11/IMM/SC; exhaustive for bounded programs | explores all executions; reports races and assertion failures with the execution graph | **(spike)** supported LLVM versions (ours is 21; GenMC pins its own); C++ support is partial. To confirm: `std::atomic_ref` (C++20; in clang's IR it is ordinary `load atomic`/`atomicrmw i8`/`cmpxchg` on the plain object, so the question is only whether GenMC's own clang accepts the header); templates; `new`/`delete`, `new[]` of atomics, `std::vector::push_back` (`grow()`'s `retired_`) and its exception paths; **aligned** `operator new` (the deque's `alignas(64)` members; the sketches avoid it with placement new); `calloc`; `llvm.memcpy`/`llvm.memset` next to word and byte accesses (mixed size, §7.6); whether a weak CAS is modelled as strong (safe for safety checks) |
| **C11Tester** | dynamic tester: an instrumenting LLVM pass plus a runtime that controls scheduling and weak-memory reads | handles bigger programs; C++ friendly **(spike)** | random exploration, not exhaustive: it can miss a bad execution, so a pass is weaker evidence; mixed-size and plain-vs-atomic access on one byte **(spike)** |
| **herd7** (litmus, RC11 `.cat` model) | exhaustive enumeration of hand-written litmus tests | the reference semantics; tiny tests are exact | tests are hand-derived from the code, so drift is only caught by the canary regions (§11). Its C11 model is not known to support mixed-size accesses, so it likely cannot express a byte `fetch_or` against a word read (W3c, W3e), nor, perhaps, one location accessed both plainly and atomically **(spike)**. It cannot run any real header |
| CDSChecker, Dartagnan | older exhaustive C11 checker / bounded model checker for weak memory | alternatives if the above fail | not evaluated |

### 4.2 The spike (plan Step 0, before any W is written)

Goal: one working W1 run and one flagged W1 mutant, reproducible in the dev image.

1. **Build GenMC in its own Docker stage** (`docker/genmc.Dockerfile`, a new file) with the LLVM
   release GenMC supports, and copy `/opt/genmc` into the dev image, like `/opt/llvm-mlir`. Pin
   the GenMC commit and LLVM version with SHAs. Do not try to build it against our LLVM 21.
2. Run `w1_deque.cpp` (§5.3) unmodified.
   - If GenMC rejects the header (C++20, `std::atomic_ref`, `<chrono>`/`<thread>` includes,
     `new[]`, `std::vector`), try `-std=c++17` with `std::atomic_ref` provided by a GenMC-side
     shim (`genmc_atomic_ref.hpp`, mapping `atomic_ref<T>` onto `__atomic_*` builtins on the
     object).
   - If the header still fails, fall back to a **transliteration**: a shim copy of the tested
     functions with `std::vector` replaced by fixed arrays. Each transliterated function carries a
     `TLA-REGION`-style canary pin of the original (§11), so drift fails the build.
   - Run `w5_forwarding.cpp` too: its first two asserts check that the tool's addresses fit the
     40-bit address fields of the forward word (`MinorWork.hpp:36-37`, `fwdWord`) and of the shadow
     entry (`TenureWork.hpp:56`, bits 3..42). A tool that places globals or heap blocks at or above
     2^43 (a Linux PIE binary puts its data near 2^46) breaks every read-through in W5, so this
     must be known before W5 is written. If they fail, W5 needs a shim that allocates its objects
     below 2^43, or a transliteration.
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
| `grow` | 176-188 | `Array::make` writes the **plain** fields `mask` and `buf` (`:162-168`); copy `[t, b)` relaxed load → release store; old array pushed onto owner-only `retired_`; `array_` release store | relaxed buffer accesses; `array_` release |
| `emptyApprox` | 135-137 | relaxed loads (a hint) | — |

### 5.2 Property

1. Every pushed entry is returned **exactly once**, by `take` or by `steal`. No entry is returned
   twice, and none is lost.
2. **Message passing:** if a thief steals entry `i`, it sees everything the owner wrote before
   `push(i)`. The phase 6 minor needs this: a thief scans a copy that another worker just wrote
   (`MarkWork.hpp:83-88`).
3. No data race, including across `grow()`: a thief may read the *old* array, which is only retired
   (never freed) during the run, and a thief that reads the *new* `array_` must see `make()`'s plain
   `mask`/`buf` writes (the `array_` release/acquire pair, `:185`/`:123`).

### 5.3 Driver

```cpp
// test/genmc/w1_deque.cpp
#include <new>
#include "wdriver.hpp"
#include "MarkWork.hpp"
using Elm::markwork::WorkStealingDeque;
using Elm::markwork::kEmpty;
using Elm::markwork::kAbort;

#ifndef W1_THIEVES
#define W1_THIEVES 1                         // w1_deque_2thieves: -DW1_THIEVES=2
#endif
// Placement new into a static buffer: the deque's alignas(64) members would
// otherwise need the aligned operator new (spike).
alignas(WorkStealingDeque) static unsigned char dq_mem[sizeof(WorkStealingDeque)];
static WorkStealingDeque* dq;
static uint64_t payload[4];                  // NON-atomic, written before the push
static int got_owner[4], got_thief[W1_THIEVES][4];   // each row written by one thread only

static void* owner(void*) {
    for (uint64_t i = 1; i <= 3; ++i) {      // 3 pushes into 2 slots: grow() unless a steal came first
        payload[i] = i * 10;
        dq->push(i);
    }
    for (int k = 0; k < 2; ++k) {
        const uint64_t e = dq->take();
        if (e != kEmpty) { assert(payload[e] == e * 10); ++got_owner[e]; }
    }
    return nullptr;
}
static void* thief(void* arg) {
    const int me = static_cast<int>(reinterpret_cast<intptr_t>(arg));
    const uint64_t e = dq->steal();
    if (e != kEmpty && e != kAbort) { assert(payload[e] == e * 10); ++got_thief[me][e]; }
    return nullptr;
}
int main() {
    dq = new (dq_mem) WorkStealingDeque(/*log_initial=*/1);
    pthread_t a = spawn(owner);
    pthread_t t[W1_THIEVES];
    for (int j = 0; j < W1_THIEVES; ++j) t[j] = spawn(thief, reinterpret_cast<void*>(static_cast<intptr_t>(j)));
    join(a);
    for (int j = 0; j < W1_THIEVES; ++j) join(t[j]);
    for (;;) { const uint64_t e = dq->take(); if (e == kEmpty) break; ++got_owner[e]; }
    for (int i = 1; i <= 3; ++i) {
        int n = got_owner[i];
        for (int j = 0; j < W1_THIEVES; ++j) n += got_thief[j][i];
        assert(n == 1);                      // exactly once: none lost, none duplicated
    }
    dq->~WorkStealingDeque();
    return 0;
}
```

Variants, each a separate compile:
- `w1_deque_2thieves` (`-DW1_THIEVES=2`): two thieves with one steal each, three pushes, two owner
  `take`s. This is the smallest shape in which a stale `top` in `take` can duplicate an entry: one
  steal makes the owner's `top` stale, the other steals the index the owner takes without a CAS
  (§2.4). With one thief the duplicate is unreachable, because the last element is always CASed.
- `w1_deque_paper`: the paper's orders: every buffer access relaxed (the element store `:88`, the
  steal's element load `:124`, `grow()`'s copy store `:181-182`); `array_`'s load stays `acquire`
  (the paper's `consume`, which compilers implement as acquire). **Expected to pass**; it shows the
  phase 6 strengthening was for TSan, not for correctness.
- The herd7 fallback: the four-event core "push(e1), push(e2) ∥ steal() ∥ steal() ∥ take()".

**Must be impossible:**
- an entry returned zero times or twice (`assert(n == 1)`);
- a thief reading a stale `payload`;
- a data race report on `payload`, or on the plain `Array::mask`/`Array::buf` fields that `grow()`
  writes in `Array::make` (`buf[i]` and `array_` are atomics and cannot race).

### 5.4 Mutants

All W1 mutants are header mutants (`mutate.sh` on `MarkWork.hpp`).

| Mutant | Change | Runs on | Bad execution the checker must show |
|---|---|---|---|
| `W1_NO_TAKE_FENCE` | remove the `seq_cst` fence in `take` (line 98) | `w1_deque_2thieves` | pushes 1, 2, 3; thief A steals index 0 (`top` 0 → 1); the owner's first `take` stores `bottom = 2`, reads a stale `top = 0` and takes index 2; thief B reads `top = 1`, then the **old** `bottom = 3`, and steals index 1 (CAS 1 → 2); the owner's second `take` stores `bottom = 1`, reads the stale `top = 0` again (`0 < 1`: no CAS) and also takes index 1. **Entry 2 is returned twice**: `assert(n == 1)` fails. Legal in RC11: with the owner's fence gone, nothing orders its `bottom` store before its `top` load, and the thieves' fences alone cannot forbid this store-buffering outcome |
| `W1_RELAXED_PUBLISH` | element store `relaxed` **and** no release fence in `push` (lines 88-89) | `w1_deque` | the thief reads `bottom` (acquire) from the owner's relaxed store, but nothing orders `payload[i] = …` before it. Expected: a **race on `payload`**, or the lost-entry assertion when the thief's element load returns the slot's initial 0 (= `kEmpty`) after its CAS succeeded |
| `W1_STEAL_RELAXED_BOTTOM` | `bottom` load in `steal` relaxed (line 121), on the paper variant (relaxed element load) | `w1_deque` | the thief sees `bottom = 1` without synchronizing; its element load may return the slot's initial 0, so the CAS succeeds and entry 1 is lost (`assert(n == 1)`), or its `payload` read races. Reachable with one thief and one push (by the axioms: nothing then synchronizes the push with the steal) **(spike: confirm the tool reports it)** |
| `W1_RELAXED_ARRAY` | `array_.store(na, relaxed)` in `grow` (line 185) | `w1_deque` | the thief reads `bottom = 2` (it synchronizes only with the second push, before `grow()`), then the **new** `array_`, and reads `na->mask` and `na->buf`, which `Array::make` wrote plainly: **race on `Array::mask`**. This is the only mutant for property 3 |

### 5.5 Pass criteria

The as-written and paper variants pass with no race, with one and with two thieves. All four
mutants are flagged with the outcome named in their row (the runner accepts the listed alternatives,
each tied to the weakened order).

---

## 6. W2: termination (publish → `goIdle` vs the decider)

### 6.1 Code under test

| Piece | Location | Orders |
|---|---|---|
| `goIdle` | `MarkWork.hpp:246` | `state.fetch_sub(1, acq_rel)` |
| `reactivate` | `MarkWork.hpp:248-257` | CAS `acq_rel` / `acquire` |
| decider | `MarkWork.hpp:369-395` (`idleUntilWorkOrDone`) | `state.load(acquire)`; `budget.load(acquire)`; `env.anyWork()`; done-CAS `acq_rel` |
| `ParallelEnv::anyWork` | `OldGenSpace.cpp:3498-3504` | per slot, in this order: `deque.emptyApprox()` (two relaxed loads, `bottom_` and `top_`, unsequenced against each other), **then** `priv.load(relaxed)` (short-circuit `||`) |
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
#include <new>
#include "wdriver.hpp"
#include "MarkWork.hpp"
using namespace Elm::markwork;

// The decider is a straight-line COPY of one round of idleUntilWorkOrDone
// (MarkWork.hpp:370-395; the real loop spins through backoff()), with BOTH of
// the round's work checks (:375 and :382). Decider mutants patch THIS copy,
// not the header. -DW2_ONE_SCAN drops the first check (see the variants).
#ifdef MUTANT_W2_RELAXED_DECIDER_LOAD
constexpr std::memory_order kStateLoad = std::memory_order_relaxed;
#else
constexpr std::memory_order kStateLoad = std::memory_order_acquire;   // MarkWork.hpp:372
#endif

static SliceControl* c;
alignas(WorkStealingDeque) static unsigned char dq_mem[sizeof(WorkStealingDeque)];
static WorkStealingDeque* dqM;               // M's deque
static std::atomic<uint64_t> privM{0};       // M's MarkWorker::priv
static int decided;                          // written by D only

static void* marker(void*) {
#if defined(W2_PRIV)                         // the entry stays private (test_leave_private_on_exit_)
    privM.store(1, std::memory_order_relaxed);   // pushGrey, OldGenSpace.hpp:989
    c->goIdle();
#elif defined(W2_IDLE_BEFORE_PUBLISH)        // M2's idle_before_publish: goIdle, THEN publishAll
    privM.store(1, std::memory_order_relaxed);
    c->goIdle();
    dqM->push(7);                            // publishAll, OldGenSpace.hpp:977-982
    privM.store(0, std::memory_order_relaxed);
#else                                        // the code's exit order, MarkWork.hpp:464-466
    dqM->push(7);                            // publishAll (one entry)
    c->goIdle();                             // fetch_sub(acq_rel)
#endif
    return nullptr;
}
// ParallelEnv::anyWork (OldGenSpace.cpp:3498-3504), M's slot: deque first, then priv.
static bool anyWorkM() {
#ifdef W2_MINOR_ANYWORK                      // MinorEnv/RegionEnv/TenureParEnv: deques only
    return !dqM->emptyApprox();
#else
    return !dqM->emptyApprox() || privM.load(std::memory_order_relaxed) != 0;
#endif
}
static void* decider(void*) {                // D: nothing to publish; goes idle, decides once
    c->goIdle();
    const uint64_t s = c->state.load(kStateLoad);
#ifndef W2_ONE_SCAN
    // The round's first check (MarkWork.hpp:375): work seen here means D
    // would reactivate, never decide.
    if (c->budget.load(std::memory_order_acquire) > 0 && anyWorkM()) return nullptr;
#endif
    if ((s & SliceControl::kActiveMask) == 0) {
        const bool work = c->budget.load(std::memory_order_acquire) > 0 && anyWorkM();   // :382
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
    dqM = new (dq_mem) WorkStealingDeque(1);
    pthread_t m = spawn(marker), d = spawn(decider);
    join(m); join(d);
    const bool left = !dqM->emptyApprox() || privM.load(std::memory_order_relaxed) != 0;
    assert(!(decided && left));              // done with work left: impossible
    return 0;
}
```

The decider body is a straight-line **copy** of one round of `idleUntilWorkOrDone`, because the
real loop spins through `backoff()` (§3). It keeps **both** of the round's work checks (`:375`
and `:382`) and omits only the `stopRequested()` read. Omitting a read can only make D's view
staler, which is sound for the variants expected to pass, but it can manufacture a failure in a
variant expected to fail: with one scan, `w2_idle_before_publish` fails even under SC, while
the real round's second scan rescues it there (below). `-DW2_ONE_SCAN` keeps the one-scan form
only to show that difference. `MarkWork.hpp` is file-pinned, so any change
to the real round trips the canary for W2. If the spike shows GenMC handles the real loop with
spin-assumption **(spike)**, add `w2_real_loop.cpp`. It runs `runMarkerLoop` itself with a
two-entry synthetic Env (the shape of `mark_harness.cpp`'s `SynthEnv`) and two members; that needs
`backoff()`'s `cpuRelax()` to be interpretable.

Variants:
- `w2_priv` (`-DW2_PRIV`): M's last entry stays **private** (`privM.store(1)`, as `pushGrey` does)
  and M goes idle without ever publishing it: the shape of the `test_leave_private_on_exit_`
  negative control. **Expected to pass** in the mark environment: `priv` is visible through the same
  synchronizes-with as a push.
- `w2_idle_before_publish` (`-DW2_IDLE_BEFORE_PUBLISH`): M's exit with `goIdle` **before**
  `publishAll` (M2's `idle_before_publish` mutant): `priv = 1`, `goIdle`, `push`, `priv = 0`.
  **Expected: the assertion fails under RC11, through weak memory only.** Under SC the real round
  is safe. Its first scan can straddle the publish (the deque read before the push, the `priv`
  read after `priv = 0`), but its second scan then reads the deque after the push. Nobody can take
  the entry out without a reactivation, which makes the done-CAS fail. M2 checks this SC side
  (its `idle_before_publish`, with `anyWork` split per slot into a deque step and a `priv` step).
  Under RC11 the relaxed `priv` read that returns 0 gives D no happens-before edge to the push, so
  **both** deque reads may return the old `bottom_`: both scans miss, the CAS succeeds, and the
  entry is left. So the code's publish-before-`goIdle` order is load-bearing in the mark
  environment under the C11 model, not under SC. With `-DW2_ONE_SCAN` it fails under SC too, an
  artifact of the reduced decider.
- `w2_reactivate`: a third thread R, idle, that sees M's entry, reactivates (CAS, epoch bump) and
  then steals the entry. D may then read an empty deque, so the assert is not vacuous. Assert that
  `decided` and R's successful `reactivate` never both happen. This is RMW atomicity on `state` (the
  done-CAS compares the whole word); cheap to include.
- `w2_returned_tickets`: the budget starts at 0 and M returns its tickets
  (`budget.fetch_add(relaxed)`, `returnTickets`) before `goIdle`. The decider must see `budget > 0`,
  else it decides with M's entry left.

### 6.4 Mutants

| Mutant | Kind | Change | Bad execution |
|---|---|---|---|
| `W2_RELAXED_GOIDLE` | header | `fetch_sub(1, relaxed)` (line 246); both threads' `goIdle` are weakened | D reads `active == 0` from M's relaxed RMW (or its own RMW that read M's), but no synchronizes-with edge exists. D's relaxed loads of `bottom`/`top` return the initial values, so the deque looks empty, D decides, and the assert fails: **work left after done** |
| `W2_RELAXED_DECIDER_LOAD` | driver (`-DMUTANT_…`) | the copy's `state.load` relaxed (the copy of line 372) | the same outcome, when D's `goIdle` is before M's in the modification order (otherwise D's own acq_rel `goIdle` read M's release and synchronized) |
| `W2_PUBLISH_AFTER_IDLE_MINOR` | driver | `w2_priv` with `-DW2_MINOR_ANYWORK` (deques only) | D decides while M's entry is private. This is also an SC bug, so M2 catches it too; W2 confirms nothing weaker rescues it |

---

## 7. W3: one mark byte, many writers (and CR-001 / CR-002)

### 7.1 Code under test

| Writer | Location | Access to the mark byte |
|---|---|---|
| background / parallel marker | `testAndSetMark<ParallelMark>`, `OldGenSpace.cpp:3067-3068` (function at `:3039`) | `atomic_ref<uint8_t>` load relaxed, then `fetch_or(mask, relaxed)` |
| allocate-black on a non-cursor path | `setMarkBitAtomic`, `OldGenSpace.hpp:1822-1833`; callers `initObjectHeaderWithSize` (`OldGenSpace.cpp:518`), `finalizePoppedCellW` (`:1083`) | `fetch_or(mask, relaxed)` |
| mutator cursor / worker cursor | `finalizeBitmapCell` (`:820`), `finalizeBitmapCellW` (`:1131`) via `bitscan::setBit` (`BitmapScan.hpp:34`); the cursor finds a free cell with `bitscan::nextFreeCell` (`:84`), which reads **whole 64-bit words** through `loadWord` (`:25-29`, a `memcpy`) | **plain** byte `|=` and **plain 64-bit word reads** on the slot of a block the cursor owns (post-t0 by IM13) |
| 7c grant (exact engine / L3 members) | `grantAllocate` (`OldGenTenure.cpp:177`), `grantAllocateShared` (`:214`, after `nextFreeCell` at `:208`) | **plain** `setBit` and word reads on granted, post-t0 blocks. L3 members own chunks of `tenureChunkCells` cells (`OldGenSpace.hpp:696-699`): a multiple of 64 cells, so `64·m` bits = whole **64-bit words** (the code comment says "whole bitmap bytes"; `nextFreeCell` needs words) |
| gap sweep | `lazySweep`: `bitscan::nextSetBit` (`OldGenSpace.cpp:5339`, word reads) then `bitscan::clearBit` (`:5360`, `BitmapScan.hpp:37`) | **plain** word reads and a plain byte `&=`, under `promo_mu_` when inside a parallel minor |
| `gc_phase_` (not a mark byte; same race shape) | write `OldGenSpace.cpp:5247` (under `promo_mu_`); unlocked reads `:1075`, `:1135` | **plain** field |
| `promo_mu_` (`OldGenSpace.hpp:765`) | `minorwork::SpinMutex` (`MinorWork.hpp:85-113`) | `try_lock`: relaxed load, then `exchange(true, acquire)`; `unlock`: `store(false, release)` |

### 7.2 Properties

- **W3a:** a marker and an allocate-black writer on the same byte: both bits end set, no race.
- **W3b:** a marker on a t0 block's slot, and a cursor allocating in **its own** block's slot (a
  word read by `nextFreeCell`, then a plain `setBit`): no race. Mark slots are 64-byte aligned
  (`MarkBitArena`, stride a multiple of 64), so two blocks never share a word. The memory-model
  content is small: the claim that matters, IM13 (the cursor never owns a t0 block), is a logic
  property that M1/M4 check. W3b and its mutant show that IM13 is exactly what makes the plain
  accesses legal.
- **W3c (CR-002):** the gap sweep's plain word read (`nextSetBit`) and byte `clearBit`, and a
  stashed cell's `fetch_or` on the **same** byte. The finalize runs outside the lock, after a pop
  made in an *earlier* lock hold. **Expected: a data race.** This shows that CR-002's access
  pattern, **if reachable**, is a C11 race. It does not show that it is reachable: the driver
  hard-codes the precondition that the register still lists as unverified (a stash pop from a block
  still being swept, within 64 bytes of a later live object). M4 (or a harness) must establish that.
- **W3d (CR-001):** `lazySweep`'s plain write of `gc_phase_` under the lock vs another worker's
  unlocked plain read. **Expected: a data race.** The pattern itself is Confirmed by code reading.
- **W3e:** two 7c L3 members in adjacent grant chunks (a word read by `nextFreeCell`, then a plain
  `setBit`) never touch the same **word**. Byte-disjoint chunks are not enough, because
  `nextFreeCell` reads whole words (`W3_BYTE_CHUNK`).
- **W3f:** `promo_mu_` is a lock: two plain increments of one field under the real `SpinMutex`
  (`try_lock` / `unlock`) do not race. M4 and M7 model `promo_mu_` as a mutex; this discharges that.

### 7.3 Driver

One file, one case per compile (`-DW3_CASE='a'` … `'f'`): a checker stops at the first report, and
W3c/W3d are *expected* to race while the other cases must not.

```cpp
// test/genmc/w3_markbyte.cpp  (one case per compile: -DW3_CASE='a' .. 'f')
#include <atomic>
#include <cstdint>
#include "wdriver.hpp"
#include "BitmapScan.hpp"
#include "MinorWork.hpp"             // minorwork::SpinMutex == promo_mu_'s type

// Two MarkBitArena slots (64-byte stride, OldGenSpace's layout): block 0 is a
// t0 mixed block (bytes 0..63), block 1 a post-t0 cursor block (bytes 64..127).
alignas(64) static uint8_t bits[128];
static Elm::minorwork::SpinMutex promo_mu;
static int phase_idle;                       // stands for OldGenSpace::gc_phase_ (plain)
static int counter;                          // a plain field guarded by promo_mu_

// SpinMutex::lock() spins through __builtin_ia32_pause, yield and sleep_for
// (MinorWork.hpp:91-108), which a checker cannot interpret (spike). The real
// try_lock(), under an assumption, is the same lock with the spin pruned.
static void lockPromo() { VERIFIER_ASSUME(promo_mu.try_lock()); }

// Copies of the real helpers (canary-pinned, §11).
static bool markerTAS(uint8_t* b, uint8_t mask) {           // testAndSetMark<ParallelMark>, :3067-3068
    std::atomic_ref<uint8_t> r(*b);
    if (r.load(std::memory_order_relaxed) & mask) return true;
    return (r.fetch_or(mask, std::memory_order_relaxed) & mask) != 0;
}
static void allocateBlack(uint8_t* b, uint8_t mask) {        // setMarkBitAtomic, OldGenSpace.hpp:1832
#ifdef MUTANT_W3_PLAIN_ALLOCATE_BLACK
    *b = static_cast<uint8_t>(*b | mask);                    // setMarkBitInBlock (05c negative control)
#else
    std::atomic_ref<uint8_t>(*b).fetch_or(mask, std::memory_order_relaxed);
#endif
}

// a: marker (bit 0) and allocate-black (bit 1) on the same byte: both bits end set.
static void* a_marker(void*) { markerTAS(&bits[0], 0x01); return nullptr; }
static void* a_alloc(void*)  { allocateBlack(&bits[0], 0x02); return nullptr; }

// b: IM13. The cursor allocates in ITS OWN slot (block 1): a 64-bit word read
// (nextFreeCell -> loadWord) and a plain setBit, while a marker marks block 0.
static void* b_cursor(void*) {
#ifdef MUTANT_W3_CURSOR_ON_T0_BYTE
    const size_t base = 0;                   // IM13 violated: the cursor owns the t0 block
#else
    const size_t base = 64 * 8;
#endif
    const uint32_t k = Elm::bitscan::nextFreeCell(bits + base / 8, 1, 0, 64);
    Elm::bitscan::setBit(bits + base / 8, k);
    return nullptr;
}

// c (register CR-002): the gap sweep, under the lock, finds the live object
// with a WORD read (nextSetBit) and plain-clears its bit, while a stashed
// cell's allocate-black fetch_or on the SAME byte runs outside the lock (the
// cell was popped in an earlier lock hold).
static void* c_sweeper(void*) {
    lockPromo();
    const size_t nb = Elm::bitscan::nextSetBit(bits, 0, 64);   // lazySweep :5339
    Elm::bitscan::clearBit(bits, nb);                            // lazySweep :5360
    promo_mu.unlock();
    return nullptr;
}
static void* c_finalizer(void*) {
    lockPromo();                             // batch pop into the stash
    promo_mu.unlock();
    allocateBlack(&bits[0], 0x01);           // finalizePoppedCellW :1083, outside the lock
    return nullptr;
}

// d (register CR-001): lazySweep writes gc_phase_ under the lock; another
// worker reads it without the lock (finalizePoppedCellW :1075, finalizeBitmapCellW :1135).
static void* d_sweeper(void*) { lockPromo(); phase_idle = 1; promo_mu.unlock(); return nullptr; }
static void* d_reader(void*)  { const int p = phase_idle; (void)p; return nullptr; }

// e: 7c L3 members in adjacent grant chunks (grantAllocateShared, OldGenTenure.cpp:208-214):
// nextFreeCell reads whole 64-bit words, so chunks must own whole WORDS, not just bytes.
#if defined(MUTANT_W3_SMALL_CHUNK)
constexpr uint32_t kChunk = 4;               // two members in one byte
#elif defined(MUTANT_W3_BYTE_CHUNK)
constexpr uint32_t kChunk = 8;               // byte-disjoint, but one 64-bit word
#else
constexpr uint32_t kChunk = 64;              // tenureChunkCells: a multiple of 64 cells (m = 1 here)
#endif
static void* e_member(void* arg) {
    const uint32_t lo = static_cast<uint32_t>(reinterpret_cast<intptr_t>(arg)) * kChunk;
    const uint32_t k = Elm::bitscan::nextFreeCell(bits, 1, lo, lo + kChunk);
    Elm::bitscan::setBit(bits, k);
    return nullptr;
}

// f: promo_mu_ is a lock (M4, M7 assume it): two plain increments under it.
static void* f_worker(void*) { lockPromo(); ++counter; promo_mu.unlock(); return nullptr; }

#ifndef W3_CASE
#define W3_CASE 'a'
#endif
int main() {
    pthread_t x{}, y{};
    switch (W3_CASE) {
    case 'a': x = spawn(a_marker); y = spawn(a_alloc); break;
    case 'b': x = spawn(a_marker); y = spawn(b_cursor); break;
    case 'c': bits[0] = 0x10;                // the live object's bit (4) is set
              x = spawn(c_sweeper); y = spawn(c_finalizer); break;
    case 'd': x = spawn(d_sweeper); y = spawn(d_reader); break;
    case 'e': x = spawn(e_member, reinterpret_cast<void*>(0));
              y = spawn(e_member, reinterpret_cast<void*>(1)); break;
    default:  x = spawn(f_worker); y = spawn(f_worker); break;
    }
    join(x); join(y);
    if (W3_CASE == 'a') assert(bits[0] == 0x03);
    if (W3_CASE == 'f') assert(counter == 2);
    return 0;
}
```

The two helpers `markerTAS` and `allocateBlack` are copies of the real ones: `testAndSetMark`'s
parallel branch and `setMarkBitAtomic`'s non-large branch. The canary pins those regions (§11).
`bitscan::nextFreeCell`, `nextSetBit`, `setBit`, `clearBit` and the `SpinMutex` are the real code
(`BitmapScan.hpp` and `MinorWork.hpp` are file-pinned).

### 7.4 What each case must show

| Case | Expected | Meaning |
|---|---|---|
| W3a | pass, `bits[0] == 0x03` | relaxed `fetch_or` is enough for byte sharing between markers and allocate-black (05c H1) |
| W3b | pass, no race | with IM13, the cursor's plain word reads and `setBit` touch only its own slot |
| W3c | **race reported** on `bits[0]` (the sweeper's word read or `clearBit` against the `fetch_or`) | CR-002's access pattern is a C11 data race **if** its precondition is reachable. Recorded in the register's history as C11 classification evidence; the status moves to Reproduced only when M4 or a harness shows the precondition is reachable |
| W3d | **race reported** on `phase_idle` | CR-001's first half (Confirmed by code reading) is a C11 data race; the recorded GenMC report is the Reproduced evidence for the race half, not for the moved decision point |
| W3e | pass | 7c L3 chunk ownership is whole 64-bit words (`tenureChunkCells`; 07 plan §10.18 item 1 says bytes) |
| W3f | pass, `counter == 2` | the real `SpinMutex` orders its critical sections (M4, M7) |

### 7.5 Mutants

| Mutant | Kind | Change | Bad execution |
|---|---|---|---|
| `W3_PLAIN_ALLOCATE_BLACK` | driver | `allocateBlack` as a plain `*b |= mask` (the 05c negative control `test_plain_allocate_black_`), case a | race with the marker's `fetch_or`. The worst case loses the marker's bit, so a live object is freed by the sweep (05c H1) |
| `W3_CURSOR_ON_T0_BYTE` | driver | case b's cursor works on block 0's slot (IM13 violated) | race between the cursor's word read / `setBit` and the marker's byte atomics |
| `W3_SMALL_CHUNK` | driver | case e with 4-cell chunks (two members in one byte) | race between the members' `setBit`s |
| `W3_BYTE_CHUNK` | driver | case e with 8-cell chunks (byte-disjoint, one word) | race between member 1's word read (`nextFreeCell` from cell 8 reads word 0) and member 0's `setBit` on byte 0: the reason chunks must be whole words |
| `W3_SPIN_RELAXED_UNLOCK` | header (`MinorWork.hpp:109`) | `unlock` stores `relaxed` | case f: the second worker's `try_lock` reads the unlock without synchronizing: **race on `counter`** |
| `W3_SPIN_RELAXED_TRYLOCK` | header (`MinorWork.hpp:89`) | `try_lock`'s `exchange` relaxed | case f: the same race |

After a fix for CR-001/CR-002 lands, W3c/W3d are rewritten to the fixed shape and become
pass-expected, and the pre-fix shape stays as a must-fail mutant. That gives the register's Guarded
status its negative control.

### 7.6 Mixed-size and mixed plain/atomic access

The bitmap is accessed at two widths and in two modes:
- markers and allocate-black use **byte** atomics (`atomic_ref<uint8_t>`);
- cursors, grant members and the gap sweep use **plain byte** writes (`setBit`, `clearBit`) and
  **plain 64-bit word** reads (`loadWord`: an 8-byte `memcpy`; in clang's `-O0` IR it is an
  `llvm.memcpy` of 8 bytes, at higher levels an `i64` load);
- `mark_.assign` zeroes a slot with `memset` (`BlockTable.hpp:316`), and the pause's `clearForMark`
  and `discard` do too (single-threaded).

Where it matters:
- **W3c (CR-002):** the sweeper's `nextSetBit` word read of the byte that the finalizer
  `fetch_or`s is a race in its own right, before `clearBit` runs. A driver that models only
  `clearBit` misses half the pattern.
- **W3b, W3e:** ownership must be at word granularity; a byte-granular model would pass
  `W3_BYTE_CHUNK`.
- **W4, W4b, W5:** a `memset`/`memcpy`-written object later read as words (§8.3, §9.3). The W4
  sketch writes `BlockInfo` field by field and the W5 sketch copies word by word for this reason
  (clang lowers a struct assignment to `llvm.memcpy`); the code's struct copy or `memcpy` is a plain
  bulk write, the same for happens-before and races.

**Tool behaviour (spike).** GenMC is expected to report, or reject, accesses of different sizes
to overlapping memory; how it treats `llvm.memcpy`/`llvm.memset` next to byte atomics is unknown.
herd7 likely cannot express mixed sizes at all (§4.1, **spike**). **Fallback:** replace each word read in the driver
by the eight byte reads of the same bytes, keeping the real function's control flow in a shim
pinned by the canary. That is a sound over-approximation for race detection: a word read races if
and only if one of its bytes does.

**Not checkable by any C11 tool:** C++20's rule for `atomic_ref` ([atomics.ref.generic]/3: while an
`atomic_ref` to an object exists, every access to it must go through an `atomic_ref`) is stricter
than the data-race rule. The single writer's **plain reads** of `region_end_`
(`OldGenSpace.cpp:875`, `:2768`, `OldGenSpace.hpp:351`) and of owner words (`assignPageIndexForBlock`,
`:599-609`) can overlap a background marker's `atomic_ref` load. Read/read is not a data race, so
GenMC will not report it, but it breaks that rule by the letter (reported in the review, §14).

## 8. W4: publishing a new block to background markers

### 8.1 Code under test

The code's order, for a large block (`allocateLargeBlock`, `OldGenSpace.cpp:2765-2775`) and for a
bag page (`ensureBagPageAvailable`, `:874-878`, then `materializeVirginBlock` or
`startVirginBlockShared`): the region grows and the page index is committed **first**, and
`materializeBlock` runs **after**. The other growth sites (`:2433-2437`, `:2522-2526`,
`:6624-6628`) have the same order.

| Step | Location | Access |
|---|---|---|
| 1. region bounds | `setRegionBase/End`, `OldGenSpace.hpp:412-413`, called at `:874-876`, `:2765-2770` (then `resizePageIndexForRegion`, `:878`, `:2774`) | relaxed stores; "grow-only during a cycle" (IM5). `recomputeRegionBounds` writes `region_end_` **plainly** (`:561`, CR-009), legal only outside a cycle |
| 2. page index commit | `resizePageIndexForRegion` → `commitPageIndexThrough` (`:540-546`) → `ReservedArray::ensureCommitted`, `ReservedArray.hpp:110-136` | `committed_.store(release)` after the commit syscall; a no-op when the 64 KiB chunk is already committed (the usual case) |
| 3. `blocks_.add` writes `BlockInfo` | `BlockTable.hpp:158-186`; `materializeBlock`, `OldGenSpace.cpp:657-664` | plain, into a `ReservedArray` slot (a reused id is possible: the free list is LIFO) |
| 4. `mark_.assign` zeroes the slot and writes `len_` | `BlockTable.hpp:310-319` | plain (`memset`) |
| 5. `live.commitThrough(id)` for every marker slot | `OldGenSpace.cpp:662`, `BlockTable.hpp:388-390` | the materializer commits each marker's private accumulator; a marker only indexes it (`add`, `:391`), and reads `committed_` only in `operator[]`'s assert. The reduction omits it and follows the NDEBUG build: that assert's acquire load would add edges the shipping build does not have |
| 6. owner words | `assignPageIndexForBlock`, `OldGenSpace.cpp:586-627` (its own `ensureCommitted(last + 1)` at `:595` is normally a no-op after step 2); `storeOwner`, `OldGenSpace.hpp:446-448` | `atomic_ref<uint32_t>::store(release)`: **the only edge that publishes steps 3–4** |
| marker lookup | `blockIdFor`, `OldGenSpace.cpp:1797-1816` | region bounds relaxed; `committed()` acquire (`ReservedArray.hpp:174`); `loadOwner` acquire (`OldGenSpace.hpp:449-451`); then **plain** reads of `BlockInfo` and (in the callers) `mark_.len` |
| promotion workers (W4b) | `startVirginBlockShared` (`:1249`) → `publishShared` (`:1201`: plain `alloc_state`, then release store of the shared word) vs `claimChunkW` (`:1171`: acquire load, plain `blocks_.info(id)` before the CAS, CAS `acq_rel`/`acquire`, then `mark_.slot(id)`, which is only address arithmetic) | release/acquire on `PromoCtx::shared[cls]`; the bitmap bytes are read later by `nextFreeCell` |

### 8.2 Properties

1. A marker that decodes an owner id sees the complete `BlockInfo` and `mark_.len` the mutator
   wrote before the owner store: no race and no stale `start`/`end`.
2. A marker's lookup of a **t0** object never fails while the mutator grows the region. This holds
   by coherence plus the launch's HB (§2.1); a relaxed stale bound still covers every t0 block. It
   also rests on three premises W4 does not check: IM5 (no release, so no bound shrinks and no
   `clearPageIndexForBlock` during a cycle), HEAP_049 (at most two owners per page slot; a third
   overwrites `secondary`, `:611-628`, and could drop a t0 owner), and CR-009's direct write staying
   outside cycles (`W4_RECOMPUTE_PLAIN` shows it would be a race).
3. **W4b:** a promotion worker that claims a chunk of a block another worker just materialized
   sees that block's `BlockInfo` and bitmap slot.

### 8.3 Driver (a pinned reduction)

`OldGenSpace` cannot be instantiated in a litmus test: it drags in the allocator, platform and
mmap. W4 therefore uses a **reduction**:
- the exact accesses and orders of the functions above, **in the code's order** (§8.1), over small
  static arrays;
- `storeOwner`/`loadOwner`/region-bound accessors copied verbatim.

The canary pins the originals (§11). A change to any of them fails the build until W4 is re-audited.

Two variants: `w4_publication` starts with the page-index slots already committed (the usual case),
`w4_commit` (`-DW4_COMMITTED0=2`) commits them in step 2. In both, the commit comes before the
`BlockInfo` writes, so it cannot mask a weakened owner store. (The first version of this sketch
committed **after** the writes, the reverse of the code; its `committed_` release/acquire then
published `info[1]` by itself and `W4_RELAXED_OWNER` could never fire.)

```cpp
// test/genmc/w4_publication.cpp  (a pinned REDUCTION, §8.3)
#include <atomic>
#include <cstdint>
#include <cstring>
#include "wdriver.hpp"

#ifndef W4_COMMITTED0
#define W4_COMMITTED0 4   // page-index slots already committed (the usual case: 64 KiB chunks)
#endif                    // w4_commit: -DW4_COMMITTED0=2 (this block's growth commits them)
struct BlockInfo { char* start; char* end; };
static char heap[4 * 64];                    // 4 "pages" of 64 bytes
static BlockInfo info[2];                    // BlockTable::info_ (plain)
static uint32_t mark_len[2];                 // MarkBitArena::len_ (plain)
static uint8_t mark_slot[2][8];              // MarkBitArena slots (plain)
struct PageOwners { uint32_t primary, secondary; };
static PageOwners page_index[4];             // page_index_ (owner words via atomic_ref)
static std::atomic<size_t> committed{W4_COMMITTED0};   // page_index_.committed_
static char* region_base; static char* region_end;

static void storeOwner(uint32_t& w, uint32_t v) {           // OldGenSpace.hpp:446-448
#ifdef MUTANT_W4_RELAXED_OWNER
    std::atomic_ref<uint32_t>(w).store(v, std::memory_order_relaxed);
#else
    std::atomic_ref<uint32_t>(w).store(v, std::memory_order_release);
#endif
}
static uint32_t loadOwner(const uint32_t& w) {              // OldGenSpace.hpp:449-451
    return std::atomic_ref<uint32_t>(const_cast<uint32_t&>(w)).load(std::memory_order_acquire);
}
static char* regionEnd() { return std::atomic_ref<char*>(region_end).load(std::memory_order_relaxed); }
static char* regionBase() { return std::atomic_ref<char*>(region_base).load(std::memory_order_relaxed); }

static int blockIdFor(const char* p) {       // OldGenSpace.cpp:1797-1816; returns id or -1
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
// The mutator (or a promotion worker under promo_mu_) adds block 1 = pages [2, 4)
// while a marker runs, in the code's order: the region grows and the page index
// is committed BEFORE materializeBlock (allocateLargeBlock, OldGenSpace.cpp:2765-2775;
// ensureBagPageAvailable, :874-878), so the owner store is the only edge that
// publishes the BlockInfo.
static void* mutator(void*) {
#if defined(MUTANT_W4_REGION_SHRINK)
    std::atomic_ref<char*>(region_end).store(heap + 64, std::memory_order_relaxed);   // IM5 violated
#elif defined(MUTANT_W4_RECOMPUTE_PLAIN)
    region_end = heap + 256;                 // recomputeRegionBounds :561 (CR-009) inside a cycle
#else
    std::atomic_ref<char*>(region_end).store(heap + 256, std::memory_order_relaxed);  // setRegionEnd
#endif
    if (committed.load(std::memory_order_relaxed) < 4)
        committed.store(4, std::memory_order_release);        // resizePageIndexForRegion -> ensureCommitted
    info[1].start = heap + 128; info[1].end = heap + 256;     // materializeBlock: blocks_.add (word-wise, §7.6)
    std::memset(mark_slot[1], 0, 8); mark_len[1] = 8;         //   mark_.assign
    storeOwner(page_index[2].primary, 2);                     //   assignPageIndexForBlock
    storeOwner(page_index[3].primary, 2);
    return nullptr;
}
// A background marker: looks up a t0 object (block 0, page 1), and probes block 1.
static void* marker(void*) {
    assert(blockIdFor(heap + 72) == 0);                       // t0 lookups never fail
    const int id = blockIdFor(heap + 130);
    if (id >= 0) { assert(id == 1); (void)mark_len[id]; }     // new block: full BlockInfo seen
    return nullptr;
}
int main() {
    info[0].start = heap; info[0].end = heap + 128; mark_len[0] = 8;   // t0 block 0 = pages [0, 2)
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
- The materializer may be a promotion worker under `promo_mu_` rather than the mutator
  (`startVirginBlockShared`); the accesses are the same.
- **W4b** (`w4b_shared_chunk.cpp`), same style. Worker A (under the real `SpinMutex`, taken with
  `try_lock` under an assumption) materializes block 1 (plain `info[1]`, bitmap zeroing), writes
  `alloc_state`, and does `shared.store((1+1) << 32, release)`. Worker B does `claimChunkW`'s
  `load(acquire)`, reads `info[1]`, CASes (`acq_rel`/`acquire`), then reads its claimed chunk's
  bitmap word. Expected: pass. For the CAS-failure mutant, A publishes a second block (block 2) in a
  later lock hold, so B's CAS can fail by reading it.
- **What W4 can and cannot say about `committed_`.** Its release/acquire pair exists to order the
  commit **syscall** before markers index the new slots. Whether memory beyond `committed_` is
  *mapped* is kernel behaviour, outside every C11 tool. In C11 terms the pair orders only writes made
  before the count store, and in the code's order no `BlockInfo` write precedes it, so W4 has no
  negative control for `committed_` (weakening it changes no C11 outcome). It is covered by
  argument and by HEAP_049's audit (§13 item 5), not by W4.

### 8.4 Mutants

All W4 mutants are driver mutants (the driver is a reduction).

| Mutant | Change | Bad execution |
|---|---|---|
| `W4_RELAXED_OWNER` | `storeOwner` relaxed (copy of `OldGenSpace.hpp:447`) | the marker reads `committed = 4` (initial, or the step-2 store, which precedes the writes) and decodes owner 2 from the relaxed store, then reads `info[1]` unordered with the mutator's write: **race on `info[1]`** |
| `W4_RELAXED_SHARED` | `publishShared`'s store relaxed (W4b) | worker B reads `info[1]` / the bitmap before A's writes: race |
| `W4_RELAXED_CLAIM_FAIL` | `claimChunkW`'s CAS failure order relaxed (W4b; `:1184`) | B's CAS fails by reading block 2's word without acquiring, and B's next iteration reads `info[2]`: race |
| `W4_REGION_SHRINK` | the mutator *lowers* `region_end` to `heap + 64`, below the t0 object at `heap + 72` (IM5 violated: a release during a cycle) | `assert(blockIdFor(heap + 72) == 0)` fails. A logic mutant: it shows the relaxed-bounds argument really rests on IM5. (With the first sketch's lookup at `heap + 8`, a shrink to any end above `heap + 8` could not fire it) |
| `W4_RECOMPUTE_PLAIN` | the mutator writes `region_end = heap + 256` **plainly**, as `recomputeRegionBounds` does (`:561`, CR-009) | **race on `region_end`** with the marker's `atomic_ref` load: a direct bound write is safe only because IM5 keeps it outside cycles. It states CR-009's hazard in C11 terms; CR-009's regression guard stays the footprint grep `region_end_ =` that the register names |

## 9. W5: claim → copy → publish

### 9.1 Code under test

| Piece | Location | Orders |
|---|---|---|
| header word load | `MinorWork.hpp:54` `loadHeader` | acquire |
| claim | `MinorWork.hpp:58-61` | CAS `acq_rel` / `acquire` |
| publish | `MinorWork.hpp:63-65` | release store of the forward word |
| wait out BUSY | `MinorWork.hpp:69-75` | acquire loads in a backoff loop |
| copy | `NurseryParallel.cpp:250` `copyClaimed` | plain `memcpy` of body, then header from the **saved** word (`:301-304`), publish `:311` |
| reader | `NurseryParallel.cpp:315` `evacuateP`; `spineRunP` (`:397`) | acquire load; installs the address (reads nothing through it during the drain) |
| 7c shadow | `TenureWork.hpp:73` `lookup` (acquire), `:79` `claim` (CAS from the **observed** word, `acq_rel`/`acquire`), `:84` `publish` (release), `:89` `waitPublished` | as listed |
| 7c exact engine | `TenureWork.hpp:248-268` `SerialEngine::tenure` | **relaxed** load, plain copy, release `publish`, **no claim** (it is the only writer while it runs) |
| 7c help and L3 members | `NurseryTenure.cpp:969-1003` `TenureParEnv::tenure`: acquire load, BUSY wait, claim, `memcpy`, release `publish`. L3 members run it concurrently with each other; help runs it only after `tenureJoin` (`:575`) has joined the gang (`join()`/`stopAndJoin()` at `:587-590`, `:618-625`) | full claim protocol |
| join | `GCBackgroundGang::memberLoop` finish (`GCHelperPool.cpp:590-595`), `joinLocked` (`:622-625`); `finishedApprox` (`:619`) is only a hint before `join()` | mutex; `finished_pub_` release/acquire |
| post-join readers | `majorRedirect` (`NurseryRegion.cpp:225`), `resolveRetire` (`:361`), the merge's validators (`NurseryTenure.cpp:694`) | acquire (or relaxed) loads of the shadow, after the join's mutex |

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

Fidelity: (b)'s collector runs the **real** `SerialEngine::tenure` (`TenureWork.hpp:248-268`)
through a four-member Env. `mw::loadHeader`/`claim`/`publish`/`waitPublished` and
`tw::ref`/`fwdOf`/`claim`/`publish`/`waitPublished` are the real functions. Three pieces are
**copies**, pinned by canary regions (§11): `evac` (the claim loop of `evacuateP`,
`NurseryParallel.cpp:332-341`, plus `copyClaimed`'s copy-then-publish), `helpTenure`
(`TenureParEnv::tenure`, `NurseryTenure.cpp:969-1003`), and the join (a `pthread_mutex_t` in place
of `GCBackgroundGang`'s `std::mutex` and condition variable).

```cpp
// test/genmc/w5_forwarding.cpp
#include <atomic>
#include <cstdlib>
#include "wdriver.hpp"
#include "MinorWork.hpp"
#include "TenureWork.hpp"
namespace mw = Elm::minorwork;
namespace tw = Elm::tenurework;

struct Obj { uint64_t header; uint64_t f1, f2; };   // header = 8-byte header word
// Word-wise plain copies: the code's memcpy is a plain bulk write, the same for
// happens-before and races, and word accesses avoid mixed-size memcpy (spike).
static void copyObj(Obj* d, const Obj* s) { d->header = s->header; d->f1 = s->f1; d->f2 = s->f2; }
static void setObj(Obj* d, uint64_t h, uint64_t a, uint64_t b) { d->header = h; d->f1 = a; d->f2 = b; }
static void pruneBusy(unsigned) { VERIFIER_ASSUME(false); }   // a waitPublished pause that prunes the spin

// (a) phase 6: two workers evacuate one from-space object.
static Obj* from;                                   // heap objects: forward words hold addr >> 3
static Obj* copies;                                 // in 40 bits, so addresses must be < 2^43 (spike)
static int copied[2];

static void* evac(void* arg) {                       // evacuateP's claim loop (NurseryParallel.cpp:332-341), copied
    const int me = static_cast<int>(reinterpret_cast<intptr_t>(arg));
    uint64_t hw = mw::loadHeader(from);
    for (;;) {
        if (mw::isForwardWord(hw)) {
            if (hw == mw::kBusy) { hw = mw::waitPublished(from, pruneBusy); continue; }
            const Obj* d = reinterpret_cast<const Obj*>(mw::fwdAddr(hw));
            assert(d->f1 == 11 && d->f2 == 22);      // the documented contract: read through
            return nullptr;
        }
        if (mw::claim(from, hw)) break;
    }
    Obj& dst = copies[me];                           // copyClaimed (:250-311), copied: plain body
    dst.f1 = from->f1; dst.f2 = from->f2;            // copy, then the header from the SAVED word
    dst.header = hw;
    copied[me] = 1;
    mw::publish(from, &dst, mw::colorOf(hw));
    return nullptr;
}

// (b) 7c: the REAL exact engine (SerialEngine::tenure, no claim) on the
// collector, then the join, then help (the claim protocol, copied).
static const uint32_t kGen = 2;
static Obj *tA, *tB;                                 // tenuring objects
static Obj *gA, *gB;                                 // grant cells: [0] collector, [1] help
static uint64_t sh[2];                               // shadow words: stale gen-1 FWD, set in main
static pthread_mutex_t gang_m = PTHREAD_MUTEX_INITIALIZER;   // GCBackgroundGang::m_
static int finished;                                 // GCBackgroundGang::finished_ (under gang_m)
static std::atomic<int> finished_pub{0};             // GCBackgroundGang::finished_pub_
static int copiesCol, copiesHelpA, copiesHelpB;      // one writer each

struct CollectorEnv {                                // the Env SerialEngine::tenure needs
    uint64_t* shadow(const void* o) const { return &sh[o == tA ? 0 : 1]; }
    uint32_t gen() const { return kGen; }
    size_t sizeOf(const void*) const { return sizeof(Obj); }
    void* copy(const void* o, size_t) {
        Obj* d = (o == tA) ? &gA[0] : &gB[0];
        copyObj(d, static_cast<const Obj*>(o));
        ++copiesCol;
        return d;
    }
};
static void* collector(void*) {                      // tenureEntry -> runJobExact, one item
    tw::SerialState st;
    CollectorEnv env;
    tw::SerialEngine<CollectorEnv> eng(st, env);
    (void)eng.tenure(tA, /*push=*/false);            // TenureWork.hpp:248-268: relaxed load, copy, release publish
    pthread_mutex_lock(&gang_m);                     // memberLoop's finish, GCHelperPool.cpp:590-595
    ++finished;
    finished_pub.store(finished, std::memory_order_release);
    pthread_mutex_unlock(&gang_m);
    return nullptr;
}
static int helpTenure(uint64_t* w, const Obj* src, Obj* dst) {   // TenureParEnv::tenure (NurseryTenure.cpp:969-1003), copied
    uint64_t e = tw::ref(w).load(std::memory_order_acquire);
    for (;;) {
        if (const char* d = tw::fwdOf(e, kGen)) {
            const Obj* o = reinterpret_cast<const Obj*>(d);
            assert(o->f1 == src->f1 && o->f2 == src->f2);          // read through (post-join readers do)
            return 0;
        }
        if (tw::genOf(e) == kGen && tw::stateOf(e) == tw::kStateBusy) {
            e = tw::waitPublished(w, kGen, pruneBusy);
            continue;
        }
        if (tw::claim(w, e, kGen)) break;            // CAS from the OBSERVED (stale) word: trap 11
    }
    copyObj(dst, src);
    tw::publish(w, dst, kGen);
    return 1;
}
static void* mutator(void*) {                        // tenureJoin: join, then help
#ifdef MUTANT_W5_HELP_WITHOUT_JOIN
    VERIFIER_ASSUME(finished_pub.load(std::memory_order_relaxed) == 1);   // no mutex, no acquire
#else
    pthread_mutex_lock(&gang_m);                     // joinLocked: cv_done_.wait(finished_ >= members)
    VERIFIER_ASSUME(finished == 1);
    pthread_mutex_unlock(&gang_m);
#endif
    copiesHelpA = helpTenure(&sh[0], tA, &gA[1]);
    copiesHelpB = helpTenure(&sh[1], tB, &gB[1]);
    return nullptr;
}
static Obj* objs(size_t n) { return static_cast<Obj*>(std::calloc(n, sizeof(Obj))); }
int main() {
    from = objs(1); copies = objs(2); tA = objs(1); tB = objs(1); gA = objs(2); gB = objs(2);
    // The encodings keep addr bits 3..42 only: fail loudly, not spuriously, if the
    // tool's addresses do not fit (spike).
    assert(mw::fwdAddr(mw::fwdWord(copies, 0)) == reinterpret_cast<char*>(copies));
    assert(tw::addrOf(tw::make(gB, tw::kStateFwd, kGen)) == reinterpret_cast<char*>(gB));
    setObj(from, /*tag Cons=*/3, 11, 22);
    { pthread_t a = spawn(evac, reinterpret_cast<void*>(0)), b = spawn(evac, reinterpret_cast<void*>(1));
      join(a); join(b); assert(copied[0] + copied[1] == 1); }
    setObj(tA, 3, 1, 2); setObj(tB, 3, 3, 4);
    sh[0] = tw::make(&gA[1], tw::kStateFwd, /*stale gen*/1);
    sh[1] = tw::make(&gB[0], tw::kStateFwd, /*stale gen*/1);
    { pthread_t c = spawn(collector), m = spawn(mutator); join(c); join(m);
      assert(copiesCol + copiesHelpA == 1 && copiesHelpB == 1); }
    return 0;
}
```

Implementer notes:
- The join is `VERIFIER_ASSUME(finished == 1)` under the mutex: it prunes the executions in which
  the collector has not finished, which is what `cv_done_.wait` does. A lock-and-poll loop would be
  unbounded for the checker. Use `pthread_cond_wait` only if the spike shows condvars are modelled
  **(spike)**.
- (b) initialises **both** shadow words to **stale** FWD entries (generation 1). The collector must
  treat `sh[0]` as unvisited (`fwdOf(e, 2) == nullptr`) and copy A without a claim. Help finds
  `sh[0]` forwarded by the collector and reads through it, and must claim `sh[1]` by a CAS from the
  observed stale word (07 plan trap 11). The first sketch left `sh[1]` at 0, so help's stale-word
  claim was never exercised.
- Every copy counter has one writer, so a double copy shows as the named assertion, not as a race
  on a shared counter.
- `helpTenure` reads through a found forward. The job itself only installs addresses; the reads
  through a shadow forward happen after the join (merge, `majorRedirect`). Like (a), this checks the
  documented release contract (`TenureWork.hpp:83`), and it is what lets
  `W5_SHADOW_RELAXED_PUBLISH` fire.
- A three-thread variant `w5_parallel_tenure.cpp` runs two L3 members concurrently on one object,
  both using `helpTenure` (the full claim protocol with a BUSY wait), then, after their join, help
  on the same object. Expected: one copy. In the code help never overlaps the members: `tenureJoin`
  calls `stopAndJoin()` (`:590`) before `tenureConcFinish`.

### 9.4 Mutants

| Mutant | Kind | Change | Bad execution |
|---|---|---|---|
| `W5_RELAXED_PUBLISH` | header | `publish` relaxed (`MinorWork.hpp:64`) | the loser's acquire load reads the forward word without synchronizing and reads through it: **race on the copy's body** (`copies[winner]`), or the read-through assertion |
| `W5_RELAXED_CLAIM_FAIL` | header | CAS failure order `relaxed` (`MinorWork.hpp:60`) | the loser's failed CAS reads the forward word (a failed CAS is a plain load and may read the latest write), the loop reads through it at once: **race on the copy's body**. In `evacuateP` the loser only installs the address, so this guards the documented contract. Reachable by the axioms **(spike: confirm the tool reports it)** |
| `W5_HELP_WITHOUT_JOIN` | driver | help starts after `finished_pub.load(relaxed) == 1`, without the mutex | no happens-before from the collector: help's acquire load may read the stale `sh[0]`, and its claim CAS can precede the collector's publish in modification order, so both copy A: `assert(copiesCol + copiesHelpA == 1)` fails (a **double tenure**). No race is reachable: when help does see the collector's FWD, it read it with acquire from a release. This is why `tenureJoin` must `join()` before help (`NurseryTenure.cpp:587-590, 618-625`); an acquire `finishedApprox()` alone would also order it, but the code always joins |
| `W5_SHADOW_RELAXED_PUBLISH` | header | `tw::publish` relaxed (`TenureWork.hpp:85`), 3-thread variant | a member reads through the other member's FWD without synchronizing: **race on the copy** |

---

## 10. How results feed back

- **Register** (`plans/threaded-gc-concurrency-register.md`). A W case is a litmus test built on a
  premise; it shows that an access pattern **is** a C11 race, not that the code **reaches** it.
  - W3d is the recorded command for CR-001's race half, whose access pattern is Confirmed by code
    reading: it may move that half to **Reproduced (C11)**.
  - W3c records CR-002's pattern as a C11 race. CR-002 stays **Suspected** until M4 or a harness
    shows its precondition is reachable; W3c's report is attached to the entry as evidence then.
  - Their mutant form stays in `genmc-check` as the **Guard's** negative control once a fix lands.
    `W4_RECOMPUTE_PLAIN` records CR-009's hazard (its guard stays the footprint grep).
  - Any new race or assertion failure becomes a new `CR-` entry, with the checker's execution
    graph as evidence.
- **Model assumptions.** Each TLA+ model's MAPPING.md has an "A4 assumptions" table. Each row names
  the W case that discharges it and that case's status:

  | Model | Assumption | Discharged by |
  |---|---|---|
  | M2, M3, M5 | deque operations are linearizable and pass entry contents (a thief scans a copy it stole) | W1 |
  | M2 | a decider that reads `active == 0` sees all work published before those `goIdle`s, and returned tickets | W2, `w2_returned_tickets` |
  | M2 | the `priv` path makes work that stays private visible (mark env only) | W2 `w2_priv` |
  | M2 | publish-before-`goIdle` is required in **every** environment: in the deque-only environments even under SC (M2), in the `priv`-counting mark environment only under weak memory (the second scan rescues it under SC) | W2 `w2_idle_before_publish` (expected: assert, under RC11) |
  | M1 | allocate-black and marker bits never erase each other | W3a |
  | M1, M4 | cursor and grant plain accesses (byte writes, 64-bit word reads) never share a word with a marker or another member | W3b, W3e |
  | M4, M7 | `promo_mu_` (`SpinMutex`) orders its critical sections like a mutex | W3f |
  | M1 | markers see complete metadata for any block they look up; t0 lookups never fail (with IM5, HEAP_049) | W4 |
  | M4 | a chunk claimed from a freshly published shared block is fully visible | W4b |
  | M3 | one copy per object; a forward names a complete copy | W5 (a) |
  | M5 | the exact engine's claim-free publish is safe because help starts after the join; help claims stale entries by the observed word | W5 (b) |
  | M5 | L3 members' claim, copy and publish on shadow words | W5 `w5_parallel_tenure` |

  If a W case fails, the model's assumption is void: the model's MAPPING.md says so, and the
  register gets the defect.
- **Plan premises.** A W result that contradicts a phase plan's memory-order argument (a 05c
  H-row, 06 P§3.3, 07 P§3.10) goes into that plan's as-built section and into the model's AUDIT.md.

### 10.1 Coverage census (A4)

Every `memory_order_*` and `atomic_thread_fence` in `runtime/src/allocator/` (259 lines on
2026-09-28), grouped by what an SC model's argument needs from it. "No W needed" rows carry the
argument; the census check (§11) fires when a line is added or removed.

| Group | Sites | What the models need | Disposition |
|---|---|---|---|
| Chase–Lev deque | `MarkWork.hpp:66-192` | linearizable, passes entry contents | **W1** |
| termination word, decider, budget as seen by the decider | `MarkWork.hpp:237-257, 372-387`; `budget` `:237, 287-300` | the decider's view of publish → `goIdle` | **W2** |
| `priv` stores and `anyWork` loads | `OldGenSpace.hpp:972, 981, 989`; `OldGenSpace.cpp:3489, 3501`; minor envs `NurseryParallel.cpp:117, 137, 145, 169`, `NurseryRegion.cpp:289`, `NurseryTenure.cpp:185, 948` | mark env: private work visible to the decider | **W2** (`w2_priv`). The minor envs' `anyWork` does not read `priv` (M2 `AnyWorkCountsPriv = FALSE`), so their stores need nothing. Pause-time resets (`OldGenSpace.cpp:378, 2850`, `NurseryParallel.cpp:85, 734`, `NurseryRegion.cpp:859`) run with no participant |
| mark bytes, allocate-black, gap sweep, `gc_phase_`, `promo_mu_` | `OldGenSpace.cpp:3067-3068`; `OldGenSpace.hpp:1832`; `MinorWork.hpp:88-109` | indivisible `fetch_or`; byte/word ownership; the lock | **W3** |
| large-mark byte | `OldGenSpace.cpp:3057-3058` (`exchange`), `OldGenSpace.hpp:1825` (`store(1)`) | indivisibility only: both sides write 1 | no W: both are atomic, so no race; no data travels through the byte |
| region bounds, owner words, page-index count, shared chunk word | `OldGenSpace.hpp:407-413, 447, 450`; `ReservedArray.hpp:111, 135, 174`; `OldGenSpace.cpp:1173-1184, 1212` | complete metadata; t0 lookups | **W4**, W4b. `committed_` orders a syscall: no C11 check (§8.3). The shared word's relaxed load/store under `promo_mu_` (`:1221, 1227, 1267`) are ordered by the lock; a lock-free claimer that reads the relaxed 0 carries no data |
| header forward word, shadow words, the join | `MinorWork.hpp:55-71`; `TenureWork.hpp:74-91, 255`; `NurseryTenure.cpp:971, 1038`; `GCHelperPool.cpp:590-625` | one copy; complete copies; help after the join | **W5** |
| post-join shadow readers | `NurseryRegion.cpp:225, 361` (`lookup`, acquire), `NurseryTenure.cpp:694-695` (validator, relaxed) | reads after `tenureJoin` | no W beyond W5 (b): the mutex join orders them (M6 LaunchJoin) |
| indivisibility-only RMWs | ticket pools (`MarkWork.hpp:287-300`, the assist `pool`), to-space top (`MinorWork.hpp:153-168`), builder bottom (`NurseryRegion.cpp:385`), grant chunk claims (`OldGenTenure.cpp:235-249`), 07b age mark words (`NurseryTenure.cpp:209-210`, `acq_rel`, stronger than needed) and reached flags (`:233, 244, 1009`), `live_bytes` (`OldGenSpace.cpp:527, 1034, 1085`) | the models assume only that each RMW is indivisible | no W: SC and C11 agree on RMW atomicity (primer §3.6 item 2). What a winner then writes travels by another edge (a forward word, the deque, the join). `live_bytes` is read by the shrink only after the join |
| stop and share hints | `SliceControl::stop` (`MarkWork.hpp:245`; set by `stopAndJoin`, `GCHelperPool.cpp:641`, release; cleared before launch, `NurseryTenure.cpp:514`), the exact engine's stop check (`TenureWork.hpp:218`), `share_epoch` (`OldGenSpace.cpp:4538, 4579`; `MarkWork.hpp:425`) | a stop ends a run without `done`; a share makes private work stealable | no W: a stale value only delays the reaction (liveness), and the work left behind is handed over by the join (mutex). A checker of safety cannot show "eventually visible", which C++ only recommends ([atomics.order]/11) |
| gang and episode hints | `finished_pub_`, `running_` (`GCHelperPool.cpp:593, 602-625`, `GCHelperPool.hpp:258`); `bg_ep_` (plain, mutator-only) | `running()` exact on the mutator; members' writes visible after `join()` | **Partly covered.** Most consumers of member data call `join()` (mutex) first, and `W5_HELP_WITHOUT_JOIN` shows what skipping it costs. One does not: `tenureJoin`'s orphan test (`NurseryTenure.cpp:613-615`) reads the job's state after `running()` (acquire, `GCHelperPool.hpp:258`) returns false, without joining. When a foreign `stopAndJoin` (fork prepare, exit) did the join, the members' writes reach the owner only through the chain member → `m_` → foreign joiner → `running_` release store (`GCHelperPool.cpp:625`) → the owner's acquire load. Proposed (M6 review): a 3-thread reduction `w_running_chain.cpp` (mutant: the `running_` store relaxed → the owner may read a stale job state), used by M5 and M6 |
| **pool job state** | `HelperJob::state`: post CAS (`GCHelperPool.cpp:154-155`), worker `Running`/`Done` stores (`:214, 219`; Sync mode `:163-165`), `wait()`'s fast path (`:238`), `isDone()`/`isIdle()` (`GCHelperPool.hpp:56-57`), `resetForReuse` (`:59-61`) | a waiter that sees `Done` sees the job's outputs (M7: `failures`) | **Not covered.** The `Done` store is `release` inside `m_`, but `wait()`'s fast path and `isDone()` read it with `acquire` **without** the mutex, so the outputs travel by that pair alone: a message-passing assumption, not "the pool mutex" as M7's A4 row says. Proposed: a 2-thread reduction `w_pool_done.cpp` (worker: write `failures`, store `Done` release under a mutex; waiter: acquire load, read `failures`; mutant: `Done` relaxed → race), added at M7's close-out |
| validators and test hooks | `im10_armed_` (`OldGenSpace.cpp:383, 3636, 4136, 4314`), `test_bg_hold_` (`:4407, 4585`), H2 validator reads (`OldGenSpace.hpp:1840, 1847`), TV7 (`NurseryRegion.cpp:255-256`) | none | out of scope |
| pause-only and single-threaded | deque `reset`, `SliceControl` constructor, shared-word and grant-claim resets (`OldGenSpace.cpp:1395, 1404, 1468-1469`, `OldGenTenure.cpp:80`), `closeLabs` (`MinorWork.hpp:219, 222`), `copy_ptr_` (`NurseryParallel.cpp:777`), `ReservedArray::reserve/release` | none | no concurrent access |
| relaxed counters a decision reads | `bgConsumedApprox` (`OldGenSpace.cpp:4392`, the running episode's budget: pacing), `sizeApprox`/`markStackSize` (pause) | policy, not safety (parent plan §0 non-goals) | no W |
| statistics | `member_cpu_ns`, pool `stats_`, `J.cpu_ns` (`NurseryTenure.cpp:1218`), `Allocator.cpp:1365-1375`, `RuntimeExports.cpp` | none | out of scope |
| outside M1–M7 | `PermanentSpace` `base_`/`used_` (`PermanentSpace.cpp:50-85`, `.hpp:45-48`), `GCHelperPool::configured_` (M6) | — | out of scope for W |

## 11. Build and canary wiring

- **Layout:** `test/genmc/` holds `wdriver.hpp`, `w1_deque.cpp` … `w5_forwarding.cpp` (one compile
  per case where a checker stops at the first report, as in W3's `-DW3_CASE`), `mutate.sh`, and
  `drivers.txt` (the runner's registry).
  - One line per driver or mutant: `name  file  defines  expected`, where expected is `pass`,
    `race`, or `assert`.
  - `race` and `assert` rows name the variable or assertion that must be reported, so a mutant that
    fails for a different reason does not count (primer §5). Where one weakened order produces two
    reports in different executions (a race on the data, or the assertion on the value read), the
    row lists both, as the mutant tables do; the checker's exploration order decides which comes
    first. A report outside the list (a crash, an `abort()` in the code, a memory error) fails the
    row.
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
  - `file` lines: `MarkWork.hpp` (W1, W2, M2), `MinorWork.hpp` (W3f, W5, M3), `TenureWork.hpp`
    (W5, M5), `BitmapScan.hpp` (W3);
  - `region` lines for code the drivers copy or reduce:
    - `testAndSetMark` parallel branch, `setMarkBitAtomic`, `lazySweep`'s gap-sweep loop and phase
      change, `finalizePoppedCellW`, `finalizeBitmapCellW`, `grantAllocateShared`,
      `tenureChunkCells`/`kChunkUnitCells` (W3);
    - `materializeBlock`, `assignPageIndexForBlock`, `blockIdFor`, `storeOwner`/`loadOwner`, the
      region-bound accessors, `recomputeRegionBounds` (CR-009), the grow-commit-materialize order of
      `allocateLargeBlock` and `ensureBagPageAvailable`, `commitPageIndexThrough`,
      `ReservedArray::ensureCommitted`/`committed`, `publishShared`, `claimChunkW` (W4);
    - `ParallelEnv::anyWork` (W2);
    - `evacuateP`'s claim loop and `copyClaimed`'s copy-then-publish (W5a);
      `TenureParEnv::tenure` (W5b);
    - `GCBackgroundGang::memberLoop`'s finish and `joinLocked`, and `tenureJoin`'s join branches
      (W5b);
  - `census` lines: the §10.1 census is the allocator census of parent §7.1, with W1–W5 named on the
    lines they cover, so a new `memory_order` anywhere in `runtime/src/allocator/` needs a W verdict;
  - a W's AUDIT entry (in `test/genmc/AUDIT.md`) is what `--update` checks for, as for the TLA+
    models.

## 12. Implementation steps

1. **Step 0, the spike** (§4.2): the GenMC Docker stage, W1 as written, `W1_RELAXED_PUBLISH` and
   `W1_NO_TAKE_FENCE` (on the two-thief variant) flagged, and W5's address-width asserts. Record
   the tool facts in the parent plan §3. If GenMC fails, switch to C11Tester plus herd7 and rewrite
   §4.1's row.
2. **W1**, including the paper variant and the two-thief variant.
3. **W2**, including `w2_priv`, `w2_idle_before_publish` and `w2_reactivate`. Cross-check against
   M2's `idle_before_publish` result (M2 splits a slot's `anyWork` read into two steps): M2 must
   fail on its deque-only configuration and pass on the `priv`-counting ones, and
   `w2_idle_before_publish` must fail under RC11. If W2 passes here, check that the driver still
   has both scans and the deque-then-`priv` order before believing it.
4. **W5** (a) and (b), plus the 3-thread shadow variant.
5. **W3**, one compile per case. Expect W3c/W3d to report races. Attach the execution graphs to
   CR-001 (race half: Reproduced) and CR-002 (evidence; its status waits on M4, §10).
6. **W4** and W4b, with the reduction pinned in the manifest.
7. **Wiring:** `drivers.txt`, `run_drivers.py`, `genmc-check`, the manifest lines, AUDIT.md first
   entries, and the MAPPING.md A4 tables of M1–M5 (and M7, for W3f and the pool-job row of §10.1)
   filled in with W statuses.

## 13. Open questions

1. **(spike)** Does GenMC handle `std::atomic_ref` on a non-atomic object, and C++ templates with
   `new[]`/`std::vector` (`WorkStealingDeque::grow`)? If not, how thin can the shim be while still
   compiling the real functions' bodies?
2. **(spike)** How does GenMC treat a location accessed both through `atomic_ref` (atomic) and
   plainly (W3c), and at two widths (a byte `fetch_or` against `loadWord`'s 8-byte `memcpy`, §7.6)?
   It must report the mixed access as a race, not silently treat the location as atomic or plain
   throughout, and not abort on the size mismatch. If it cannot, use §7.6's byte-read fallback.
3. **(spike)** Spin loops: can `idleUntilWorkOrDone` and `waitPublished` be checked as written with
   spin-assumption, or must every driver straight-line them, as the sketches above do?
4. `W1_STEAL_RELAXED_BOTTOM` and `W5_RELAXED_CLAIM_FAIL`: the review argued both reachable from the
   RC11 axioms at these sizes (§5.4, §9.4); the spike confirms the tool reports them. If it does not,
   they are not valid negative controls: enlarge the driver or drop the mutant, with a note.
5. W4 cannot see mmap. Is there any path where a marker reads a page-index slot beyond what the
   kernel has mapped, despite `committed_`? That is a question for the M1 audit (HEAP_049), not for
   a C11 tool.
6. **(spike)** Addresses: the forward word, the shadow entry and the mark entry keep address bits
   3..42 only. Do the tool's global and heap addresses fit below 2^43 (W5's first asserts)? If not,
   W5 needs a low-address allocation shim or a transliteration.
7. **(spike)** Intrinsics and runtime calls the headers can reach: `__builtin_ia32_pause`
   (`cpuRelax`, `SpinMutex::lock`), `sched_yield`, `nanosleep`, aligned `operator new`,
   `llvm.memcpy`/`llvm.memset`/`llvm.memmove`. The sketches avoid the pause, the sleeps and aligned
   `new`; `w2_real_loop` cannot. In clang's IR, W1/W2 still reach `llvm.memmove` (`std::vector`
   growth of `retired_` in `grow()`) and W4 reaches `llvm.memset` (`mark_.assign`'s `memset`, on a
   slot no other driver thread reads).

## 14. Adversarial review (2026-09-28)

Against the current tree. Mutant reachability was argued by hand from the RC11 axioms; no checker
was run. All sketches and variants were re-checked with g++ 12.2 and clang++ 14 (`-fsyntax-only
-Wall -Wextra`), and each header mutant's `sed` pattern was checked to match its line exactly once.

| Id | Severity | Finding | Change |
|---|---|---|---|
| R1 | Blocker | `W4_RELAXED_OWNER` could never fire: the sketch committed the page index **after** the `BlockInfo` writes, the reverse of the code (`allocateLargeBlock` `:2765-2775`, `ensureBagPageAvailable` `:874-878`), so `committed_`'s release/acquire published `info[1]` on its own | reduction reordered to the code; slots pre-committed by default; `w4_commit` variant; §8.3 says why `committed_` has no C11 negative control |
| R2 | Blocker | `W5_SHADOW_RELAXED_PUBLISH` could never fire: `helpTenure` returned on a forward without reading through it | read-through added (the documented release contract, `TenureWork.hpp:83`) |
| R3 | Blocker | `W1_NO_TAKE_FENCE` was unreachable with one thief doing one steal: the last element is decided by the CAS, and the fence bug needs two successful steals; its bad-execution text was wrong | two-thief variant (`-DW1_THIEVES=2`), execution rewritten, §2.4 corrected |
| R4 | Major | `W2_RELAXED_DECIDER_LOAD` patched `MarkWork.hpp:372`, which the driver does not run (it copies the round): a no-op mutant | driver mutant; §3 splits header and driver mutants; `mutate.sh` must match exactly once |
| R5 | Major | `W4_REGION_SHRINK` could not fire as described: the t0 lookup at `heap + 8` stays inside any lowered end above it | lookup at `heap + 72`, shrink to `heap + 64` |
| R6 | Major | `W5_HELP_WITHOUT_JOIN`'s "race on `gA[0]`" is unreachable (help reads a found forward with acquire from a release), and the shared `copiesA` would race first | one writer per counter; expected outcome is the double-copy assertion |
| R7 | Major | `w2_priv` was presented as M2's `idle_before_publish`. The real reversed order (publish **after** `goIdle`) fails even under SC, because `anyWork` reads the deque before `priv`; M2's `AnyWorkNow` hides this by reading a slot in one step (**corrected by R20**: under SC only with a one-scan decider) | `w2_priv` renamed to what it is; new `w2_idle_before_publish` (expected: assert); A4 table row; reported to M2 |
| R8 | Major | W3c/W3d were said to move CR-002/CR-001 to Reproduced. W3c hard-codes CR-002's unverified precondition, so it classifies the pattern, it does not reproduce the defect | §7.4, §10: CR-002 waits on M4; W3d is the race-half evidence for CR-001 |
| R9 | Major | W3b/W3e were byte-granular, but `nextFreeCell`/`nextSetBit` read 64-bit words (`loadWord`); chunks must be whole words, and CR-002 includes the sweeper's word read (`:5339`) | real `nextFreeCell`/`nextSetBit` in the driver; `W3_BYTE_CHUNK`; §7.6 on mixed size and its fallback |
| R10 | Major | Feasibility: `SpinMutex::lock` compiles to `llvm.x86.sse2.pause`, `sched_yield`, `nanosleep` (clang IR); W5 used `std::mutex`, a lock-and-poll loop and a static initializer needing a global constructor; `new WorkStealingDeque` needs aligned `operator new` | `try_lock` under assume; `pthread_mutex_t` with assume; init in `main`; placement new; `waitPublished` with a pruning pause; §4.1 and §13 list the rest as **(spike)** |
| R11 | Major | Forward words, shadow entries and mark entries keep address bits 3..42; a tool (or a PIE binary) may place objects above 2^43, breaking every W5 read-through | heap objects and round-trip asserts in W5; spike step and open question 6 |
| R12 | Major | No negative control for `grow()`'s publication (property 3) | `W1_RELAXED_ARRAY` |
| R13 | Major | No coverage census. Uncovered: `promo_mu_`'s `SpinMutex` (M4/M7 treat it as a mutex) and `HelperJob::state`, whose `Done` travels release/acquire **outside** the pool mutex (`wait()` fast path, `isDone()`) | §10.1 census; W3f with two header mutants; a proposed `w_pool_done` for M7 |
| R14 | Minor | W5 (b) never exercised the stale-word claim (`sh[1]` was 0); the collector re-implemented `SerialEngine::tenure` | stale `sh[1]`; the collector now runs the real `SerialEngine::tenure` |
| R15 | Minor | CR-009 (`recomputeRegionBounds`' plain write, `:561`) and W4's other premises (IM5, HEAP_049's third-owner overwrite) were not stated | `W4_RECOMPUTE_PLAIN` (CR-009's hazard in C11 terms); premises in §8.2 |
| R16 | Minor | §8.3 said `committed_` "orders the plain writes that follow the commit" (release orders earlier writes) | rewritten |
| R17 | Minor | The 3-thread tenure variant ran help concurrently with L3 members; the code joins first (`:590`) | members concurrent, help after their join |
| R18 | Minor | Drift: `testAndSetMark`'s atomics are at `:3067-3068`; the `initObjectHeaderWithSize` call is `:518`; `evacuateP`'s loop is `:332-341`; page-index commit order; "no race on `buf`/`array_`" named atomics; the paper variant left `grow()`'s copy store `release` | fixed in place |
| R20 | Major | (Orchestrator, reconciling R7 with the M2 review.) R7's "fails even under SC" held only for the driver's one-scan decider. The real round checks work twice (`MarkWork.hpp:375`, `:382`); under SC the second scan sees the published deque, and any removal needs a reactivation that fails the done-CAS. Under RC11 both scans can miss (the relaxed `priv` read gives no happens-before to the push) | driver keeps both scans (`-DW2_ONE_SCAN` for the old form); the variant's expected outcome, the A4 row and §12 step 3 now say "fails under RC11, not SC"; compiled with g++ and clang++ over six variants |
| R21 | Minor | (Orchestrator, from the M6 review.) §10.1 said every consumer of member data joins first; `tenureJoin`'s orphan test reads the job state after an unjoined `running()` acquire, so a foreign joiner's `running_` release is the only edge | census row corrected; `w_running_chain` proposed |
| R19 | Minor | Plain reads of `region_end_` and owner words by their single writer overlap markers' `atomic_ref` loads: not a data race, but against [atomics.ref.generic]/3; no C11 tool sees it | noted in §7.6; reported |
