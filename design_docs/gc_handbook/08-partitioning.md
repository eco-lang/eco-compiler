# 8. Partitioning the Heap (Deep Summary)

Partitioning divides the heap into regions/areas to tailor collection policies to object properties (age, size, mobility, kind, thread, etc.). This summary covers why and how to partition, and design patterns like regioned heaps and per-thread spaces.

---

## 8.1 Why Partition

- **Mobility**: separate movable vs pinned objects.
- **Size**: large objects handled differently (LOS).
- **Kind**: pointer-free, code, metadata, arrays vs scalars.
- **Yield**: evacuate sparse regions to compact efficiently.
- **Pause reduction**: collect small regions incrementally.
- **Locality**: cluster related objects or thread-local data.
- **Thread isolation**: reduce contention; per-thread heaps.
- **Availability**: segregate real-time vs best-effort areas.

---

## 8.2 Partitioning Dimensions

- **By age**: generational (young/old), age buckets.
- **By size**: small-object vs large-object spaces.
- **By kind**: pointer-free vs pointerful; code vs data.
- **By locality**: region-based alloc (e.g., arenas) for modules/threads.
- **By mutability**: immutable vs mutable; affects barrier needs.
- **By mobility**: movable vs pinned.

---

## 8.3 How to Partition

- Fixed address ranges for each space (young, old, LOS, code).
- Region-based heaps (G1/Immix): equal-sized regions tracked individually.
- Per-thread arenas: each thread owns regions for fast allocation.
- Buckets/steps for age-based partitioning inside a generation.

---

## 8.4 When to Partition

- To bound pause times: collect small regions incrementally.
- To control fragmentation: evacuate sparse regions and sweep dense ones.
- To reduce barrier cost: isolate areas where pointers are restricted.
- To improve NUMA locality: allocate near threads.

---

## 8.5 Patterns and Examples

- **Generational**: young copy + old mark/compact; card tables for inter-gen pointers.
- **Immix/G1-style regions**: mark lines; evacuate selected regions; partial compaction.
- **Per-thread heaps**: each thread has nursery + local old; remembered sets for cross-thread pointers.
- **Large object space**: page-aligned blocks; mark-sweep or pin-only.
- **Pointer-free space**: skip tracing within; scanned only for reachability from others.

---

## 8.6 Design Considerations

- Routing allocations to the right space (size thresholds, type tags).
- Remembered sets/card tables for cross-space pointers.
- Space accounting: per-region live bytes to choose evacuation targets.
- Balancing number/size of regions vs metadata overhead.
- Promotion/demotion policies between partitions.

---

## 8.7 Summary

Partitioning tailors GC strategy to object characteristics, enabling better pause control, fragmentation management, and locality. Common schemes include generational splits, regioned heaps, per-thread spaces, LOS, and kind-based segregation. Successful designs define clear routing rules, maintain cross-space remembered sets, and track per-region liveness to drive policy decisions.

