# 19. Work-Based / Real-Time Collectors (Deep Summary)

This chapter covers collectors that pace their work based on mutator activity to provide predictable latency: work-based copying, slack-based collectors, and replication-based schemes used in real-time or near-real-time systems.

---

## 19.1 Work-Based Copying (Blelloch/Cheng)

- Collector does a bounded amount of work per mutator allocation or per unit of mutator work.
- Maintain a work counter; increment on mutator actions; collector performs proportional copying/marking.
- Goal: avoid long pauses by spreading GC over time.

**Pseudocode**
```pseudo
alloc(size):
  obj = bump_alloc(size)
  work_credit += size * WORK_FACTOR
  while work_credit > 0 and gc_work_available():
    do_gc_step()
    work_credit -= WORK_PER_STEP
  return obj
```

GC step might pop a grey object and copy/scan it.

---

## 19.2 Slack-Based Collector (Henriksson)

- Maintain “slack” (available memory margin). Each allocation consumes slack; collector regains slack by collecting.
- Aims to keep slack above a threshold to guarantee real-time deadlines.
- Similar to paced/incremental collectors with explicit slack accounting.

---

## 19.3 Replication-Based (Staccato/Chicken/Clover)

- Maintain two copies and switch between them to avoid pauses; mutator runs on one copy while collector updates another.
- Use barriers to keep copies consistent; on flip, mutator switches to updated copy with minimal pause.
- High space overhead; complex barriers; designed for hard real-time constraints.

---

## 19.4 Bounded Latency Techniques

- Incremental marking/copying with strict quanta.
- Synchronize at safepoints with bounded work.
- Avoid unbounded root scanning: precomputed stack maps; limit stack size or scan incrementally.

---

## 19.5 Testing and Guarantees

- Need worst-case bounds on pause and per-allocation GC work.
- Formal analysis often required for real-time certification.

---

## 19.6 Summary

Work-based and real-time collectors pace GC to meet latency goals, charging GC work to allocations or time. Approaches include proportional work (Blelloch/Cheng), slack accounting (Henriksson), and replication-based pauseless designs (Staccato/Chicken/Clover). They trade space and throughput for predictability.

