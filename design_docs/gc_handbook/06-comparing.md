# 6. Comparing Collectors (Deep Summary)

This chapter focuses on how to evaluate and compare GC algorithms across throughput, latency, space, and implementation complexity. It also covers adaptive systems and the “unified theory” that relates tracing and reference counting.

---

## 6.1 Metrics and Trade-offs

- **Throughput**: fraction of time spent executing mutator vs GC. Copying/minor GCs often higher throughput for young objects; concurrent/barrier-heavy collectors may reduce throughput.
- **Pause time (latency)**: worst-case and distribution of stop-the-world pauses; incremental/concurrent collectors aim to cap pauses at the cost of barrier overhead.
- **Space overhead**: memory footprint, including copy reserve, fragmentation, metadata (bitmaps, cards).
- **Promptness/completeness**: how quickly garbage is reclaimed (RC is prompt; tracing is eventual).
- **Scalability**: parallel efficiency; thread contention; NUMA effects.
- **Portability/complexity**: barrier requirements, object model constraints (movable vs pinned).

---

## 6.2 Benchmarking and Methodology

- Use realistic workloads; synthetic microbenchmarks can mislead.
- Report configuration: heap sizes, GC parameters, number of threads, object size distributions.
- Measure live set, allocation rate, promotion rate, remembered set/card dirty rates.
- Present pause time distributions (percentiles), not just averages.
- Consider OS interactions (page faults, TLB, NUMA).

---

## 6.3 Adaptive Systems

- Collectors can adapt heap size, nursery size, promotion age, compaction frequency based on observed metrics (allocation rate, survival, pause targets).
- Feedback loops: e.g., increase nursery size if survival is low and pauses acceptable; trigger compaction when fragmentation or remembered set pressure high.
- Auto-tuners: require instrumentation and pacing; risk oscillation without damping.

---

## 6.4 Unified Theory: Tracing vs RC

- Tracing and reference counting are duals in terms of liveness: tracing finds reachable from roots; RC infers liveness from reference counts reaching zero.
- Hybrids exploit strengths of both: tracing for cycles, RC for promptness.
- Abstract models show how mutator writes correspond to graph edge insertions/removals; barriers maintain invariants accordingly.

---

## 6.5 Guidelines for Choosing Collectors

- **Copying/Generational**: best when most objects die young; space is available; moving objects acceptable.
- **Mark-Sweep/Compact**: when space is tight or moving is acceptable to reduce fragmentation; choose compacting if fragmentation hurts.
- **Concurrent**: when latency is key and barrier overhead acceptable; requires precise barriers and testing.
- **RC/Hybrids**: when prompt reclamation or non-moving is required; add tracing for cycles.
- **Region/Immix/G1-style**: when you want partial compaction and regional control of pauses.

---

## 6.6 Summary

Comparing collectors hinges on workload, constraints (latency vs throughput vs space), and implementation complexity. Metrics must include pause distributions, throughput impact, and memory overhead. Adaptive strategies tune parameters dynamically. No single collector wins universally; design is a choice of trade-offs informed by measurements.

