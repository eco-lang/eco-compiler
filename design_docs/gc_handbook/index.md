# GC Handbook Reference

Detailed summaries extracted from *The Garbage Collection Handbook* (Jones, Hosking, Moss). Each chapter provides algorithms in pseudocode, implementation guidance, and trade-off analysis.

**Quick start**: See [cheatsheet.md](cheatsheet.md) for a practical guide to choosing GC strategies by runtime type.

---

## Part I: Core Algorithms

### [01-intro.md](01-intro.md) — Introduction to Garbage Collection
Why automatic memory management matters. The four fundamental approaches (mark-sweep, mark-compact, copying, reference counting). Key terminology: roots, liveness, reachability, mutator vs collector. Metrics for comparing collectors.

### [02-mark-sweep.md](02-mark-sweep.md) — Mark-Sweep Collection
The foundational tracing algorithm. Tricolor abstraction and invariants. Bitmap vs header marking. Mark stack overflow handling. Lazy sweeping for reduced pauses. Cache-conscious marking with FIFO prefetch buffers and edge marking.

### [03-mark-compact.md](03-mark-compact.md) — Mark-Compact Collection
Eliminating fragmentation through compaction. Two-finger (Edwards), Lisp2 (threaded), and sliding compaction algorithms. Forwarding pointer storage options. Break tables for space efficiency. Handling pinned and large objects.

### [04-copying.md](04-copying.md) — Copying Collection
Cheney's semispace algorithm. BFS vs DFS traversal and locality trade-offs. Forwarding pointer installation. Generational copying with survivor spaces. Parallel copying with PLABs and work stealing. Baker's read barrier for concurrent copying.

### [05-refcounting.md](05-refcounting.md) — Reference Counting
Direct collection via reference counts. Deferred and coalesced RC for reduced overhead. The cycle problem and solutions: trial deletion (Bobrow), Bacon-Rajan cycle collection, backup tracing. Concurrent RC with biased counting.

---

## Part II: Evaluation and Allocation

### [06-comparing.md](06-comparing.md) — Comparing Garbage Collectors
Metrics: throughput, pause time, space efficiency, completeness, promptness. The unified theory of GC (Bacon et al): tracing and RC as dual fixed-point computations. How to evaluate collector trade-offs for your workload.

### [07-allocation.md](07-allocation.md) — Memory Allocation
Sequential (bump-pointer) allocation. Free-list allocation: first-fit, next-fit, best-fit. Segregated-fits and size classes. Fragmentation: internal vs external. Thread-local allocation buffers (TLABs). Block-structured heaps.

### [08-partitioning.md](08-partitioning.md) — Heap Partitioning
Why partition the heap: reduce pause times, optimize by object characteristics. Partitioning by mobility (moving vs pinned), size (small vs large), age (generational), thread (thread-local heaps), and mutability.

---

## Part III: Generational Collection

### [09-generational.md](09-generational.md) — Generational Garbage Collection
The generational hypothesis: most objects die young. Young generation copying with eden and survivor spaces. Promotion policies and age thresholds. Inter-generational pointers: card tables, remembered sets, write barriers. Tuning: nursery sizing, promotion age.

### [10-other-partitioned.md](10-other-partitioned.md) — Other Partitioned Schemes
Large object spaces (LOS) with mark-sweep. The Treadmill collector for non-copying LOS. The Train algorithm for incremental old-gen collection. Thread-local heaps. G1 and Immix: region-based collectors with selective evacuation.

---

## Part IV: Runtime Integration

### [11-runtime-interface.md](11-runtime-interface.md) — Runtime Interface
Allocation interface design. Finding pointers: conservative vs precise, stack maps, register maps. Object layout requirements: headers, alignment, type descriptors. Safe points and handshakes. Handling finalizers and weak references.

---

## Part V: Parallelism and Concurrency

### [12-concurrency.md](12-concurrency.md) — Concurrency Preliminaries
Hardware memory models and why they matter for GC. Sequential consistency vs relaxed models. Memory barriers and fences. The tricolor abstraction for concurrent collection. Strong vs weak tricolor invariants.

### [13-atomics-and-sync.md](13-atomics-and-sync.md) — Atomic Operations and Synchronization
Test-and-set, compare-and-swap (CAS), load-linked/store-conditional. Building spin locks. The ABA problem and solutions. Lock-free data structures: Treiber stack, Michael-Scott queue. Work-stealing deques.

### [14-parallel-gc.md](14-parallel-gc.md) — Parallel Garbage Collection
Parallel marking with work stealing. Parallel sweeping with chunked heaps. Parallel copying with PLABs and CAS forwarding. Termination detection. Load balancing strategies.

### [15-barriers.md](15-barriers.md) — Barriers
Write barriers for generational collection: card marking, store buffers. Write barriers for concurrent marking: Dijkstra (incremental update), SATB (snapshot-at-beginning). Read barriers for concurrent copying: Baker, Brooks. Barrier implementation: inline vs out-of-line, filtering.

---

## Part VI: Concurrent Collection

### [16-mostly-concurrent-mark-sweep.md](16-mostly-concurrent-mark-sweep.md) — Concurrent Mark-Sweep
Initial mark (STW), concurrent mark, remark (STW), concurrent sweep. SATB barrier implementation. Concurrent precleaning to reduce remark pause. Pacing: allocation-based, time-based, adaptive. Mark stack overflow handling.

### [17-mostly-concurrent-copying.md](17-mostly-concurrent-copying.md) — Concurrent Copying
The challenge of concurrent relocation. Baker's to-space invariant. Brooks forwarding pointers. The Sapphire algorithm phases. Self-healing reads. Memory ordering requirements. Notable systems: Azul C4, Shenandoah, ZGC.

### [18-concurrent-refcounting.md](18-concurrent-refcounting.md) — Concurrent Reference Counting
Buffered RC to reduce synchronization. Lock-free RC with atomic operations. Split and biased reference counts. Handling cascade deletions. Concurrent cycle collection with SATB barriers. Sliding views for concurrent reconciliation.

### [19-work-based-and-real-time.md](19-work-based-and-real-time.md) — Real-Time Collection
Scheduling strategies: work-based, slack-based, time-based. Blelloch-Cheng replicating collector with provable bounds. Henriksson's slack-based collector. Metronome: time-based with arraylets. Controlling fragmentation: incremental compaction, Staccato, Schism.

---

## Quick Reference

### [cheatsheet.md](cheatsheet.md) — Implementation Cheatsheet
Practical guide organized by runtime type (functional languages, OO languages, databases, real-time, scripting). Write barrier selection. Tuning parameters. Common pitfalls. Performance targets.

