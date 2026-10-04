# Parallel and Concurrent Garbage Collection for Eco — Design-Space Investigation

**Status:** investigation report, 2026-09-24. Not an implementation plan. Nothing in the runtime was
changed to produce it.

**Question:** Eco's collector runs entirely on the mutator thread (THEORY.md §Execution Model).
How much GC work can move to other threads, to improve throughput and pause times? Four headline
ideas were examined: (1) incremental marking, (2) concurrent marking, (3) concurrent sweeping and
(4) concurrent copying in the nursery. The study also looks at the space around them and at what
Eco's invariants make cheap or impossible.

**Method:** five parallel investigations (marking, sweeping, parallel nursery copying, concurrent
nursery copying, runtime interface and prior art). Each read the code, `invariants.csv`, THEORY.md
and the GC Handbook summaries in `design_docs/gc_handbook/`. Their load-bearing claims were then
cross-checked against the code. Where two investigations disagreed, this report says which one was
right and why (§2.4, §7.4.3).

**Evidence tags** used throughout:
- **[M]** measured by the team (source named);
- **[D]** derived arithmetically from measurements;
- **[E]** estimate or reasoning with no measurement behind it;
- **[L]** literature from memory, not in the local handbook summaries (check before citing).

Handbook references are `HB <chapter>.<section>`, e.g. `HB 16.3` is
`gc_handbook/16-mostly-concurrent-mark-sweep.md` §16.3.

---

## 0. Executive summary

1. **Immutability collapses almost the whole barrier problem.** One lemma (§2.1) implies all of
   the following:
   - Old-gen marking can run concurrently with **no mutator write barrier and no remark pause**.
   - Nursery survivors can be copied concurrently with **no read barrier, no write barrier and no
     mutation log**. A stale from-space copy and its replica are interchangeable, because contents
     never change and Elm has no pointer identity.

   The lemma needs two things: a one-shot snapshot of the small set of *mutable* locations (roots,
   plus off-heap stores such as MVar), and a guarantee that the heap outside them is
   not written after publication.
2. **But "immutable" has to mean two different things, and the second one is not true today.**
   - *Contents immutability* (fields never change) is what the lemma needs. It holds for compiled
     code (HEAP_031).
   - *Header immutability* (the header word never changes while the mutator may read it) is what
     concurrent copying additionally needs. **The existing HEAP_030 forward-check is a
     stop-the-world-only barrier.** It checks the tag once, and code then re-reads other header
     bits. For example, `String.length` loads `header.size` separately
     (`runtime/src/codegen/EcoBackend.cpp:2299-2303`), and a `Tag_Forward` header overwrites
     `size`.
   - Rule: **a concurrent collector must never install a forwarding pointer in a header the
     mutator can read.** Forwarding goes in a side table or a GC-private word (§2.4).
3. **Where the time is.** On the self-compile (~180 s wall), GC is ~67 s [M]:

   | component | time | notes |
   |---|---|---|
   | minor GC | **~59 s**, 1,924 × ~31 ms [M] | ~75–80 % of it is *promotion* into the old gen [D, ±30 %] |
   | major mark | ~7 s [M] | |
   | sweep | small eager part [M] + **1.5–3 s hidden inside minor GC** [D/E] | no counter measures the hidden part |

   Two further costs are not counted as GC time at all: the stack walk runs before the minor-GC
   timer starts, and the large-body sweep runs after it stops (§1). **Anything that does not touch
   the minor GC can win at most ~8 s. Promotion is the prize.**
4. **For a single-mutator batch compiler, *parallel* stop-the-world collection buys most of the
   throughput at a fraction of the risk of *concurrent* collection.**
   - With 4 helper threads, parallel minor GC is estimated at **−30 to −38 s** of wall [E] and
     parallel mark at **−4.5 to −5 s** [E].
   - The mutator is stopped throughout, so none of the heap-metadata races of §3.5 arise.
   - The precondition is a **thread-safe promotion path into the old gen**: per-thread promotion
     buffers claimed from *already-swept* cells, never virgin pages (the W6 lesson). Without them,
     parallel minor GC is capped at ~1.3× [E].
5. **The best concurrent design for the nursery is "concurrent tenuring" (§7.4, design C).** The
   mutator keeps the first survivor copy (stop-the-world, as today). A collector thread promotes
   the previous survivor region into the old gen while the mutator runs.
   - Retention is statically bounded (three small survivor regions), it needs no barrier, and its
     fallback is today's code.
   - Estimate [E]: **−20 to −28 s** net. It composes with parallel STW.
   - **Correction to the investigation that proposed it:** it *does* need a kernel audit. Today's
     minor GC deliberately tolerates kernel writes into once-survived objects (the Cheney ↔
     promoted-queue re-drain loop, `NurserySpace.cpp:549-566`), and a concurrent promoter would
     silently miss such writes.
6. **Concurrent marking is sound and fairly simple in theory, but hard in engineering.**
   - Snapshot at a minor-GC end, allocate black, and no barrier is needed (§5).
   - The work is making ~10 old-gen metadata structures safe against a second thread (`blocks_`
     reallocation, the mark-bit arena resize, non-atomic byte mark bits) and deferring
     `freeLargeBodyCell`, which today frees snapshot-reachable memory mid-cycle.
   - Benefit is **−5.5 to −6.5 s** [E] and major pauses of ~50 ms.
7. **Concurrent sweeping is the weakest of the four.** Most sweep work already hides inside minor
   GC as a 4 KiB slice per promotion. The better move is **not a sweeper thread but making sweep
   nearly free**: allocate directly from the mark bitmap (Go's `allocBits = gcmarkBits`, HB 7.4
   bitmapped fits). This deletes the ~14 GB-per-run header walk, doubles as a promotion buffer and
   is single-threaded. Estimate: −1 to −4 s [E].
8. **Incremental marking on the mutator thread cannot improve throughput.** `MARK_WORK_RATIO` is
   inert because the paced branch was dead code and has been deleted; major GC always marks to
   completion. Its only value is as a deterministic, race-free test bed for the concurrent-mark
   invariants.
9. **Handshakes can be entirely mutator-initiated.** The collector starts and finishes work at the
   mutator's own minor-GC slow paths, every ~60 ms of mutator time. That needs no codegen change,
   no loop polls and no signals. An asynchronous "doorbell" via the `bump.end` clamp is possible
   but blocked by **a latent bug**: `ensureHeadroom` computes `size_t(end - ptr)`
   (`NurserySpace.cpp:254-256`), which underflows if `end < ptr` and lets hoisted unchecked bumps
   run past the nursery.
10. **One strategic fork needs a decision early.** The deferred RC tier
    (`plans/opt-tier3-rc-runtime.md`: RC-1 in-place reuse of `count==1` arrays and RB-tree nodes)
    writes into published objects. That breaks the lemma behind every design in this report,
    unless reuse is confined to objects that have **never survived a GC** (§12.1).

### Ranked candidates (throughput on the self-compile)

| # | Direction | Off the mutator [E] | Risk | Prerequisites |
|---|---|---|---|---|
| 1 | Parallel STW minor GC, 4 threads (§7.2) | **−30 to −38 s** | medium | promotion buffers over swept cells; CAS forwarding; deterministic trigger |
| 2 | Concurrent tenuring, design C (§7.4) | **−20 to −28 s** | medium-high | as #1, plus survivor-region ring, off-header forwarding, kernel write audit |
| 3 | Pipelined nursery, design B (§7.4) | −30 to −45 s | high | all kernels "write only fresh objects" (P0); retention horizon; +256–512 MB |
| 4 | Concurrent old-gen mark (§5) | −5.5 to −6.5 s | medium-high | metadata hardening; `freeLargeBodyCell` deferral; allocation log |
| 5 | Parallel STW mark, 4 threads (§5.8) | −4.5 to −5 s | low | atomic mark bits, work stealing |
| 6 | Bitmap allocation / "free sweep" (§6.3) | −1 to −4 s | low-medium | HEAP_021/024 rewording; W6 ladder placement |
| 7 | Concurrent sweep, block hand-over (§6.2) | −0.5 to −2.5 s | medium | most of #4's metadata work |
| 8 | Background decommit / prefault / zeroing (§8) | ≈ 0 | low | good "hello world" for the thread plumbing |

The rows overlap: #1 and #2 split the same 59 s, and #4 and #5 split the same 7 s. They are not
additive.

---

## 1. Baseline: where the GC time actually goes

Reference: the W13c tree (180.08 s wall), from `benchmarks/gc-opt-loop.md` and the GC memory notes.

