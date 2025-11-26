# 12. Concurrency & Parallelism (Deep Summary)

This chapter covers parallel and concurrent GC, barriers, termination, and supporting synchronization primitives. Parallel = GC threads in stop-the-world; concurrent = GC overlaps with mutators. Copying, mark-sweep, and compaction all have concurrent/parallel variants.

---

## 12.1 Parallel GC

- Stop-the-world, multiple GC threads.
- **Parallel mark**: shared/stealable worklists; per-thread mark stacks; work stealing balances load.
- **Parallel sweep**: divide heap into chunks; threads sweep independently, build local free lists; merge.
- **Parallel copy**: divide from-space; use PLABs for to-space bumps; work stealing of grey sets.

**Work packet pattern**
```pseudo
initialize_packets(roots)
parallel_for worker in GC_threads:
  while packet = steal_or_take():
    for obj in packet:
      scan_children(obj)
      push_new_children(packet_pool)
```

---

## 12.2 Concurrent Marking

- Mutator runs during marking; must maintain tri-colour invariant with barriers.
- Barriers:
  - **Incremental update (Dijkstra)**: on store, shade new target if source is black.
  - **Snapshot-at-beginning (SATB)**: on store, shade old value to preserve “as-of-start” heap snapshot.
  - **Baker read barrier**: on load, ensure object is marked/moved (common in concurrent copying).
- Mark loop runs in small quanta or on dedicated threads; termination when mark stack drains and no new greys are added (consider barrier buffers).

**SATB store barrier**
```pseudo
write(obj, field, new):
  old = obj.field
  obj.field = new
  if GC.state == MARKING and is_heap_ptr(old):
    shade(old)
```

---

## 12.3 Concurrent Sweep / Compaction

- Sweep can run concurrently if allocator avoids unswept regions or coordinates reuse.
- Compaction concurrent/incremental requires indirection or barriers (Brooks pointer, load barrier) to avoid stale references while moving.
- Partial/region evacuation used to bound pause.

---

## 12.4 Pauseless / Mostly-Concurrent Copying

- **Brooks pointer/indirection**: each object points to its current location; reads follow indirection; moves happen concurrently; eventual self-heal.
- **Sapphire** and similar algorithms: phase-based barriers for read/write; flip phases coordinate mutators and collector.
- Overhead: read barrier on every load; higher steady-state cost vs STW minors.

---

## 12.5 Termination Detection

- Need to know when marking is done with concurrent barriers.
- Techniques: global work counters, quiescence detection, barrier buffers drained.
- Algorithms: Dijkstra’s token rings, work-stealing with counters, epoch-based schemes.

---

## 12.6 Synchronization Primitives

- CAS/LL-SC for installing forwarding pointers or updating state.
- Spin locks, test-and-set; backoff strategies for GC metadata.
- Atomic state transitions for GC phases (marking, sweeping, compacting).

---

## 12.7 Pacing and Scheduling

- Incremental GC: run small slices per allocation or timer to meet pause targets.
- Concurrent GC: throttle GC threads based on mutator utilization to avoid oversubscription.
- Coexistence with OS schedulers; NUMA-aware placement.

---

## 12.8 Read/Write Barrier Costs

- Read barriers are more frequent than writes; designs prefer write barriers unless copying/concurrent move demands read barriers.
- SATB typically cheaper than incremental-update (fewer re-greys).
- Optimize barrier fast path: minimal branches; card granularity tuning.

---

## 12.9 Example Concurrent Mark (SATB) Loop

```pseudo
// Mutators perform SATB barrier on stores

mark_thread():
  while GC.state == MARKING:
    // process local buffer first
    while local_buffer not empty:
      obj = local_buffer.pop()
      if mark_bit(obj) == 0:
        set_mark_bit(obj)
        for child in children(obj):
          if mark_bit(child) == 0:
            push(global_mark_stack, child)
    // steal from global work if idle
    obj = pop(global_mark_stack)
    if obj:
      if mark_bit(obj) == 0:
        set_mark_bit(obj)
        for child in children(obj):
          if mark_bit(child) == 0:
            push(global_mark_stack, child)
    else:
      if buffers_empty_globally(): attempt_termination()
```

---

## 12.10 NUMA Considerations

- Allocate and collect within NUMA node to reduce cross-node traffic.
- Local mark stacks and region ownership per node; avoid stealing across nodes unless idle.
- Card/remembered sets kept node-local when possible.

---

## 12.11 Summary

Parallel GC reduces stop-the-world time via multiple GC threads. Concurrent GC overlaps collection with mutator, requiring barriers and careful termination. Concurrent marking is common; concurrent compaction/copying is harder and uses read barriers or indirection. Pacing, barrier efficiency, and region-based partial collection are key to usable latency.

