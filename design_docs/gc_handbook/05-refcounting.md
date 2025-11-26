# 5. Reference Counting (Deep Summary with Pseudocode)

Reference counting (RC) maintains a count of references to each object and reclaims objects when the count reaches zero. It offers prompt reclamation and local work but struggles with cycles and write-barrier costs. This summary covers eager/deferred/coalesced RC, cycle handling, hybrids, and performance engineering.

---

## 5.1 Core Eager RC

- Each object has a reference count (RC) field.
- On pointer assignment: increment RC of new referent; decrement RC of old referent; when RC hits zero, reclaim recursively (cascading deletes).
- Pros: prompt reclamation, predictable local work.
- Cons: high write-barrier cost (every pointer store updates RC), cache traffic, cycles not collected.

**Pseudocode (eager, no cycles)**
```pseudo
assign(obj, field, new_ptr):
  old = obj.field
  obj.field = new_ptr
  if is_heap_ptr(new_ptr):
    inc_rc(new_ptr)
  if is_heap_ptr(old):
    dec_rc(old)

dec_rc(ptr):
  rc(ptr) -= 1
  if rc(ptr) == 0:
    reclaim(ptr)

reclaim(ptr):
  for each child in children(ptr):
    if is_heap_ptr(child):
      dec_rc(child)
  free(ptr)
```

---

## 5.2 Deferred and Coalesced RC

- Buffer decrements instead of applying immediately (deferred).
- Batch increments/decrements to reduce cache churn (coalesced).
- Apply buffered operations at safepoints or when buffer is full.

**Deferred decrement buffer**
```pseudo
dec_rc(ptr):
  buffer.push(ptr)
  if buffer.full():
    flush_buffer()

flush_buffer():
  while not buffer.empty():
    p = buffer.pop()
    rc(p) -= 1
    if rc(p) == 0:
      reclaim(p)
```

Coalesced: count occurrences per object in buffer, apply net delta once.

---

## 5.3 Cycles

- RC alone cannot reclaim cycles (objects only referenced by each other).
- Solutions:
  - **Trial deletion / backup tracing**: periodically run a tracing collector to find cyclic garbage.
  - **Cycle detection algorithms**: e.g., Bacon’s partial cycle collector, trial deletion using candidate sets.
  - **Hybrid RC + tracing**: RC for prompt reclamation, tracing for cycles.

**Trial deletion sketch**
```pseudo
candidate_set = suspected_cycle_roots()
mark_candidates(candidate_set)
for obj in candidate_set:
  if rc(obj) == internal_refs_only(obj):
    // unreachable from roots
    reclaim_cycle(obj)
```

---

## 5.4 Limited-Field / Compressed RC

- Limit RC field width to reduce header size; overflow handling (sticky high bit + overflow table).
- Trade precision for space; large fan-out structures may saturate count and force conservative retention or table lookups.

---

## 5.5 Performance Engineering

- **Barrier cost**: every pointer store becomes heavier; mitigate via:
  - Coalescing/deferred updates.
  - Avoiding increments for constants/null.
  - Specialized fast paths for intra-object initialization (bulk init without intermediate RC changes).
- **Cache locality**: RC updates are writes to scattered headers; consider biasing RC fields into hot cache lines, or using “update-avoidance” when pointer stability is high.
- **Threading**: per-thread RC buffers; atomic RC updates if shared; avoid false sharing of RC fields.

---

## 5.6 Promptness vs Throughput

- RC reclaims immediately at last release, reducing memory footprint.
- Throughput cost: frequent barrier updates; can be significant vs tracing which amortizes.
- Pause time: mostly short pauses; but cycle collection may add longer pauses if tracing-based.

---

## 5.7 Hybrids with Tracing

- **Deferred RC + periodic tracing**: use RC for fast reclamation; periodically trace to remove cycles.
- **Ulterior reference counting**: young gen tracing, old gen RC.
- **Generational RC**: RC in old gen, tracing in young; maintain inter-gen remembered sets.

---

## 5.8 Examples of RC Algorithms

- **Deferred RC (Deutsch-Bobrow style)**: buffers decrements; treats buffer flush as mini-GC.
- **Coalesced RC (Levanoni/Petrank)**: counts net changes in buffers per object.
- **Partial cycle collectors**: select candidates via heuristics (e.g., low out-degree, old objects) and perform limited tracing to prove collectability.
- **Sliding views (Yuasa, Blackburn)**: maintain two views of RCs to allow concurrent RC updates with less synchronization.

---

## 5.9 Pseudocode: Coalesced Buffer Flush

```pseudo
flush_buffer():
  table = hashmap<object, int>()
  for each entry e in buffer:
    table[e.ptr] += e.delta  // delta = -1 for dec, +1 for inc
  buffer.clear()
  for (ptr, delta) in table:
    rc(ptr) += delta
    if rc(ptr) == 0:
      reclaim(ptr)
```

---

## 5.10 Concurrency Considerations

- Atomic RC updates needed for shared objects; high contention risk.
- Per-thread buffers reduce contention; flush with synchronization.
- Concurrent cycle detection requires barriers or quiescent states to avoid missing reachability changes.

---

## 5.11 Strengths and Weaknesses

- Strengths: prompt reclamation, fine-grained locality (frees where last used), easy to integrate with systems disallowing moving objects.
- Weaknesses: cycles; high barrier cost; RC field space; performance sensitive to mutation patterns.

---

## 5.12 When to Use RC

- Systems needing prompt reclamation (streaming, low-latency memory reuse).
- Environments where moving objects is hard (interop, embedded, shared memory).
- As a component in a hybrid (RC + tracing) to get promptness without missing cycles.

---

## 5.13 Summary

Reference counting provides immediate reclamation but burdens the write barrier and misses cycles. Practical RC uses buffering/coalescing to reduce overhead and relies on tracing or specialized algorithms to collect cycles. Hybrids place RC in old generations or for specific object kinds, with tracing for the rest. Careful engineering of buffers, atomic updates, and cycle detection is required for competitive performance.