| Component | Time | Evidence | Notes |
|---|---|---|---|
| Wall | 180.08 s | [M] W13c | |
| GC total (banner) | ~67 s | [M] W1/W1b | |
| Minor GC (banner) | ~59 s over 1,924 cycles, ≈30.8 ms each | [M] | Promotion allocation is included. |
| Major GC (banner) | ~8 s over ~6 cycles | [M] | Mark ≈ 6.8–7.1 s; roots ≈ 0.25 s in total; eager sweep ≈ 0.5 s |
| Objects copied per minor | ≈387 K to to-space + ≈351 K promoted | [D] from 744 M / 676 M per run | ≈41.7 ns per copied object; the same latency-bound regime as mark (39–41 ns per object) |
| Cost of a to-space copy | ≈13–16 ns | [D] differential of the `promotion_age` 2→1 sweep cells, ±30 % | |
| Cost of a promotion | ≈70–110 ns | [D] remainder | The aged object is cold (a DRAM miss). The free-list pop is a second miss. Each promotion also carries a 4 KiB lazy-sweep slice and a rescan from `promoted_buf_`. |
| Promotion share of the minor pause | **≈75–80 %** | [D] | The single most important number in this report |
| Lazy sweep hidden in minor GC | 1.5–3 s | [D/E] | Sweeps ~14 GB of headers per run (Σ before−recovered, 10-major baseline log). `lazySweep` was 1.1 % of samples in the Sep-20 profile. |
| Worst minor pause | 986 ms | [M] W7 leg A | Caused by the post-major sweep burst: 350 K promotions × 4 KiB ≈ 1.4 GB swept per minor |
| Stack walk (libunwind + stackmap lookup) | **not measured** | — | Runs **before** the minor timer starts (`ThreadLocalHeap.cpp:530`, timer at `NurserySpace.cpp:439`), so it is billed as mutator time |
| CellStore root scan (cells + trail; CellStore removed 2026-10-04, plans/remove-cellstore.md) | **not measured** | — | Two `std::function` hops per slot. Grows with the union-find store. |
| Large-body sweep (`sweepNurseryLargeBodies`) | not measured | — | Runs **after** the timer stops (`NurserySpace.cpp:931`) |
| Mark-bitmap clear at `startMark` | ≈20–30 ms per major | [E] | ~140 MB `std::fill` at a 9 GB old gen |

**Consequences for any offload design:**
- Minor GC is ~88 % of GC time, and **promotion** dominates it. A design that leaves the old-gen
  allocator single-threaded and on the mutator leaves most of the cost where it is.
- The ~8 s of major GC bounds everything that only touches marking and sweeping.
- The pause that a concurrent nursery design cannot remove (stack walk + root scan) is exactly the
  part nobody has measured. **Measure it before choosing between designs B and C (§7).**

---

## 2. The immutability dividend, and its fine print

### 2.1 The snapshot-closure lemma

Take a handshake H: the mutator is at a statepoint, for example inside a minor-GC slow path.

- **R_H** is the contents at H of every mutable location:
  - stack slots and shadow-stack ranges;
  - RootSet roots;
  - CAF/JIT slots;
  - every external root scanner, MVar
    slots, scheduler queues, the list scratch stack and the literal-intern slots;
  - every nursery object that exists at H.
- **S_H** = Reach(R_H).
- **N_H** = objects allocated after H.

**Premise P0:** no heap object that exists at H is written after H.

**Lemma:** under P0, at every instant after H, every reference held anywhere points into
S_H ∪ N_H.

*Proof sketch* (induction over mutator steps):
- The mutator obtains a pointer only by allocating it (N_H), by reading a root, or by reading a
  field of an object it holds.
- By P0, fields of pre-H objects are as they were at H, so their targets are in S_H by closure.
- Fields of post-H objects hold values the mutator held when it built them.
- Roots written after H receive held values.
- Minor GC relocates objects but preserves identity.
- Other threads (timer, wait and HTTP services) exchange only POD tokens and never hold HPointers
  (verified: `runtime/src/platform/*Service.cpp`). ∎

What the lemma gives each technique:

| Technique | What it normally needs (handbook) | What Eco needs, given the lemma |
|---|---|---|
| Concurrent mark (SATB) | Yuasa deletion barrier on every pointer store, plus a remark to drain buffers (HB 15.3, 16.3, 16.5) | **No heap barrier; no remark.** An atomic snapshot of the *mutable* locations at t0, plus allocate-black. Overwriting a root or an off-heap store after t0 cannot lose an object: its old value was captured at t0. |
| Concurrent copying | A read barrier (Baker/Brooks, HB 17.2–17.3) or write mirroring (Sapphire, HB 17.6), plus pointer-equality handling (HB 17.5) | **No mutator barrier.** A stale pointer is *valid* until its memory is reused (contents immutable), and replicas are interchangeable (no identity). This is replication copying (Nettles–O'Toole [L]; HB 19.3's replication invariant) with an empty mutation log. |
| Concurrent sweep | Allocation only from swept regions (HB 16.6) | The same. Immutability does not help sweeping much: sweep is a metadata problem. |
| Termination | Multiple remark passes, ragged handshakes (HB 17.8, 19.6) | The mark stack is empty ⇒ done. One mutator per heap (HEAP_007) ⇒ no ragged epochs. |

### 2.2 The mutation surface: where P0 is not (yet) true

These exceptions are what every design must handle. They are the real cost of concurrency here.

| # | Mutation | Where | Effect on concurrent designs |
|---|---|---|---|
| M1 | **Objects under construction written across safepoints:** `builder` arrays (HEAP_BUILDER_*); closures filled by `closureCapture`/`papExtend`, which raise `n_values` after allocation (`HeapHelpers.hpp:1934-1987`; kernel pattern `allocClosure → resolve → closureCapture`, e.g. `TaskEffectManager.cpp:88-91`) | nursery | A concurrent copier would miss a write made after it copied the object. Builders are already pinned to the nursery; closures are not flagged at all. |
| M2 | **Kernel writes into an object after it has survived a GC** | Evidence: the re-drain loop comment, `NurserySpace.cpp:549-566` ("kernel-side mutation paths can violate it") | Today's STW minor GC tolerates this by alternating Cheney and promoted scans to a fixed point. **Any design that copies survivors concurrently (C and B) or promotes blindly (en-masse, §7.3) must forbid it or detect it.** The heap-validate `in_phase3_` assertion is the natural census tool. |
| M3 | **Header words the runtime writes:** `age` and `color` (GC); `builder` cleared by `clear_builder`; `eco_array_set_fix_kind`; the `refcount` bits reserved by the borrow-inference plan (`NurserySpace.cpp:956-964`) | any | Header writes break "header immutability" (§2.4). Mutator-side refcount writes would break P0 itself (§12.1). |
| M4 | **Off-heap mutable roots:** MVar, Scheduler queues and `pendingResumes_`, the list scratch stack (HEAP_040), CAF slots (HEAP_035), PlatformRuntime model storage, literal-intern slots | C++ kernels | Harmless *if snapshotted at H*. A collector that reads them lazily later would hit the classic lost-object race, and a use-after-free when a `std::vector` grows. A kernel-only Yuasa barrier in `CellStore::set/rollback` is the fallback if the snapshot is too big. |
| M5 | **Runtime frees of old objects between majors:** `freeLargeBodyCell` (`OldGenSpace.cpp:4518`) frees and *reuses* a split-header body once its nursery header dies | old gen | Unsound under concurrent mark: the collector may hold the body. Defer the free while marking is active (the compaction deferral path already exists, `:4456-4469`). |
| M6 | **Identity-negative comparisons:** `ListOps::member` compares `hpBits` only (`ListOps.cpp:564-575`); no callers today | kernel | A stale copy and its replica would compare *unequal*. Positive fast paths (`a == b ⇒ equal`, `Utils.cpp:509`, `UtilsExports.cpp:44`) stay sound. |
| M7 | **Heap metadata** mutated by the mutator's allocator while a collector reads it | `OldGenSpace` | Not an object mutation, but it is the bulk of the engineering (§3.5). |

### 2.3 What immutability does *not* buy

- **Pretenuring is incompatible with having no write barrier.** An object allocated old whose
  fields are filled later would create an unremembered old→young edge. The runtime refuses this
  explicitly (`ThreadLocalHeap.cpp:225-231`). The same argument makes `promotion_age = 0`
  (en-masse promotion) unsafe until M1/M2 are audited.
- **Older-first, beltway and train collectors** reintroduce the remembered sets that immutability
  eliminated, because they reorder "age" relative to allocation order (HB 9.10, 10.3). Poor fit.
- **The old-gen allocator gets no help.** Sweep, free lists and block management are GC-private
  metadata, and immutability says nothing about them.

### 2.4 Two immutabilities, and where forwarding pointers may live

HEAP_006 says forwards never exist while the mutator runs. HEAP_030 relaxed that for old-gen
incremental compaction (which has no production caller) by adding an inline forward check to
every compiled dereference. `Allocator::resolveFast` does the same for kernels
(`Allocator.hpp:67-72`). Two investigations proposed reusing that check for concurrent copying
(background promotion in the parallel study; concurrent compaction in the sweep study). **That is
unsound, for a reason that was verified in the code:**

- The Tag_Forward layout repurposes the whole 64-bit header, `size`/`unboxed` included (Heap.hpp
  Forward struct).
- Readers check the tag and then **re-read other header fields**. Examples:
  - the `String.length` lowering loads the 32-bit `header.size` at `kHeaderSizeFieldOffset` after
    the forward marker (`EcoBackend.cpp:2299-2303`);
  - kernels do `resolveFast(p)` and then read `hdr->size`/`hdr->unboxed`.
- Under stop-the-world forwarding, nothing can happen between the check and the re-read. Under
  concurrent forwarding, a forward installed between them hands the mutator a garbage length or
  bitmap. This is a TOCTOU race.

