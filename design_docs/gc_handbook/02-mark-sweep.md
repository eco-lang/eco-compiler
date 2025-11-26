# 2. Mark-Sweep (Deep Summary with Pseudocode)

This chapter expands the core mark-sweep family, focusing on correctness invariants, practical implementations, optimizations, and trade-offs. It also sketches incremental/parallel extensions because they shape real-world designs. Lengthy by design (~5k words) for CLI-friendly reference.

---

## 2.1 Core Algorithm and Invariants

**Goal**: reclaim unreachable objects without moving survivors. Two phases:
1) **Mark**: discover all reachable (live) objects from roots.
2) **Sweep**: reclaim unmarked (white) objects and return their memory to the allocator (typically as free-list nodes).

**Tri-colour abstraction**:
- White: unvisited (candidate garbage).
- Grey: discovered but not yet scanned.
- Black: discovered and all children scanned.
Correctness invariant: no black object points to white (prevents losing reachable objects).

### Minimal Pseudocode (Stop-the-World, Non-moving)

```pseudo
mark_sweep(heap, roots):
  // Phase 1: Mark
  for each root in roots:
    mark(root)

  // Phase 2: Sweep
  free_list = null
  cursor = heap.start
  while cursor < heap.end:
    hdr = header(cursor)
    size = object_size(cursor)  // robust parser is required
    if hdr.color == WHITE:
      // reclaim
      add_to_free_list(cursor, size, free_list)
    else:
      hdr.color = WHITE  // reset for next GC
    cursor += size

mark(obj):
  if obj == null: return
  hdr = header(obj)
  if hdr.color != WHITE: return
  hdr.color = GREY
  push(mark_stack, obj)
  while mark_stack not empty:
    o = pop(mark_stack)
    scan_children(o)
    header(o).color = BLACK

scan_children(o):
  for each pointer field p in o:
    if p is heap pointer:
      mark(p)
```

### Complexity
- Time: O(L + H) where L = number of live objects (mark), H = number of heap objects/blocks (sweep must visit all). Sweep can dominate when the heap is sparse.
- Space: stack/queue for grey set. For bounded-stack variants, uses pointer reversal or iterative depth-first with limited auxiliary space.

---

## 2.2 Practical Marking

### Root discovery
- **Precise**: compiler/runtime supplies exact root locations (preferred).
- **Conservative**: scans stacks/globals for bit patterns that look like pointers; avoids moving objects but can retain false positives.

### Mark stack management
- Use explicit vector/stack; can overflow → employ overflow lists or fallback to recursive traversal of already-marked objects (pointer reversal).
- Parallel marking: per-thread local stacks + global work stealing.

### Pointer finding and layouts
- Need parsable object layouts: tag/size, field descriptors, or metadata tables.
- For variable-sized objects, `object_size` must be robust and resilient to corrupted headers; often guarded by segregated layouts per type.

### Bitmap marking
- Store mark bits in a side bitmap instead of headers to reduce header writes and allow cheap sweeping.
- Addressing: `bit_index = (addr - heap_base) / alignment`.
- Sweep uses bitmap to decide liveness without touching cold objects.

### Card tables vs. remembered sets
- For mark-sweep itself, card tables not needed; but if combined with generational or incremental barriers, cards record dirty ranges to rescan.

---

## 2.3 Optimizing Sweep

### Lazy sweeping
- Delay sweeping until allocation time; spreads cost.
- Maintain “current sweep cursor”. Allocation first tries free list; when empty, sweep incrementally to replenish.
- Reduces pause; but must ensure full pass before next mark to avoid accumulating garbage.

**Pseudocode (lazy sweep skeleton)**:
```pseudo
lazy_sweep_state = { cursor = heap.start, free_list = initial }

allocate(size):
  blk = find_in_free_list(free_list, size)
  if blk: return carve(blk, size)
  // replenish
  while cursor < heap.end:
    hdr = header(cursor)
    sz = object_size(cursor)
    if hdr.color == WHITE:
      add_to_free_list(cursor, sz, free_list)
    else:
      hdr.color = WHITE
    cursor += sz
    blk = find_in_free_list(free_list, size)
    if blk: return carve(blk, size)
  // if we fall through, out of memory → trigger GC or grow
  trigger_gc_or_fail()
```

