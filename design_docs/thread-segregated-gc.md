# Thread-Segregated Generational GC Plan

Goal: move from a shared old generation to per-thread generations (nursery + private old gen), reducing contention and STW impact while keeping predictable promotion/collection semantics.

## Design Sketch
- **Heap layout**: keep a unified reserved arena; carve per-thread regions for both nursery and thread-old-gen. Reserve a guard region or alignment to let address-range checks map to thread ownership.
- **Nursery**: keep per-thread Cheney semispace. Promotion goes to the same thread’s old gen.
- **Thread-old-gen allocator options**:
  - *Copying (semispace/slide)*: simplest, fast allocation, compacts by design. Costly 2× space; fine if thread-old-gen is bounded and promotion rates are low. Good for real-time-ish pauses when region fits in cache.
  - *Mark-compact in fixed-size regions*: region-based sliding compaction with copy reserve <100%. Less space overhead than semispace, still reduces fragmentation, pauses longer than copying.
  - *Free-list mark-sweep (current style) per thread*: lower space overhead, but fragmentation risk; avoids global contention. Add size-classed free lists to reduce fragmentation.
  - Recommendation: start with **per-thread free-list mark-sweep + optional compaction in fixed-size regions**, since code is already mark-sweep based; add a config flag to experiment with pure semispace for small thread heaps.
- **Cross-thread references**: introduce inter-thread write barrier + remembered sets per target thread. For immutable Elm data, this mainly covers FFI or process mailboxes. Card-table keyed by target heap id avoids scanning all old gens.
- **Major GC scope**: a thread collects only its own old gen, plus scans remembered-set entries from other threads that point into it. Global STW only for shared metadata changes (e.g., thread start/stop) and to snapshot remembered sets if needed.
- **Promotion policy**: keep age-threshold promotion; consider a small survivor space (or aging count) to avoid over-promoting into thread-old-gen.
- **TLABs**: keep TLABs for promotion inside each thread-old-gen; no global locking needed.
- **Compaction**: per-thread, incremental if needed. When compaction moves objects, update that thread’s remembered-set entries (and any cards referencing it) via forwarding/self-heal reads.

## Refactor Plan
1) **Add thread-heap metadata**
   - Introduce `ThreadHeap` struct (nursery + old-gen + remembered set + stats).
   - Map `std::thread::id` → `ThreadHeap` in `GarbageCollector`.
   - Define per-thread region carving policy (e.g., fixed slice from reserved heap or bump allocator from a “thread arena” high-water mark).

2) **Split old-gen into per-thread spaces**
   - Extract current `OldGenSpace` into `SharedOldGen` base and `ThreadOldGen` wrapper.
   - Parameterize allocator strategy: `mark_sweep`, `mark_compact`, `semispace` (config).
   - Add per-thread TLAB pool; remove global free-list contention.

3) **Update allocation paths**
   - `allocate()` uses current thread’s `ThreadHeap` nursery; promotion uses its TLAB/old-gen.
   - Remove global old-gen lock usage; confine to thread-local structures.
   - Handle thread init/shutdown: create/destroy `ThreadHeap` safely.

4) **Inter-thread write barrier + remembered sets**
   - Implement card/slot barrier on stores that may write cross-thread pointers (FFI, message queues).
   - Maintain remembered sets per target thread (vector of cards or coarse blocks).
   - Provide APIs to buffer cross-thread roots for GC start.

5) **Major GC workflow per thread**
   - Minor GC unchanged (nursery Cheney); survivors promote to thread-old-gen.
   - Major GC: only collect calling thread’s old-gen; trace roots from its root set + remembered-set entries pointing into it.
   - Optional global coordination hook to stagger or throttle concurrent thread GCs.

6) **Compaction adjustments**
   - Keep block metadata per thread-old-gen; reuse current compaction code but scoped per heap.
   - Ensure read/write barriers follow forwarding pointers and self-heal pointers (already present; make thread-aware).

7) **Heap discovery utilities**
   - Replace `isInNursery/OldGen` with thread-aware queries to route promotion, barrier checks, and remembered-set bookkeeping.
   - Add debugging helpers to map an address to owning thread heap.

8) **Configuration and tuning**
   - New config knobs: per-thread old-gen size/strategy, per-thread TLAB defaults, barrier mode (off/on) for immutability vs FFI mode.
   - Safety checks to prevent overcommitting reserved heap when many threads start.

9) **Testing plan**
   - Unit tests: allocation/promote/collect in single thread; cross-thread reference barrier populates remembered sets; forwarding self-heal across threads.
   - Stress: many short-lived threads allocating/promoting; mixed cross-thread messages.
   - Measure pauses/throughput vs baseline; tune default sizes and promotion age.

10) **Migration steps**
    - Phase 1: introduce `ThreadHeap` with current shared old-gen pointer (no behavior change).
    - Phase 2: clone old-gen per thread with mark-sweep allocator; remove global old-gen use.
    - Phase 3: add remembered sets + barriers; enable per-thread GC.
    - Phase 4: optional compaction/semispace modes; tuning and cleanup.

## Alternatives Considered
- **Pure semispace per thread-old-gen**: simplest, compacting, but 2× space; acceptable for small per-thread heaps, less so for memory-heavy workloads.
- **Region/immix-style per thread**: good locality and partial compaction, more engineering; consider later if fragmentation appears with mark-sweep.
- **Global shared oldest generation**: hybrid approach if cross-thread sharing dominates; defer unless needed. 