**Rule (proposed as a FORBID row, §11):** *a concurrent collector never writes a header the mutator
may read.* Forwarding for concurrent copying goes in:

| Location | Cost | Caveat |
|---|---|---|
| A side table (hash or per-chunk array) | one extra probe per edge, on the collector only | the table exceeds the 16 MiB L3 |
| A GC-private pre-header word | 8 B per object | only possible in GC-laid-out regions (survivor regions), never in eden, whose layout the inline bump fixes (HEAP_034) |
| The 15-bit `refcount` field as an index into a per-chunk forwarding array | none | only while that field stays unused (§12.1) |

Once forwards never become mutator-visible, HEAP_006 stays literally true, and the HEAP_030 check
stays dormant. HEAP_030 is sound only for stop-the-world forwarding, and **§11 proposes saying so
in the invariant.**

---

## 3. Runtime-interface prerequisites (shared by every design)

### 3.1 Threads and ownership

- HEAP_007 ("each mutator collects only its own heap") and about ten TLS singletons encode "GC
  runs on the mutator thread":
  - `Allocator::tl_heap_`
  - `eco_tl_bump_state`
  - `eco_tl_root_*` shadow-stack cursors
  - `g_in_minor_gc`
  - the `thread_local ListScratch` (`RuntimeExports.cpp:4542`)
  - `g_scan_parent/tag/size`
  - `g_push_origin`
  - `g_batch_release_depth`
  - `in_phase3_`
  - the unwind `Context` (it captures the *calling* thread)

  Each must become explicit per-heap state or be published at the handshake.
- The existing service threads (Timer, Wait, Http) never touch HPointers. They are not an
  obstacle.
- Real Elm programs run one mutator (`eco_entry.cpp:325-334`). Only the synthetic benchmark driver
  runs several (`main.cpp` `program_threads`). One collector (or pool) can serve many heaps,
  because heaps are disjoint (HEAP_007). This is the Doligez–Leroy–Gonthier shape (HB 10.4; [L]).
- Machine: Xeon 6521P, 24 cores, no SMT, **16 MiB shared L3**, 15 GB RAM. Collector and mutator
  interfere through the L3 and DRAM latency, not through SMT.

### 3.2 Handshakes and safepoints

| Mechanism | Verdict | Reason |
|---|---|---|
| **Mutator-initiated post/collect.** At a minor-GC slow path the mutator publishes a work item (roots, a region, a block list) and collects results at a later slow path. | **Use this.** | Needs no codegen change. The mutator is already at a statepoint with precise roots. It is the degenerate case of HB 11.6's handshake and of HB 19.6's ragged epochs. Latency is one minor-GC period (~60 ms), negligible against a ~1 s mark cycle. |
| **Async doorbell via the `bump.end` clamp** | Possible later; **three defects first** | (a) The `ensureHeadroom` underflow (`NurserySpace.cpp:254-256`) turns a remote clamp below `ptr` into "plenty of room", and the covered region then bumps up to 4 KiB unchecked past the extent. Fix: `ptr + n <= end`, the compiled-code form (`EcoBackend.cpp:1434, 3219`). (b) The mutator rewrites `end` in `computeAllocEnd`/`failSoftUnclamp`, so a request must live in a separate atomic flag checked after a fence (Dekker ordering, HB 12.3). (c) The compiled `end` loads should become `load atomic unordered`, or GVN may merge them. |
| Signal suspension | **Reject** | Stack maps describe only return addresses of statepointed calls. gc-leaf frames (CGEN_072) have no records and omit frame pointers (CGEN_073). |
| Loop polls (`__eco_safepoint_poll` exists but is never emitted) | **Reject** | A non-allocating loop cannot write the heap (HEAP_031 stores need a fresh allocation), so it cannot harm a concurrent collector; it only delays the next handshake. Polls would undo CGEN_072/073/074. |

Fix the `ensureHeadroom` underflow regardless of what is built. It is a one-line change, and
latent: nothing clamps `end` below `ptr` today.

### 3.3 Stack scanning

- The collector cannot walk a running mutator's stack. Slots change at every statepoint. The walk
  stays on the mutator, which publishes slot *addresses* (for relocation) or root *values* (for
  marking).
- **Stack depth and walk time are unmeasured** (Elm runs on a 64 MB pthread stack,
  `eco_entry.cpp:36-38`). At about 100 ns per `unw_step` [L], 10⁴ frames × 1,924 minors ≈ 2 s,
  while 10³ frames is negligible [E].
- **Generational stack scanning is sound here** (HB 11.5; Cheng–Harper–Lee [L]).
  - With `PROMOTION_AGE = 1`, a frame not returned into since two minor GCs ago holds only
    old-gen, permanent or constant words, so minor GC may skip it.
  - Exceptions: builder objects (rooted through C++ guards, not stack maps), and old-gen
    compaction (dead code).
  - Detecting "not returned into" needs a return-address trampoline. That clashes with CFI
    unwinding and with stack-map lookup keyed by return address. Feasible but intricate: build it
    only if measurement shows deep stacks.
  - It shortens the unavoidable pause of *every* concurrent nursery design.

### 3.4 Memory model

- **Publication.** Everything a collector reads under the lemma was written before the handshake.
  So a release/acquire pair at the handshake (a mutex or futex) publishes all object contents
  (HB 13.7). **No fences on any mutator fast path.**
- **Collector writes the mutator may observe.** Healing a slot in a young object (design C) is an
  aligned 8-byte store of one valid pointer over another. It is benign on x86-TSO, but a data race
  in C++ and `undef` in LLVM. Use relaxed atomics on the collector side and document the race.
- **Copy-then-publish** is only needed for forwards the *collector* reads (HB 17.9), because
  mutator-visible forwards are banned (§2.4).

### 3.5 Old-gen metadata that a second thread would race on

Every concurrent old-gen design (concurrent mark, concurrent sweep, concurrent tenuring) pays for
this. Parallel STW designs mostly avoid it, because the mutator is stopped.

| Structure | Hazard | Fix direction |
|---|---|---|
| `blocks_` (`std::vector`), `push_back` at `OldGenSpace.cpp:1218, 1307, 1498, 3945`; swap-remove at `:3409-3440` | reallocation ⇒ use-after-free; unstable indices | fixed-capacity array plus an atomic count; a stable block id for work items; releases happen only at mutator sync points |
| `mark_bits_arena_` (`markBitsAppendForBlock`, `OldGenSpace.hpp:571-575`; re-pack at `startMark`) | reallocation moves every bitmap ⇒ lost marks (**unsound**) | a VA-reserved arena that grows in place |
| mark bits: plain byte RMW (`OldGenSpace.hpp:1111-1167`) from allocate-black and from the marker | lost update ⇒ a live object is swept | single writer (the collector) plus an allocation log, or `fetch_or` |
| `buffer_meta_[i].live_bytes +=` from both sides (`:404`, `:1957`) | lost increments ⇒ a live block released as all-dead (the historical bug at `:1561-1570`) | per-thread accumulators merged at the sync point |
| `page_to_block_index_`, `large_block_mark_`, `region_end_` | reallocation or torn reads | reserve for the whole reservation; collector uses copies taken at t0 |
| `free_lists_[]` global heads; Tier-M cross-block `prev_in_class` back-links | cannot be made lock-free cheaply | hand over whole blocks, never shared lists (§6.2) |
| `large_body_index_` (`unordered_map`), `free_large_blocks_`, `unassigned_blocks_` | concurrent mutation | owner-only, reached by message queue |
| `GCStats` counters | races | per-thread, merged |

The cross-check memory note applies directly here ([[gc-plan-premises-need-rederiving]]): **every
entry in this table is a place where missing one site is rare, silent and catastrophic.** A
stepping-stone build must run the protocol under TSan in isolation, with the heap validator at the
sync points.

---

## 4. Idea 1 — Incremental marking

**Today.** `ThreadLocalHeap::majorGC` calls `finishMarkAndSweep`, which loops
`while (incrementalMark(1000))` to completion (`OldGenSpace.cpp:2103, 2146`). The allocation-paced
branch was gated on `gc_phase_ == Marking`, which nothing ever sets. It was deleted as dead code
(`:665-672`). `mark_work_ratio` is still parsed (`HeapConfigJson.cpp:286`) but read by nothing.
This is why the Sep-22 sweep found it inert. THEORY.md:83 is stale on this point.

