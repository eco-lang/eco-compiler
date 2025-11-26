# 7. Allocation (Deep Summary with Pseudocode)

Allocation strategies underpin GC performance. This chapter covers sequential bump, free lists (first/next/best fit), segregated fits/size classes, fragmentation management, alignment, and concurrent allocation with TLABs/PLABs.

---

## 7.1 Sequential (Bump) Allocation

- Simple pointer bump in a contiguous region; O(1) fast path.
- Requires compaction or copying GC to reclaim space; otherwise fragmentation stalls bump.
- Used in copying nurseries or in region/arena allocators.

**Pseudocode**
```pseudo
alloc(size):
  size = align(size)
  if bump + size <= limit:
    obj = bump
    bump += size
    return obj
  else:
    return null // trigger GC or region refill
```

---

## 7.2 Free-List Allocation

- Reuses freed blocks of memory; common with mark-sweep.
- Policies:
  - **First-fit**: pick first block ≥ size; fast, can fragment.
  - **Next-fit**: continue from last search position; reduces search overhead.
  - **Best-fit**: pick smallest block ≥ size; reduces external fragmentation but slower.
- Splitting/coalescing: split large blocks; merge adjacent free blocks to reduce fragmentation.

**Pseudocode (first-fit with splitting)**
```pseudo
alloc(size):
  size = max(align(size), MIN_BLOCK)
  prev = &free_list
  cur = free_list
  while cur:
    if cur.size >= size:
      if cur.size >= size + MIN_SPLIT:
        remainder = cur + size
        remainder.size = cur.size - size
        remainder.next = cur.next
        *prev = remainder
      else:
        *prev = cur.next
        size = cur.size
      return init_object(cur, size)
    prev = &cur.next
    cur = cur.next
  return null // grow heap or GC
```

---

## 7.3 Fragmentation

- **Internal**: wasted space inside allocated blocks (alignment, size classes).
- **External**: free space split into small holes unusable for large allocations.
- Mitigations: size classes (segregated fits), coalescing, occasional compaction, careful splitting thresholds.

---

## 7.4 Segregated Fits / Size Classes

- Maintain per-size-class free lists (e.g., powers of two or tuned classes).
- Fast allocation: pick class, pop from list; fallback to split larger block if empty.
- Reduces search time and external fragmentation; increases internal fragmentation by rounding up.

**Pseudocode**
```pseudo
class_index = size_to_class(size)
if freelist[class_index] not empty:
  blk = pop(freelist[class_index])
  return init_object(blk, class_size(class_index))
else:
  blk = get_from_global(size) // split larger or grow
  return init_object(blk, rounded_size)
```

---

## 7.5 Combining Strategies

- Hybrid: segregated fits for small sizes, best/first-fit for large.
- “Large object space” for objects above threshold, managed separately (page-aligned blocks).
- Use boundary tags to aid coalescing across classes.

---

## 7.6 Additional Considerations

- **Alignment**: ensure alignment for architecture and SIMD; affects bitmap/card indexing.
- **Size constraints**: cap/round sizes; avoid too many classes to save metadata.
- **Heap parsability**: maintain headers and consistent layouts for GC scanning.
- **Locality**: packing similar sizes reduces cache line churn; bump within a block helps.
- **Wilderness preservation**: keep a “wilderness” region at heap end for expansion.
- **Crossing maps**: help map interior pointers to object starts in non-copying heaps.

---

## 7.7 Allocation in Concurrent Systems

- Contention on global free lists → use TLABs/PLABs (thread-local allocation buffers).
- **TLABs**: per-thread bump regions carved from global heap; reduce locks; refilled under lock.
- **PLABs**: for promotion during copying/compaction.
- Synchronization: CAS bump pointers for TLAB creation; locks for global lists; avoid false sharing.

**TLAB refill**
```pseudo
tlab_alloc(size):
  size = align(size)
  if tlab.bump + size <= tlab.end:
    obj = tlab.bump
    tlab.bump += size
    return obj
  else:
    tlab = refill_tlab(default_size)
    if !tlab: return null
    return tlab_alloc(size)
```

---

## 7.8 Issues to Consider

- Allocation speed vs fragmentation trade-offs.
- Overhead of maintaining many free lists/classes.
- Interaction with GC: non-moving heaps need robust object-size computation.
- NUMA: allocate from local nodes; per-node free lists/TLABs.

---

## 7.9 Summary

Allocation strategy shapes GC behavior and performance. Bump allocation is ideal with moving/compact collectors; free lists and segregated fits suit non-moving heaps but must manage fragmentation. TLABs/PLABs reduce contention in multithreaded environments. Size classes balance speed and fragmentation at the cost of internal waste. Alignment and parsability are fundamental to reliable GC interaction.

