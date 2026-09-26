# Threaded GC 05b — Parallel marking (written against the snapshot)

**Status:** DONE (2026-09-26), **default-on: `gc_mark_threads` = 0 (auto), cap 16, T = 32**.
Written against the `keep-TG5a` tree (`bin/eco-opt-prev` = `eco-optTG5a`); as-built record in
P§10.

**Parent:** `plans/threaded-gc-master-plan.md`, phase 5b (formerly phase 4).

**Depends on:** phase 3 (thread infrastructure, GC_DET_001, the TSan harness) and phase 5a
(the snapshot cycle; the forward contract in `plans/threaded-gc-05a-incremental-marking.md`
§9, which this plan implements for its 5b column).

**Background:**
- `design_docs/parallel-gc.md` §5.8 (parallel STW marking), §3.4 (memory model), §3.5
  (metadata a second thread would race on), §10 (measuring a concurrent collector);
- handbook sections cited there: HB 13.4 (atomic test-and-set), HB 12.7/13.5 (Chase–Lev
  work-stealing deques), HB 13.6 (termination), HB 16.4 (chunking large objects).

§n points into `design_docs/parallel-gc.md`, P§n into this plan, 5a-P§n into the 5a plan, M§n
into the master plan.

---

## 0. What this phase delivers, and why

**Where 5a left the pauses** (self-compile, T = 32, triple medians):

| pause kind | count | p99 | max | of which GC work in the pause |
|---|---|---|---|---|
| minor only | 1,686 | 113 ms | 186 ms | — |
| minor + mark slice | 224 | 300 ms | 336 ms | slice ≤ 225 ms |
| minor + t0 snapshot | 7 | 136 ms | 136 ms | t0 ≤ 23 ms |
| minor + handoff | 7 | 153 ms | 153 ms | tail ≤ 95 ms |

- **The worst pause is now a mark slice.** A slice is up to 225 ms of single-threaded marking,
  on top of a minor pause.
- **Marking is latency-bound:** about 41 ns per object, dominated by cache misses, with a 16-deep
  prefetch ring. k markers should give close to k times the memory-level parallelism (§5.8).
- **All of it sits inside pauses:** 9.9 s of in-pause mark time per self-compile, plus the
  7 handoffs.

**This phase runs every mark slice, closing drain and emergency drain on N markers:**
- the paused mutator is marker 0;
- N − 1 gang threads are markers 1 … N − 1;
- the markers share the work through Chase–Lev work-stealing deques, set mark bits with
  `fetch_or`, and keep one live-bytes accumulator each.

The snapshot (t0), the handoff tail, the schedule and every GC decision stay exactly as in 5a.

**Two properties make 5b more than "add threads":**
1. **Deterministic pacing.** 5a's pacing reads the units done (5a-P§3.5: the doubling on
   overrun). With N markers, the number of objects processed in a slice would depend on
   scheduling, and so would every later decision.

   5b therefore accounts work in **exact tickets**: a slice processes exactly
   `min(budget, work remaining)` entries, whatever N is and however they are split. Units per
   slice, per cycle and per run become bit-identical at every N (GC_DET_001, P§3.3).
2. **Written against the snapshot (M§3 phase-5 rule).** A marker reads only:
   - old-gen objects reachable from the t0 snapshot;
   - the page index and `BlockInfo` of t0 blocks;
   - its own deque, ring and accumulator;
   - other markers' deques, only through `steal`.

   It never reads a root, a young object or any mutator-owned structure (5a-P§3.10). 5c then
   moves the same markers off the pause without rewriting them.

**Expected result** [E]:
- the slice's mark part shrinks by about ÷k (k = 4: 225 ms → ~60 ms);
- the worst pause drops to the minor-pause floor (~186 ms), which phase 6 lowers;
- in-pause mark time falls from 9.9 s to about 2.5 s per self-compile, i.e. −5 to −7 s wall;
- because slices get k times cheaper, a **smaller T** (less retention) may now fit under the
  floor, and E3 re-chooses it.

| # | Deliverable |
|---|---|
| D0 | Re-verified facts (P§2), a same-session baseline with `eco-optTG5a`, snapshot `try-TG5b-pre` |
| D1 | Pure refactor, counters bit-identical: a packed 8-byte mark entry, a `MarkWorker` context, and the mark loop, `markOneObject`, `markChildren` and `pushMarkRoot` rewritten as templates on a mark policy (`SerialMark` / `ParallelMark`) |
| D2 | Exact ticket accounting in the serial marker: no ring overshoot. Decision counters identical; per-slice units change by ≤ 15 |
| D3 | Large-array chunking: `Tag_Array` and `Tag_ListBacking` above `MARK_CHUNK_ELEMS` = 1,024 slots are scanned in chunk entries. Mark units change only for such arrays |
| D4 | Per-marker `LiveBytesAccumulator`s (HEAP_051), merged in index order; atomic mark-bit policy |
| D5 | `WorkStealingDeque` (Chase–Lev, C11 memory orders, growable, retire-after-join), std-only, TSan-tested |
| D6 | `GCMarkGang`: a gang of parked threads that runs one function on members 0 … n−1 (0 = the caller) and joins. std-only, TSan-tested, fork-safe |
| D7 | The parallel marker: ticketed ring loop, stealing, termination with spin → yield → sleep idling; wired into `runCycleSlice`, `drainCycleMark` and a T = 0 cycle for `incremental_mark = false` |
| D8 | Config `gc_mark_threads` (0 = auto from affinity mask and cgroup quota, capped; 1 = serial reference) and `ECO_GC_MARK_THREADS` |
| D9 | Validators IM10 (each object scanned once) and IM11 (serial replay check in validate builds), stats, banner, event log, collector CPU |
| D10 | Tests (unit, TSan harness, negative controls), experiments E0–E6, gates, invariants, docs, default flip |

**Out of scope:**
- concurrent marking (the mutator running during marking): 5c;
- parallelising the t0 snapshot's young walk (≤ 23 ms) or the handoff tail (≤ 95 ms): record
  them if they become the worst pause;
- the STW `ThreadLocalHeap::majorGC()` path (joins, allocation failures, `eco_major_gc`). It
  traces through the nursery with `nursery_visited_`, which cannot be shared, and it stays
  serial;
- parallel minor GC: phase 6.

---

## 1. Ground rules

1. **`gc_mark_threads = 1` is the reference.** After D1–D4 it runs the templated serial
   marker.
   - Counters must equal `eco-optTG5a` except mark units (D2 changes per-slice units by the
     ring overshoot; D3 changes the units of arrays over 1,024 slots).
   - Every decision counter (minors, majors, promoted, copied, allocated, per-major
     before/after/garbage/recovered, old-gen peak) is identical.
   - `out.mlir` is byte-identical.
2. **Every N reproduces N = 1 bit for bit.** Every counter, mark units included, and the major
   event log's non-timing columns are identical at `gc_mark_threads` ∈ {1, 2, 4, 8, auto} and
   with `ECO_GC_HELPER_JITTER_US` set. This is the TG3 gate recipe applied to marking. A
   difference is a bug in P§3.3, never noise.
3. **Nothing outside the mark changes.**
   - The snapshot, schedule, triggers, handoff tail and allocation policy are 5a's.
   - The markers run only while the owning mutator is inside a GC pause and joined before it
     returns.
   - They never overlap mutator execution (that is 5c).
4. **Markers write only:**
   - mark bits and large-mark bytes (atomic);
   - their own deque, ring, accumulator and stats;
   - other markers' deques' `top` (by stealing).

   Everything else they read is frozen for the pause: P1 for objects, and the mutator is
   stopped for metadata. IM10/IM11 and the TSan harness check it.
5. **Assert what you rely on** (M§2): the validate tree runs IM1–IM11 on unit, E2E and stress;
   the TSan harness runs the deque, gang and termination protocol on a synthetic heap.
6. **Standing gates** (M§2): E2E, elm-tests, `full`, stress under GC pressure, the validate
   tree, stats-off build, `out.mlir` byte-identical, bootstrap fixed point.

---

## 2. Verified facts

Verified 2026-09-26 against `keep-TG5a`. Paths are under `runtime/src/allocator/`; line numbers
are approximate. **Re-verify before editing (Step 0).**

