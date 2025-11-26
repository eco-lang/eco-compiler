# 15. Barriers (Deep Summary)

Barriers maintain GC invariants when the mutator runs concurrently with or between collections. They intercept reads or writes to update remembered sets, maintain tri-colour safety, or ensure mutators see the correct object version.

---

## 15.1 Write Barriers

- **Incremental update (Dijkstra/Steele)**: on store of `new` into black object, shade `new` grey to prevent black→white edge.
- **Snapshot-at-beginning (SATB)**: on store, shade the overwritten `old` value to preserve the mark snapshot.
- **Card marking**: coarse-grain; set card dirty bit/byte when writing into an object (often old-gen). Minor GC scans dirty cards.
- **Store buffer**: push address of updated slot into buffer; processed at GC.

**Incremental update example**
```pseudo
write(obj, field, val):
  old = obj.field
  obj.field = val
  if GC.marking and color(obj) == BLACK and is_heap_ptr(val):
    shade(val)
```

**SATB example**
```pseudo
write(obj, field, val):
  old = obj.field
  obj.field = val
  if GC.marking and is_heap_ptr(old):
    shade(old)
```

---

## 15.2 Read Barriers

- Ensure mutator sees up-to-date/forwarded/mutator-safe object.
- **Baker**: on load, if object in from-space, evacuate/return to-space copy; used in concurrent copying.
- **Brooks indirection**: each object has an indirection pointer to current location; reads follow indirection.
- Costly (every read), so typically used only when needed (concurrent copying/compaction, pauseless collectors).

```pseudo
read(ptr):
  obj = ptr
  if in_from_space(obj) and header(obj).tag == FORWARD:
    return header(obj).fwd
  return obj
```

---

## 15.3 Mutator Barriers for Generational GC

- Card marking or store buffer to record old→young pointers.
- Frame-based barriers (on function exit) are rarer; typically simpler card/store barriers suffice.

---

## 15.4 Barrier Costs and Tuning

- Fast path must be minimal: few branches, simple operations.
- Card size tuning: larger cards → fewer writes but more scanning; smaller → more card dirties.
- SATB vs incremental-update: SATB tends to fewer re-greys; incremental-update may shade more often.
- Filtering: skip null/constant writes; combine adjacent writes; thread-local buffers to batch.

---

## 15.5 Barrier Correctness

- Must maintain tri-colour invariant: no black→white edges unshaded.
- Ordering: memory barriers as needed so that published pointers are visible to collector.
- Avoid dropping entries: store buffers must be drained before GC phases end; card tables flushed.

---

## 15.6 Summary

Barriers are essential for generational remembered sets and concurrent/incremental collection. Write barriers (card, store buffer, SATB, incremental-update) are most common due to lower frequency than reads. Read barriers appear in concurrent copying/compaction with moving objects. Barrier design balances correctness, overhead, and scan granularity.