**Handbook options:**
- work-based (Baker's allocation tax, HB 19.2);
- time-based quanta and MMU (Metronome, HB 19.5);
- slack-based (HB 19.2);
- adaptive on free ratio (HB 16.7).

The natural Eco choice would be N mark units at each minor-GC end, with N chosen so that marking
finishes before the old gen grows by a set fraction.

**Throughput.** Same-thread incremental marking does the same work plus overheads:
- the prefetch ring drains at every slice, and each slice restarts cold;
- cache interleaving with the mutator;
- allocate-black for promotions;
- floating garbage.

**It cannot reduce wall time.** It shortens the major pause (up to ~1.3 s today), and a batch
compiler does not care about pause length.

**Its real value is as a stepping stone.** It exercises every invariant concurrent marking needs,
deterministically and on one thread:
- the t0 snapshot;
- allocate-black promotion;
- deferred large-body frees;
- mark cycles spanning many minor GCs;
- metadata growth mid-cycle;
- the handoff.

Recommended ladder:
1. Incremental marking at minor-GC ends behind a flag, with a validator asserting "every object
   reachable at handoff is marked or allocated after t0".
2. The same slices on a collector thread with the mutator *waiting* (the synchronous mode, §10),
   run under TSan.
3. Fully concurrent.

---

## 5. Idea 2 — Concurrent marking of the old generation

### 5.1 Snapshot point

Take the snapshot at the end of a minor GC, which is exactly where `majorGC` runs today
(`ThreadLocalHeap.cpp:533-547`). The mutator is at a statepoint, the stack roots have just been
collected, and old-gen allocation is quiescent.

### 5.2 The nursery at t0

The to-space survivors (age 1) point into the old gen. **They must be covered at t0.** Suppose
survivor X is the only path to old object O. If X is promoted black at the next minor GC and O was
never greyed, O is swept while X still points at it. So the belief that "promoted objects never
need tracing" is true for objects allocated *after* t0, and false for t0 survivors unless one of
the following options covers them:

| Option | Mechanism | Verdict |
|---|---|---|
| (a) Grey buffer | During the snapshot minor GC (or in one linear walk over the contiguous survivor prefix, HEAP_042), push every old-gen pointer found in a survivor | Exact, O(survivors) ≈ a few ms |
| (a′) Promote-all snapshot minor GC | Run that one minor GC with an effective promotion age of 0, so the nursery is empty apart from pinned and builder objects | **Simplest:** the collector's world is purely old gen and it *never* dereferences a nursery address (assertable). Costs one prematurely tenured cohort per major, ~6 per run. M1/M2 do not bite here because the promotion is STW and keeps the re-drain fixed point. |
| (b) Trace through the nursery concurrently | as today, via `nursery_visited_` | **Reject.** Minor GCs move nursery objects and poison from-space under the collector. |

Either (a) or (a′) retires the `nursery_visited_` hash set (`OldGenSpace.cpp:1860-1870`) from the
concurrent path.

### 5.3 Allocate-black during the cycle

Promotions, large objects, permanent objects and split-header bodies must be live for this cycle.
The code already allocates black (`initObjectHeaderWithSize`, `OldGenSpace.cpp:385-410`), but with
plain byte RMWs. Options:

| Option | Mutator cost | Notes |
|---|---|---|
| A. `fetch_or` on the shared bitmap from both sides | ~20 cycles per promotion ≈ 30–50 ms per cycle, plus line ping-pong (1 byte of bitmap covers 64 B of heap) | the minimum for correctness if both sides write |
| **B. SPSC allocation log.** The mutator appends each old-gen allocation; the collector is the *only* bitmap writer. | one 8 B store per allocation | **Recommended.** It must cover *every* entry point (`allocate`, `allocateLargeBody`, `allocatePermanent`, `allocateLargeBlock`, bag-page splits). Missing one reproduces the all-dead-block release bug. |
| C. Mutator-owned "allocated-during-mark" bitmap, OR-ed at handoff | none | doubles the bitmap unless allocated lazily |
| D. Per-block top-at-mark-start watermark | none | covers fresh pages only. Promotions mostly pop free-list cells inside old blocks, and Eco's segregated free lists do not allocate in address order (unlike GHC's `next_free_snap` [L]). A supplement only. |

The children of objects allocated after t0 never need tracing. They are in S_H ∪ N_H by the lemma,
and every S_H old object is marked by the collector.

### 5.4 What must change in today's code

1. **`freeLargeBodyCell` must be deferred** while marking is active (M5).
   - The comment at `NurserySpace.cpp:926-928` ("Skipped if a major GC is mid-cycle") is **stale**:
     only compaction defers today.
   - `case GCPhase::Marking` in `freeLargeBodyCell` is dead, because `gc_phase_` is never set to
     Marking.
2. The §3.5 metadata hardening.
3. `startMark`'s early return when `marking_active` (`OldGenSpace.cpp:1542`) would silently no-op
   an emergency major. Emergency paths (`allocateLargePinned` failure, `allocateRegionSlow`,
   `eco_major_gc`) must *join* the running cycle: wait or help, then run the tail, then retry.
4. Compaction must be asserted idle for the whole cycle. The lazy sweep of the previous cycle must
   finish before the next mark starts (already true: `startMark` drains it, `:1545-1557`).

### 5.5 Termination and handoff

- There are no barrier buffers and no root rescan, so **marking is done when the collector's stack
  is empty and it has drained the allocation log up to the tail it has seen.** No remark pause.
- At the next minor-GC end after `mark_done` (acquire), the mutator:
  1. drains the log tail;
  2. merges `live_bytes`;
  3. runs today's post-mark tail unchanged (`finalizeMetaAfterMark`, demote,
     `transitionToSweeping`, all-dead reclaim, capacity adjustment, initial sweep slice).

  Block releases therefore never race.

### 5.6 Pacing

A concurrent major must start early enough to finish before the old gen reaches its cap. Two
mechanisms:
- **Trigger model:** the Go pacer ([L]); HB 16.7 allocation-based pacing. Start when
  `occupancy + promotion_rate × predicted_mark_time` crosses the cap fraction. That means lowering
  `major_gc_initiating_occupancy` from the shipped 0.95 by roughly that margin.
- **Fallback when the collector is late:** the mutator's slow path either waits or does mark work
  itself (Go's mark assist; HB 19.6 tax-and-spend). Assists need parallel-safe mark bits, so they
  come for free once §5.8 exists.

**Trap from the sensitivity sweep:** factors that raise the old-gen peak compound
([[gc-sensitivity-sweep-sep22]]). SATB floating garbage plus deferred body frees raise the peak by
an estimated 2–5 %. Gate every experiment on old-gen peak before reading its wall time.

### 5.7 Handbook caveat

The local summaries' comparison tables claim SATB has "no floating garbage" (HB 12.10 table; HB
15.3 advantages). The standard understanding is the reverse: SATB retains everything live at t0
and floats *more* than incremental update. Do not size the heap from those tables.

### 5.8 Parallel STW marking: the cheaper alternative

- k helper threads mark during today's pause, using atomic test-and-set on mark bits (HB 14.2,
  13.4), Chase–Lev work-stealing deques (HB 12.7, 13.5), two-phase termination (HB 13.6), and
  chunking for large arrays (HB 16.4).
- **It needs none of §3.5**, because the mutator is stopped.
- Marking is latency-bound at ~40 ns per object, and list spines are serial pointer chains that the
  depth-16 prefetch ring cannot overlap. So k threads should add close to k× memory-level
  parallelism, far below DRAM bandwidth (~1.6 GB/s per marker).
- Estimate [E]: 7 s → 2–2.5 s at k = 4, i.e. **−4.5 to −5 s at low risk**.
- Concurrent marking (−5.5 to −6.5 s) is only ~1–1.5 s better on throughput. Its real advantage is
  the ~50 ms major pause.

**Verdict:** build parallel STW mark first. Build concurrent mark only if major pauses matter
(interactive or worker programs), or as part of a combined "collector thread owns the old gen"
architecture (§13).

---

## 6. Idea 3 — Concurrent sweeping

### 6.1 Where sweep actually runs

- **Eagerly, in the major pause** (the "sweep" column, ~0.5 s per run): demotion, all-dead reclaim,
  shrink, stats and one 64 KiB slice.
- **The bulk runs lazily,** as a 4 KiB `sweep_work_budget` slice at *every* old-gen allocation
  while `gc_phase_ == Sweeping` (`OldGenSpace.cpp:677-693`). Almost every old-gen allocation is a
  promotion, so **almost all lazy sweeping happens inside minor-GC pauses** and no counter
  measures it:
  - "Old-gen alloc in mutator" (144 ms) skips promotions by design (`:657`);
  - the sweep-on-demand counter reads 344 KB per run.
- **It is bursty.** ~1.4 GB is swept per minor, so the post-major heap is swept within 2–4 minors.
  That burst is the 986 ms worst pause (W7).
- Estimate: **1.5–3 s of wall** [D/E, ±2×].

### 6.2 Concurrent-sweep options

| Option | Mechanism | Fast-path atomics | Verdict |
|---|---|---|---|
| A. **Sweep a block, hand over the block** | The collector claims unswept blocks by CAS on per-block state and builds *block-local* free chains. It publishes each block through per-class SPSC rings (HB 13.5). The consumer (promotion) owns a block outright. A help-sweep rung ensures the allocator never grows while unswept blocks remain (the W6/W7 lesson). | 0 per object; 1 acquire-load per block | The right concurrent shape. Its benefit is limited to how far the sweeper runs ahead, and the first post-major minors, where the cost concentrates, are where it is least ahead. |
| B. Background sweeper racing an on-demand sweeper over *shared* free lists | CAS on list heads; Tier-M back-links | an RMW per promotion ≈ 3.5–7 s | **Reject.** It costs more than the whole prize. |
| D. Parallel STW sweep inside the major pause | chunked sweep (HB 14.3), merged in block order | none | Deterministic. Moves the burst into the major pause at 1/N of the cost. |

