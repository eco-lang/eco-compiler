# 16. Mostly-Concurrent Mark-Sweep (Deep Summary with Pseudocode)

Mostly-concurrent mark-sweep collectors overlap marking with mutator execution to reduce pause times. They rely on barriers to maintain the tri-colour invariant and often keep sweeping stop-the-world or partially concurrent.

---

## 16.1 Shape of the Algorithm

1) Initial mark (often STW): mark roots, seed mark stack.
2) Concurrent marking: mutators run with write barriers; GC threads drain mark stack.
3) Remark (short STW): catch up missed references, process buffers.
4) Sweep: often stop-the-world, but can be concurrent with allocation discipline.

---

## 16.2 Barriers

- **Incremental-update**: shade new targets on writes from black objects.
- **SATB**: shade overwritten old values to preserve snapshot.
- Both prevent black→white edges during concurrent marking.
- Minor GC interaction: card tables/store buffers for old→young still required.

---

## 16.3 Incremental Marking Loop

```pseudo
// mutator store barrier (SATB)
write(obj, field, val):
  old = obj.field
  obj.field = val
  if GC.state == MARKING and is_heap_ptr(old):
    shade(old)

// concurrent marker
mark_loop():
  while GC.state == MARKING:
    obj = pop_work()
    if !obj: if try_terminate(): break else continue
    if mark_bit(obj) == 0:
      set_mark_bit(obj)
      for child in children(obj):
        push_work(child)
```

Remark phase: stop-the-world, drain all buffers, rescan dirty roots/stacks to close the world.

---

## 16.4 Sweep

- STW sweep: straightforward; rebuild free lists.
- Concurrent sweep: allocator must avoid unswept regions or synchronize reuse; maintain a “sweep frontier.”
- Lazy sweep can overlap with mutators if allocation only uses swept areas.

---

## 16.5 Pauses and Pacing

- Initial mark and remark are pauses; tuning aims to keep them short (scan roots, drain buffers quickly).
- Concurrent marking paced by allocation or time to avoid starving mutator.

---

## 16.6 Correctness Concerns

- Barrier coverage: all pointer writes during marking must be barriered; un-barriered paths cause missed edges.
- Stack/regs: must be treated as roots; stacks may change during marking; remark rescans to capture latest.
- Mark stack overflow: use overflow queues or restart marking chunks.

---

## 16.7 Interaction with Generations

- Old-gen concurrent marking with generational minors: must process card tables/remembered sets to see young references, or perform a minor GC before/within remark.
- Barriers already present for generational remembered sets can be combined with concurrent marking needs.

---

## 16.8 Summary

Mostly-concurrent mark-sweep reduces pauses by moving marking off the STW path, using barriers to maintain correctness. Initial and remark pauses remain; sweep may be STW or partially concurrent. Proper barriers, buffer draining, and pacing are key to correctness and performance.