### Free-list policy
- First-fit (fast, more fragmentation), Next-fit (cache-friendly scanning), Best-fit (less fragmentation, slower).
- Segregated free lists by size class reduce search time and fragmentation.

### Coalescing
- Adjacent free blocks merged to control external fragmentation.
- Boundary tags or footer/headers help coalescing; interacts with object parsing.

---

## 2.4 Cache and Locality Considerations

- Marking touches live objects; sweeping touches the whole heap. For large heaps with sparse liveness, sweep dominates cache misses.
- Bitmap marking + block-local sweeping improves locality: sweep per block and skip all-white blocks.
- Prefetching during mark stack popping can hide latency.
- Layout-sensitive scanning: group frequently-pointed-to metadata to the front of objects; compact headers.

---

## 2.5 Incremental and Concurrent Mark-Sweep

### Motivation
- Reduce pause times by interleaving collector work with mutator execution.
- Need write/read barriers to maintain tri-colour invariant when mutator runs during marking.

### Barriers (common styles)
- **Dijkstra (incremental update)**: On pointer store `obj.f = new`, if obj is black, shade `new` grey. Prevents black→white edge creation.
- **Baker (read barrier)**: On pointer load, ensure the referent is blackened (copying collectors), less common for mark-sweep.
- **Snapshot-at-beginning (SATB)**: On pointer store overwriting old value, shade the old value; preserves view of heap as of mark start.

### Incremental marking loop (SATB style)
```pseudo
on_store(obj, field, new):
  old = obj.field
  obj.field = new
  if mutator_state == MARKING and is_heap_pointer(old):
    shade(old)  // push to mark stack/queue

incremental_mark_step(quanta):
  steps = 0
  while steps < quanta and mark_stack not empty:
    o = pop(mark_stack)
    scan_children(o)
    header(o).color = BLACK
    steps++
```

### Concurrent sweep
- Easier: sweep can run after world is stopped for mark completion and then overlap with mutators if allocator can avoid unswept regions or synchronize reuse.
- Techniques: bump “sweep frontier”; mutators allocate from already-swept regions only; requires atomic updates to free lists.

### Restart and termination
- Need a termination protocol (when mark stack empty) and a way to restart if barriers add new grey objects.
- SATB tends to have fewer rescans; incremental-update can produce more re-greying.

---

## 2.6 Parallel Mark-Sweep

- Multiple GC threads traverse the mark stack in parallel; work stealing to balance load.
- Parallel sweep: partition heap into chunks; each thread sweeps a chunk and builds local free lists; merge at end.
- Concurrency vs parallelism: parallel still stop-the-world but faster; concurrent overlaps with mutators but needs barriers.

Work packet pattern (parallel):
```pseudo
initialize_work_packets(mark_stack, roots)
parallel_for_each(worker):
  while packet = steal_or_take():
    for obj in packet:
      scan_children(obj)
      header(obj).color = BLACK
      enqueue_newly_found(packet_pool, children)
```

---

## 2.7 Interaction with Generational GC

- Mark-sweep typically manages the **old generation**; young generation uses copying.
- Requires **remembered set/card table** for old→young pointers; during old-gen mark, you must treat young objects reachable from old as roots (or perform minor GC first).
- Major GC often collects old + young together or minor-first to reduce cross-generation traversal.

---

## 2.8 Handling Large / Pinned Objects

- Moving is off the table for pure mark-sweep, so large/pinned objects fit naturally.
- Still must manage fragmentation: use a separate large-object space with coarse blocks to reduce sweep overhead; can recycle via free lists of big spans.
- For pinned objects in mostly-moving collectors, mark-sweep regions are the natural home.

---

## 2.9 Safety and Robustness

- Heap parsability: sweep must be able to walk objects even when corrupted; often use object-size tables or guarded headers.
- Overflow protection: mark stack overflow must not corrupt invariants; use overflow lists or fallback to recursive/pointer reversal.
- Fault tolerance: conservative marking on stacks can prevent freeing objects if address ambiguity exists.

---

## 2.10 Example Variants and Pseudocode

### Simple Bitmap Mark-Sweep

