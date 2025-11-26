# 18. Concurrent Reference Counting (Deep Summary)

Concurrent RC variants aim to reduce pause times and contention by buffering updates and performing decrements/collection concurrently. They still need solutions for cycles and synchronization of RC updates.

---

## 18.1 Buffered/Deferred RC

- Decrements (and sometimes increments) are buffered per thread; flushed asynchronously.
- Reduces barrier cost on the mutator; flush threads process buffers to update RCs and trigger reclamation.

**Pseudocode**
```pseudo
dec(ptr):
  buf.push(ptr)
  if buf.full(): flush_buf(buf)

flush_buf(buf):
  for p in buf: rc[p] -= 1; if rc[p] == 0: reclaim(p)
  buf.clear()
```

---

## 18.2 Sliding Views

- Maintain two “views” of RC: mutator-visible stable counts and collector-visible deltas.
- Allows concurrent processing of updates with less synchronization; collector reconciles deltas periodically.

---

## 18.3 Locks vs CAS for RC Updates

- Atomic RC updates (fetch-add) for shared objects; per-thread ownership for thread-local objects to avoid atomics.
- CAS-based RC can break under ABA; use wide RC fields or versioning.

---

## 18.4 Cycles in Concurrent RC

- Same cycle problem as sequential RC; use concurrent tracing or trial deletion in background threads.
- Barriers/handshakes may be needed to get a consistent snapshot for cycle detection.

---

## 18.5 Interaction with Tracing

- Hybrids: run concurrent RC updates; periodically trigger tracing for cycles. Mutator barriers may be minimal if tracing is full-heap and STW; more complex if tracing is concurrent.

---

## 18.6 Performance Considerations

- Buffer sizes vs latency: larger buffers reduce overhead but delay reclamation.
- Contention on RC fields: use padding to avoid false sharing; segregate hot headers.
- Batch reclamation to reduce cache churn.

---

## 18.7 Summary

Concurrent RC relies on buffering/coalescing and sometimes sliding views to reduce write-barrier cost while keeping reclamation timely. Cycle handling still requires tracing or specialized algorithms. Atomicity, contention control, and buffer management are key engineering points.