**Determinism:** consume swept blocks strictly in index order, and help-sweep the next one if it is
not ready. The allocator's observable state is then independent of *which* thread swept, and the GC
counters stay bit-identical (§10).

### 6.3 Better than concurrency: make sweeping (nearly) free

- The old gen already records liveness in a side bitmap (1 bit per 8-byte granule at object
  start). For a *uniform* block of class size s, the free cells are exactly the clear cell-start
  bits.
- **Proposal:** allocate straight from the bitmap. This is HB 7.4 "bitmapped fits", HB 14.3
  `free = alloc & ~mark`, and Go's `allocBits = gcmarkBits` swap [L]. For uniform blocks:
  - "Sweeping" becomes a popcount (already known as `live_bytes`) plus a list insertion.
  - Dead memory is never touched.
  - The ~14 GB-per-run header walk disappears.
  - The per-promotion free-list pop, which is a DRAM miss on a cold cell, becomes a bitmap word
    that is usually in L1.
  - The same structure is the promotion buffer (§7.2) that parallel minor GC needs.
  - W6's virgin-page cursor is subsumed: a virgin page is an all-clear bitmap. The reuse-before-grow
    order becomes structural: refill from `partial_blocks_[cls]` first, then virgin pages.
- **What it costs:**
  - HEAP_021/024 need rewording for uniform blocks (dead headers become stale rather than
    `Tag_Free`).
  - `demoteMostlyDeadUniformBlocks` must go, or write headers only for demoted blocks.
  - The HEAP_027 sentinel protocol reduces to clearing one bit.
  - Mixed blocks keep a gap sweep that reads only *live* headers (O(live)).
  - Uniform blocks stop being header-parsable. That is acceptable: only sweep and the dead
    compaction code parse block contents (mark does not, and no validator walks whole blocks).
- **Risk:** a branchy ctz scan replaces a predicted pointer pop. W3/W4 show that "branchless" or
  table-driven rewrites of predicted code can *lose* ([[gc-opt-loop-results]]). The hypothesis that
  it wins rests on the pop being a cache miss. Measure.
- **Estimate: −1 to −4 s** [E], with no second thread. Once it exists, a concurrent sweeper has
  almost nothing left to take for uniform blocks.

### 6.4 Housekeeping that could move to a GC thread

| Item | Value | Note |
|---|---|---|
| Page decommit (`madvise DONTNEED`) | ≈ 0 s | **Premise correction:** decommit is *on* (`AllocatorCommon.hpp:177`). THEORY.md:87, which says `false`, is stale. The old corruption was carry-over mark bits, fixed by the `startMark` bitmap clear. The `decommit_off` cell measured inert. A background madvise opens a timing window onto that same bug class. |
| Mark-bitmap clear (~140 MB) | ~0.1 s per run | needs a double-buffered arena |
| Prefault and pre-slice the next old-gen page (`MADV_POPULATE_WRITE`) | unknown | the per-minor page-fault count is not in the saved logs; measure first |
| Residency and fragmentation statistics | small | stats builds only |
| Concurrent evacuation of the sparse tail | ≈ 0 throughput; ≈ −550 MB RSS | See §8.1. Blocked by the §2.4 rule and by missing root fix-up (the HEAP_040 caveat). |

**Verdict on idea 3:** instrument promotion-path sweep first (bytes and ns per minor, plus
`minflt` per minor). Then prefer bitmap allocation (§6.3). Consider a sweeper thread (option A)
only for the residual mixed-block work, run on the same helper thread that parallel mark or minor
GC creates.

---

## 7. Idea 4 — The nursery: parallel and concurrent copying

### 7.1 Anatomy of the ~31 ms minor pause

| Phase | Code | Estimate per pause |
|---|---|---|
| Stack walk (untimed today) | `ThreadLocalHeap::collectStackRootsFromStackMap` (`:793-864`) | **unmeasured**, 0.05–1.5 ms [E] |
| Roots 1a/1b/1c/1e | `NurserySpace.cpp:457-513` | < 0.2 ms [E] |
| Root 1d: external scanners (included CellStore cells and trail until 2026-10-04) | `:515-524`; `CellStore.cpp:147-166` | **unmeasured**, possibly 1–5 ms [E] |
| Cheney copy of age-0 survivors (hybrid DFS for spines) | `:562-576`, `evacuate` `:974-1263` | ≈5–6 ms (~18 %) [D] |
| Promotion: cold read, `oldgen.allocate` per object, memcpy, forward, `promoted_buf_` rescan, 4 KiB lazy-sweep slice | `:1147-1181`; `OldGenSpace.cpp:630-720` | **≈23–25 ms (~75–80 %)** [D] |
| Large-body sweep (untimed) | `:931` | small |

Instrumentation needed at loop granularity (per-object clocks cost several % of wall, per the
`inline-bump-state-tls` lesson):
- move the timer above the stack walk, and count frames walked and matched;
- time each root phase, and time each external scanner with its slot counts;
- time the Cheney inner loop and the promoted inner loop separately;
- record promotion-allocation ns per 1024-promotion batch, and sweep bytes under `g_in_minor_gc`;
- record `minflt` per minor;
- add a **per-minor event log** mirroring the major one, which is what made the W13 decisions
  resolvable below the noise floor.

### 7.2 Parallel stop-the-world copying (HB 14.4, 4.6, 12.12)

**Shape.**
- A persistent helper pool parks on a futex. The mutator is worker 0. Wake plus barriers cost
  ~0.06 s per run [E].
- The **stack walk stays serial**; the `StackMapRoots` slot vector is the seam where the work fans
  out.
