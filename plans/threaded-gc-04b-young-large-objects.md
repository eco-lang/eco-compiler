# Threaded GC 04b — Young large objects (restore HEAP_005 without exceptions)

**Status:** PLANNED (2026-09-26). Written against the `keep-TG4` tree (`bin/eco-opt-prev` =
`eco-optTG4`; reference MLIR `ecoghash.mlir`). **Scheduled before phase 5a**: the remaining GC
phases build on HEAP_005, HEAP_BUILDER_001 and HEAP_SNAPSHOT_001, and those should carry no
special cases.

**Parent:** `plans/threaded-gc-master-plan.md` (inserted as phase 4b).

**Replaces:** HEAP_061, the born-old pending list, from `plans/threaded-gc-04-frozen-published-heap.md`
Step 7b.

**Background:**
- TG4 P§2a S2 (the hazard);
- HEAP_026 / HEAP_056 (split-header bodies: the existing "old-gen cell owned by the young
  generation" machinery this plan reuses);
- the design discussion of 2026-09-26, options 1–4.

§n points into `design_docs/parallel-gc.md`, P§n into this plan, 04-P§n into the phase 4 plan.

---

## 0. What this phase delivers, and why

**The hazard (TG4 S2).**
- A pointer-bearing object of `size >= large_object_threshold` (8 KiB) that reaches
  `ThreadLocalHeap::allocate`'s slow path is placed in the **old gen** (`allocateLargePinned`).
- Its kernel then fills it with pointers, some of them young.
- No minor GC scans old objects, so those young children were lost.

**The TG4 fix (HEAP_061)** registers such objects in a pending list that every minor scans as
roots until the children are old. It works, but it makes old→young pointers legal (an exception
to HEAP_005, and to HEAP_BUILDER_001 for large builders), and every later phase must honour that
exception:
- 5a: snapshot roots;
- 6: parallel scanning of the list;
- 7b/7c: survivor regions;
- compaction: already skipped while the list is non-empty.

**This phase removes the exception** by making every such object **young** until it is promoted,
exactly like any other object:

| option | what | role |
|---|---|---|
| **3. Nursery placement** | Pointer-bearing large objects up to a cap are allocated **in the nursery**. The cap is the smaller of a relative bound (`large_ptr_nursery_divisor`, default ⅛ of the per-side nursery: 8 MiB at start, 16 MiB at the 128 MiB cap) and a fixed, tunable size (`large_ptr_nursery_max_size`, e.g. 128 KiB or 1 MiB; chosen by experiment E1) | the common case, with no new machinery. Most of these objects already land there today through `eco_alloc_with_roots`' size-blind bump fast path |
| **4. Young large-object space (YLOS)** | Above the cap, or when the nursery cannot fit the object after a GC: a **non-moving young object**. Its cell sits in the old-gen address range, is traced by the minor GC when reachable, ages like a nursery object, is **promoted in place** (a flag flip, no copy), and is freed at a minor when unreachable | the giants. HEAP_005 becomes literally true again: the young generation = nursery ∪ YLOS |
| **2. Kernel change** | JSON arrays of more than ~1,020 elements are stored **chunked** (a two-level array of ≤ 8 KiB pieces) instead of one flat `ElmArray`; the other kernels are covered by a census plus a guard | removes the only input-driven source of large flat arrays |

Option 1 (force a minor at creation) is **rejected**:
- a safe promotion of young objects needs a full minor, since only it updates every reference;
- the minor would need a promote-the-subgraph mode that doesn't exist;
- it doesn't cover builders filled across allocations;
- it pays a full pause per large array.

| # | Deliverable |
|---|---|
| D0 | A census of pointer-bearing large allocations (by tag, placement, call site) on the self-compile, E2E, stress and a JSON microbenchmark: the baseline |
| D1 | Placement policy: `tagMayHoldPointers(tag)`, two configs that bound nursery placement, `large_ptr_nursery_divisor` (relative; default 8; 0 = never nursery) and `large_ptr_nursery_max_size` (fixed bytes; 0 = no fixed bound), and one routing function used by every large-allocation entry point |
| D2 | Option 3: nursery placement in `allocate`, `allocateSlow` and `allocateRegionSlow`, with the fail-soft to YLOS |
| D3 | Option 4: YLOS on top of the HEAP_026 body index (`LargeBodyMeta.kind`), the minor-GC reach/scan/age/promote-in-place path, the bounding-box filter in the evacuation copiers, and freeing through the existing `sweepNurseryLargeBodies` / `retireDeadLargeBodies` |
| D4 | Removal of HEAP_061: the born-old list, `OldGenBornOld.cpp`, the compaction guard, the `markOneObject` / `clear_builder` exceptions, and detector W's exception |
| D5 | Option 2: chunked JSON arrays behind two accessors, `jsonArrayLength` / `jsonArrayAt` |
| D6 | Guard + stats: banner counters for large pointer allocations by placement; a validate-build trace of call sites |
| D7 | P1 census updates (W knows YLOS ages; O records in-place promotions; N covers YLOS survivors) |
| D8 | Tests (unit, negative controls), gates, measurement, invariants, docs, tracking row |

**Out of scope:**
- large **pointer-free** objects: strings and byte buffers keep the HEAP_026 split header;
  pointer-free `Tag_Array`s are treated as pointer-bearing, because the tag cannot tell;
- any change to the promotion policy for small objects;
- any concurrency.

---

## 1. Ground rules

1. **Invariants first, then numbers.** The exit condition is:
   - HEAP_005 strict, with no exception;
   - HEAP_BUILDER_001 phrased over the young generation;
   - HEAP_061 retired.

   Performance must not regress beyond noise on the self-compile.
2. **Placement may change GC counters deliberately.** Objects that used to go to the old gen now
   go to the nursery or YLOS, which can change minor counts, copied and promoted bytes. Every
   delta must be explained by D0's census: if the census shows 0 pointer-bearing large
   allocations on a workload, its counters must be **identical**. `out.mlir` is always
   byte-identical.
3. **HEAP_031/034 are untouched.** Compiled-code inline allocation stays ≤ 4 KiB, and compiled
   stores go only to fresh objects.
4. **A YLOS object obeys every rule a nursery object obeys** (age, builder, promotion
   predicate), except that it never moves. If a rule needs a YLOS special case, first check
   whether the design is wrong.
5. **Assert what you rely on** (M§2): validators V1–V5 (P§3.8) in the validate tree; negative
   controls for the scan path and the free path.
6. The standing gates: E2E, elm-tests, `full`, stress under GC pressure, the validate tree with
   the P1 tripwire, the census tree in abort mode, stats-off build, `out.mlir` byte-identical,
   bootstrap fixed point.

---

## 2. Verified facts

Verified 2026-09-26 against `keep-TG4`. Line numbers are in `runtime/src/allocator/` unless a
path is given. **Re-verify before editing.**

| # | Fact | Where |
|---|---|---|
| F1 | `ThreadLocalHeap::allocate`: `size >= large_object_threshold` → `allocateLargePinned(size, tag)` (old gen, `pin = 1`), **for every tag**. `allocateSlow` has the same branch. `allocateSlowRaw` asserts the size is below the threshold (compiled inline sizes). | `ThreadLocalHeap.cpp:~196`, `allocateSlow` `~:262`, `allocateSlowRaw` `~:290` |
| F2 | `allocateRegionSlow` has **two** identical `total >= large_object_threshold` branches (the second is dead code shadowed by the first), both allocating the region with `old_gen_.allocate(total)`. | `ThreadLocalHeap.cpp:~345-380` |
| F3 | `eco_alloc_with_roots` tries `Allocator::allocateFast(size)`, a nursery bump **with no size check**, before `allocateSlow`. So a large object lands in the nursery whenever it fits, and in the old gen only when the bump misses. This is why S2 was intermittent. | `RuntimeExports.cpp:149-174` |
| F4 | `allocateLargePinned` registers pointer-bearing tags in `OldGenSpace::born_old_` (HEAP_061, TG4). `allocateRegionSlow` registers regions. | `ThreadLocalHeap.cpp` (TG4 edits) |
| F5 | The minor GC's copiers return early for anything not in from-space: `evacuate` (`NurserySpace.cpp:1195`, the `!isInFromSpace(obj)` return near `:1284`), `evacuateJitPtr` (`:1493`), `evacuateValueSlot` (`:1589`). List spines (`evacuateListSpine` `:2004`) handle cons/chunk nodes only, which are never large. | `NurserySpace.cpp` |
| F6 | Promotion: `shouldPromote(hdr)` = `age >= promotion_age_ && !pin && !builder`. Evacuation copies the object and increments the copy's age unless it is a builder. A promoted copy is pushed on `promoted_objects` and scanned with `in_phase3_ = true`, where young children of a promoted parent are copied to to-space (re-drain loop). | `NurserySpace.hpp:358`, `NurserySpace.cpp:1320-1420` |
| F7 | HEAP_026 bodies: `OldGenSpace::allocateLargeBody(total, logical, tag, initial_color)` (it asserts a string/bytes tag), `registerLargeBody`, `LargeBodyMeta {body_base, cell_size, is_large, color}`, `large_body_index_` (address → id), `nursery_owned_bodies_`, `markLargeBodySeen(body, minor_color)`, `promoteLargeHeader(body)` (removes from the nursery-owned list), `sweepNurseryLargeBodies(minor_color)` (at minor end, frees bodies whose color ≠ the current minor color; deferred during compaction), and `freeLargeBodyCell` (correct accounting for is_large blocks and size-class cells, in every GC phase). | `OldGenSpace.hpp:296-316, 780-791, 1186-1194`, `OldGenSpace.cpp:4881-5050` |
| F8 | `minor_color_` flips at the start of every minor (`NurserySpace.cpp:439`). Headers seen during the minor record the new color. `sweepNurseryLargeBodies` runs at minor end (`:1135`). | `NurserySpace.cpp` |
| F9 | The major GC traces **through nursery objects** from the roots (`startMark` pushes nursery objects; `markOneObject` calls `markChildren` for nursery objects, deduped by `nursery_visited_`). So an old-gen cell reachable only via nursery objects is marked. `retireDeadLargeBodies` (HEAP_056, bitmap mode) erases unmarked nursery-owned bodies at mark end, before any cell can be reused. | `OldGenSpace.cpp:2031-2040, 2350-2356`; HEAP_056 |
| F10 | Compaction does not move pinned objects (`if (hdr->pin)` in the evacuation slice, `:4417`), and skips is_large blocks. | `OldGenSpace.cpp:4332, 4417` |
| F11 | JSON arrays: `jsonToHeap` builds `CTOR_JSON_ARRAY` (105) = `Custom{values[0] = ElmArray}` via `arrayFromPointers` over **all** elements. Readers of the payload: `heapJsonToNlohmann` (`:431`), the `list` decoder (`:648`), the `array` decoder (`:754`), the `index` decoder (`:988`), plus the dispatch at `:1360`. | `elm-kernel-cpp/src/json/JsonExports.cpp` |
| F12 | Elm's `Array` is a 32-way tree (`JsArray` leaves ≤ 32), so `Array.fromList` / `Array.initialize` never make large `JsArray`s. The flat-array producers are JSON (F11), the `Elm_Kernel_List_toArray` fallback for non-list input (`ListExports.cpp:376-406`, rare), `allocArrayBuilder` at a large capacity, and closure-group regions (`eco_alloc_closure_group_slow` → `allocateRegionSlow`). | as listed |
| F13 | `NurserySpace::capacityBytes()` (TG4) gives the current per-side capacity: 64 MiB initially, 128 MiB at the cap (`NURSERY_BLOCK_COUNT` 256, `NURSERY_MAX_BLOCKS` 512, `ALLOC_BUFFER_SIZE` 512 KiB). | `NurserySpace.hpp`, `AllocatorCommon.hpp:91,125,131` |
| F14 | P1 census detector W treats a non-nursery target as a violation unless `isBornOldPending`. O records the born-old entries it retires. | `P1Census.cpp` (TG4) |

---

## 3. Design

### 3.1 Placement policy (one function)

```cpp
// ThreadLocalHeap
enum class LargePlacement { Nursery, Ylos, OldPinned };
LargePlacement placeLarge(size_t size, Tag tag) const;
```
- Not large (`size < large_object_threshold`): not called.
- `!tagMayHoldPointers(tag)` → `OldPinned`, today's `allocateLargePinned`. Only
  `Tag_Int/Float/Char/String/ByteBuffer` reach it through `allocate()` (strings and bytes
  normally take the split-header path before this point).
- `large_ptr_nursery_divisor == 0` → `Ylos` (a test knob: never place in the nursery).
- Otherwise the **nursery cap** is
  ```cpp
  size_t cap = nursery_.capacityBytes() / large_ptr_nursery_divisor;     // relative bound
  if (large_ptr_nursery_max_size != 0)
      cap = std::min(cap, large_ptr_nursery_max_size);                    // fixed bound
  ```
  and `size <= cap` → `Nursery`, otherwise → `Ylos`.

The two bounds do different jobs:
- **The divisor is a safety bound.** It keeps a large object from crowding the nursery when the
  nursery is small (early in a run, or in a small-heap configuration). It scales with the
  nursery.
- **The fixed maximum is a tuning knob.** It chooses how big an object is still worth copying
  through the nursery (copied once to to-space, then promoted by copy) rather than keeping it in
  place in the YLOS (scanned, never copied), **independently of how large the nursery has
  grown**. A value such as 128 KiB or 1 MiB keeps big arrays out of the nursery even at the 128
  MiB cap. Its default is chosen by experiment E1 (P§5a).
- A `large_ptr_nursery_max_size` below `large_object_threshold` is legal. Every large pointer
  object then goes to the YLOS, which gives the same behaviour as `large_ptr_nursery_divisor = 0`
  and is useful for tests.

`tagMayHoldPointers(tag)` is an inline in `AllocatorCommon.hpp`: `tag` is not one of `Tag_Int,
Tag_Float, Tag_Char, Tag_String, Tag_ByteBuffer`.

New `HeapConfig` fields, each with a compiled default in `AllocatorCommon.hpp`, a JSON key in
`HeapConfigJson.cpp` (known-key list plus a parse block), and a line in `HeapConfigJson.hpp`'s key
comment:

| field | type | default | parse | `validate` |
|---|---|---|---|---|
| `large_ptr_nursery_divisor` | `uint32_t` | `LARGE_PTR_NURSERY_DIVISOR = 8` | `parseU32` | none (0 is legal: never nursery) |
| `large_ptr_nursery_max_size` | `size_t` | `LARGE_PTR_NURSERY_MAX_SIZE = 0` (no fixed bound) until E1 sets it | `parseByteSize` (accepts `"128K"`, `"1M"`) | must be a multiple of 8 |

### 3.2 Option 3: nursery placement

- **`allocate(size, tag)`**, large branch:
  - `OldPinned` → as today.
  - `Nursery` → fall through to the normal nursery path (fast bump; `minorGC`; `failSoftUnclamp`).
    Where today it would `assert(false)` after the fail-soft, it now calls `allocateYoungLarge`.
  - `Ylos` → `allocateYoungLarge(size, tag)`.
- **`allocateSlow`**: the same routing. Its large branch must not skip the `minorGC()`
  for the `Nursery` placement.
- **`allocateRegionSlow`**: delete the dead duplicate branch (F2).
  - A large region takes the `Nursery` path (fast, GC, fail-soft).
  - A region that cannot fit, or exceeds the cap, is a **fatal error** with a message ("closure
    group region of N bytes exceeds the nursery cap; split the group"). Regions are several
    objects, and YLOS is per object. Nothing in the census (D0) should come close, and D0
    confirms it.
- **Nursery-placed large objects are not pinned** (`pin = 0`, as `initHeaderForTag` leaves it),
  so they promote normally. Promotion of a size ≥ `alloc_buffer_size` object goes through
  `oldgen.allocate` → `allocateLargeBlock` (a dedicated block), as for any big survivor today.
- **Kernel contract** (already required by F3's fast path): a kernel must not hold a raw pointer
  to a large pointer-bearing object across an allocation. The TG4 audit found none. The
  validate tree's stale-pointer tripwires check it in the gates.

### 3.3 Option 4: the young large-object space (YLOS)

**Representation.** YLOS reuses the HEAP_026 index. `LargeBodyMeta` gains `uint8_t kind` (0 =
split-header body, 1 = young object):
- the entry is in `large_body_index_` and `nursery_owned_bodies_`, colored with the minor color;
- the cell is allocated like a body, by new `OldGenSpace::allocateYoungLarge(size, tag,
  initial_color)`, which shares `allocateLargeBody`'s code minus the string/bytes assertion;
- `header.tag = tag`, `pin = 1` (never moved: F10), `age = 0`, `builder` as the caller sets it.

Freeing and major-GC interplay need **no new code**:
- `sweepNurseryLargeBodies` frees unreached young objects at minor end (F8);
- `retireDeadLargeBodies` erases unmarked ones at mark end (F9), and the sweep reclaims their
  cells;
- `freeLargeBodyCell` does the accounting (F7).

**The bounding-box filter.** `OldGenSpace` keeps `char* ylo_lo_, *ylo_hi_` (the minimum start
and maximum end of all kind-1 entries), plus `size_t ylo_count_`:
- updated on registration;
- recomputed (O(n)) after `sweepNurseryLargeBodies`, `retireDeadLargeBodies`, and every
  promotion in place;
- `nullptr` / `nullptr` when the count is 0.

Public inline: `bool mayBeYoungLarge(const void* p) const { return p >= ylo_lo_ && p < ylo_hi_; }`
(false when empty).

**Minor GC: reaching a YLOS object.** In `evacuate`, `evacuateJitPtr` and `evacuateValueSlot`,
immediately **before** the `!isInFromSpace(obj)` early return (F5):
```cpp
if (__builtin_expect(oldgen.mayBeYoungLarge(obj), 0)) {
    reachYoungLarge(obj, oldgen, promoted_objects);
    return;   // the pointer is unchanged: YLOS objects never move
}
```
`NurserySpace::reachYoungLarge(void* obj, OldGenSpace& og, std::vector<void*>* promoted)`:
1. `LargeBodyMeta* m = og.youngLargeMeta(obj)` (a hash lookup). If it is not kind 1, return: the
   pointer was an old object inside the bounding box.
2. If `m->color == minor_color_`, return: already reached this cycle.
3. Set `m->color = minor_color_`.
4. `Header* h = getHeader(obj)`.
   - **Promote in place** when `!h->builder && h->age >= promotion_age_`, the same predicate as
     `shouldPromote` minus `pin`:
     - `og.promoteYoungLarge(obj)`: remove it from `nursery_owned_bodies_` and
       `large_body_index_`, recompute the bounding box, count it;
     - push `obj` on `*promoted` so its children are scanned as a promoted parent's. By
       immutability they are at least as old as the object (its elements existed before it was
       filled), so they qualify for promotion in the same minor. For a large builder the rule is
       the same as for nursery builders: it never ages while `builder == 1`, and after
       `clear_builder` it ages from 0, so every child is at least as old.
   - **Otherwise it stays young:** `if (!h->builder) h->age++`, and push `obj` on the new
     `young_large_scan_` queue.
5. **The drain loop** (`minorGC`'s alternation) gains a third inner loop over
   `young_large_scan_`, with `in_phase3_ = false`: a young parent may have young children. The
   outer loop condition includes it. The queue is cleared at the start of each minor.

**Roots that point directly at a YLOS object** (stack maps, root ranges, external scanners) go
through the same copiers, so they are covered. **Old objects cannot point at a YLOS object**
(that would be old→young, now forbidden again), and **V2** checks it.

**Aging and promotion timing** match a nursery object exactly:
- reached at minor k with age a < `promotion_age` → age a+1;
- reached with age ≥ `promotion_age` → promoted.

With `promotion_age` = 1, a YLOS object allocated before minor 1 stays young at minor 1 (age
0 → 1) and is promoted in place at minor 2. That is the same schedule as a nursery object
(copied at minor 1, promoted at minor 2), but with zero copies.

**A major GC between minors:**
- marking reaches reachable YLOS objects through roots and nursery objects (F9);
- unreachable ones are erased at mark end by `retireDeadLargeBodies`, and their cells are
  reclaimed by the sweep;
- the bounding box is recomputed after the retirement.

**Compaction:** YLOS cells are pinned, so compaction never moves them (F10). There is no
compaction guard, and TG4's is removed (D4).

### 3.4 Removing HEAP_061 (D4)

Delete:
- `OldGenSpace::born_old_`, `noteBornOld`, `isBornOldPending`, `bornOld()`,
  `pruneBornOldAtMarkEnd`, and the file `OldGenBornOld.cpp` (remove it from the four source
  lists);
- the born-old scan and retire blocks in `NurserySpace::minorGC`;
- the calls in `ThreadLocalHeap::allocateLargePinned` and `allocateRegionSlow`;
- the `scheduleCompaction` guard;
- the HEAP_061 exceptions in `markOneObject`'s builder assertion and in `clear_builder`'s
  assertion. These go back to nursery-only, **plus** YLOS (see below).

Builder rule restated (HEAP_BUILDER_001): a builder object is **young**, i.e. in the nursery or
a kind-1 YLOS object. Both assertions test `isInNursery(h) || og.isYoungLarge(h)`, where
`isYoungLarge` is the exact hash lookup (validate path only).

### 3.5 Option 2: chunked JSON arrays (D5)

- `F = (large_object_threshold − 1 − sizeof(ElmArray)) / sizeof(Unboxable)`, about 1,020, so
  every chunk stays below the threshold.
- **Representation:**
  - `n ≤ F`: unchanged. `CTOR_JSON_ARRAY` (105) holds one `ElmArray` of the elements.
  - `n > F`: new `CTOR_JSON_ARRAY_CHUNKED` (the next free ctor number; check the table at the top
    of `JsonExports.cpp`) = `Custom{values[0] = ElmArray of chunk ElmArrays, values[1] = Int n}`
    (unboxed mask for `values[1]`). Chunk i holds elements `[i·F, min(n, (i+1)·F))`.
  - The top-level index array has ⌈n/F⌉ entries. It is itself below 8 KiB up to n ≈ 1.04 M. Above
    that it is a large pointer-bearing object and correctly takes option 3/4. No third level is
    needed for correctness.
- **Accessors**, in the anonymous namespace of `JsonExports.cpp`:
  ```cpp
  u32 jsonArrayLength(Custom* jarr);             // either ctor
  HPointer jsonArrayAt(Custom* jarr, u32 i);    // resolves chunk then element; no allocation
  bool isJsonArray(u16 ctor);                   // 105 or the chunked ctor
  ```
- **Construction:** `jsonToHeap`'s array branch keeps its rooted `elements` vector (64-slot
  ranges). For `n ≤ F`, `arrayFromPointers(elements)`. For `n > F`:
  1. allocate the ⌈n/F⌉ chunk arrays **first**, each via `arrayFromPointers` over its slice,
     collecting their HPointers into a second rooted vector (64-slot ranges);
  2. then allocate the index array from that vector;
  3. then the Custom.

  Every array is filled immediately after allocation. That is SAFE-FRESH, and P1 holds.
- **Readers:** replace every `CTOR_JSON_ARRAY` test with `isJsonArray` and every direct
  `ElmArray` access with the accessors. That is `:431`, `:648`, `:754` (the `array` decoder, which
  already builds its result incrementally), `:988` (`index` = `jsonArrayAt` with bounds against
  `jsonArrayLength`), and `:1360`. Grep for `CTOR_JSON_ARRAY` and `values[0].p` near each to
  find any other reader.
- **Encoding side:** check whether `Json.Encode.list` / `array` build `CTOR_JSON_ARRAY` values.
  If they do, route them through the same constructor.

### 3.6 Guard and stats (D6)

- `ThreadLocalHeap` counters (stats builds): `large_ptr_nursery_{allocs,bytes}`,
  `large_ptr_ylos_{allocs,bytes}`, `ylos_promoted_in_place`, `ylos_freed_minor`,
  `ylos_retired_major`, `ylos_reach_calls`. They are printed as a new banner block, "Large pointer
  objects (threaded-gc-04b)", only when any is non-zero, so existing banner lines are unchanged.
- **Validate builds:** `ECO_LARGE_PTR_TRACE=1` prints `tag`, `size`, `placement` and the caller's
  return address (symbolised with `dladdr`) for every large pointer-bearing allocation. This is
  the tool for D0 and for spotting a new flat-array kernel.

### 3.7 P1 census (D7)

- **W** (`noteWrite`): a non-nursery target that is a kind-1 YLOS object is judged like a
  nursery object: a violation iff `age >= 1 && !builder`. Remove the born-old exception.
- **O:** `reachYoungLarge`'s in-place promotion records the object (`p1::recordPromoted(&og,
  {obj})`), as a normal promotion is recorded after the drain.
- **N:** optionally extend `censusRecord`/`censusCheck` to hash the kind-1 YLOS objects reached
  in the minor (a small list) and re-check them at the next minor start. Do it: it makes P1
  coverage of YLOS equal to the nursery's.

### 3.8 Validators (validate builds)

| # | Check | Where |
|---|---|---|
| V1 | Every kind-1 entry's cell has `pin == 1`, `builder ⇒ age == 0`, and lies inside `[ylo_lo_, ylo_hi_)` | after `sweepNurseryLargeBodies` |
| V2 | **HEAP_005 strict:** after the drain, no promoted object (the whole `promoted_objects` list) has a boxed child in the nursery or in YLOS. A per-slot walk over the promoted list, validate-only | minor end |
| V3 | No `born_old_`-style or HEAP_061 code path remains (static; gate G9) | — |
| V4 | A large pointer-bearing object is never in an old-gen cell unless it has been promoted (its kind-1 entry is gone and it was reached at promotion age), or it was promoted by copy | `allocateLargePinned`: assert `!tagMayHoldPointers(tag)` |
| V5 | JSON: `jsonArrayLength(chunked) == n`, and every chunk's size is below the threshold | chunked constructor |

---

## 4. Steps

Every step ends with `cmake --build build --target check` green. Steps 2–7 also build the
validate tree's `test` target and run the new tests there.

**Before you start:** `benchmarks/lss-loop-snap.sh verify keep-TG4`; snapshot `try-TG4b-pre`.

### Step 0 — D0: census of large pointer allocations (no behaviour change)

1. Add the D6 counters and `ECO_LARGE_PTR_TRACE`, **only**. Placement is unchanged.
2. Record placement counts and call sites on:
   - the self-compile (stats build);
   - `build/test/test` (unit + E2E);
   - stress under GC pressure;
   - **a new JSON microbenchmark**: an Elm program in `test/stress-elm/` that decodes a 1 M-element
     JSON array with `Json.Decode.list` and `Json.Decode.array`, checks the sum, and re-encodes it.
3. Record the table in P§9 (as-built). It predicts rule 2's counter deltas.

### Step 1 — D1: policy

1. `tagMayHoldPointers` inline (`AllocatorCommon.hpp`).
2. `HeapConfig::large_ptr_nursery_divisor` and `large_ptr_nursery_max_size`, with their
   constants, JSON keys and the `validate` rule (P§3.1 table).
3. `ThreadLocalHeap::placeLarge` (P§3.1).
4. Unit tests:
   - `testPlaceLargeDecisions`:
     - a string → OldPinned;
     - an array under the cap → Nursery;
     - an array over the cap → Ylos;
     - divisor 0 → Ylos;
     - `max_size` = 128 KiB with a 64 MiB nursery: a 100 KiB array → Nursery, a 200 KiB one →
       Ylos (the fixed bound wins over the divisor's 8 MiB);
     - `max_size` = 64 MiB with a 64 MiB nursery: the divisor wins (8 MiB);
     - `max_size` below the large-object threshold → every large pointer object → Ylos.
   - `testLargePtrConfigJson`: both keys round-trip through JSON, including `"1M"`, and
     `max_size` = 1001 is rejected by `validate`.

### Step 2 — D2: nursery placement

1. Route `allocate` and `allocateSlow` per P§3.2, and delete `allocateRegionSlow`'s duplicate
   branch.
2. `allocateLargePinned` gets `assert(!tagMayHoldPointers(tag))` (V4) in validate builds and
   loses its HEAP_061 registration.

   **Keep HEAP_061's code until Step 4**, so the tree stays correct between steps: every
   pointer-bearing path now avoids `allocateLargePinned`, so `born_old_` simply stays empty.
3. Tests:
   - `testLargeArrayInNurseryKeepsChildren`: the TG4 S2 regression test, reworked. The array is
     now nursery-placed, and every element survives 3 minors and a major.
   - `testLargeArrayPromotesByCopy`: after 2 minors the array is in the old gen, `pin == 0`, and
     its elements are old.
   - Self-compile checkpoint: counters vs `eco-optTG4` are identical or explained by D0.

### Step 3 — D3: YLOS

1. `LargeBodyMeta.kind`; `allocateYoungLarge`; `youngLargeMeta` / `isYoungLarge` /
   `mayBeYoungLarge`; the bounding-box maintenance; `promoteYoungLarge`.
2. `ThreadLocalHeap::allocateYoungLarge(size, tag)` calls `old_gen_.allocateYoungLarge(size, tag,
   nursery_.minor_color_)` and initialises the header for the tag. It is the `Ylos` placement,
   and the fail-soft after the nursery path.
3. `NurserySpace::reachYoungLarge`, the `young_large_scan_` queue, the drain-loop third inner
   loop, and the calls in the three copiers (P§3.3).
4. The validators V1 and V2.
5. Tests, all with `large_ptr_nursery_divisor = 0` to force YLOS:
   - `testYlosChildrenSurviveMinors`: a 2,000-element array of fresh Ints, rooted; 3 minors with
     churn; every element intact.
   - `testYlosAgesAndPromotesInPlace`: age 0 → 1 → promoted at minor 2. The address is
     unchanged throughout. Afterwards there is no kind-1 entry and the bounding box is empty.
   - `testYlosUnreachableFreedAtMinor`: an unrooted YLOS array is freed at the next minor
     (`ylos_freed_minor` 1; the cell is reusable).
   - `testYlosUnreachableFreedAtMajor`: allocate, then a major with no minor in between: retired
     at mark end, the cell reclaimed.
   - `testYlosReachedOnlyThroughNurseryObject`: the only reference is from a young Tuple2. It
     survives minors and a major.
   - `testYlosBuilderNeverAges`: an `allocArrayBuilder` at a large capacity stays at age 0
     across 3 minors while filled across allocations, then ages and promotes after
     `clear_builder`.
   - `testYlosReachedTwiceScannedOnce`: two roots, one scan (`ylos_reach_calls` vs scans).
   - **Negative control:** with the `reachYoungLarge` call removed from `evacuate`,
     `testYlosChildrenSurviveMinors` fails.

### Step 4 — D4: remove HEAP_061

Delete per P§3.4. Replace TG4's born-old tests with the YLOS tests above: delete
`testBornOldEntryRetires`, `testBornOldDeadEntryPrunedAtMark`, `testBornOldRegionSplitAtMark`, and
rename `testBornOldArrayChildrenSurviveMinors` to the Step 2 test. `grep -rn
"born_old\|BornOld\|HEAP_061" runtime/src test` must print nothing but the invariant history.

### Step 5 — D5: chunked JSON arrays

Implement P§3.5. Tests:
- unit tests in the kernel test suite, or E2E Elm tests in `test/elm-json/src`: decode arrays of
  sizes F−1, F, F+1, 3F+7 and 100,000;
- `Json.Decode.index` at 0, F−1, F, n−1 and n (error);
- `list` / `array` decoders produce the right elements;
- `Json.Encode` round-trip is byte-identical;
- `Json.Decode.oneOf` over array alternatives;
- the D0 JSON microbenchmark shows **0** YLOS placements for n ≤ ~1 M.

### Step 6 — D7: census updates

Implement P§3.7. Census-tree tests:
- a write into a YLOS object with age ≥ 1 is caught by W;
- an in-place promotion is recorded by O;
- N covers YLOS survivors.

### Step 7 — gates, measurement, docs

P§5, P§6, P§8.

---

## 5. Measurement

- **Self-compile.** One same-session control (`eco-optTG4`) and the candidate `eco-optTG4b`, in
  mode 2:
  - counters identical, or deltas explained by D0;
  - `out.mlir` identical;
  - wall inside the band;
  - max RSS within ±1 %.
- **JSON microbenchmark (D0):** wall, GC time and max RSS, before and after. Expected:
  - fewer old-gen large blocks;
  - no YLOS placements up to ~1 M elements;
  - the pause is not worse.
- **Stress under GC pressure:** the `large_ptr_*` counters, and 100/100.

### 5a. Experiment E1 — choosing `large_ptr_nursery_max_size`

Run after Step 5, on the JSON microbenchmark (D0), a second microbenchmark that builds large
arrays through `List.toArray` / `allocArrayBuilder` at sizes of 10 k, 100 k and 1 M elements, and
the self-compile. Arms, each set as a **compiled default** (one lowered binary per arm, as in the
GC loop; env-free):

| arm | `large_ptr_nursery_max_size` |
|---|---|
| A | 0 (divisor only: up to 8–16 MiB in the nursery) |
| B | 4 MiB |
| C | 1 MiB |
| D | 128 KiB |
| E | 16 KiB (almost everything large goes to the YLOS) |

Record per arm:
- wall and GC time (minor and major);
- max pause, minor-only p99 (phase-timer builds);
- copied-in-nursery and promoted bytes;
- `large_ptr_nursery_*` / `large_ptr_ylos_*` counts, `ylos_promoted_in_place`,
  `ylos_reach_calls`;
- max RSS.

**Decision rule:**
- choose the **largest** value whose microbenchmark GC time and max pause are within noise of the
  best arm and whose self-compile is FLAT against A;
- if every arm is within noise, choose **1 MiB**, which bounds the per-object nursery copy cost
  without relying on the YLOS for common sizes.

Record the table and the choice in P§9, and set `LARGE_PTR_NURSERY_MAX_SIZE`.

What to watch: nursery placement costs two copies (to-space, then promotion) and speeds up the
next minor. YLOS placement costs a hash lookup per reach, plus a scan of the whole object at
every minor while it is young. The crossover is the object size at which copying twice outweighs
scanning in place.

## 6. Gates

| # | Gate | Pass |
|---|---|---|
| G1 | `build/test/test` | all pass |
| G2 | elm-tests | the reference set |
| G3 | `--target full` | all pass |
| G4 | stress under GC pressure | 100/100, ≳1,000 minors |
| G5 | validate tree (P1 tripwire on; V1–V5) | all pass; zero `[heap-validate]` and P1 violation lines; stress: only the pre-existing `JsonRoundtrip*` aborts (or fewer: record it if chunked JSON changes them) |
| G6 | stats-off `ecoc` | builds |
| G7 | census tree in abort mode: unit + E2E, stress, and the self-compile in count mode | 0 violations |
| G8 | production counters + `out.mlir` | P§5 |
| G9 | static: `grep -rn "born_old\|BornOld\|noteBornOld\|isBornOldPending" runtime/src test` empty; `allocateLargePinned` asserts pointer-free tags | as stated |

## 7. Traps

1. **The bounding box must shrink**, or every old pointer inside a stale box pays a hash lookup
   in the minor GC's hottest loop. Recompute it after every removal.
2. **Promotion in place must remove the entry before the minor-end sweep.** Otherwise
   `sweepNurseryLargeBodies` sees the old color and frees a live, just-promoted object.
3. **The age increment happens once per minor**, at the first reach. The same-cycle dedupe is the
   color check.
4. **`in_phase3_` must be false** while scanning `young_large_scan_`. Young children of a young
   parent are normal.
5. **Region allocations must never reach YLOS** (P§3.2): a region is several objects.
6. **Raw pointers across allocation.** Nursery placement moves large objects. The validate tree's
   stale-pointer tripwires are the check. Run G5 before trusting any timing.
7. **Counters are a program input** (TG3 rule 5): compare only same-session, same-environment
   runs.
8. **JSON ctor numbers** are baked into the Elm side of the kernel (decoders dispatch on ctor).
   Check `elm-kernel-cpp/src/json` and any Elm-level code that inspects them before choosing the
   chunked ctor's number.

## 8. Invariants (land in Step 7)

- **HEAP_005 (restore strict):** "There are no old-to-young pointers in the heap. The young
  generation is the nursery plus the young large-object space (HEAP_062); both are traced by the
  minor GC. Guaranteed by Elm immutability and by the placement rule for large pointer-bearing
  objects. (Restored 2026-09-2x, threaded-gc-04b; the HEAP_061 exception is retired.)"
- **HEAP_061:** mark it **retired** (status `retired`), with a pointer to HEAP_062.
- **HEAP_062 YoungLargeObjectSpace (new):**
  - A pointer-bearing object of size ≥ `large_object_threshold` is placed in the nursery when it
    fits under `min(capacity / large_ptr_nursery_divisor, large_ptr_nursery_max_size)` (the
    fixed bound applies when non-zero). Otherwise it goes to the YLOS: a pinned old-gen-range cell
    registered as a kind-1 entry of the HEAP_026 body index.
  - A YLOS object is young. The minor GC reaches it through a bounding-box filter plus an index
    lookup in the evacuation copiers, colors it, ages it like a nursery object, scans its
    children, and promotes it in place (the entry is removed, no copy) when `age >=
    promotion_age && !builder`.
  - An unreached YLOS object is freed at minor end (`sweepNurseryLargeBodies`) or at mark end
    (`retireDeadLargeBodies`).
  - `allocateLargePinned` is for pointer-free tags only.
- **HEAP_BUILDER_001:** "…must be young (in the nursery or a YLOS object)"; remove the HEAP_061
  clause.
- **HEAP_026:** note that the body index also holds kind-1 young objects.
- **HEAP_SNAPSHOT_001:** replace "in the old gen other than as a born-old pending object
  (HEAP_061)" with "in the old gen".
- The master plan's phase 5a notes: YLOS objects are part of the young generation at t0,
  handled with the nursery. The TG4 note about born-old snapshot roots is withdrawn.

## 9. As-built deviations

Implemented 2026-09-26. Every step landed. The deviations and results follow.

### 9.1 Pre-existing bugs found and fixed on the way

The D0/D5 tests and the validate gate exposed five defects that predate this plan:

1. **`Json.Decode.array` built an invalid `Array` for more than 1,056 elements.** The old code
   built a flat tree with shift 5, so `Array.get 499999` returned 287. It is replaced by
   `buildElmArrayFromElements`, which mirrors `Array.fromList`:
   - the tail is `len % 32`, and full 32-chunks are `Leaf` nodes;
   - `SubTree` levels group by 32;
   - `startShift = max 5 (5 * floor(log32(numLeaves*32 - 1)))`.

   A first attempt with tail `((len-1)%32)+1` crashed `Array.get`.
2. **`invokeSaturatedTyped` took `closure_bits` by value** and passed a reference to that
   unrooted copy to `spliceArgsForSaturatedCall`. The splice re-resolves the closure after a
   primitive→boxed allocation, so it read a stale closure ("PTR IN TO-SPACE"). Fixed by rooting
   the local.
3. **`runDecoder`'s recursive calls passed the unrooted `jvalEnc` parameter copy** (`oneOf`,
   `andThen`, `map2`+, `lazy`). After the first sub-decoder GC'd, later ones decoded a stale
   value. They now pass `Export::encode(jvalHP)`, and the parameter is renamed `jvalEncIn`.

   Items 2 and 3 were the long-standing validate-stress `JsonRoundtrip*` aborts: **validate
   stress under GC pressure went from 95/101 to 101/101.**
4. **Stack root ranges longer than 64 slots** relied on `1ULL << i` for i ≥ 64, which is UB.
   `stackRangeSlotIsRoot` now defines the semantics (beyond slot 63, only an all-ones mask
   roots). Every such range in the tree uses an all-ones mask, and the old code compiled to
   `bt reg,reg` (mod-64 wrap) in both scanners, so behaviour is unchanged.
5. **The heap-graph test generator made 0-field `Custom`s**, which HEAP_044 forbids. The
   validate unit suite failed on about half the seeds. The generator now pads to one unboxed
   field.

### 9.2 Design deviations

- **`LargePlacement` enum.** It is `{Nursery, Ylos, Region, PointerFree}`, one enum shared by
  the policy and the counters. The policy is the pure static
  `ThreadLocalHeap::placeLargeFor(size, tag, nursery_capacity, cfg)`, so tests can pass any
  capacity.
- **`eco_alloc_with_roots`: large sizes skip the size-blind bump (F3).** They go through
  `Allocator::allocate` with the caller's roots open. Otherwise the cap and the fixed maximum
  did nothing for kernel allocations (`allocArray`, `allocArrayBuilder`), which is most of them.
- **Regions are bounded by the whole nursery, not the placement cap.** A region is fatal only
  if it does not fit after a minor plus the fail-soft. A nursery/8 cap would abort real
  programs in small-nursery configs (GC-pressure: 128 KiB, so a 16 KiB cap).
- **The bounding box is conservative between minors.** It is not recomputed per in-place
  promotion (that would be O(n²)), only at minor end, after the major's retirement, and grown
  on registration. `youngLargeMeta` is an exact index lookup, so a stale box costs a lookup,
  never a wrong answer.
- **The copier hook sits inside the `!isInFromSpace` branch**, and on a miss the copier returns
  as before. The from-space path costs nothing.
- **Major-side index retirement keys on the index, not the tag**, at three sites
  (`classifyBlocksAfterMark`'s `is_large` branch and both legacy sweep branches). Keying on
  String/ByteBuffer would leak the kind-1 entry of a dead YLOS object in an `is_large` block,
  and a later `freeLargeBodyCell` would double-free it.
- **Validate integrity check.** The old-gen check ("OLD-GEN→NURSERY(stale)") skips unreached
  kind-1 parents: they are dead until the minor-end sweep frees them.
- **Census N for the YLOS** records survivors by address and drops them across a major
  (`OldGenSpace::majorEpoch()`). A major can retire a cell and reuse it.
- **V2 (`HeapChildWalk.hpp`)** reuses PermanentSpace's per-tag child walker, moved to a shared
  header.
- **Step 4's test swap happened in Step 2:** the born-old region test cannot run once regions
  are nursery-only.
- **Kernel-license manifest.** The `JsonExports.cpp` rows (33) carry a dated re-audit note: no
  apply, no retention, no closure mint. The manifest was regenerated.
- **E1 microbenchmark 2 is a C++ bench** (`testE1LargeArrayPlacementBench`, enabled by
  `ECO_E1_BENCH=1`). Elm cannot build large flat pointer arrays:
  - `List.toArray` is a pass-through in eco;
  - `Elm.JsArray` is not exposed;
  - `Array`'s JsArrays hold at most 32 elements.

  Arms are set in the `HeapConfig` (unit tests ignore `ECO_HEAP_CONFIG`), so every arm runs in
  one binary and one environment.

### 9.3 D0 census (placement of large allocations)

| workload | nursery (ptr) | YLOS | regions | pointer-free | born old (before) |
|---|---|---|---|---|---|
| self-compile (candidate, mode 2) | 0 | 0 | 0 | 1 (0.02 MB) | 0 |
| unit + E2E (validate tree, before Step 2) | 3 (tests) | — | 1 (test) | 63 (ByteBuffer) | 3 (tests) |
| stress under GC pressure (before Step 2) | 20 arrays | — | 0 | — | 1 |
| JSON benchmark (`JsonLargeArray`, after D5) | 0 | 0 | 0 | 0 | — |

**The self-compile makes no large pointer-bearing allocation.** It is therefore invariant under
the whole policy, including every E1 arm.

### 9.4 Measurement (P§5, G8)

Same-session control `eco-optTG4` vs candidate `eco-optTG4b`, mode 2, two runs each:

| | wall | max RSS | out.mlir | objects / minors / majors | promoted / copied |
|---|---|---|---|---|---|
| control | 2:56.52, 2:52.32 | 9,778,496 / 9,778,056 KB | — | 254,179,007 / 1,924 / 7 | 675,771,142 / 744,248,460 |
| candidate | 2:50.98, 2:50.42 | 9,781,300 / 9,780,708 KB (+0.03 %) | identical | identical | +241 / +1,880 |

Each binary is deterministic (r1 = r2). The promoted/copied delta (3.6e-7 relative) is **not
attributed**:
- reverting the two stale-pointer fixes did not change the candidate's counters;
- restoring the TG4 JSON kernel did not either;
- the root-range change is behaviour-identical (see §9.1 item 4);
- a *fresh* lowering of the keep-TG4 sources differs from the old `eco-optTG4` by 2 copies.

So same-source lowerings are not bit-exact on this counter, and the residue is most likely
layout-sensitive. Two intermediate experiments were invalid and are discarded: a source swap
restored with `cp -a` kept old mtimes, so ninja linked stale objects.

### 9.5 Experiment E1 (P§5a)

`testE1LargeArrayPlacementBench`, production `HeapConfig` defaults, `gc_thread_mode` 0.
24 M elements per cell: arrays filled across allocations (like `JsArray.initialize`), with the
last 4 kept live. Run 1 is shown; run 2 agreed within ~3 %.

| arm (`max_size`) | 10 k (80 KB): wall / minor ms | 100 k (800 KB): wall / minor ms | 1 M (8 MB): wall / GC ms / majors |
|---|---|---|---|
| A 0 (divisor only) | 204 / 4.5 | 235 / 47.6 | 1,735 / 1,524 / 5 |
| B 4 MiB | 190 / 4.0 | 236 / 48.8 | 923 / 684 / 1 |
| C 1 MiB | 189 / 3.9 | 235 / 48.0 | 914 / 683 / 1 |
| **D 128 KiB** | **190 / 3.9** | **234 / 29.9** | **913 / 680 / 1** |
| E 16 KiB | 317 / 2.7 | 234 / 30.9 | 908 / 677 / 1 |

Where the cost goes:
- **An 8 MB array in the nursery (A)** is copied twice, and the doubled promotion volume drives
  4 extra majors: 1.9× the wall.
- **An 800 KB array in the YLOS (D, E)** cuts minor GC time by 37 %.
- **An 80 KB array in the YLOS (E)** is 1.65× slower in wall while its GC time drops. YLOS
  allocation (an old-gen cell plus index registration, then a free at the next minor) costs
  more than copying 80 KB. The plan's GC-time-only rule would pick E; it cannot see that cost.

**Choice: 128 KiB (D).** It is best or tied at every size on wall and GC time, and max pauses
are within noise. `LARGE_PTR_NURSERY_MAX_SIZE = 128 KiB`. The self-compile is flat by
construction (§9.3).

### 9.6 Gates

| gate | result |
|---|---|
| G1 | `check` 1805/1805 |
| G2 | elm-tests 13,565 / 12 (the reference set) |
| G3 | `full` 1804/1804 |
| G4 | stress under GC pressure 101/101 |
| G5 | validate unit + E2E 1806/1806, stress under pressure 101/101, zero `[heap-validate]` / P1 / STALE lines |
| G6 | stats-off `ecoc` builds |
| G7 | census tree (abort mode): unit + E2E 1805/1805, stress 101/101, 0 violations; self-compile in count mode (`eco-optTG4bcensus`): N 743,942,253 re-hashes, O 264,965,968 checks, W 18,800,491 writes, **0 violations**, out.mlir identical |
| G8 | §9.4 |
| G9 | `grep -rn "born_old\|BornOld\|noteBornOld\|isBornOldPending\|HEAP_061" runtime/src test` is empty; `allocateLargePinned` asserts a pointer-free tag |

Negative control: with `reachYoungLarge` removed from `evacuate`,
`testYlosChildrenSurviveMinors` fails ("YLOS after minor: length").

## 10. Out of scope

| item | where |
|---|---|
| The `chunkChainFits` bound on chunked lists | `plans/chunked-list-spine-data-split.md` |
| The 5 validate-stress `JsonRoundtrip*` aborts (a stale closure in `eco_apply_closure_eval`) | separate investigation; re-check after Step 5 in case the JSON change moves them |
| Root ranges longer than 64 slots with `mask = ~0` | separate RootSet fix |
| Growing the nursery on demand for a large allocation | not needed: YLOS covers it |

## 11. Done means

- HEAP_005 is strict, HEAP_062 is in, and HEAP_061 is retired, with no born-old code left (G9).
- G1–G9 are green. The D0 census and the P§5 measurements are recorded.
- The chunked JSON arrays are in, with their tests.
- Experiment E1 has been run, and `LARGE_PTR_NURSERY_MAX_SIZE` has been set by its rule.
- Snapshot `keep-TG4b` is taken, loop entry TG4b is written, and the master plan has a row 4b and
  its §5 row.