```pseudo
// Setup: heap divided into fixed-size blocks; each block has a mark bitmap.

mark(obj):
  if obj == null: return
  if test_mark_bit(obj): return
  set_mark_bit(obj)
  push(mark_stack, obj)
  while mark_stack not empty:
    o = pop(mark_stack)
    for child in children(o):
      if is_heap_pointer(child) and !test_mark_bit(child):
        set_mark_bit(child)
        push(mark_stack, child)

sweep_block(block):
  free_list_local = null
  for each object slot in block:
    if mark_bit(slot) == 0:
      add_to_list(free_list_local, slot)
    else:
      clear_mark_bit(slot)
  merge(free_list, free_list_local)
```

### Lazy Sweep with Allocation

```pseudo
state:
  sweep_cursor = heap.start
  sweep_end    = heap.end
  free_lists[class]  // segregated by size

alloc(size):
  cls = size_class(size)
  blk = pop(free_lists[cls])
  if blk: return init_object(blk, size)
  // replenish by sweeping incrementally
  while sweep_cursor < sweep_end:
    hdr = header(sweep_cursor)
    sz  = object_size(sweep_cursor)
    if hdr.color == WHITE:
      push_to_class(free_lists, sweep_cursor, sz)
    else:
      hdr.color = WHITE
    sweep_cursor += sz
    blk = pop(free_lists[cls])
    if blk: return init_object(blk, size)
  trigger_full_gc_or_fail()
```

### Incremental Update Barrier (Dijkstra) Skeleton

```pseudo
// invoked on every pointer store during marking
write_barrier(obj, field, new_val):
  old = obj.field
  obj.field = new_val
  if GC.state == MARKING:
    if is_heap_pointer(new_val) and color(obj) == BLACK:
      shade(new_val)  // push to mark stack
```

### Snapshot-at-Beginning (SATB) Barrier

```pseudo
write_barrier(obj, field, new_val):
  old = obj.field
  obj.field = new_val
  if GC.state == MARKING and is_heap_pointer(old):
    shade(old)
```

---

## 2.11 Fragmentation and Compaction Interplay

- Mark-sweep leaves holes; over time, fragmentation increases allocation failures despite free memory.
- Mitigations:
  - Segregated fits/size classes to keep similar-sized objects together.
  - Periodic compaction or evacuation of fragmented regions (hybrid collectors).
  - Allocation policies: prefer best-fit for large blocks, first/next-fit for small blocks to reduce large-block breakage.
- Heap growth policy: grow before fragmentation stalls allocation; shrink rarely to avoid oscillation.

---

## 2.12 Tracing Order and Locality

- Depth-first vs breadth-first:
  - DFS (stack) preserves parent-child adjacency; uses less queue space but can cause deep recursion unless iterative.
  - BFS (queue) may improve cache for wide object graphs and copying collectors; for mark-sweep, order mainly affects cache.
- Prefetch hints for child headers can reduce stalls on NUMA/large heaps.
- Chunked scanning: process heap in blocks to improve TLB and cache hit rates.

---

## 2.13 Memory Layout, Alignment, and Bitmaps

- Alignment (e.g., 8 or 16 bytes) simplifies bitmap addressing and object parsing.
- For bitmap marking, ensure bitmap alignment so `bit_index` is constant-time (shift instead of division).
- Crossing maps: optional for interior pointers; mark-sweep generally needs object starts for sweep correctness.

---

## 2.14 GC Triggers and Policies

- Common triggers: allocation threshold, heap occupancy ratio, time since last GC, external signals (low OS memory).
- Mark-sweep often paired with “occupancy threshold” (e.g., 60–70% full) to balance pause vs throughput.
- With lazy sweeping, trigger mark when free lists + unswept region below threshold.

---

## 2.15 Parallel Sweep Details

- Partition heap into equal-sized chunks; each thread sweeps a chunk independently into thread-local free lists.
- Merge phase: concatenate or keep per-thread free lists to reduce lock contention in alloc fast path (requires thread-safe selection).
- Avoid sharing writes: each sweeper resets mark bits and builds local lists to reduce cache ping-pong.

---

## 2.16 Correctness Corner Cases

- Double-free: avoided by reset-to-white protocol; sweep only frees white, then resets black to white.
- Header corruption: guard `object_size` against nonsense values (e.g., by block bounds).
- Interior pointers: mark-sweep needs to find object starts; if interior pointers allowed, must map interior → base (card/crossing maps).
- Finalizers: if supported, mark reachable finalizable objects, queue for finalization, possibly a second mark to keep resurrected reachability.

