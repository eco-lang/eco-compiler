# 4. Copying Collection (Deep Summary with Pseudocode)

Copying collectors evacuate live objects from a “from-space” to a “to-space,” leaving behind forwarding pointers and flipping roles afterward. They trade space (copy reserve) for very fast allocation and built-in compaction/locality. This summary covers Cheney semispace, traversal orders, worklists, locality, variants, and practical engineering concerns.

---

## 4.1 Semispace Copying (Cheney)

- Heap divided into two equal regions: from-space and to-space.
- Allocation: bump pointer in from-space.
- GC: copy live objects to to-space, install forwarding pointers, then flip spaces.
- Guarantees: no fragmentation; objects compacted; allocation is extremely fast (bump).

### Cheney’s Breadth-First Algorithm (Pseudocode)

```pseudo
collect():
  // Assume roots contains pointers into from-space
  // Phase 1: Evacuate roots
  for each root in roots:
    *root = copy(*root)

  // Phase 2: Scan to-space (BFS)
  scan = to_space_start
  alloc = to_space_alloc  // bumped by copy()
  while scan < alloc:
    obj = scan
    for each pointer field p in obj:
      *p = copy(*p)
    scan += size(obj)

  // Phase 3: flip
  swap(from_space, to_space)
  from_alloc = alloc - to_space_start  // live size becomes new allocation top

copy(ptr):
  if ptr == null or is_constant(ptr): return ptr
  obj = ptr
  hdr = header(obj)
  if hdr.tag == FORWARD:
    return hdr.forward_ptr
  size = object_size(obj)
  new_loc = to_space_alloc
  memcpy(new_loc, obj, size)
  to_space_alloc += size
  // install forwarding pointer in from-space object
  hdr.tag = FORWARD
  hdr.forward_ptr = new_loc
  return new_loc
```

Notes:
- BFS traversal (Cheney) improves locality for siblings; DFS variants are also possible.
- Forwarding pointer typically stored in header or object body; header reuse is common.

---

## 4.2 Traversal Order and Worklists

- **BFS (Cheney)**: uses scan/alloc pointers, no explicit stack; good cache behavior on wide graphs; deterministic order.
- **DFS**: uses explicit stack; may give better locality for deep structures; enables tail recursion to reuse stack space.
- **Worklist implementations**: single queue, double-ended queues, chunked work packets (for parallel copying).

---

## 4.3 Locality Considerations

- Copying compacts live objects; improves cache/TLB behavior.
- Traversal order affects clustering: BFS clusters siblings; DFS clusters parent-child chains.
- “Approximately depth-first” or “weighted” orders can pack hot objects together.
- Prefetch headers/fields during scan to reduce stalls.

---

## 4.4 Space and Alignment

- Requires copy reserve: to-space must fit all live data from from-space.
- Typical 2× overhead for pure semispace; mitigations:
  - Use copying only for young gen where live set is small.
  - Use sliding compaction in old gen.
  - Use smaller to-space fraction and fallback to mark-compact if overflow (copy-failure handling).
- Alignment: 8/16-byte align for predictable object starts and bitmap/card computations.

---

## 4.5 Write/Read Barriers

- For stop-the-world copying, no barrier needed.
- For concurrent/incremental copying (rare), need read barriers (Baker) to ensure mutator sees to-space object and not stale from-space; or use indirection (Brooks pointer).
- Snapshot-at-beginning barrier on stores can also be used in some concurrent copying designs.

---

## 4.6 Promotion and Generations

- Commonly used for young gen: fast alloc, short pauses.
- Promotion policy: survivors after N minor collections promoted to old gen; use age counters or survivor spaces.
- Inter-generational pointers: remember old→young edges with card tables; minor GC must treat card-marked old objects as roots (or maintain remembered set).
- Copy-failure handling: if to-space overflows, promote survivors to old gen or trigger major GC.

---

## 4.7 Variants and Hybrids

- **Copying with remembered set only**: For partial-heap copying; not full semispace.
- **Replicating collectors**: maintain multiple copies for fault tolerance (rare).
- **Train algorithm / older-first**: copy in age order to reduce promotion spikes.
- **Immix-like**: copy within lines/blocks; mix copying with bump-in-block allocation.
- **Bookmarking**: modifies copy traversal to avoid scanning pointer-free objects fully; specialized.

