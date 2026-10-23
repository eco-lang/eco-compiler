# 06 — Draft invariants, verification, open questions

## 6.1 Draft invariants

Candidates for `design_docs/invariants.csv` once a design is chosen. Names
are placeholders.

| Draft id | Statement |
|---|---|
| HEAP_MT_001 | One mutator per heap; several heaps per process (amends HEAP_007). |
| HEAP_MT_002 | **Closure (S1):** memory reachable by more than one thread never points into any thread's heap; only into itself, other shared memory, embedded constants or static data. |
| HEAP_MT_003 | **Immutability (S2):** shared memory is never written after publication, except metadata kept outside the objects and forwarding written by a receiver into memory it owns exclusively. |
| HEAP_MT_004 | **Age order (S3):** shared memory points only to shared memory published before it; the shared graph is acyclic. |
| HEAP_MT_005 | A ring record is referenced by no heap object or root once the consumer's read cursor has passed it (lazy copy-out: after the end-of-update escape scan). |
| HEAP_MT_006 | An arena in transit has exactly one owner at a time; adoption registers it with the receiving heap before any of its objects are used. |
| HEAP_MT_007 | In an unsealed append-only log, the consumer's GC neither allocates, frees, moves nor decommits anything at or above the last page boundary below the published write pointer read at the start of the collection. |
| HEAP_MT_008 | A thread's set of referenced shared memory includes references from promoted objects, recorded at promotion time. |
| HEAP_MT_009 | Message types are sendable: no per-thread kernel handles unless the type has transfer semantics. |
| HEAP_MT_010 | Publication of a record, arena or log prefix is a release store; consumption begins with an acquire load. |

## 6.2 Verification

- **TLA+ models** (alongside `test/tla/`; the canary rule in `test/tla/README.md` applies once the
  allocator code exists):
  - ring protocol: commit flags, cursors (single, *k* readers, claim cursor
    with out-of-order completion), the sleep/wake flag (lost wakeups);
  - lazy copy-out slot lifecycle including a minor GC mid-update;
  - append-only log: publish, consumer GC bounds, seal, rotation counts;
  - reference counting with thread-held sets and in-flight counts;
  - the weak-memory variant (the existing W model) for every publication.
- **GenMC** for the ring and log implementations under the C11 memory model.
- **Heap validation** (validate builds): after every `update`, no pointer into
  a freed ring record; poisoned freed records; no thread-to-shared pointer
  missing from the thread's referenced set; no shared-to-thread pointer.
- **TSan** targets for every hand-off path.

## 6.3 Open questions

1. **Thresholds:** the record size below which copy-out is eager (and the
   ring is used at all) versus lazy or arena transfer. Measure.
2. **Minor-GC cost of lazy copy-out:** the "held ring record?" range check in
   the copy loop. Measure before committing to lazy copy-out.
3. **Nursery walkability** for the end-of-update escape scan: per-site
   zeroing, capacity reservations, multiple nursery regions.
4. **Adoption mode** for tier B arenas: young (evacuated by the next minor GC)
   or old. Default proposed: young.
5. **Tier C granularity:** per arena with copy-out on long retention, or per
   object. Start per arena; move only if pinning is measured to matter.
6. **Back-references in append-only logs** (delta streams): allow (consumer
   cannot evacuate unsealed prefixes; producer keeps a copy map of its
   old-generation objects) or forbid (simpler; no structural sharing).
7. **Broadcast slow-consumer policy:** throttle, bounded lag with
   disconnect, or overflow.
8. **Sendable rule:** a compiler constraint, kernel transfer semantics for
   chosen handles, or both; which handles transfer (HTTP request handles,
   sockets).
9. **Compiler escape analysis** of `update` to skip copy-out for messages
   that never escape.
10. **Wake-up mechanism** and spin budget per platform (eventfd, kqueue).
11. **Ring sizing and memory per pair** for MPMC push at large thread counts.
12. **JS backend parity** for each tier (structured clone, transferables,
    `SharedArrayBuffer`).
