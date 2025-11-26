# 14. Parallel GC (Deep Summary with Pseudocode)

Parallel GC uses multiple GC threads during stop-the-world phases to shorten pause times. This chapter focuses on parallel mark-sweep/mark-compact/copying, work distribution patterns, and contention avoidance.

---

## 14.1 Parallel Mark-Sweep

- Mark phase: multiple workers share/steal from a global work queue; each processes grey objects.
- Sweep phase: heap partitioned into chunks; threads sweep independently, building local free lists.
- Bitmaps help sweep quickly without touching headers.

**Pseudocode (mark)**
```pseudo
init_work(roots)
parallel_for worker in GC_threads:
  while obj = steal_or_pop():
    for child in children(obj):
      if try_mark(child):
        push(child)
```

**Pseudocode (sweep)**
```pseudo
parallel_for chunk in heap_chunks:
  local_free = null
  for obj in chunk:
    if mark_bit(obj) == 0:
      add_to(local_free, obj)
    else:
      clear_mark(obj)
  publish(local_free)
```

---

## 14.2 Parallel Mark-Compact

- After marking, compute liveness per block/region; assign evacuation tasks to threads.
- To avoid write races, each thread copies disjoint sets of objects to disjoint destinations (region-based evacuations).
- Forwarding pointers installed with CAS if overlaps possible.

Work packet approach: each packet describes a source block to evacuate; destinations chosen from pool of dense blocks or fresh space.

---

## 14.3 Parallel Copying

- From-space divided into ranges; workers evacuate and scan in parallel.
- To-space allocation: per-thread PLABs to avoid contention on global bump.
- Work stealing for grey objects to balance.

---

## 14.4 Load Balancing and Work Distribution

- Work stealing (Chase-Lev deques) common; avoid global locks.
- Chunking: break heap into coarse chunks to avoid too-fine overhead.
- Remembered set/card scanning can be parallelized by partitioning card ranges.

---

## 14.5 Synchronization Hotspots

- Forwarding pointer install: CAS to avoid double-copy; may leak dup copies but forwarding ensures uniqueness.
- Free list merging after sweep: reduce contention by per-thread caches; merge lazily.
- Phase transitions: atomic state flags; barrier to ensure mutators stopped.

---

## 14.6 Summary

Parallel GC reduces STW pause by dividing mark/sweep/evacuation work across threads. Core patterns: work stealing for marking/copying, chunked sweep, PLABs/TLABs for allocation without locks, and CAS-based forwarding install. Careful partitioning minimizes contention.