---

## 4.8 Handling Large Objects

- Typically avoid copying very large objects; place in LOS (large object space) managed by mark-sweep or mark-compact.
- Alternative: chunked large objects to allow partial copying; more complex.

---

## 4.9 Parallel Copying

- Divide from-space into chunks; workers steal copying work.
- Work packets: grey objects to process; each worker pops, scans children, pushes new greys.
- Need synchronization for to-space bump pointer; use per-thread to-space “PLABs” (promotion-local allocation buffers) or CAS bump pointer.

**Pseudocode (with PLAB)**
```pseudo
worker_copy():
  plab = alloc_plab()
  while obj = steal_or_pop():
    for each child in obj:
      if needs_copy(child):
        if plab.remaining < size(child):
          plab = alloc_plab()
        new_loc = plab.alloc(size(child))
        install_forward(child, new_loc)
        memcpy(new_loc, child, size(child))
        push_work(new_loc)
```

---

## 4.10 Copying Order Tuning

- “Approximately depth-first copying” can reduce to-space footprint for trees.
- Cache-aware copying may prefetch likely hot successors.
- Card/line clustering: place related objects in the same card to reduce barrier/card scanning cost in future minors.

---

## 4.11 Failure Modes and Robustness

- Copy overflow: need graceful fallback (promote or trigger full GC).
- Forwarding chain prevention: always check forwarding before copying; avoid repeated copies.
- Object parsing correctness: must not read invalid size; usually guaranteed by invariant that only live objects are copied.
- Interop/FFI: moving objects requires pinning or handles/indirection for external references.

---

## 4.12 Incremental Copying and Barriers

- Requires read barrier (Baker) to ensure every load returns to-space pointer; mutator may still hold from-space pointers.
- Brooks indirection pointer: each object has a “to-space header pointer”; mutator uses indirection to current location, allowing relocation without updating all references immediately.
- Higher overhead; often avoided in favor of stop-the-world minors.

**Baker Read Barrier (simplified)**
```pseudo
read_barrier(ptr):
  obj = ptr
  if in_from_space(obj) and header(obj).tag == FORWARD:
    return header(obj).forward_ptr
  return obj
```

---

## 4.13 Example: Copying Minor GC with Promotion

```pseudo
minor_gc():
  to_space_alloc = to_space_start
  scan = to_space_start

  // Evacuate roots
  for root in roots:
    *root = evac(*root)

  // Cheney scan
  while scan < to_space_alloc:
    obj = scan
    for child in children(obj):
      *child = evac(*child)
    scan += size(obj)

  flip_spaces()

evac(ptr):
  if ptr == null or is_constant(ptr): return ptr
  obj = ptr
  hdr = header(obj)
  if hdr.tag == FORWARD:
    return hdr.forward_ptr
  size = object_size(obj)
  if hdr.age >= PROMOTION_AGE:
    new_loc = old_gen_alloc(size)  // promotion
  else:
    new_loc = to_space_alloc
    to_space_alloc += size
  memcpy(new_loc, obj, size)
  new_hdr = header(new_loc)
  new_hdr.age = hdr.age + 1
  hdr.tag = FORWARD
  hdr.forward_ptr = new_loc
  return new_loc
```

---

## 4.14 When to Use Copying

- Pros: fast allocation, compaction by default, simple nursery collector, good cache locality.
- Cons: 2× space for full-space copying; moving objects complicate interop; large objects excluded.
- Fit: young generation in generational GC; small heaps needing predictable pauses and no fragmentation; partial-heap collectors with region evacuation.

---

## 4.15 Summary

Copying collectors move live data to a fresh space, naturally compacting the heap and enabling fast bump allocation. Cheney’s semispace BFS is the canonical form. Variations address space overhead (partial/region evacuation), parallel copying (PLABs and work stealing), and concurrency (read barriers). In generational designs, copying underpins fast minor GCs; promotion, card tables, and copy-failure handling connect it to the old generation strategy.