---

## 2.17 When to Use Mark-Sweep

- Pros: space-efficient (no copy reserve), supports large/pinned objects, simple allocator (free list).
- Cons: fragmentation, sweep cost proportional to heap size, pauses unless incremental/parallelized.
- Fit: old-generation management in a generational collector; environments with many large/pinned objects; memory-constrained systems where 2× space for copying is unacceptable.

---

## 2.18 Relationship to Other Algorithms

- Mark-compact: same marking, but adds relocation to remove fragmentation.
- Copying: replaces sweep with evacuation; trades space for locality and fast allocation.
- RC hybrids: mark-sweep can be fallback for cycle collection in RC systems.
- Region/Immix: incorporate block/line concepts to get partial compaction benefits while sweeping.

---

## 2.19 Implementation Checklist (pragmatic)

- Object parsing: robust size computation; tables per tag.
- Mark stack: bounded, overflow strategy.
- Roots: precise list; handle globals, stacks, registers; optional conservative scan.
- Mark bits: header vs bitmap; choose alignment to simplify.
- Sweep: coalescing + size classes; lazy sweep option.
- Barriers: only if incremental/concurrent; choose SATB vs incremental-update.
- Allocation fast path: bump or segregated free-list selection; clear headers.
- Concurrency/parallelism: locks or thread-local caches; per-thread free lists.
- Large objects: dedicated space or classes; avoid fragmentation.
- Testing: stress mark stack overflow, corrupted headers, interior pointers, cross-gen and remembered sets (if generational).

---

## 2.20 Extended Pseudocode (Stop-the-World, Size Classes, Bitmap)

```pseudo
struct Heap {
  base, end
  bitmap  // 1 bit per min_align unit
  free_lists[MAX_CLASS]
}

function gc(Heap H, Roots R):
  // Mark
  for r in R: shade(r)
  while mark_stack not empty:
    o = pop(mark_stack)
    for child in children(o):
      if is_heap_pointer(child):
        shade(child)

  // Sweep by blocks to improve locality
  for each block in H:
    sweep_block(block, H)

function shade(ptr):
  if ptr == null: return
  if test_bit(bitmap, ptr): return
  set_bit(bitmap, ptr)
  push(mark_stack, ptr)

function sweep_block(block, H):
  cursor = block.start
  free_runs = []
  while cursor < block.end:
    if test_bit(bitmap, cursor) == 0:
      // start of a free run
      run_start = cursor
      while cursor < block.end and test_bit(bitmap, cursor) == 0:
        cursor += object_size(cursor)  // or min_align if not parsable
      add_free_run(run_start, cursor - run_start, H.free_lists)
    else:
      clear_bit(bitmap, cursor)
      cursor += object_size(cursor)
```

---

## 2.21 Notes on Real Implementations

- **HotSpot CMS**: concurrent mark-sweep with incremental-update barrier; fragmentation issues → optional compaction via Full GC.
- **Boehm GC**: conservative mark-sweep; bitmap-based; incremental/concurrent options.
- **Lua**: incremental mark-sweep for tables/objects; uses tri-colour invariant and barriers.
- **Go (pre-1.5)**: stop-the-world mark-sweep; later moved to concurrent mark + sweep with pacing.

---

## 2.22 Practical Tuning Tips

- If pauses are long, add incremental marking (small quanta per allocation) or parallel mark/sweep.
- If fragmentation hurts, add size classes and occasional compaction, or switch some regions to moving collectors.
- If mark stack overflows, increase size or add overflow list; avoid recursion.
- If write barrier cost is high (incremental/concurrent), prefer SATB (lower store-barrier frequency) or coarsen the barrier with cards.

---

## 2.23 Summary

Mark-sweep is the canonical non-moving collector: straightforward to implement, space-efficient, and flexible for large/pinned objects. Its main costs are heap-proportional sweep and fragmentation, which can be mitigated with bitmaps, lazy/parallel sweep, size classes, and—when needed—periodic compaction. Incremental/concurrent variants rely on barriers to maintain tri-colour safety, enabling shorter pauses. In generational systems, mark-sweep naturally serves as the old-generation manager with remembered sets handling inter-generational pointers.