| # | Fact | Where |
|---|---|---|
| F1 | The grey set is `std::vector<MarkStackEntry> mark_stack` (16 B entries: `void* obj; BlockId block`) with 17 uses in `OldGenSpace.cpp`: `prepareMark`/`reset` clear it; `pushMarkRoot` pushes; `markWorkUnits` pops through the FIFO ring; `incrementalMark`, `drainCycleMark`, `runCycleSlice` and `handoffMarkCycle` test `empty()`; the two profiling `finishMarkAndSweep` overloads read `size()` for `mark_stack_peak`. | `OldGenSpace.hpp:~640`, `OldGenSpace.cpp:392, 2044, 2123-2172, 2364, 2380, 2735-2761, 2853-2913` |
| F2 | `markWorkUnits(budget)` is the one mark loop (5a D1): it fills a `MARK_FIFO_DEPTH` = 16 ring from the stack with prefetch, scans the ring's head, and **drains the ring before returning**, so it processes up to 15 objects over budget. Units = `markOneObject` calls that returned true. | `OldGenSpace.cpp:~2115-2155` |
| F3 | `pushMarkRoot(obj)` is the grey transition. In a cycle it drops young targets in snapshot mode and aborts on them otherwise (IM3, validate). A nursery target (legacy STW only) is deduplicated by `nursery_visited_` (a `std::unordered_set`). An old target is `testAndSetMarkBitInBlock`ed (a plain byte RMW, or the large-mark byte for `is_large` blocks) and pushed with its block id. | `OldGenSpace.cpp:~2335-2381`, `OldGenSpace.hpp:~1273-1290` |
| F4 | `markOneObject(obj, block)` skips `Tag_Free`/`Tag_Forward`; for a nursery object it calls `markChildren` and attributes nothing; for an old object it asserts HEAP_BUILDER_001 (validate: `isYoungLarge` hash read), computes the walk step (the class size for a uniform block, else `getObjectSize`), calls `mark_live_.add(block, step)` and `markChildren(obj)`. | `OldGenSpace.cpp:~2392-2462` |
| F5 | `markChildren(obj)` is a per-tag switch calling `markHPointer` / `markUnboxable` → `pushMarkRoot`. `Tag_Array` scans `length` elements; `Tag_ListBacking` scans `[hd, size)`; `Tag_Custom`/`Tag_Record` at most 24/32 fields; `Tag_DynRecord` scans `size` values. No tag is chunked. | `OldGenSpace.cpp:~2175-2330` |
| F6 | `LiveBytesAccumulator mark_live_` (one `ReservedArray<uint64_t>` per BlockId). Uses: reserved in `reserveMetadata` for `g.max_blocks`; `commitThrough(id)` in `materializeBlock`; `add` in `markOneObject` and `snapshotYoungLarge`; `peek` in the V5 check (`resetBufferMetaForMark`) and IM6; `mergeInto` first thing in `finalizeMetaAfterMark`; `sum` in `handoffMarkCycle`; `take` in two `freeLargeBodyCell` branches when `marking_active`; `storageBase` in V7. | `OldGenSpace.cpp:232-266, 599, 2460, 2477, 2497, 2841, 2919, 3055, 5518, 5642, 5733` |
| F7 | Mark bits: `mark_.slot(id)` is a fixed per-id arena slot (HEAP_050), 1 bit per 8-byte slot (`MARK_ALIGNMENT` 8, `markBitLocation`); one bitmap byte covers 64 B of heap. `is_large` blocks use `blocks_.largeMark(id)` (one byte). | `OldGenSpace.hpp:~1273-1345`, `BlockTable.hpp` |
| F8 | 5a cycle driver: `runCycleSlice()` (paced slice at 1 ≤ k < T, closing drain at k = T) and `drainCycleMark()` (closing, pressure finish, join) both call `markWorkUnits`. Pacing reads `cycle_units_`: the doubling-on-overrun and the budget formula (5a-P§10.1 item 1). `handoffMarkCycle` asserts the stack is empty. | `OldGenSpace.cpp:~2845-2935` |
| F9 | The t0 snapshot runs serially on the mutator: `beginMarkCycle` (prepare), roots through `markHPointer`, `snapshotYoungLarge`, `forEachSurvivor` → `markChildren`. The greys land on the mark stack. | `ThreadLocalHeap.cpp` `startMarkCycle` |
| F10 | `incremental_mark = false` still reaches the legacy `ThreadLocalHeap::majorGC` from the trigger (it marks through the nursery with `nursery_visited_`). 5a E0 showed a T = 0 cycle reproduces every decision counter of that path. | `ThreadLocalHeap.cpp` `minorGC`; 5a-P§10.3 |
| F11 | `GCHelperPool` (phase 3): a process singleton with a mutex-guarded FIFO job queue and `gc_helper_threads` workers (default 1, range [1, 64]). Jobs are posted at pause end (HEAP_058). There is no way to start N jobs together, and a queued decommit or populate job runs first. `configure` is first-call-wins; `shutdownForTesting` exists; fork safety comes from `pthread_atfork` (prepare drains, child forgets its workers and restarts lazily). The header and its `.cpp` are std-only, which is what makes the TSan harness possible. | `GCHelperPool.hpp/.cpp` |
| F12 | TSan harness: `test/gc-helper-tsan` is a standalone CMake project built with g++ (clang 14 here has no TSan runtime). It compiles `GCHelperPool.cpp` and `PageWork.cpp` with a `harness.cpp`. | `test/gc-helper-tsan/` |
| F13 | `ECO_GC_THREAD` / `ECO_GC_HELPER_JITTER_US` are parsed by `applyGcThreadEnv` (one character; env wins over JSON). The jitter is a process-level determinism probe. | `HeapConfigJson.cpp:~407-436`, `Allocator.cpp:~245` |
| F14 | `OldGenSpace.cpp` is compiled with `-falign-loops=64` (the mark-loop alignment trap: +4.5 % mark with identical instructions when the loop sat off 64 B). | `runtime/src/codegen/CMakeLists.txt:~186-191` |
| F15 | Heap addresses are below 2^43 (`POINTER_BITS` = 40 on 8-byte units, `OldGenSpace.hpp` back-link encoding), so `addr >> 3` fits in 40 bits. | `OldGenSpace.hpp:~180` |
| F16 | The machine: 24 cores, no SMT, 16 MiB shared L3, 15 GB RAM (§3.1). The mutator is paused during a slice, so up to 23 other cores are idle. | report §3.1 |

---

## 3. Design

### 3.1 The mark entry (8 bytes)

The grey set holds `uint64_t` entries, `namespace Elm::markwork` in a new std-only header
`MarkWork.hpp`:

```
bit 63     = 0: object entry         = 1: chunk entry
bits 0..39 = address >> 3 (the object, or the array for a chunk)
bits 40..62: object entry = block id + 1 (0 = unknown: recompute with blockIdFor)
             chunk entry  = chunk index c (elements [c * CHUNK, min((c + 1) * CHUNK, n)))
```

```cpp
constexpr uint64_t kChunkBit = 1ull << 63;
constexpr uint32_t kBlockField = (1u << 23) - 1;          // id + 1 must be <= this
inline uint64_t objEntry(const void* p, uint32_t id_plus1);   // id_plus1 > kBlockField -> 0
inline uint64_t chunkEntry(const void* arr, uint32_t c);      // asserts c <= kBlockField
inline bool     isChunk(uint64_t e);
inline void*    entryAddr(uint64_t e);                        // (e & ((1ull<<40)-1)) << 3
inline uint32_t entryField(uint64_t e);                       // (e >> 40) & kBlockField
constexpr uint64_t kEmpty = 0;                               // address 0 is never an object
```

- Entry 0 is never a valid entry (null address), so `WorkStealingDeque` can use it as
  "empty".
- The deque needs its elements to be single 8-byte atomics (P§3.4). A 16-byte
  `MarkStackEntry` would need `cmpxchg16b`, and it doubles the stack's memory.
- Block ids up to 2^23 − 2 (4 TB of 512 KiB blocks) keep today's "skip the second
  `blockIdFor`" optimisation; larger ids fall back to recomputing it.

### 3.2 The mark policy and the worker context

```cpp
struct SerialMark   { static constexpr bool kParallel = false; };
struct ParallelMark { static constexpr bool kParallel = true;  };

struct MarkWorker {                         // OldGenSpace owns kMaxMarkers of these
    std::vector<uint64_t> stack;            // SerialMark grey set (worker 0 only)
    markwork::WorkStealingDeque deque;      // ParallelMark grey set
    LiveBytesAccumulator live;              // HEAP_051: one per marker
    uint64_t tickets = 0;                   // locally claimed, unconsumed (P§3.3)
    uint64_t units = 0;                     // consumed this slice
    MarkWorkerStats stats;                  // steals, failed steals, idle ns, cpu ns ...
#if ECO_HEAP_VALIDATE
    // nothing extra: IM10 uses a shared side bitmap
#endif
};
```

- `OldGenSpace` holds `std::array<MarkWorker, kMaxMarkers> markers_` (`kMaxMarkers` = 64,
  the `gc_helper_threads` bound).
- Only the first `mark_threads_` have their accumulator reserved. Each reserves
  `g.max_blocks` × 8 B of VA; commits follow `materializeBlock` for every active marker.
- `mark_stack` is deleted. Worker 0's `stack` replaces it on the serial path, and worker 0's
  `deque` on the parallel path. `bool mark_parallel_` is fixed at `beginMarkCycle`:
  `mark_threads_ > 1`.

The mark functions become templates on the policy, with the worker passed explicitly:

| today | 5b |
|---|---|
| `pushMarkRoot(obj)` | `template<class P> void greyObject(MarkWorker& w, void* obj)` |
| `markHPointer(ptr)` / `markUnboxable` | `template<class P> void greyHPointer(MarkWorker&, HPointer&)` |
| `markChildren(obj)` | `template<class P> void scanChildren(MarkWorker&, void* obj)` (+ chunking, P§3.6) |
| `markOneObject(obj, block)` | `template<class P> void scanEntry(MarkWorker&, uint64_t e)` |
| `markWorkUnits(budget)` | `template<class P> uint64_t runMarker(MarkWorker&, SliceControl&)` (P§3.3) |
| `testAndSetMarkBitInBlock` | `template<class P> bool testAndSetMark(BlockId, const void*)` |

- The non-template names stay as thin wrappers on `SerialMark` + worker 0, so
  `OldGenSpaceTestAccess`, the unit tests and the legacy STW path compile unchanged.
- Nursery handling (the `nursery_visited_` path) exists **only** in `SerialMark`. With
  `ParallelMark`, a nursery or YLOS target is a fatal error in every build (an
  `if (__builtin_expect(nursery_->contains(obj), 0)) abort()`: two compares; YLOS through
  IM3 in validate builds). It cannot happen by HEAP_005 + 5a's snapshot.

`testAndSetMark<ParallelMark>`:

```cpp
if (blocks_.info(id).is_large)
    return std::atomic_ref<uint8_t>(blocks_.largeMark(id)).exchange(1, std::memory_order_relaxed) != 0;
markBitLocation(id, obj, &byte, &mask);
if (byte >= mark_.len(id)) return false;
return (std::atomic_ref<uint8_t>(mark_.slot(id)[byte]).fetch_or(mask, std::memory_order_relaxed) & mask) != 0;
```

Why relaxed ordering is enough:
- the bit only arbitrates who scans the object;
- the object's contents were written before the pause (P1), and the gang's start barrier (a
  mutex release/acquire) publishes them;
- the scanner does not need to see anything the setter did.

`SerialMark` keeps today's plain RMW.

### 3.3 Exact tickets, the marker loop, and termination

**Why tickets.** 5a's pacing reads units done. In parallel, "how many objects did this slice
scan" would depend on the ring overshoot of each marker and on steal timing, and so the
doubling decision and every later slice would too. **A ticket is permission to consume one
entry.** A slice has `budget` tickets (∞ for a drain). An entry may be taken from a deque, own
or stolen, only with a ticket in hand. Taken entries are always scanned (rings drain). So:

> units consumed in a slice = min(budget, entries that exist to be consumed),

and that is a function of the heap and the budget alone. The set of entries consumed may
differ with N; their **count** does not. The final mark set at the handoff never depends on
N, because marking is monotone and complete.

**Shared slice state:**

```cpp
struct SliceControl {
    std::atomic<int64_t>  budget;        // global unclaimed tickets (INT64_MAX = drain)
    std::atomic<uint32_t> active;        // markers currently not idle
    std::atomic<bool>     done;
    uint32_t              n;             // markers in this slice
    unsigned              jitter_us;     // determinism probe (F13)
};
```

**Ticket claims are batched** (`kTicketBatch` = 256) to keep the shared counter off the hot
path:

```cpp
bool claimTicket(MarkWorker& w, SliceControl& c) {
    if (w.tickets > 0) { --w.tickets; return true; }
    int64_t b = c.budget.load(std::memory_order_relaxed);
    while (b > 0) {
        const int64_t take = std::min<int64_t>(b, kTicketBatch);
        if (c.budget.compare_exchange_weak(b, b - take, std::memory_order_relaxed)) {
            w.tickets = take - 1;
            return true;
        }
    }
    return false;
}
void unclaimTicket(MarkWorker& w) { ++w.tickets; }          // a take/steal came back empty
void returnTickets(MarkWorker& w, SliceControl& c) {        // before going idle, and at exit
    if (w.tickets) { c.budget.fetch_add(w.tickets, std::memory_order_relaxed); w.tickets = 0; }
}
```

**The marker loop** (`runMarker<ParallelMark>`, run by every member; `SerialMark` is the same
loop without stealing, idling or atomics):

```
active.fetch_add(1)                      (all members start active; the caller sets active = n)
loop:
  // (1) fill the ring
  while ring.count < DEPTH:
      if !claimTicket(w, c): break
      e = w.deque.take()
      if e == kEmpty: unclaimTicket(w); break
      prefetch(entryAddr(e)); ring.push(e)
  // (2) scan one
  if ring.count > 0:
      scanEntry<P>(w, ring.pop()); ++w.units; continue
  // (3) own deque empty (or no ticket): try to steal
  if claimTicket(w, c):
      e = stealFromOthers(w)             // random victim order, 2n attempts
      if e != kEmpty: ring.push(e); continue
      unclaimTicket(w)
  // (4) idle: termination protocol
  returnTickets(w, c)
  active.fetch_sub(1)
  idle:
      if done: exit
      if c.budget > 0 and anyDequeNonEmpty():  // own or others'
          active.fetch_add(1)
          if done: active.fetch_sub(1); exit
          goto loop
      if active == 0: done = true; exit
      backoff()                          // spin 2^10 pause, then sched_yield x 64, then nanosleep 50 us
exit: returnTickets(w, c)
```

**Why termination is correct:**
- A marker goes idle only after returning its tickets, with an empty ring and an empty own
  deque (or no ticket to take from it).
- Only an active marker pushes. So when `active` reads 0, no deque can gain entries.
- At that moment, either the budget is 0 (the slice is used up), or the budget is positive
  and every deque is empty. A marker idles with work only when it holds no ticket, and it
  holds no ticket only when the budget is 0. So the mark is complete.
- A marker that saw stale work reactivates, claims a ticket *before* stealing, and finds
  nothing: no ticket can be claimed when the budget is 0, and no entry exists when the budget
  is positive.
- So `done` is final, and after the join,
  `consumed = initial budget − remaining budget` is exact.

**Backoff** is what keeps an oversubscribed machine from starving the marker being waited for
(M§3 phase 5b): spin, then yield, then sleep. It is measured in E5.

**The deterministic "stack empty".** After the join, the mark is complete iff every active
marker's deque is empty (rings always drain). `markStackEmpty()` becomes that test.
`runCycleSlice`'s doubling decision reads `cycle_units_` (exact) and `markStackEmpty()`
(exact); both are independent of N.

### 3.4 The work-stealing deque (`WorkStealingDeque`)

Chase–Lev as given in Lê, Pop, Cohen, Zappa Nardelli, *Correct and Efficient Work-Stealing for
Weak Memory Models* (PPoPP 2013), figure 1. The memory orders are copied exactly; do not
"simplify" them for x86.

```cpp
class WorkStealingDeque {                 // std-only (MarkWork.hpp), owner = one thread at a time
public:
    void     push(uint64_t e);            // owner
    uint64_t take();                      // owner; kEmpty if empty
    uint64_t steal();                     // any thread; kEmpty if empty, kAbort if lost a race
    bool     emptyApprox() const;         // bottom <= top, relaxed loads (termination hint only)
    size_t   sizeApprox() const;
    void     retireOldArrays();           // only while no other thread can access (after a join)
    void     reset();                     // same; drops content (asserts empty) and old arrays
private:
    struct Array { int64_t log_size; std::atomic<uint64_t> buf[]; };   // power-of-two size
    alignas(64) std::atomic<int64_t> top_{0};
    alignas(64) std::atomic<int64_t> bottom_{0};
    std::atomic<Array*> array_;
    std::vector<Array*> retired_;         // owner-only; freed by retireOldArrays
};
```

- **`push`:**
  - `b = bottom.load(relaxed)`, `t = top.load(acquire)`, `a = array.load(relaxed)`;
  - if `b − t > size − 1`, grow: allocate 2× the size, copy `[t, b)` modulo, push the old
    array to `retired_`, then `array.store(new, release)`;
  - `a->buf[b & mask].store(e, relaxed)`; `atomic_thread_fence(release)`;
    `bottom.store(b + 1, relaxed)`.
- **`take`:**
  - `b = bottom.load(relaxed) − 1`, `a = array.load(relaxed)`, `bottom.store(b, relaxed)`,
    `atomic_thread_fence(seq_cst)`, `t = top.load(relaxed)`;
  - if `t <= b`: `e = a->buf[b & mask].load(relaxed)`. If `t == b`, CAS `top` t → t+1
    (seq_cst / relaxed); if that fails, `e = kEmpty`. Then `bottom.store(b + 1, relaxed)`;
  - else `e = kEmpty`, `bottom.store(b + 1, relaxed)`.
- **`steal`:**
  - `t = top.load(acquire)`, `atomic_thread_fence(seq_cst)`, `b = bottom.load(acquire)`;
  - if `t < b`: `a = array.load(acquire)`, `e = a->buf[t & mask].load(relaxed)`, CAS `top`
    t → t+1 (seq_cst / relaxed). If the CAS fails, return `kAbort`; otherwise return `e`;
  - else return `kEmpty`.