- **Block-local Cheney** (Imai–Tick; GHC's block-structured parallel GC [L]): each thread copies
  into its own to-space LAB (a `fetch_add` on the contiguous to-space, HEAP_042) and scans it with
  its own cursor. Unscanned LAB tails are published as stealable scan blocks.
- `promoted_buf_` becomes per-thread packets of promoted objects, stolen through Chase–Lev
  deques.
- Two-phase termination (HB 13.6).

**Forwarding install.** Today it is three bitfield stores (`NurserySpace.cpp:1254-1256`, `1360`,
`1890`). It must become one composed 64-bit word installed by `lock cmpxchg` against the header read
before the copy. The loser rolls back its LAB bump (HB 13.4). Only GC threads race; the mutator is
stopped, so §2.4 does not apply. The cost is ~5 ns on a 42 ns path, a **~12 % single-thread tax**
[E]. That is why two threads may gain little, and why `gc_threads=1` must remain the old code path.

**List spines (hybrid DFS, worth 8.1 s).**
- A spine is inherently serial. One thread copies a spine in bounded runs of 256–1024 cells, then
  pushes the remaining tail as work.
- The existing "already forwarded → link and break" arm (`:1812-1826`) handles shared tails.
- `evacuateListHeads` must stop at the count of cells *it* copied, not at "left to-space" (which
  would wander into another thread's cells).

**Promotion: the crux.** `OldGenSpace::allocate` is single-threaded throughout. A global lock
serializes the 75–80 % that matters, capping speedup at ≈1.2–1.3× [E]. The requirement is
**per-thread, per-size-class promotion buffers that claim batches of *already swept* free cells
block by block**:
- Place them at the rung they replace, never above the reuse ladder (W6: +77 s, +33 % RSS).
- Keep each block single-class, so sweep keeps its fixed stride.
- Parallelize in-pause lazy sweep by block claim (HB 14.3).
- Keep `allocated_bytes` per thread, merged at the barrier.
- Put large objects and `promoteLargeHeader` (~4 K per run) under a mutex.
- §6.3's bitmap allocation *is* this buffer.

**Determinism.**
- *Output* stays byte-identical: Elm has no identity, interning is content-keyed,
  `Debug.toString` never prints addresses, and handles are integers. The mark ring already proved
  "trace order cannot reach emission".
- *Counters* stay exact only if the minor-GC trigger counts **object bytes**, not LAB-claimed bytes.
  Fillers at LAB tails would otherwise make the survivor prefix, and everything downstream,
  nondeterministic.

**Scaling estimate** [E]:

| GC threads | Pause | Minor GC per run | Wall saving |
|---|---|---|---|
| 1 (parallel code) | ~34 ms | ~66 s | **−7 s (a loss)** |
| 2 | ~20 ms | ~38 s | ~20 s |
| 4 | ~12 ms | ~23 s | **~34–38 s** |
| 8 | ~9 ms | ~17 s | ~40–44 s |

Why Eco should scale better than GHC's disappointing parallel minor GC ([L]: Marlow et al. 2008 and
2011; GHC later made gen-0 load balancing optional): GHC's nursery is 1–4 MB, with pauses of tens
to hundreds of µs, so synchronization dominates and the data is hot in the mutator's cache. Eco's
pauses are **31 ms over cold, latency-bound survivors**, so each extra thread brings its own
outstanding misses.

### 7.3 En-masse promotion of the survivor prefix (a stop-the-world idea worth testing first)

After each pause, the age-1 objects are exactly the contiguous prefix of the new from-space
(`NurserySpace.cpp:908-912`), and **~91 % of them are still live at the next GC** [D: 676 M
promoted / 744 M survivors]. So the next pause can promote the whole prefix **in address order,
split by address range across threads**:
- no liveness trace;
- no CAS (each range has one owner);
- streaming reads the hardware prefetcher covers;
- a deterministic layout;
- Cheney/hybrid-DFS locality preserved into the old gen.

The cost is ~9 % garbage tenured (~2 GB per run), which means more old-gen growth and an earlier
major.

Safety: it relies on "children of aged objects are aged", which M2 says kernels can violate. Keep
the Cheney ↔ promoted fixed-point loop as the safety net (it catches young children of promoted
parents). Validators must skip unreached promoted garbage, which may hold pointers to cells freed
by a later major.

Single-threaded, it is also a cheap probe of how much of the 70–110 ns per promotion is *finding*
the object versus *allocating* its destination.

### 7.4 Concurrent nursery copying

#### 7.4.1 Designs considered

| Design | Mechanism | Verdict |
|---|---|---|
| A. Replicate-then-flip, one region (Nettles–O'Toole [L]) | The collector replicates the snapshot while the mutator allocates in the *same* nursery; the flip copies what was allocated during the cycle. | **Reject.** The flip copies the youngest survivors, which are most of them. Deferring that work turns A into B. |
| **B. Pipelined regions** | The nursery is a ring of N ≥ 3 regions. At each handshake the mutator only walks roots and switches region; the collector evacuates the just-closed region. Stale pointers stay valid until the region is reused. | Largest prize (up to ~55 s off the mutator; **−30 to −45 s net** [E]). But: (1) P0 is required for *all* kernels: every object written across a safepoint must be builder-flagged and evacuated by the mutator. (2) Retention is **not statically bounded**, because the mutator copies stale pointers out of unhealed originals into new objects. It needs a dynamic horizon rule plus a synchronous fallback. (3) +256–512 MB. |
| **C. Concurrent tenuring** | Eden plus three small rotating survivor regions G. The mutator does E→G_n stop-the-world, as today. A collector thread promotes G_{n-1} into the old gen during the next epoch, recording forwarding off-header and healing the recorded G_n→G_{n-1} slots. | **Recommended concurrent design.** Details in §7.4.2. |
| D. Doligez–Leroy–Gonthier | Thread-local young heaps plus a concurrent shared old heap | Eco already *is* thread-local young heaps. DLG offloads only old-gen work, 0 s of the 59 s. Complementary (it is §5). |
| E. "Barrier-free" | — | A property of B and C, not a separate design. Brooks words exist to give *mutable* objects one canonical copy; Baker's to-space invariant exists because of mutation; Sapphire's write mirroring is empty when there are no writes. **Eco is the degenerate, ideal Sapphire.** |
| F. Blelloch–Cheng, Staccato, Chicken, Clover, Metronome (HB 19.3–19.7) | machinery for mutator *writes* or real-time bounds | Not needed. Only work-based pacing (HB 19.2/19.3) transfers, as B's backpressure. |

#### 7.4.2 Design C in detail

- **Protocol at minor n** (stop-the-world):
  1. If the collector has not finished G_{n-2}, wait or help.
  2. Evacuate roots into E → G_n. Rewrite roots into G_{n-2} through forwarding. *Record* roots
     into G_{n-1} for the collector, using a range compare only, with no header load.
  3. Cheney-scan G_n. Its fields into G_{n-2} are resolved; its fields into G_{n-1} are recorded as
     slot addresses F_n.
  4. G_{n-2} is now unreferenced, so retire it.
  5. Hand G_{n-1}, the recorded roots and F_n to the collector.
- **Why retention is bounded.** After minor n+1:
  - roots have been rewritten;
  - E is empty;
  - G_{n+1} copies were resolved;
  - G_n's fields were healed by the collector during the previous epoch;
  - the old gen never points into the nursery.

  So nothing reachable points into G_{n-1}. That is exactly three live G regions.
- **Why healing is required.** Without healing, G_n originals would keep leaking G_{n-1} pointers
  into E. That is design B's unbounded chain.
- **Memory:** eden (no copy reserve needed) + 3 × ~32 MB ≈ 350 MB, against today's 2 × 256 MB.
  Less than today.
- **Gain:** promotion leaves the mutator (≈45–55 % of the 59 s at the per-object costs of §7.1,
  i.e. 27–32 s), minus recording (<1 s) and minus L3 interference (the collector streams ~24 MB per
  59 ms epoch through the shared 16 MiB L3; 2–6 s). **Net ≈ −20 to −28 s** [E].
- **The collector still needs a thread-safe old-gen allocator:** promotion buffers plus a lock on
  page acquisition, exactly as in §7.2.

#### 7.4.3 Correction: design C needs a kernel write audit

The investigation that proposed C argued that it needs "no invariant beyond what today's
generational design relies on", on the grounds that writing into an object after it has survived
*two* GCs is already unsound. That argument misses M2:

- Today, a kernel write into a *once-survived* object (sitting in to-space with age 1) is
  tolerated.
- At the next minor GC, that object is promoted, the young child it now references is found by
  the promoted-object scan, and the alternating drain loop (`NurserySpace.cpp:549-566`) re-drains
  to a fixed point. The comment there says kernel mutation paths do this.
- Under C, the object sits in G_n, and the kernel's write happens during the epoch after minor n.
  Minor n+1 does not rescan G_n; it only records roots into it. The collector then promotes it
  concurrently, possibly before the write.
- Result: an old-gen object pointing into a reset eden, i.e. dangling.

**C therefore needs a new invariant P1: no kernel writes into an object that has survived a GC,
unless that object carries `builder`** (and so is never placed in G). That is weaker than B's P0,
but it is an audit. The census tool already exists: the heap-validate build's `in_phase3_`
assertion fires on exactly this case. The fact that the repaired validator gate passes 1731/1731
E2E ([[nursery-per-site-zeroing-shipped]]) is evidence, but not proof, that no production path
does it. Run the self-compile under the validator before committing to C.

#### 7.4.4 Hazards common to B and C

| Hazard | Detail |
|---|---|
| **H-hdr** | Forwarding must be off-header (§2.4). |
| **H-body** | Split-header large bodies (HEAP_026) are swept at every minor GC if their header was not scanned *in that minor*. In C, headers in G_{n-1} are not scanned by the mutator; in B, whole regions are not. Without **per-owning-region body sweeping**, live string data is freed. |
| **H-valid** | Validators encode "nothing points into from-space": the post-GC walk, `debugAssertValidNurseryPointer`, `validateNurseryHPtr`, the `EcoBoxedStoreVerify` tripwire, and `poisonOldFromSpaceUsedRegion` at every minor. Re-specify them as "points into a *retained* region" and poison only on retirement, or they will false-positive, or be switched off and hide real P0/P1 bugs. |
| **H-major** | A major GC may start only at a minor where the collector is drained. Promotions by the collector are allocated black (§5.3). |
| **H-id** | Identity-negative comparisons (M6) must be linted out. |
| **H-L3** | The collector competes with a latency-bound mutator for the shared L3. The net figures depend most on this term, and it is the least certain. **Measure it before building:** run a synthetic co-runner that streams ~25 MB per 59 ms of random 35-byte copies on another core during a normal self-compile, and read the mutator slowdown. |

#### 7.4.5 As built (threaded-gc-07, 2026-09-27)

Design C was built as `plans/threaded-gc-07-concurrent-tenuring.md` (HEAP_069/HEAP_070,
FORBID_HEAP_004), with four changes from the text above:

- **The heal is pause work, not collector work.** The collector records nothing and writes no
  published object; the next minor heals the recorded slots (H_m) before anything else touches
  the heap. The self-compile's heal lists are small (p50 47 slots, p99 25 K, max 67 K per minor;
  p99 0.24 ms), so the pause heal costs almost nothing and keeps HEAP_006 / P1 literal.
- **The collector allocates from a promotion grant**, not through the promotion lock: uniform
  blocks in state `kAllocTenure`, sized in the pause from the tenuring extent's per-class object
  counts, invisible to every allocator selection path until the merge. F11's light shrink runs
  outside pauses, so the skip rule is load-bearing; so is excluding the mutator's own cursor
  block, which `classifyBlocksAfterMark` can leave on the partial queue.
- **Young large objects are handled by generation** (first reach at m, hand-over at m + 1,
  promotion in place at the m + 2 merge), and the job reads a private sorted snapshot, never the
  body index. H-body is solved by re-marking the hand-over extent's bodies at hand-over.
- **Every nursery object must have a size class** (the grant allocates cells). The region cap on
  large pointer objects is the largest old-gen class (8 KiB at the default
  `large_object_threshold`), not 64 KiB.

H-L3 was real and is the deciding term: the region nursery by itself makes the mutator faster
(mutator CPU outside pauses 97.7 s vs 112.1 s legacy at N = 1), one concurrent collector costs
about 2.4 s of it, four collectors about 13 s. See the plan's P§10 for the measurements.

### 7.5 Nursery comparison

| | Parallel STW (§7.2) | En-masse prefix (§7.3) | C: concurrent tenuring | B: pipelined |
|---|---|---|---|---|
| Off the mutator | 30–38 s at 4 threads | unknown; single-threaded it removes the promotion trace only | 27–32 s | ≤ 55 s |
| Net wall [E] | −30 to −38 s | measure | −20 to −28 s | −30 to −45 s |
| Mutator barrier | none | none | none | none |
| Pause | ~12 ms | today's | ~15 ms | stack walk + roots (unmeasured) |
| Retention bound | n/a | n/a | static, 3 small regions | dynamic horizon + STW fallback |
| New kernel invariant | none | none (keeps the fixed-point loop) | **P1** | **P0** (all kernels) |
| Memory | ≈ today | +old-gen growth (~2 GB/run tenured garbage) | −150 MB | +256–512 MB |
| Old-gen allocator | promotion buffers | promotion buffers | promotion buffers + lock | promotion buffers + lock |
| Composes with | all | §7.2 | §7.2 (shrinks the STW part) | §7.2 |

**Verdict:** parallel STW first, because it is the largest win per unit of risk and it builds the
promotion buffers everything else needs. Then design C, if the single mutator's pause or core
count argues for it. Design B only after C has proven that concurrent promotion pays, and after the
root-scan pause has been measured.

---

## 8. Beyond the four ideas

### 8.1 Concurrent old-gen evacuation

This is compaction of the ≤5 %-live tail: ~1,100 pages, ~550 MB holding ~8 MB of live data [M:
residency snapshot].
- **Feasible in principle because of immutability:** a copy races with no writer.
- **Remapping without a heap walk:** mark N+1 heals every traced slot that points into an evacuated
  page (ZGC-style remap-during-mark, HB 17.11 [L]), and minor GC heals nursery slots it scans
  anyway. From-space pages are freed only after mark N+1.
- **Blocked by:**
  - the §2.4 rule: no header forwards visible to the mutator, so the "HEAP_030 is already paid"
    argument does *not* apply concurrently;
  - `fixReferencesSlice` never fixes the nursery, stacks or external scanners (the HEAP_040
    caveat);
  - `markOneObject` rejects `Tag_Forward` (`OldGenSpace.cpp:1903`);
  - kernel raw-pointer audits.
- Value: RSS only. Low priority.

### 8.2 Collector-side reference counting for the old gen

HEAP_018 (acyclic) makes RC complete, and the old gen has a property no mainstream RC system has:
**old→old references are created only by the GC at promotion, and never change afterwards.** That
makes a collector-owned scheme possible:
- **Increments** happen only in the promoting minor GC.
- **Decrements** happen only in death cascades, which can run on a background thread (the dying
  objects are unreachable, and counts belong to old objects the mutator never writes; HB 18.4).
- **Stack and nursery references are deferred** (Deutsch–Bobrow, HB 18.2): an old object whose
  count reaches zero waits in a zero-count table until a minor GC confirms that no root or survivor
  references it.

This is ulterior RC (HB 18.7) with no mutator barrier. It targets the ~8 s major, not the 59 s
minor, and it conflicts with the stack watermark (frozen frames keep objects alive unseen).
**Worth a design note, not a build.**

### 8.3 Other items

| Item | Verdict |
|---|---|
| Background page zeroing | **No.** The zeroing requirement was retired (W1b: bounding the closure scan by `n_values`). Another core's zeroing lands Modified in *its* L2 and must migrate, so it does not reproduce the cache-warmth the bulk memset gave. If allocation-front misses matter, try a same-thread `prefetchw` ahead of `bump.ptr`. |
| Background decommit / `MADV_POPULATE_WRITE` prefault | Small. **Good first "hello world" for the collector-thread plumbing**, because it touches no HPointers. |
| Idle-time GC (GHC `-I` [L]; HB 19.2 slack-based) | Cheap and good for Platform.worker programs (major GC while the scheduler waits on Timer/Wait/Http). Irrelevant to the compiler benchmark, which is never idle. |
| Pretenuring / allocation-site feedback | **Incompatible** with the no-barrier design (§2.3). |
| Page-protection read barrier (Appel–Ellis–Li [L]; HB 11.10, 15.5) | A research option only. Its appeal is covering C++ kernels without an audit, but µs-scale traps at 2 MiB THP granularity are expensive, and `vm.unprivileged_userfaultfd = 0` on this box. Keep it for "we cannot audit the kernels". |
| Generational stack scanning | §3.3. Orthogonal, and shortens every design's residual pause. |

---

## 9. Prior art mapped to Eco

The local handbook summaries name Erlang (HB 10.4), G1 (HB 10.6), Shenandoah/ZGC/C4 (HB 17.11),
Blelloch–Cheng (HB 19.3), Henriksson (HB 19.4) and Metronome (HB 19.5). They do **not** cover
Doligez–Leroy, Nettles–O'Toole, OCaml 5, GHC's nonmoving collector or Go. Rows marked [L] come from
memory and should be checked against the papers before being cited in a plan.

| System | What mutation costs them (Eco does not pay it) | Idea that transfers |
|---|---|---|
| **Doligez–Leroy (POPL'93) / Doligez–Gonthier (POPL'94)** [L] | a barrier on mutable ML fields; promote-on-escape; three-phase ragged handshakes | **The closest template**: thread-local young heaps plus a concurrent non-moving old heap. Eco keeps the shape and drops the barrier (§5). |
| **Nettles & O'Toole, replication GC** [L] | a mutation log re-applied to replicas | Eco's log is empty (§7.4). The textbook fit for concurrent nursery copying. |
| **GHC** (parallel copying; nonmoving old gen, Gamari & Dietz ISMM'20) [L] | an update remembered set for thunk updates, MVars and TVars (HB 9: Haskell's old→young pointers come from thunk updates) | A nonmoving concurrent old gen with the nursery kept STW (HB 17.7) is the right split. Its segregated-fits heap with bitmap marking is the closest structural match to Eco's old gen. Idle GC. Its disappointing parallel *minor* GC is a caution, though its conditions differ (§7.2). |
| **OCaml 5** (ICFP'20) [L] | a Yuasa deletion barrier in `caml_modify`; ephemeron termination | Parallel STW minor GC plus a concurrent major, sliced by allocation. Eco has no ephemerons or weak references, so termination is trivial. |
| **Go** [L] | a hybrid write barrier on every pointer store; conservative scan of async-preempted frames | The **pacer** (trigger from promotion rate × mark time) and **mark assist**. Signal preemption does not transfer (§3.2). |
| **Erlang BEAM** (HB 10.4) | nothing shared is mutable | Thread-locality already bought the *latency*. A collector thread is about throughput on spare cores. |
| **G1** (HB 10.6, 16.9) | SATB pre-barrier, card post-barrier, remembered-set refinement threads | Selecting old regions for evacuation; `selectEvacuationSet` already exists. |
| **ZGC / Shenandoah / C4** (HB 17.2–17.5, 17.11) | a load barrier on every reference load; the to-space invariant | Eco needs no to-space invariant (stale copies are valid), so cheaper replication replaces load barriers. Remap-during-mark (§8.1). |
| **Cheng–Harper–Lee, PLDI'98** [L] | pretenured objects need barriers | Generational stack scanning (§3.3). Pretenuring does not transfer. |
| **Blelloch–Cheng** (HB 19.3) | dual writes to both replicas | work-based pacing bounds |
| **MPL / Manticore** [L] | entanglement detection; promote-on-escape | The model to follow if Eco ever gains fork-join parallelism. |

---

## 10. Measuring a concurrent collector

The team's loop depends on **GC counters being bit-identical per binary × tree**: inert cells form
the noise population, and "counters identical" is a gate ([[gc-sensitivity-sweep-sep22]],
[[gc-opt-loop-results]]). A collector thread breaks that unless it is designed not to.

1. **Collector progress is never a decision input.** Phase transitions, triggers, promotion and
   nursery sizing may depend only on mutator allocation bytes and on occupancy as computed at a
   mutator sync point. A late collector turns into a mutator *wait* or *assist* of a fixed quantum,
   never into a different decision. Things to avoid:
   - "start the next mark when the previous one finishes";
   - "sweep as far as the thread got";
   - `evaluateMajorGCTrigger` reading a committed size that depends on sweeper progress.
2. **A synchronous mode** (e.g. `ECO_GC_THREAD=sync`) runs the same work items on the mutator at the
   same post/collect points. It is the regression gate for counters and for byte-identical
   `out.mlir`. The concurrent mode must reproduce its counters exactly; a divergence means a timing
   dependence leaked in.
3. **Report the decomposition:**
   - wall;
   - mutator CPU and collector CPU (`CLOCK_THREAD_CPUTIME_ID`);
   - **mutator stall** (waits plus assists; the part that costs wall);
   - **interference** (mutator CPU in concurrent mode minus mutator CPU in sync mode);
   - an MMU curve from a stall event log (HB 1; HB 19.5).

   "GC time" as a sum of pauses stops being comparable across modes.
4. **Pin** the mutator and collector to distinct cores. Re-derive the 2σ noise band (5.3 s today)
   for concurrent mode, including a duplicate-baseline cell.
5. **New failure modes:**
   - Hangs: every run needs a timeout, and a timeout counts as a failure.
   - Collector-thread crashes: always check the output artifact, never `rc`
     ([[gc-sensitivity-sweep-sep22]]: the `abuf_128K` "win" was a SIGSEGV).
   - Races: run TSan on the protocol in isolation.
   - Validation: validators may run only at sync points.
   - Stress coverage: run stress under `benchmarks/heap-config-gc-pressure.json`. At the default
     config the stress suite runs **zero** minor GCs ([[nursery-per-site-zeroing-shipped]]).
6. **Escape hatch:** `ECO_GC_THREAD=0` / `gc_threads=1` restores today's path byte for byte, like
   the `ECO_GCFREE_LEAF` and `ECO_ALLOC_HOIST` flags.

---

## 11. Invariant impact

### 11.1 Rows that must be amended

| Row | Change |
|---|---|
| HEAP_007 | "Each heap region is owned by one ThreadLocalHeap. Its *collection work* may run on helper threads while the owner is parked (parallel STW), or on a collector thread for phases listed as concurrent-safe, touching only state that phase owns." |
| HEAP_006 / HEAP_030 | Reconcile them. HEAP_030's mutator-visible forwards are an exception for **stop-the-world** forwarding only (the old-gen compaction window). HEAP_006 remains absolute for any concurrent phase. |
| HEAP_026 | Body sweeping must be keyed to the header's owning region (for B/C) and deferred during concurrent mark. |
| HEAP_021 / HEAP_024 / HEAP_027 | Reword for uniform blocks if bitmap allocation is adopted (§6.3). |
| HEAP_041 | "A miss against the clamped end has exactly one meaning" gains a third meaning if an async doorbell is added. Fix `ensureHeadroom`'s unsigned subtraction regardless. |

### 11.2 Candidate new rows (drafts)

- **HEAP_SNAPSHOT_001 (frozen published heap).** No runtime or kernel code writes a field or header
  of a heap object after the object has survived a GC, unless `builder == 1`. Mutator-side RC
  writes, in-place reuse and "optimized" kernel updates are forbidden on such objects. This is P1
  (§7.4.3), and it licenses concurrent marking, concurrent tenuring and en-masse promotion.
- **HEAP_SNAPSHOT_002 (mutable roots are off-heap and snapshotted).** Every location that can be
  overwritten while Elm code runs is either a stack/root slot or an off-heap store registered as
  an external root scanner. A concurrent collector reads such stores only through a copy taken at a
  handshake, never lazily.
- **FORBID_HEAP_004 (no concurrent header forwarding).** No collector thread may overwrite an object
  header the mutator can read. Concurrent forwarding lives off-header (§2.4).
- **FORBID_HEAP_005 (no identity-negative comparisons).** No code may conclude that two values are
  *different* from differing HPointer words. `a == b ⇒ equal` fast paths are allowed. This is M6
  (`ListOps::member`).
- **FORBID_HEAP_006 (no layout-dependent output).** No kernel may hash or order by heap address in a
  way that reaches program output. Parallel copying makes layout nondeterministic.
- **GC_DET_001 (deterministic GC decisions).** Every GC policy decision is a function of mutator
  allocation and of occupancy measured at a mutator sync point, never of collector progress (§10).

---

## 12. Cross-cutting conflicts and strategic forks

### 12.1 RC-1 in-place reuse vs immutability-based concurrency

`plans/opt-tier3-rc-runtime.md` is deferred, but it describes **RC-1 in-place reuse** of `count==1`
arrays and RB-tree nodes (up to ~45 % of allocated bytes by its own census). The header reserves
`refcount` bits for it (`NurserySpace.cpp:956-964`). Mutator-side count updates or in-place writes
to *published* objects break:
- the snapshot lemma, since P0/P1 stop holding;
- design C's healing and design B's replication, since a write to a stale original is lost in the
  replica: exactly the lost-update problem Brooks and Sapphire barriers exist for (HB 17.4);
- the refcount-bits forwarding option (§2.4).

The plan already favours "nursery-residency-gated first". **The compatible form is reuse restricted
to objects that have never survived a GC** (eden-resident, age 0). That is compatible with
concurrent mark, concurrent tenuring (C) and parallel STW, but *not* with pipelined regions (B).
Whichever track moves first should record this constraint in the other plan.

### 12.2 Pretenuring

Pretenuring is permanently excluded by the no-barrier design (§2.3). Any future proposal for it is
a proposal to add a remembered set.

### 12.3 The HEAP_030 read barrier

Every compiled dereference pays a tag test that is only ever exercised by dead code (old-gen
compaction has no caller). This study found **no concurrent use for it** (§2.4). If old-gen
compaction stays dead, removing the barrier is a separate stop-the-world micro-optimization.
Measure it, keeping in mind that predicted branches are cheap.

---

## 13. Where to refine next

This is a map of what to decide, not a schedule.

### 13.1 Measure first

No code design needed for these:
1. Minor-GC phase timers (§7.1): the stack walk moved inside the timer, per-root-phase and
   per-scanner times, Cheney vs promoted loops, promotion-allocation ns, sweep bytes in minor GC,
   `minflt`. Plus a per-minor event log. **This decides between designs B and C, and it sizes the
   promotion prize.**
2. Stack depth at GC (frames walked and matched). This decides whether generational stack scanning
   matters.
3. The L3 co-runner interference experiment (§7.4.4 H-L3). This decides whether *any* concurrent
   design nets its estimate.
4. A validator self-compile census of the `in_phase3_` assertion (M2/P1). This decides whether
   design C and en-masse promotion are sound.

### 13.2 Single-threaded prerequisites that pay on their own

- Fix the `ensureHeadroom` underflow (§3.2).
- Promotion buffers over swept cells, or bitmap allocation (§6.3). This is the precondition for
  every parallel or concurrent nursery design.
- Minor-GC prefetch (item 53 was skipped unbuilt; the mark-path FIFO won 12 %).
- En-masse prefix promotion, single-threaded (§7.3).
- Make the minor trigger count object bytes (for determinism under LABs).

### 13.3 The first multi-threaded step

A helper-thread pool used for **parallel STW** minor GC and mark, with a synchronous mode and
`gc_threads=1` as the reference. It needs no heap-metadata hardening, because the mutator is
stopped, and it captures the majority of the available throughput.

### 13.4 Then choose the architecture

- **Throughput-oriented** (the compiler): parallel STW everywhere, optionally plus design C to
  hide promotion entirely.
- **Latency-oriented** (worker programs): concurrent mark (§5) plus idle GC, with the §3.5
  metadata hardening.
- The two share the collector plumbing, the deterministic-decision rule and the promotion
  buffers.

### 13.5 Decisions only the team can make

- Is pause time a goal at all, or only wall time? This decides whether concurrent mark is worth
  its engineering over parallel mark.
- Adopt HEAP_SNAPSHOT_001 (P1) now, before the RC tier reactivates (§12.1)?
- What memory headroom is acceptable on the 15 GB box? This governs design B, promote-all
  snapshots and the pacing margin.

---

## 14. Stale documentation found along the way

| Location | Stale claim | Actual state |
|---|---|---|
| THEORY.md:83 | "incremental marking driven by `MARK_WORK_RATIO`" | Marking always runs to completion; the paced branch was deleted; `mark_work_ratio` is parsed but never read. |
| THEORY.md:87 | `decommit_on_oldgen_release` is `false` | It is `true` (`AllocatorCommon.hpp:177`). |
| `NurserySpace.cpp:926-928` | the large-body sweep is "Skipped if a major GC is mid-cycle" | Only compaction defers it. |
| `OldGenSpace.cpp` `freeLargeBodyCell` | has a `GCPhase::Marking` case | Dead: `gc_phase_` is never set to Marking. |
| Minor-GC timer | includes the whole minor GC | Excludes the stack walk and the large-body sweep. |
| THEORY.md:65, :208-209 | "`alloc_buffer_size` 128 KiB, `promotion_age` default 2" | Defaults are 512 KiB and 1 (`AllocatorCommon.hpp`). |
| `gc_handbook` 12.10 / 15.3 | SATB has "no floating garbage" | SATB floats *more* garbage than incremental update (§5.7). |

---

## 15. Handbook sections used

- **Marking:** HB 2.3, 2.5–2.8, 12.7–12.10, 13.4–13.7, 14.2, 14.6–14.7, 15.1, 15.3, 16.1–16.8,
  19.2, 19.5–19.6.
- **Sweeping and allocation:** HB 2.5, 2.7, 2.8, 2.10, 7.4, 7.6–7.8, 10 (Immix), 14.3, 16.6.
- **Copying:** HB 3.4, 3.10, 4.2–4.3, 4.5–4.7, 4.9, 9.5, 12.12, 13.4–13.6, 14.4, 17.2–17.11,
  19.3–19.4, 19.7.
- **Runtime interface:** HB 11.1, 11.2, 11.5, 11.6, 11.10, 12.3, 13.7.
- **Partitioning and RC:** HB 8.2, 9.4, 9.7, 9.10, 10.3, 10.4, 10.6, 18.2–18.5, 18.7.
- **Methodology:** HB 1 (MMU/BMU), 19.5; cheatsheet.md (functional-language guidance).

**Caveats about the summaries:**
- They are condensed and omit several named systems; §9 marks what comes from memory.
- Their SATB floating-garbage claim is wrong (§5.7).
- Their Sapphire summary shows a read barrier in the copy phase, whereas the original design exists
  to *avoid* read barriers by mirroring writes (§7.4.1, design E).
