# 10. Other Partitioned Schemes (Deep Summary)

This chapter surveys heap organizations beyond simple young/old splits: large-object spaces, treadmills, connectivity-based collectors, thread-local collectors, stack/region allocation, and hybrids like G1/Immix/bookmarking/ulterior RC.

---

## 10.1 Large Object Spaces (LOS)

- Large objects are expensive to move; place them in a separate space.
- Allocation: page-aligned, from free lists or page allocators.
- Collection: mark-sweep; often non-moving; may support pinning.
- Fragmentation: mitigated by coarse block sizes; free-list coalescing; can return pages to OS.

---

## 10.2 Treadmill Collectors

- Non-copying, incremental structure using circular lists (white, grey, black, free).
- Each object has pointers to next/prev in its color list; GC operations move objects between lists.
- Advantages: incremental without moving objects; fine-grained.
- Costs: extra pointers per object; list maintenance overhead; less common in modern VMs.

**State machine:** white → grey (discovered) → black (scanned) → free (reclaimed).

---

## 10.3 Topological / Connectivity-Based Collectors

- Organize heap based on graph structure (e.g., connectivity, component size).
- Collectors may prioritize regions with low connectivity for reclamation.
- More complex; less widely deployed.

---

## 10.4 Thread-Local Collectors

- Per-thread heaps (nursery + old) to reduce contention; inter-thread pointers tracked in remembered sets keyed by target thread.
- Minor/major per-thread; global coordination minimal.
- Needs inter-thread barriers to maintain remembered sets; cross-thread promotion rules.

---

## 10.5 Stack Allocation and Region Inference

- Allocate short-lived objects on stack or regions with lexical lifetimes; no GC needed for them.
- Region inference (static/auto): compiler determines lifetimes; runtime can reclaim region en masse.
- Benefits: zero GC overhead for region-scoped objects; risks: lifetime mismatches force heap allocation.

---

## 10.6 Hybrids and Regioned Collectors

- **G1/Immix-like**: heap split into regions/lines; mark lines; evacuate selected regions; partial compaction.
- **Bookmarking collectors**: reduce scan cost by bookmarking pointers at boundaries.
- **Copying in constrained space**: selective evacuation when copy reserve is limited; fallback to mark-compact.
- **Ulterior reference counting**: tracing young + RC old.

---

## 10.7 Design Considerations

- Routing rules for objects to spaces (size threshold, type, mutability).
- Remembered sets for cross-space pointers.
- Region metadata overhead vs flexibility.
- Pause control: collect/evaluate regions incrementally.

---

## 10.8 Summary

Beyond simple generational heaps, partitioned schemes tailor collection to object properties: LOS for large/pinned objects, treadmills for incremental non-moving collection, thread-local heaps for contention reduction, regions for partial compaction, and hybrids combining tracing and RC. Design hinges on routing policies, remembered sets, and balancing metadata overhead with pause/throughput goals.

