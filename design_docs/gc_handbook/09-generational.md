# 9. Generational GC (Deep Summary with Pseudocode)

Generational GC exploits the weak generational hypothesis: most objects die young. It separates the heap into young (nursery) and old generations, collects young frequently with fast algorithms, and collects old less often. This summary covers layout, promotion policies, inter-generational pointers, tuning, and variants.

---

## 9.1 Basics and Layout

- Two or more generations; most systems use 2 by default (young + old).
- Young generation often uses copying (semi-space) for fast allocation and compaction.
- Old generation uses mark-sweep/compact or region-based evacuation.
- Optional intermediate generations/steps to throttle promotion.

---

## 9.2 Promotion Policies

- **En masse**: promote all survivors of young GC to old. Simple but can over-promote very young objects (nepotism).
- **Age-based**: require N survivals before promotion (age counters or survivor spaces).
- **Aging semispaces/steps**: multiple survivor spaces or buckets to delay promotion.

**Pseudocode (age counter)**
```pseudo
evacuate(ptr):
  obj = ptr
  if forwarded(obj): return fwd(obj)
  sz = size(obj)
  if age(obj) >= PROMOTION_AGE:
    dst = old_alloc(sz)
    promoted = true
  else:
    dst = to_space_alloc(sz)
    age(obj)++
  memcpy(dst, obj, sz)
  set_forward(obj, dst)
  return dst
```

---

## 9.3 Inter-Generational Pointers and Barriers

- Need to find old→young references so young GC sees complete roots.
- **Remembered sets**: track slots/card regions in old gen that may reference young.
- **Card table barrier** (common): mark a byte/bit for a card on writes into old; minor GC scans dirty cards.

**Card-marking barrier**
```pseudo
write_barrier(obj, field, new):
  obj.field = new
  if is_old(obj) and is_young(new):
    card_table[addr(obj) >> CARD_SHIFT] = DIRTY
```

- Alternative: remembered-set of exact slots (store-buffer).

---

## 9.4 Minor and Major Collection

- **Minor GC**: collect young only; roots = thread stacks/globals + remembered set/card-marked old objects. Copy survivors to to-space or promote.
- **Major/Full GC**: collect old (and often young) using mark-sweep/compact; can optionally clear remembered sets or rederive them.
- Often run minor first before major to reduce young references.

**Minor GC sketch**
```pseudo
minor_gc():
  to_alloc = to_space_start
  scan = to_space_start
  // evacuate roots
  for root in roots: root = evac(root)
  // scan dirty cards in old
  for card in dirty_cards:
    for obj in objects_in_card(card):
      for field in obj.children:
        if is_young(field): field = evac(field)
  // Cheney scan
  while scan < to_alloc:
    obj = scan
    for child in children(obj):
      child = evac(child)
    scan += size(obj)
  flip_spaces()
  clear_dirty_cards()
```

---

## 9.5 Nursery Sizing and Tuning

- Larger nursery: fewer GCs but longer minor pauses; more survivors if too large.
- Too small nursery: frequent GCs, premature promotion.
- Tuning knobs: nursery size, promotion age, GC trigger threshold (e.g., 90% full), survivor space sizes.
- Measure survivor rate to adjust promotion age/size; feedback-controlled promotion can reduce major-GC frequency.

---

## 9.6 Multiple Generations / Steps

- Add intermediate generations or steps/buckets to filter survivors further.
- Steps allow objects to age through multiple copying cycles before old-gen promotion.
- More generations increase remembered-set pressure (more cross-gen edges) and complexity.

---

## 9.7 Older-First / Beltway Variants

- **Older-first**: collect older regions before youngest if they have high garbage (older but still hot).
- **Beltway**: multiple belts (age strata) evacuated in a round-robin to smooth pause times and promotion.
- These aim to reduce long-lived garbage retention and smooth throughput.

---

## 9.8 Space Management

- Young copy needs to-space reserve; Appel-style collectors reduce reserve by copying only survivors into a single survivor space plus old-gen promotion.
- Old-gen may be mark-sweep/compact or region-based evacuation; promotion allocators (PLABs/TLABs) reduce contention.

---

## 9.9 Write Barrier Choices

- Card marking vs store buffer (remembered set of slots).
- SATB vs incremental-update in concurrent old-gen marking (if old-gen is concurrent).
- Cost model: cheap fast path is critical; limit card size to balance scan cost vs marking overhead.

---

## 9.10 Common Problems and Mitigations

- **Nepotism**: young objects kept alive by older relatives; increase promotion age, reduce en masse promotion.
- **Promotion storms**: too many survivors → old-gen pressure; add steps/survivor spaces or enlarge nursery judiciously.
- **Write barrier overhead**: choose simple card marking; avoid per-field heavy logic; batch or reduce card dirties via filtering (e.g., skip null/constant).
- **Remembered set bloat**: periodically clear/age; use card size that bounds entries.

---

## 9.11 Example: Appel-Style Minor GC

Appel collector uses one survivor space and old-gen promotion; to-space is just survivor space, not full-size.

```pseudo
minor_gc():
  survivor_alloc = survivor_start
  scan = survivor_start

  for root in roots: root = evac(root)
  for card in dirty_cards: scan_card(card)

  while scan < survivor_alloc:
    obj = scan
    for child in children(obj):
      child = evac(child)
    scan += size(obj)

  swap(nursery_from, survivor_space) // survivors now in survivor; nursery cleared

evac(ptr):
  if ptr == null or constant(ptr): return ptr
  obj = ptr
  if forwarded(obj): return fwd(obj)
  sz = size(obj)
  if age(obj) >= PROMO_AGE:
    dst = old_alloc(sz)
  else:
    if survivor_alloc + sz > survivor_end:
      dst = old_alloc(sz) // overflow promote
    else:
      dst = survivor_alloc
      survivor_alloc += sz
    age(obj)++
  memcpy(dst, obj, sz)
  set_forward(obj, dst)
  return dst
```

---

## 9.12 Interaction with Concurrency

- Concurrent old-gen marking requires barriers; minor GC typically stops the world.
- Card marks must be visible to concurrent markers; flush card caches before mark phases.
- Cross-gen pointers from young to old are naturally handled during minor GC copying.

---

## 9.13 Summary

Generational GC accelerates common-case allocation/collection by focusing frequent copying on young objects and deferring old-gen collection. Key components are promotion policy, remembered sets/card tables for old→young references, and tuned nursery sizing. Variants like steps/belts and Appel-style survivor spaces refine promotion. Barriers and remembered sets are essential for correctness; tuning balances pause time, promotion rate, and throughput.

