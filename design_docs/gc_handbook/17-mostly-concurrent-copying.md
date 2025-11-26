# 17. Mostly-Concurrent Copying (Deep Summary)

Concurrent or mostly-concurrent copying collectors move objects while mutators run, using barriers to maintain consistency. Techniques include read barriers (Baker), indirection (Brooks pointers), and phased algorithms (e.g., Sapphire).

---

## 17.1 Core Idea

- Evacuate objects from from-space to to-space while mutators may still reference from-space.
- Ensure every access yields the to-space copy via barriers or indirection.

---

## 17.2 Read Barriers (Baker)

- On load, if object is still in from-space (not yet evacuated), evacuate or forward to to-space; return to-space pointer.
- Ensures mutator always sees the latest copy; from-space references can remain but are translated on access.

```pseudo
read(ptr):
  obj = ptr
  if in_from_space(obj):
    fwd = header(obj).fwd
    if fwd == null: fwd = evacuate(obj)
    return fwd
  return obj
```

---

## 17.3 Brooks Indirection

- Each object has an indirection pointer (often first word) to its current location.
- Mutator loads via the indirection; collector updates indirection when moving object.
- Reduces per-load logic to one indirection; avoids conditional evacuation on each read.

---

## 17.4 Sapphire-style Phases

- Phased barriers for mark/copy/flip; ensures consistent handling of reads/writes during concurrent copying.
- Uses read/write barriers tuned per phase to manage forwarding and equality checks.

---

## 17.5 Write Barriers

- Needed to keep to-space up to date: if mutator writes to object, write must go to to-space copy or be replayed.
- Commonly, mutator always writes through the forwarded/indirected location to avoid divergence.

---

## 17.6 Equality and Identity

- Must ensure pointer equality semantics are preserved; often normalize pointers to to-space in mutator.
- Self-healing: once read barrier translates a pointer, mutator stores/uses the translated version to reduce repeated barriers.

---

## 17.7 Interaction with Generations

- Concurrent copying usually for young gen is rare (minors are typically STW). More common for whole-heap concurrent copying in pauseless designs.
- Generational card/store barriers still needed for cross-gen pointers.

---

## 17.8 Correctness and Termination

- Invariant: all reachable objects eventually forwarded; all pointers the mutator sees point to to-space.
- Termination when work queues empty and no pending evacuation from barriers.

---

## 17.9 Costs

- Read barrier on every load is expensive; Brooks indirection reduces conditional logic but adds pointer chasing.
- More common in hard real-time/pauseless collectors where latency trumps throughput.

---

## 17.10 Summary

Mostly-concurrent copying relies on read barriers or indirection to make mutator accesses see to-space copies while evacuation proceeds concurrently. It preserves low pause times at the cost of steady-state barrier overhead. Phased algorithms (Sapphire) refine barriers per phase to manage forwarding and equality.