- **Memory.** The initial array holds 2^14 entries (128 KiB). Growth is unbounded. Old
  arrays are freed only by `retireOldArrays()`, which `runCycleSlice` / `drainCycleMark` call
  after the gang's join, when no thief can hold a pointer. This is the standard "no
  reclamation during the phase" answer; the arrays live at most one slice.
- **Ownership across slices.** Between slices the deques are quiescent. Slice k's member i
  may be a different OS thread from slice k−1's member i: the gang barrier (a mutex
  release/acquire) orders the two, so owner-only fields transfer safely.
- `kAbort` is treated by `stealFromOthers` as "try the next victim".

### 3.5 The gang (`GCMarkGang`)

The helper pool cannot start N jobs together, and it may have decommit jobs queued first
(F11). Marking needs **gang scheduling**: every member runs the same function at once, and the
caller joins them all. A new std-only class goes in `GCHelperPool.hpp/.cpp` (same TSan
harness, same atfork hooks):

```cpp
class GCMarkGang {
public:
    static GCMarkGang& instance();                 // leaky singleton
    // First call wins, as GCHelperPool::configure; members includes the caller.
    void configure(unsigned members, unsigned jitter_us);
    unsigned members() const;
    // Runs fn(ctx, i) for i in [0, n): i = 0 on the caller, 1..n-1 on gang
    // threads (started lazily). Returns when all n returned. n <= members().
    // Publication: the start and the join are mutex release/acquire pairs.
    void run(void (*fn)(void* ctx, unsigned member), void* ctx, unsigned n);
    struct Stats { std::atomic<uint64_t> runs, member_cpu_ns, wake_ns_total, wake_ns_max; };
    const Stats& stats() const;
    void shutdownForTesting();
private:
    std::mutex m_; std::condition_variable cv_start_, cv_done_;
    uint64_t generation_ = 0; unsigned running_n_ = 0, finished_ = 0;
    void (*fn_)(void*, unsigned) = nullptr; void* ctx_ = nullptr;
    std::vector<std::thread>* threads_ = new std::vector<std::thread>();
    // atfork: prepare asserts idle (runs happen only inside pauses) and takes m_;
    // child forgets threads, restarts lazily.
};
```

- **Member thread loop:** wait on `cv_start_` for a new `generation_` in which this member's
  index is below `running_n_`. Copy `fn_`/`ctx_`. Optionally sleep a random 0…`jitter_us`
  (the probe). Run `fn`, add the thread's CPU delta (`threadCpuNs`) to the stats, and under
  `m_` increment `finished_` and notify `cv_done_` when it reaches `running_n_ − 1`.
- **`run`:** under `m_`, set `fn_`, `ctx_`, `running_n_ = n`, `finished_ = 0`,
  `++generation_`, then notify all. Run `fn(ctx, 0)` on the caller. Then wait on `cv_done_`
  for `finished_ == n − 1`. With `n == 1`, it just calls `fn(ctx, 0)` (no locking).
- **Threads** are named `eco-mark-%u`. They are not pinned by default.
- **Wake latency.** It is counted in the stats: 224 slices per self-compile × a few tens of µs
  is negligible, and E2 verifies it.
- `pthread_atfork` registration is added to the existing handlers (M§4 TG3 note: every later
  phase's pool state goes into `atforkChild`).

### 3.6 Large-array chunking

`MARK_CHUNK_ELEMS` = 1,024 (8 KiB of slots; `AllocatorCommon.hpp`). In
`scanChildren<P>(w, obj)`:
- **`Tag_Array` with boxed elements and `length > MARK_CHUNK_ELEMS`:**
  - scan `[0, CHUNK)` inline;
  - for `c = 1 … ceil(length / CHUNK) − 1`, push `chunkEntry(obj, c)` onto `w`'s deque.
- **`Tag_ListBacking`, boxed (unboxed bits 0), live range `[hd, size)` longer than CHUNK:**
  the same, with chunk c covering `[hd + c·CHUNK, …)`.
- **`scanEntry` on a chunk entry** scans that element range with the same `markUnboxable`
  logic and attributes **no** live bytes: the array's bytes were attributed once, when its
  object entry was scanned.
- **Units:** every entry, object or chunk, costs one ticket. An array of n > CHUNK boxed
  elements therefore costs `ceil(n / CHUNK)` units instead of 1. This is deterministic and
  identical at every N. It makes the slice budget roughly proportional to work for huge
  arrays, which the 5a plan noted as a gap (5a-P§3.5).
- **Chunking applies to `SerialMark` too.** One definition of units keeps rule 2.
- YLOS arrays are scanned at t0 by the snapshot, serially, through `scanChildren<SerialMark>`
  on worker 0, so their chunks land on worker 0's grey set. Chunks are allowed in snapshot
  mode.
- **Immutability makes a stale chunk harmless.** Arrays are immutable after publication (P1).
  Builders are young, and young objects are never scanned by a slice (only by the t0
  snapshot, serially). So a chunk read later sees the same elements.

### 3.7 Per-marker live bytes (HEAP_051 for N markers)

| site | 5a | 5b |
|---|---|---|
| `reserveMetadata` | `mark_live_.reserve(max_blocks)` | reserve `markers_[i].live` for i < `mark_threads_` (V7 records every base) |
| `materializeBlock` | `commitThrough(id)` | loop over the reserved accumulators |
| scan (`markOneObject`) | `mark_live_.add` | `w.live.add` |
| `snapshotYoungLarge` | `mark_live_.add` | `markers_[0].live.add` |
| V5 (`resetBufferMetaForMark`) | `peek == 0` | every accumulator's `peek == 0` |
| `finalizeMetaAfterMark` | `mergeInto` | `mergeInto` for i = 0 … n−1 **in index order** (integer sums: exact regardless of which marker attributed what) |
| `handoffMarkCycle` | `sum` | Σ over markers |
| IM6 | `peek` | Σ `peek` |
| `freeLargeBodyCell` (`marking_active`) | `take` | `take` from each and sum |

`mark_threads_` is fixed at `initialize` from the config. `OldGenSpace::reset` with a new
config re-reserves.

### 3.8 Wiring into the 5a cycle

```cpp
uint64_t OldGenSpace::runMarkers(int64_t budget) {        // budget < 0: drain
    if (!mark_parallel_) {                                 // SerialMark on worker 0
        SliceControl c(budget); return runMarker<SerialMark>(markers_[0], c);
    }
    SliceControl c(budget, mark_threads_, jitter_us_);
    c.active.store(mark_threads_);
    GCMarkGang::instance().run(&OldGenSpace::markerEntry, &sliceArgs{this, &c}, mark_threads_);
    for (unsigned i = 0; i < mark_threads_; ++i) markers_[i].deque.retireOldArrays();
    const uint64_t consumed = initial - c.budget;          // exact (P§3.3); drain: sum of units
    // stats: per-marker units/steals/idle into alloc_stats_.pm (P§3.10)
    return consumed;
}
```

- `markWorkUnits(b)` → `runMarkers(b)`. `drainCycleMark()` → `runMarkers(-1)` (the closing
  slice, a pressure finish, a join).
- `incrementalMark` and the legacy `finishMarkAndSweep` loops call `runMarker<SerialMark>` on
  worker 0 with a budget of 1,000 (the legacy STW path is serial by design).
- `markStackEmpty()` = every active marker's deque (parallel) or worker 0's `stack` (serial)
  is empty. It replaces every `mark_stack.empty()`.
- **`beginMarkCycle`** sets `mark_parallel_ = mark_threads_ > 1` and resets every deque. The
  t0 snapshot pushes onto worker 0's deque (parallel) or stack (serial) as the owner thread.
  Nobody steals during t0. The first slice's thieves spread the work.
- **`incremental_mark = false` with `mark_threads_ > 1`:** `minorGC`'s trigger branch calls
  `startMarkCycle` with T = 0 (snapshot + parallel drain + handoff in one pause), not the
  serial `majorGC`. The legacy `majorGC` remains for `incremental_mark = false` with one
  thread (the bit-identical reference), and for joins and explicit majors (out of scope,
  P§0).
- **Profiling.** The two profiling `finishMarkAndSweep` overloads' `mark_stack_peak` becomes
  worker 0's stack size (serial only).

### 3.9 Configuration

| field | type | default | parse | `validate` |
|---|---|---|---|---|
| `gc_mark_threads` | `uint32_t` | `GC_MARK_THREADS = 1` (serial) until E2/E3 flip it to 0 | `parseU32` | ≤ 64 |
| `gc_mark_threads_cap` | `uint32_t` | `GC_MARK_THREADS_CAP = 8` (E2 sets it) | `parseU32` | in [1, 64] |

- **Environment:** `ECO_GC_MARK_THREADS` (decimal, 0 … 64) wins over JSON, parsed next to
  `applyGcThreadEnv` (the environment is a program input: TG3 rule).
- **Resolution** (`Allocator::initialize` → `resolveMarkThreads(cfg)`):
  - 0 means auto: `min(cap, available_cpus())`;
  - any other value is taken as given, capped at 64.
- **`available_cpus()`:**
  - `sched_getaffinity` + `CPU_COUNT` (Linux);
  - then, if `/sys/fs/cgroup/cpu.max` reads `"<quota> <period>"` with a numeric quota, take
    `min(that, ceil(quota / period))`;
  - macOS: `sysconf(_SC_NPROCESSORS_ONLN)`;
  - Windows: `GetActiveProcessorCount`;
  - never `hardware_concurrency`.
- **Result.** A resolved value of 1 means serial (no gang). The gang is configured once per
  process with the resolved member count (first call wins; tests use `shutdownForTesting`).
- **`ECO_GC_HELPER_JITTER_US`** also drives the gang's jitter (member start delay, and a
  0 … jitter µs sleep every 4,096 scanned entries).

### 3.10 Stats and measurement

New `ParMarkStats pm` in `GCStats` (old-gen `alloc_stats_`; `combine` sums, maxes the maxima;
carried through `ElmE2ETestBase`'s POD like `im`):
- `runs`, `members`;
- `units_total`, and the per-run units imbalance: `max member units / mean`, as a sum and a
  max;
- `steals`, `steal_aborts`, `steal_empty`;
- `idle_ns_total`, split into spin, yield and sleep;
- `member_cpu_ns` (collector CPU, M§2 from phase 3 on);
- `wake_ns_total` / `wake_ns_max`;
- `deque_grows`, `deque_peak_entries`;
- `chunks_pushed`.

The banner block is "Parallel Mark (threaded-gc-05b)". The cycle event-log row gains a
`members` column and `idle%`.

**Collector CPU vs wall.** Report the gang's CPU per self-compile next to the in-pause mark
time it saves. Parallel marking must not buy pause at an unbounded CPU cost: E2 tabulates the
CPU/pause ratio per N.

### 3.11 Validators (validate builds)

| # | Checks | How |
|---|---|---|
| IM10 | every entry is scanned exactly once per cycle | A validate-only side bitmap, one bit per 8 B of old gen (a second `MarkBitArena`-shaped arena), cleared at `beginMarkCycle`. `scanEntry` on an object entry does `fetch_or`; a bit already set aborts with the address ("scanned twice: the mark test-and-set is broken"). Chunk entries use a per-array chunk bitset in a validate-only `unordered_map<void*, std::vector<bool>>` under a mutex. |
| IM11 | parallel = serial | At every handoff with `mark_threads_ > 1`, in validate builds and only when the heap has fewer than 5 M old objects: snapshot the mark bitmaps of all t0 blocks, clear them, re-run the whole cycle's marking serially from a recorded copy of the t0 grey set (kept in validate builds), and compare bitmaps and per-block traced bytes. Any difference aborts. This is the strong form of rule 2 inside the tree. |
| IM3 | no young pointer in a parallel slice | already in 5a; also true in `ParallelMark` (release builds abort on a nursery pointer) |
| IM6 | uniform live bytes | Σ over accumulators (P§3.7) |
| TSan | deque, gang, termination and ticket exactness on a synthetic heap | the harness (P§4 Step 5) |

**Negative controls** (Step 7), each in a forked child, as in 5a:
- `test_skip_merge_worker1_`: `finalizeMetaAfterMark` skips accumulator 1. IM6 equality at
  the handoff must fire whenever marker 1 scanned anything (force it with a heap large enough
  that stealing happens: assert `pm.steals > 0` first).
- `test_plain_bit_set_in_parallel_`: `ParallelMark` uses the plain RMW. This is racy, so it is
  not guaranteed to fire; run it 50 times on a heap built to make markers collide (a wide
  fan-out object graph). Pass when IM10 fires at least once. Record the rate.
- `test_steal_without_ticket_`: `stealFromOthers` does not claim first. Rule 2's determinism
  check (P§4 Step 8, `testParMarkUnitsExactPerSlice`) must fail.

---

## 4. Steps

Every step ends with `cmake --build build --target check` green. Steps 1–8 also build the
validate tree's `test` target and run the phase's tests there.

**Before you start:** `benchmarks/lss-loop-snap.sh verify keep-TG5a`; snapshot `try-TG5b-pre`.

### Step 0 — facts and baseline

1. Re-verify F1–F16; fix the line numbers.
2. Same-session baseline with `eco-optTG5a`:
   - a triple in the stats build;
   - one phase-timer run with `ECO_GC_EVENT_LOG`;
   - record per slice: units, slice ns (event log), per-kind pause max/p99, MMU, in-pause mark
     total, wall, GC time.
3. Count arrays above 1,024 boxed slots on the self-compile, E2E and stress with a temporary
   counter in `markChildren` (removed after). This predicts D3's unit changes.

### Step 1 — D1: entries, workers, templates (pure refactor)

1. `MarkWork.hpp`: the entry encoding (P§3.1) with `static_assert`s, and unit tests of the
   round trip (address, id + 1, chunk index, overflow → 0).
2. `MarkWorker`, `markers_`, and the `SerialMark`/`ParallelMark` tags. Delete `mark_stack`;
   worker 0's `stack` holds `uint64_t` entries.
3. Convert `pushMarkRoot` / `markHPointer` / `markUnboxable` / `markChildren` /
   `markOneObject` / `testAndSetMarkBitInBlock` to the templates in P§3.2, keeping the old
   names as `SerialMark` wrappers. `markWorkUnits` keeps its exact 5a behaviour here,
   **including the ring overshoot**.
4. Replace every `mark_stack.empty()` / `size()` with `markStackEmpty()` / worker 0's size.
5. **Gate:** counters (mark units included), the major event log (non-timing) and `out.mlir`
   identical to `eco-optTG5a`. Check the alignment trap (F14) if mark time moves.

### Step 2 — D2: exact tickets in the serial marker

1. `SliceControl`, `claimTicket` / `unclaimTicket` / `returnTickets`, and the loop of P§3.3
   without stealing or idling, as `runMarker<SerialMark>`. `markWorkUnits(b)` →
   `runMarker<SerialMark>` with `budget = b`.
2. **Gate:** decision counters identical to `eco-optTG5a`; per-slice and per-cycle units
   differ by at most 15 per slice (the removed overshoot). Record the per-major mark units in
   P§10.

### Step 3 — D3: chunking

1. `MARK_CHUNK_ELEMS`, chunk entries, and `scanChildren` / `scanEntry` per P§3.6.
2. Tests:
   - `testMarkChunkedArrayAllChildren`: a 100,000-element array of fresh Ints, promoted, in a
     cycle with T = 4 and min slice units 1; every element is marked at HandoffDue; units for
     the array = `ceil(100000 / 1024)`;
   - `testMarkChunkedListBacking`: the same for a chunk-chain backing with `hd > 0`;
   - `testMarkChunkBudgetSplitsArray`: budget 10 units per slice; the array's chunks spread
     over several slices, and the handoff is still at k = T + 1.
3. **Gate:** decision counters identical to Step 2's binary; mark units differ only by Step
   0's predicted array count.

### Step 4 — D4: per-marker accumulators and the atomic policy (still one thread)

1. P§3.7 in full; `testAndSetMark<ParallelMark>` (P§3.2); `mark_threads_` plumbing (config
   parsed, gang not yet used).
2. A test-only switch runs `SerialMark`'s loop with `ParallelMark`'s bit operations: the
   counters must not change.
3. **Gate:** as Step 3.

### Step 5 — D5/D6: deque and gang, TSan first

1. `WorkStealingDeque` in `MarkWork.hpp`. `GCMarkGang` in `GCHelperPool.hpp/.cpp`, with its
   atfork hooks.
2. Unit tests (normal tree):
   - `testDequeLifoOwnerFifoThief`;
   - `testDequeGrowKeepsEntries`: push 1 M, take and steal all, and check the multiset;
   - `testGangRunsEveryMemberOnce`: n = 1 … 8, 1,000 runs each; every index exactly once per
     run, and `run` returns only after all;
   - `testGangForkChild`: fork after a run; in the child, a run with n = 4 works.
3. TSan harness (`test/gc-helper-tsan`): add `MarkWork.hpp` and a `mark_harness.cpp`:
   - **deque storm:** one owner doing random push/take, and 3–7 thieves stealing, over 10 M
     operations. Every pushed value is consumed exactly once (a checksum and a count), with
     forced growth from a 16-entry initial array;
   - **gang storm:** 100,000 runs with n = 2 … 8 and jitter 0/50 µs;
   - **synthetic marker:** a graph of 1 M nodes (random out-degree 0–8, 5 % with 2,000
     children, cycles allowed) with `std::atomic<uint8_t>` mark bits and the **real**
     `runMarker` loop instantiated on a synthetic policy. Budgets are random per slice. It
     checks:
     - (a) the marked set equals the reachable set;
     - (b) each slice's consumption equals `min(budget, remaining entries)` exactly;
     - (c) consumption per slice is identical at n = 1, 2, 4, 8 and with jitter;
     - (d) there are no TSan reports.

     To make this possible, `runMarker`'s loop body must be a template over a policy that
     supplies `scanEntry` and the bit operation. Put the loop itself in `MarkWork.hpp`
     (std-only) and have `OldGenSpace` instantiate it with its heap policy.
4. **Pass:** the harness exits 0 with no "WARNING: ThreadSanitizer". Run it twice more with
   `taskset -c 0,1` (oversubscribed).

### Step 6 — D7/D8: the parallel marker in the heap

1. `runMarker<ParallelMark>` (the shared loop, P§3.3), `stealFromOthers` (a per-member
   xorshift RNG seeded by member index, trying victims ≠ self), `markerEntry`, and
   `runMarkers` (P§3.8).
2. `gc_mark_threads`, `gc_mark_threads_cap`, `ECO_GC_MARK_THREADS`, `resolveMarkThreads`,
   `available_cpus()`; gang configure at `Allocator::initialize`; `mark_parallel_` at
   `beginMarkCycle`; the T = 0 routing for `incremental_mark = false` (P§3.8).
3. Tests (`test/allocator/ParallelMarkTest.cpp`), with `gc_mark_threads` set in the config.
   The gang is reconfigured per test through `shutdownForTesting` in the helper.
   - `testParMarkMatchesSerial`: a heap of about 200 k old objects in a random graph, built
     identically twice; a T = 4 cycle at 1 thread and at 4. At HandoffDue the mark bitmaps
     of every t0 block, the merged per-block traced bytes and `cycle_units_` after each slice
     are identical.
   - `testParMarkUnitsExactPerSlice`: budgets 1, 7, 1,000 and 10^9; consumed units equal
     `min(budget, remaining)` at 2, 3, 4 and 8 threads.
   - `testParMarkDeterministicAcrossThreadCounts`: 1, 2, 3, 8 and 4 + jitter 50 µs, over
     three consecutive cycles; every counter identical.
   - `testParMarkResumesAcrossSlices`: work left in several deques at the end of slice 1
     (tiny budget) is finished by later slices; `markStackEmpty()` only at the right slice.
   - `testParMarkStealingHappens`: a single wide root (one array of 50,000 old objects) with
     4 threads; `pm.steals > 0` and every marker's units > 0.
   - `testParMarkIncrementalOffUsesT0Cycle`: `incremental_mark = false`, 4 threads; the
     trigger path runs a T = 0 cycle (pause kind 5, `im.cycles` incremented) with the same
     live bytes as the 1-thread legacy major on the same heap.
   - `testParMarkJoinDrainParallel`: an explicit `majorGC()` during a cycle drains in
     parallel (`pm.runs` incremented), then runs the serial STW major.
   - `testParMarkAutoThreadCount`: `available_cpus()` under a `sched_setaffinity` mask of
     2 CPUs gives 2, with the cap applied; 0 → auto; the environment wins over JSON.
   - `testParMarkPressureAndDeferredFreesUnchanged`: 5a's deferred-free and pressure tests
     rerun at 4 threads.
4. Rerun the whole 5a test file (`IncrementalMarkTest`) with `gc_mark_threads = 4` (a second
   registration of each test through a config switch in its `incrConfig`).

### Step 7 — D9: validators, stats, negative controls

1. IM10 and IM11 (P§3.11); `ParMarkStats`, banner, event-log columns, `ElmE2ETestBase`
   plumbing.
2. The three negative controls (P§3.11).
3. The validate tree: unit, E2E and stress (default and pressure-incremental configs), each
   at `ECO_GC_MARK_THREADS=4` and at `=1`. Zero `[heap-validate]` lines.

### Step 8 — measurement and the default

E0–E6 (P§5). If the decision rules pick a thread cap and a T:
- set `GC_MARK_THREADS = 0` (auto), `GC_MARK_THREADS_CAP`, and possibly a new
  `INCREMENTAL_MARK_SLICES`;
- rerun every gate default-on, plus the bootstrap fixed point.

### Step 9 — docs, invariants, tracking

P§8; THEORY.md (the Mark item: N markers, tickets, deques, gang); the master plan's row and
§5 table; a loop entry `TG5b`; snapshot `keep-TG5b`, `bin/eco-opt-prev` = `eco-optTG5b`.

---

## 5. Measurement and experiments

All self-compile arms follow the 5a method:
- one phase-timer binary, arms selected by `ECO_HEAP_CONFIG` / `ECO_GC_MARK_THREADS`;
- config paths and env values of equal length across arms;
- runs strictly serial, with **no other CPU load**: marking threads compete with anything
  running;
- the artifact verified by md5, never by the exit code.

**E0 — reference (after Step 4).** `gc_mark_threads = 1` vs `eco-optTG5a` (stats build, a
pair). Rule 1.

**E1 — determinism (after Step 7).** One run each at `ECO_GC_MARK_THREADS` ∈ {1, 2, 4, 8, 0}
and 4 + `ECO_GC_HELPER_JITTER_US=50`. **Every counter, mark units included, and the major event
log's non-timing columns are identical** (rule 2). Any difference stops the phase.

**E2 — scaling (after E1).** T = 32, N ∈ {1, 2, 4, 6, 8, 12, 16}, one run each; a triple for
the finalists. Record per arm:
- max and p99 per pause kind;
- MMU at 50/100/200/500 ms and 1/2 s;
- in-pause mark total (slices + closing + drains);
- per-slice mark ns p50/p99/max;
- wall; GC time;
- `member_cpu_ns` (collector CPU); idle share; steals per slice; imbalance;
- wake latency max.

**Decision rule for the cap:** the smallest N whose median slice-mark max is within 10 % of the
best N's. Past the memory-parallelism knee, more markers only burn CPU. A CPU/pause ratio over
3× the N = 4 value disqualifies an arm.

**E3 — re-choose T (after E2).** With the chosen cap, T ∈ {8, 16, 32}, triples. The worst pause
must not exceed the minor-only max of the same run by more than 10 %. Choose the smallest T
that passes.

Smaller T means less allocate-black retention (5a: black bytes grow with T), so gate on old-gen
peak first (M§2 retention rule), then:
- the E2-style gf sweep (0.65/0.70/0.75) at the chosen T, as in 5a E2. The trigger is chaotic
  (5a-P§10.5): judge sweep medians, and record the per-point deltas;
- **keep T = 32 unless a smaller T is no worse on the sweep-median peak.**

**E4 — `incremental_mark = false` + N (after E2).** A plain parallel STW major (T = 0 cycles):
the worst pause vs 5a's T = 0 (4.83 s), on one run at the chosen cap. This documents §5.8's
estimate (7 s → 2–2.5 s mark at k = 4). Informational; it does not gate.

**E5 — oversubscription.** `taskset -c 0,1` with `ECO_GC_MARK_THREADS=8` (4× oversubscribed)
and `=2`. The 8-thread run must not be more than 20 % slower in wall and in slice max than the
2-thread run. This is the check that backoff works; a hang or collapse fails the phase.

**E6 — small heap and stress.** The 4 GB-cap pressure config at the chosen cap and T: E2E, and
stress 101/101 with ≥ 20 cycles.

**What to watch:**
- **Bitmap line contention.** One bitmap byte covers 64 B of heap, and one 64 B cache line of
  bitmap covers 4 KiB. Markers scanning neighbouring objects contend on `fetch_or` lines. The
  imbalance/idle stats and a flat scaling curve are the signal.
- **The t0 grey set sits on worker 0.** If the first slice shows high steal counts and idle,
  consider distributing the t0 greys round-robin into the member deques before the first
  slice (the owner push is legal while nobody steals). This is a follow-up, not in the plan's
  scope.
- **Wake latency × slice count.** 224 slices × the gang wake; E2 reports it.

---

## 6. Gates

| # | Gate | Pass |
|---|---|---|
| G1 | `build/test/test` | all pass at `ECO_GC_MARK_THREADS` ∈ {1, 4} |
| G2 | elm-tests | the reference set (13,565 / 12 at TG5a) |
| G3 | `--target full` | all pass, default configuration |
| G4 | stress under GC pressure (default and pressure-incremental configs) | 101/101 at 1 and 4 threads, cycles ≥ 20 |
| G5 | validate tree (IM1–IM11, P1 tripwire) | zero `[heap-validate]` lines on unit, E2E and stress at 1 and 4 threads; negative controls fire |
| G6 | stats-off `ecoc` | builds; parallel marking works without stats (stats code guarded) |
| G7 | E0 | rule 1 |
| G8 | E1 | rule 2, bit-identical across N and jitter |
| G9 | TSan harness | exit 0, no TSan warnings, including under `taskset -c 0,1` |
| G10 | E2–E6 | decision rules recorded in P§10 |
| G11 | bootstrap fixed point | default-on compiler reproduces itself |
| G12 | static | `grep -n "mark_stack\b" runtime/src/allocator` empty; `hardware_concurrency` not used in the allocator |

---

## 7. Traps

1. **Do not relax the Chase–Lev orders for x86.** The `seq_cst` fence in `take` and `steal` is
   what prevents the owner and a thief from both taking the last element; TSO does not provide
   it (store→load reordering). Copy the paper.
2. **Claim before you steal.** A marker that steals without a ticket can take an entry it may
   not consume: counts drift and rule 2 breaks. `test_steal_without_ticket_` pins it.
3. **Return tickets before going idle.** An idle marker holding tickets can end a slice early
   while work remains elsewhere: nondeterministic units.
4. **Free old deque arrays only after the join.** A thief can hold an old array pointer until
   its CAS.
5. **Accumulator merge order is fixed (0 … n−1).** Integer sums are order-independent, but
   keep the order so a future non-integer statistic stays reproducible.
6. **A parallel marker must never meet a nursery object.** `nursery_visited_` is not
   thread-safe, and only the serial legacy path uses it. The abort in `greyObject<ParallelMark>`
   is intentional, in every build.
7. **Validate-build reads of the YLOS index** (IM3, the HEAP_BUILDER_001 assert) are concurrent
   reads of an `unordered_map` with no writer during the pause: safe in 5b, **not in 5c**.
   Record it in the 5c contract.
8. **The gang and the helper pool are separate thread sets.** A decommit or populate job may
   run on a pool thread during a slice. That is allowed: it touches no HPointer (HEAP_059/060).
   Do not route marking through the FIFO pool.
9. **Counters are a program input** (TG3): `ECO_GC_MARK_THREADS=1` and an unset variable are
   different environments. Compare arms with values of equal length (`1` vs `4`, never unset
   vs set).
10. **The alignment trap (F14)** now covers two instantiations of the mark loop. If either
    arm's mark time moves with identical instructions, check the loop address first.
11. **Oversubscription.** Pure spinning on a loaded machine can starve the one marker that has
    work. The backoff ladder is mandatory, and E5 is its test.
12. **Fork.** A forked child (E2E runner, stress) must not inherit a gang mid-run. Runs only
    happen inside pauses and fork only happens outside them; `atforkPrepare` asserts it.

---

## 8. Invariants (land in Step 9)

- **HEAP_064 ParallelMark (new):** "WITH gc_mark_threads > 1 THE OLD-GEN MARK WORK OF AN
  INCREMENTAL CYCLE (HEAP_063: SLICES, CLOSING DRAIN, PRESSURE FINISH, JOIN DRAIN) RUNS ON N
  MARKERS (plans/threaded-gc-05b-parallel-marking.md): the paused mutator as marker 0 and N−1
  GCMarkGang threads, started and joined inside the pause. Grey entries are 8-byte
  (markwork::objEntry / chunkEntry) in per-marker Chase–Lev deques; mark bits and large-mark
  bytes are set with atomic fetch_or / exchange; each marker attributes live bytes only to its
  own LiveBytesAccumulator, merged in index order at finalizeMetaAfterMark (HEAP_051). Work is
  accounted in exact tickets: an entry is taken, from an own or a stolen deque, only with a
  ticket in hand, rings always drain, and idle markers hold no tickets, so the units consumed
  by a slice are min(budget, entries available) independent of N and scheduling
  (GC_DET_001). Termination: all markers idle. Boxed Tag_Array / Tag_ListBacking ranges over
  MARK_CHUNK_ELEMS are scanned as chunk entries. The legacy STW majorGC (nursery traversal via
  nursery_visited_) stays serial; a parallel marker aborts on a nursery pointer. Validators
  IM10 (scanned once) and IM11 (parallel = serial)."
- **HEAP_050:** "set by atomic fetch_or when marking is parallel (HEAP_064)."
- **HEAP_051:** "one LiveBytesAccumulator per marker; merged in index order."
- **HEAP_007:** "… and GCMarkGang members may, inside the owner's GC pause and joined before
  it ends, read old-gen objects and metadata, set mark bits, and write their own mark state
  (HEAP_064)."
- **HEAP_058:** "GCMarkGang runs are not posted jobs: they start and join inside a pause."
- **HEAP_063:** "slice work may run on N markers (HEAP_064); units are exact tickets."
- **GC_DET_001:** "the number of markers and their scheduling never affect a decision: every
  counter is identical at every gc_mark_threads."

---

## 9. Forward notes for 5c

- The marker loop, tickets, deques, accumulators and chunking carry over unchanged. 5c changes
  *when* markers run (between pauses, on gang threads, at low priority), not how they mark.
- **5c must replace:**
  - the relaxed `fetch_or` race-freedom argument "the mutator is stopped": allocate-black now
    writes bits concurrently (5a-P§9: an allocation log or `fetch_or` on the mutator side);
  - the IM3/HEAP_BUILDER_001 validate reads of the YLOS index (trap 7);
  - the use of `BlockInfo` fields of blocks created mid-cycle (never read by a marker; keep it
    so).
- The handoff at t0 + T + 1 is where 5c's mutator waits or assists. The ticket budget of the
  closing slice is the assist.

## 10. As-built deviations

Implemented 2026-09-26. Every step landed; defaults flipped to auto markers (cap 16), T = 32.

### 10.1 Design deviations

1. **Private stacks + publish-half (not in the plan; decisive).** The first build pushed and
   popped every entry through the Chase–Lev deque, which issues a `seq_cst` fence on every
   owner `take`, and marked with an unconditional `fetch_or`. Measured (E2 v1): the in-pause
   slice mark time was 9.87 s at N = 1, **10.0 s at N = 2** (no gain, imbalance 1.07: the
   per-object overhead ate the parallelism), 6.5 s at N = 4 and 4.2 s at N = 8.

   As built, each marker keeps a **private** `std::vector` stack: owner-only, no atomics, no
   fence. `publishHalf` moves its oldest half to the stealable deque whenever the deque is
   empty, checked every 32 pushes and every 64 pops. Thieves steal only from deques. Each
   marker publishes its private size in a relaxed atomic (`priv`), so `anyWork()` (the
   termination check) sees private work. A marker idles only with both its stack and its deque
   empty, or with no ticket.

   The atomic bit set also tests first (a relaxed load; `fetch_or` only when clear).

   Result (E2 v2): 9.76 → 5.85 / 3.26 / 1.97 / 1.30 s at N = 2 / 4 / 8 / 16.
2. **No chunking in the t0 snapshot (P§3.6 was wrong).** The plan allowed chunk entries while
   the snapshot scanned YLOS arrays. A chunk entry of a young array is scanned later by a
   slice, which then reads young elements: the parallel marker's nursery abort fired on
   `testIncrDeferredYlosFree` at 4 markers. The serial path had the same hole (IM3 would
   catch it in validate). `scanChildren` now scans young objects completely when
   `snapshot_mode_` is set.
3. **Cycle units are counted in `runMarkers` itself** (not by the callers), so every path,
   including direct test calls, feeds pacing and IM12.
4. **IM11 is the closure check, not a serial replay.** It checks that the set of scanned object
   entries equals the old-gen closure of the recorded t0 grey set, computed independently with
   `visitHeapChildren` (Tag_Process by hand). This is exact in both directions: completeness
   and no extras. **IM12** was added: entries scanned (IM10's set) = tickets consumed
   (`cycle_units_`).
5. **The runtime-flag grey target.** `pushGrey` chooses a stack or a deque by `mark_parallel_`
   (fixed at `beginMarkCycle`), not by the policy template: the t0 snapshot runs `SerialMark`
   bit operations while feeding the parallel markers' grey sets.
6. **Steps 1–4 landed together.** The intermediate "counters incl. mark units identical" gate
   of Step 1 was skipped. E0 below compares the finished serial path with `eco-optTG5a`.
7. **The skipped-merge negative control is caught by V5** (unmerged accumulator bytes at the
   next mark start), not IM6: the merge happens inside the tail, after IM6's handoff check.
   The plain-bit control fires IM10, and the steal-without-ticket control fires IM12, each
   within its attempt bound.
8. **The gang reconfigures itself on demand** in `runMarkers`: `shutdownForTesting` +
   `configure` when the member count or jitter differs. There is no configure call at
   `Allocator::initialize`.
9. **The TSan harness entries** encode node indices, not heap addresses: a malloc'd graph
   lies above 2^43. The loop treats entries as opaque, so it runs unchanged.
10. **Termination race in the first build (found by a determinism test, fixed).**
    - *Symptom:* `testParMarkUnitsExactPerSlice` and the "8 == 1 markers" precondition of the
      ticket control failed intermittently, but only in the full suite, while E2E children
      loaded every core. A run consumed 0 units with its budget and work left: marker 0
      still held 718 private entries, and 218 tickets were back in the pool.
    - *Cause:* the decider read `active == 0` and then the budget, in two separate loads.
      Between them, a marker that had legitimately seen work reactivated and claimed the
      whole budget as a local batch. The decider saw budget 0 and set `done`.
    - *Fix:* the active count, a reactivation epoch and the done flag share one 64-bit
      word. The decider commits `done` with a CAS from the exact word in which it saw
      `active == 0`, and reactivation is a CAS that bumps the epoch and fails once `done`
      is set. With that, 6 loaded full-suite runs gave 0 early terminations (1–177 per run
      before).
    - *Why the TSan harness missed it:* its synthetic heap had no private stacks, and its
      slices were too few to hit the narrow window. It now mirrors the private-stack
      environment and adds a termination stress (a 60,000-node chain, 1–3-ticket slices,
      n = 8 and 16). Built against the old termination code, the stress fails in 3 of 3
      runs under `taskset -c 0,1`; it passes with the fix.
    - *The experiments below* (E1–E5) ran on binaries with the race. It never fired there:
      units were identical at every N. The determinism and key scaling arms were rerun on
      the fixed build (P§10.9).

### 10.2 E0 — the serial reference vs `eco-optTG5a` (stats build, same env, registry fresh)

Identical in both:
- minors 1924, majors 7;
- allocated 254,179,007; promoted 675,771,383;
- old-gen peak 8,935.7 MB;
- total cycle units 269,809,852;
- every per-major event-log column: before, after, garbage, recovered, minors, promoted,
  **mark units**.

Only the closing units differ: 2,739,098 vs 2,739,143, from the removed ring overshoot. The
self-compile has no array over 1,024 boxed slots, so chunking changed no unit. (Two earlier
control runs each did a package-registry POST, +157 allocated, and were discarded.)

### 10.3 E1 — determinism (phase-timer build, T = 32)

**Every counter is identical** at `ECO_GC_MARK_THREADS` = 01, 02, 04, 06, 08, 12, 16, 00
(auto = 8 then), and at 04 with `ECO_GC_HELPER_JITTER_US=50`. That covers:
- allocated, promoted and majors;
- cycle units 269,809,852 and closing units 2,739,143;
- the major event log, mark units included.

`out.mlir` is identical in every run (md5 933c3ff0d288).

### 10.4 E2 — scaling (v2: private stacks), T = 32, one run each

| N | wall (s) | slice mark total / max (ms) | worst pause (ms) | slice p99 (ms) | minor max (ms) | collector CPU (s) | steals | imbalance | MMU 500 ms / 1 s |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 169.7 | 9,765 / 223 | 315 | 298 | 187 | — | — | — | 7.9 / 11.2 % |
| 2 | 166.4 | 5,854 / 124 | 229 | 217 | 187 | 5.8 | 5.6 k | 1.08 | 9.5 / 12.7 % |
| 4 | 163.6 | 3,257 / 79 | 186 | 171 | 186 | 9.7 | 24.5 k | 1.20 | 15.7 / 16.5 % |
| 8 | 164.0 | 1,969 / 43 | 189 | 152 | 189 | 13.5 | 59.0 k | 1.36 | 17.0 / 21.0 % |
| 16 | 163.9 | 1,300 / 29 | 189 | 141 | 189 | 18.8 | 126.7 k | 1.57 | 17.0 / 21.6 % |

- **Decision rule:** the smallest N whose slice-mark max is within 10 % of the best N's (29 ms)
  is **16**. Its CPU per second of pause saved is 2.2, under 3× the N = 4 value (1.5).
- **From N = 4 on, the worst pause is the minor-GC floor**; phase 6 lowers it.
- **Wall −6 s** (169.7 → 163.9 s).
- v1 (deque-only) reference numbers: 10.0 / 6.5 / 4.2 s slice total at N = 2 / 4 / 8.

### 10.5 E3 — re-choosing T at 16 markers

| T | worst pause (ms) | minor-only max (ms) | old-gen peak (MB) | max RSS (GB) | wall (s) |
|---|---|---|---|---|---|
| 8 | 239 | 160 | 10,043 | 11.00 | 161.2 |
| 16 | 184 | 162 | 10,024 | 10.98 | 162.4 |
| **32** | **189** | **189** | **8,936** | **9.85** | **163.9** |

T = 8 and T = 16 exceed the minor-only max by more than 10 %, and raise the peak by 12 %.
**T stays 32.** The retention sweep was not needed: no smaller T passed the pause gate.

### 10.6 E4 — `incremental_mark = false` with 16 markers (parallel STW, T = 0 cycles)

Worst pause **735 ms**, against 4,643 ms for the serial legacy STW major on the same session.
The report's §5.8 estimate was a 7 s → 2–2.5 s mark at k = 4. Wall 163.4 s vs 172.9 s.

### 10.7 E5 — oversubscription (`taskset -c 0,1`, T = 32)

| N | wall (s) | slice total / max (ms) | worst pause (ms) |
|---|---|---|---|
| 2 | 165.9 | 5,855 / 122 | 226 |
| 8 | 167.4 | 6,287 / 128 | 235 |

8 markers on 2 CPUs are +0.9 % in wall and +4–7 % in slice time: well within 20 %. The backoff
ladder works (idle sleeps 167 at N = 8).

### 10.8 E6 — small heap (4 GB cap, pressure config, auto markers, T = 32)

Stress 101/101 (21 cycles, 0 pressure finishes, 0 joins); E2E 940/940 (4 cycles, 0 pressure
finishes).

### 10.9 Re-verification on the fixed build (P§10.1 item 10)

Phase-timer binary `eco-optTG5bPT3`, T = 32:

| N | slice mark total / max (ms) | worst pause (ms) | slice p99 (ms) | wall (s) | collector CPU (s) |
|---|---|---|---|---|---|
| 1 | 9,925 / 229 | 326 | 303 | 174.9 | — |
| 2 | 5,816 / 123 | 228 | 217 | 168.2 | 5.8 |
| 4 | 3,282 / 80 | 189 | 174 | 166.6 | 9.8 |
| 8 | 2,039 / 47 | 190 | 152 | 164.3 | 14.0 |
| 16 | 1,335 / 30 | 189 | 141 | 165.7 | 19.4 |
| auto (= 16) | 1,346 / 29 | 189 | 139 | 164.2 | 19.5 |
| 4 + jitter 50 µs | 4,846 / 106 | 201 | 200 | 167.6 | 10.3 |

**Every counter is identical** across all seven arms: allocated 254,179,007, promoted
675,771,383, units 269,809,852, closing 2,739,143, and old-gen peak 8,935.7 MB. The major event
log's non-timing columns hash identically at N = 1, 16 and 4 + jitter. (The first N = 1 run did
a registry POST and was rerun.)

### 10.10 Gates (default-on: auto markers, cap 16, T = 32)

| gate | result |
|---|---|
| G1 | `build/test/test` 1850/1850 (default config; also 1850/1850 at `ECO_GC_MARK_THREADS` 1 and 4 before the flip) |
| G2 | elm-tests 13,565 passed / 12 failed: the reference set, unchanged |
| G3 | `full` 1850/1850 |
| G4 | stress 101/101 on the default pressure config (21 cycles × 32 slices, 165 parallel runs on 16 markers) and on `heap-config-gc-pressure-incremental.json` (22 cycles × 4 slices) |
| G5 | validate unit + E2E 1851/1851, zero `[heap-validate]` lines; validate stress 101/101 on both configs, zero lines; phase tests 64/64 at 1 and 4 markers, including 5a's 25 at 4; negative controls fire (V5, IM10, IM12) |
| G6 | stats-off `ecoc` builds |
| G7 | E0 (P§10.2) |
| G8 | E1 (P§10.3) and the re-verification (P§10.9): bit-identical across N and jitter |
| G9 | TSan harness (deque storm, gang storm, synthetic marker with private stacks, termination stress): exit 0, no report, normal and `taskset -c 0,1`; the phase-3 harness still passes |
| G10 | E2–E6 as recorded |
| G11 | fixed point: `eco-optTG5b` (default-on) builds itself to `out.mlir` md5 933c3ff0d288, and that output lowered to `eco-optTG5bB` reproduces it byte-for-byte |
| G12 | `grep -n "mark_stack\b" runtime/src/allocator` shows only the profile field name `mark_stack_peak`; `hardware_concurrency` is not used in the allocator |

## 11. Done means

- `gc_mark_threads` exists; at 1 it reproduces `eco-optTG5a`'s decision counters; every N
  reproduces N = 1 bit for bit (E1).
- The TSan harness is clean, oversubscribed runs included.
- IM10/IM11 are green on unit, E2E and stress, and the three negative controls fire.
- The chosen cap (and T) is recorded with E2/E3 tables. The worst self-compile pause and the
  in-pause mark time are recorded against TG5a's 336 ms / 9.9 s.
- HEAP_064 and the amendments are in `invariants.csv`; THEORY.md, the master plan row, the
  loop entry and `keep-TG5b` are done.
