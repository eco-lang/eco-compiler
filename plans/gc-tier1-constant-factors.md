# GC Tier 1 — constant-factor fixes in the collector

**Status: IMPLEMENTATION-READY v1 — 2026-09-21.** Grounded against the tree;
not implementation-started. Lowers items **6–56** of `gc-opt-working-list.md`
(§1.b–§1.i).

**Items 1–5 (§1.a, root registration) are NOT here** — they are
`plans/gc-root-registration-cost.md`, which covers the TLS shadow stack, the
`EvaluatorDesc` indirection and the `$sat` fast path. That plan and this one
are independent and can land in either order.

Baseline: GC is 29–41% of Stage-7 self-compile wall; minor ~86 s / major
~56 s (Run R/S, `benchmarks/lss-opt.md`); mark is 92.4% of major. Retention is
`Custom` 60.7% + `Cons` 36.7% = 97.4% of promotion (Run H,
`benchmarks/tier2-opt.md:280`).

**Standing caution.** `plans/inline-bump-state-tls.md` deleted 10.46 B calls
and measured **−0.03% wall**. Its lesson — *"a large count is not a large
cost… rank by events × per-event cost × criticality"* — applies to most of
this document. Only W1 carries a measured cost (5.6% of CPU). Everything else
is an instruction-count argument, and the wall A/B is the arbiter.

---

## Work packages, in landing order

| # | package | items | basis | risk |
|---|---|---|---|---|
| **W0** | Free deletions | 11,12,13,27,39,48,49,50 | *bound* | trivial |
| **W1** | Nursery zeroing | 6,7,8,9 | **5.6% CPU *measured*** | medium |
| **W2** | `evacuate` inner loop | 16–23 | *bound* | low |
| **W3** | Per-object dispatch | 24–28 | *bound* | low |
| **W4** | Slot scanning | 29–32 | *bound* | medium |
| **W5** | Minor-GC structure | 33–37,53,55 | *bound* | low |
| **W6** | Old-gen virgin-page bump | 10,15 | *bound* | medium |
| **W7** | Promotion-path sweep coupling | 14 | *measured outlier* | medium |
| **W8** | Mark-side data structures | 38,40,51,52,54 | *bound* | medium |
| **W9** | Old-gen bookkeeping | 41–47 | *bound* | low |
| **W10** | Stackmap lookup | 56 | *bound* | low |

W0 first because it is free. W1 next because it is the only package with a
measured cost. W8 is also the prerequisite for parallel marking
(working-list #57–#63), so it has value beyond its own delta.

---

## W0 — Free deletions

One commit, one gate. Nothing here changes behaviour; several are pure
removals of code that can never execute.

**Item 13 — dead `Marking` branch.** `OldGenSpace::allocate:639` reads
`if (gc_phase_ == GCPhase::Marking && !mark_stack.empty())`. `gc_phase_` is
assigned at exactly four sites — `:321` Idle, `:2447` Sweeping, `:2551` Idle,
`:2703` Idle — and **never** `Marking`. Delete the branch. Also delete the
now-unreachable `case GCPhase::Marking:` in `freeLargeBodyCell` (`:4484`) and
mark `HeapConfig::mark_work_ratio` as having no effect (or remove it).

*Note this is a behaviour-preserving deletion only because the branch is
dead. `incrementalMark` itself stays — it is called from
`finishMarkAndSweep`.*

**Items 11, 12 — stats on the promotion path.** `OldGenSpace::allocate`
brackets its whole body with `GC_STATS_TIMER_START()` (`:633`) /
`GC_STATS_TIMER_ELAPSED_NS` (`:692`), i.e. two
`std::chrono::high_resolution_clock::now()` calls, plus
`GC_STATS_OLDGEN_RECORD_ALLOC` (`:619`). Promotion calls this once per
promoted object (`NurserySpace.cpp:1043`) — 357M–475M times per run.

Do **not** simply delete: the timings feed `heap-profile.py`'s
`helper_min_s`/`helper_mut_s` columns and the documented accounting identity
`wall = minor + major + oldgen_alloc_in_mutator + nursery_alloc_in_mutator +
true_mutator` (`GCStats.cpp:1331-1370`). Instead:

- Gate the bracket on a new `ENABLE_GC_ALLOC_TIMING` macro, default **off**
  even when `ENABLE_GC_STATS` is on.
- When off, `total_oldgen_alloc_in_*_ns` report 0 and the identity prints a
  `(timing disabled)` marker rather than silently mis-attributing.
- `heap-profile.py` sets `ECO_HEAP_CONFIG` but cannot set a compile-time
  macro — add a `--alloc-timing` build note to `plans/heap-profile-script.md`.

**Item 27 — redundant reload.** `getObjectSize`'s `Tag_Array` case
(`AllocatorCommon.hpp:322-323`) does `ElmArray *arr = ...; size = sizeof(ElmArray)
+ arr->header.size * sizeof(Unboxable);` when `hdr->size` is already loaded.
Use `hdr->size`. Subsumed by W3 if that lands first.

**Item 39 — root-set deep copy.** `ThreadLocalHeap::collectRoots()`
(`ThreadLocalHeap.cpp:781`) is declared to return `std::unordered_set<HPointer*>`
**by value** from `RootSet::getRoots()`'s `const&`, so every major GC copies
the whole set (bucket array plus a node allocation per root). Its single
caller (`:597`) passes it straight into `startMark` by `const&`. Change the
return type to `const std::unordered_set<HPointer*>&`. One-line change; W8
replaces the container entirely.

**Item 48 — `getenv` magic statics on the sweep path.**
`OldGenSpace.cpp:2230` (`kDbg`, inside `pushSpanOnFreeLists`, called per
coalesced run) and `:2428` (`kSweepDebug`, in `sweep()`). A function-local
`static const bool` with dynamic initialisation compiles to a guard-variable
atomic load plus branch on every call. Hoist both to a single file-scope
`const bool g_oldgen_debug` initialised in `OldGenSpace::initialize`.

**Item 49 — debug tripwire shipped as telemetry.**
`gatherFreeListSnapshotInto` (`:3479`) runs Floyd tortoise-and-hare cycle
detection over all 40 free lists (`:3496-3520`) plus an
`unordered_map<const char*,size_t>` insert per free cell (`:3524-3533`). It
is compiled in whenever `ENABLE_GC_STATS`, i.e. in the standard `build`
preset. Only ~10–17 majors per run, so the wall cost is small — but move the
cycle detection behind `ECO_HEAP_VALIDATE` and keep only the per-block
free-bytes rollup under stats.

**Item 50 — downgrade.** `sweepNurseryLargeBodies` (`:4339`) iterates
`nursery_owned_bodies_`; when that vector is empty the loop body never runs,
so the per-minor-GC cost is a call plus an assert, not a walk. **Reduced to:
add an early `if (nursery_owned_bodies_.empty()) return 0;` and stop.** The
working-list entry overstated this.

**Gate.** E2E green; self-compile output byte-identical; GC counters
unchanged except the deliberately-disabled timing rows.

---

## W1 — Nursery zeroing (items 6–9)

The only package with a **measured** cost: `guides/cpp-prof-hints.md:293`
records `libc memset (clearToSpaceFreeRegion) 5.6%` of total process CPU.

### W1.0 Why it exists (do not skip)

`clearToSpaceFreeRegion` (`NurserySpace.cpp:1841-1852`) memsets
`[copy_ptr_, toBase() + slice_.capacity)` after every minor GC — at the stock
64 MiB/side that is ~61 MiB per collection, roughly one byte zeroed per byte
allocated.

It is load-bearing because **allocation zeroes only the 8-byte header**:

```cpp
// ThreadLocalHeap.cpp:109-111
void initHeaderForTag(Header* hdr, Tag tag, size_t size) {
    std::memset(hdr, 0, sizeof(Header));    // 8 bytes, that is all
    hdr->tag = tag;
```

and it immediately sets `hdr->size` to the object's **full field count**
(`:131` Custom, `:134` Record, `:143` Closure). So the moment an object is
allocated the collector will trace all of its slots, while the mutator has
written none of them. A GC in that window reads, as raw stale bytes, both:

1. the payload slots `values[i]`, and
2. the **per-object kind bitmap word at offset 8** (`Custom.ctor|unboxed`,
   `Heap.hpp:549`; `Record.unboxed`; `Closure.unboxed`; `ListBacking.hd`),
   which sits *outside* the 8 bytes `initHeaderForTag` clears.

Pre-zeroed, (1) reads as the null HPointer — discarded at `evacuate:922` —
and (2) reads as 0, meaning "all slots boxed", which combined with (1) is
safe. The same reasoning, applied locally, is already written down at
`HeapHelpers.hpp:663-666` for `listBacking`, which memsets its own element
array for exactly this reason.

### W1.1 Item 6 — high-water clear (do first; smallest change)

The mutator never wrote past its own bump pointer last cycle, so the region
beyond the previous high-water mark is **already zero** from an earlier pass.

There is no high-water field today (`grep high_water NurserySpace.cpp` → none).
Add one:

```cpp
// NurserySpace.hpp, near bump_
char* to_high_water_;   // highest bump_.ptr ever reached in the extent that
                        // is currently TO-space. Reset on grow.
```

- In `minorGC`, before the flip, record the from-space high-water:
  `from_high_water_ = bump_.ptr;`
- Swap the two watermarks alongside `from_is_low_` (`:839`).
- `clearToSpaceFreeRegion` becomes:

```cpp
char* base = toBase();
if (!base) return;
char* end = std::min(base + slice_.capacity, to_high_water_);
if (copy_ptr_ < end) std::memset(copy_ptr_, 0, (size_t)(end - copy_ptr_));
to_high_water_ = copy_ptr_;   // this extent is now clean above copy_ptr_
```

- `checkAndGrow` (`:289`) extends the extent; the newly committed region is
  fresh `mmap` memory and therefore already zero, so growth must **raise**
  `to_high_water_` only to the old capacity, never to the new end. Get this
  wrong and you skip zeroing genuinely dirty bytes.

Pre-authorised: `plans/nursery-ghost-data-and-stale-pointer-debug.md:15`
decision Q1 — *"If profiling shows cost, optimize later with high-water-mark
clear in Release, full clear under `ECO_GC_DEBUG`."* Keep the full clear under
`ECO_HEAP_VALIDATE` as a differential check.

Expected: eliminates zeroing of the never-touched tail. In steady state the
mutator fills ~95% of the extent, so **this alone is small** — it mainly helps
the cycles right after a grow. Land it because it is nearly free, then do W1.2.

### W1.2 Items 7–8 — move the zeroing to the allocation path

Same byte count, different shape: the zeros land in L1 immediately before the
mutator's own stores overwrite them, instead of as one 61 MiB burst that
evicts all 16 MiB of L3 at every GC point.

**Design: a `zeroed_end_` watermark ahead of the bump pointer.**

```cpp
// NurserySpace.hpp
char* zeroed_end_;   // everything in [bump_.ptr, zeroed_end_) is known zero
static constexpr size_t kZeroChunk = 32 * 1024;
```

The allocation fast path is ABI (`NurseryBump {ptr, end}` is read by
`expandInlineAllocs`, HEAP_034) and **must not grow**. So the watermark is
enforced by *clamping `bump_.end`*, exactly as the proactive-GC threshold
already is via `computeAllocEnd`:

```
bump_.end = min(from-space extent end,
                proactive-GC threshold trip,
                zeroed_end_)          // NEW
```

A bump miss then has three possible meanings instead of two.
`allocateSlow` (`:193`) disambiguates:

1. `bump_.ptr < zeroed_end_`-limited → memset the next `kZeroChunk`, advance
   `zeroed_end_`, recompute `bump_.end`, retry. No GC.
2. threshold trip → minor GC, as today.
3. extent exhausted → the existing fail-soft.

`ensureNursery` (HEAP_041, `ThreadLocalHeap.cpp:314`) must learn the same
third case: it establishes `bump_.end - bump_.ptr >= n` without allocating, so
it must zero forward when the shortfall is a zeroing shortfall rather than a
GC trip. **HEAP_041's text says the miss has "exactly one meaning" — that
sentence must be amended.**

After a minor GC, `zeroed_end_ = copy_ptr_` (nothing above the survivors is
known-zero yet) and the first allocation zeroes the first chunk.

Interaction with W1.1: with chunked zeroing the post-GC bulk memset goes away
entirely, so item 6 becomes redundant. Land 6 first anyway — it is a
five-line change that de-risks the watermark work by proving the
high-water bookkeeping.

**Risk:** the clamp is on the compiled-code fast path via `computeAllocEnd`.
A wrong clamp is either a missed GC trigger (heap overrun) or an infinite
slow-path loop. The `allocateSlow` disambiguation must be exhaustive and
should `abort()` on an unclassifiable miss under `ECO_HEAP_VALIDATE`.

### W1.3 Item 9 — root-cause and delete

The real fix: prove every allocated object is fully initialised before the
next safepoint, then delete all of the above.

Investigation, not yet a change:

1. Build with `ECO_HEAP_VALIDATE`, disable `clearToSpaceFreeRegion`, and
   instead poison the free region with a recognisable non-zero pattern
   (`poisonOldFromSpaceUsedRegion`, `:1873`, already exists and picks such a
   byte).
2. Add a tripwire in `evacuate` (`:919`) and `scanObject` (`:1358`): if a slot
   or bitmap word matches the poison, report the **parent** object's tag,
   size and address. `g_scan_parent` (`:1360`) is already maintained for this.
3. Run the E2E suite and a self-compile. The reported parents name the
   allocation sites that leave a GC-visible window.
4. Cross-check against `plans/allocation-group-single-safepoint.md` and
   HEAP_031 (`FreshStoreNoForward`) — the compiler already reasons about
   freshly-allocated objects, so the gap may be narrow.

If the set is small and closable, delete the zeroing outright. If not, W1.2
is the permanent answer. **Do this investigation before W1.2** — it may make
W1.2 unnecessary, and it is cheap.

### Files

`NurserySpace.hpp/.cpp` (`:193`, `:289`, `:533`, `:839`, `:1841`),
`ThreadLocalHeap.cpp:314`, `AllocatorCommon.hpp` (chunk size knob),
`invariants.csv` (HEAP_041 amendment).
Flag: `ECO_NURSERY_ZERO_MODE=bulk|highwater|chunked` (default `bulk`).

---

## W2 — `evacuate` inner loop (items 16–23)

`NurserySpace::evacuate` (`:919-1147`) runs once per pointer slot of every
surviving object; perf has it at 5.46% self (`borrow-inf-census.md:157`) and
8.26% in the `gc-free-function-propagation` profile.

**Item 17 (do first — the only structural one).** The forward check is
deliberately ordered before the from-space check (`:955-957`), so every edge
that points at to-space, old gen or permanent space still takes a full
cache-line touch on the **child header** (`:958`) before `isInFromSpace`
(`:1022`) returns. In steady state most edges point outside from-space.

Reorder to: constants → null → `isInFromSpace` (pure arithmetic on the
already-held pointer) → header load → `Tag_Forward` → evacuate.

*Correctness argument required in the commit message:* the current order
exists so old-gen→from-space pointers get updated. Under the new order, an
old-gen pointer to a from-space object still reaches the header load, because
`isInFromSpace` is true for it. What changes is only that pointers **not** in
from-space skip the load — and those need no forwarding by construction. Add
an `ECO_HEAP_VALIDATE` assertion that no skipped pointer has
`tag == Tag_Forward`.

**Item 16.** `allocator_->getHeapBase()` and `getHeapReserved()` (`:941`,
`:943`) are re-fetched per call; same at `:1181`, `:1184-1185`, `:1669`. Both
are GC-invariant. Cache as `NurserySpace` members refreshed in
`refreshCapacityCaches()`, which already exists and is called at init/reset/
grow.

**Items 18, 19, 22.** `config_->promotion_age` is dereferenced per object at
`:1041`, `:1212`, `:1730`; `config_->use_hybrid_dfs` per Cons cell at `:1467`.
Cache both as members beside `gc_threshold_`/`growth_threshold_`
(`NurserySpace.hpp:116-121`), which were cached for precisely this reason.
Then fold the three copies of `hdr->age >= promotion_age && !hdr->pin &&
!hdr->builder` into one `inline bool shouldPromote(const Header*)`.

**Item 21.** `evacuateUnboxable` (`:1149-1153`) is an out-of-line member whose
body is `if (is_boxed) evacuate(...)`. Move to the header, or mark
`__attribute__((always_inline))`. Note `evacuate` itself is large and will
stay out-of-line — that is fine; the win is not calling through for unboxed
slots.

**Item 20.** No `__builtin_expect` anywhere in the file. Annotate: constants
and nulls are rare on the boxed-slot path; `Tag_Forward` is common
mid-scan; promotion is the minority per object. Use `ECO_LIKELY`/`ECO_UNLIKELY`
macros rather than raw builtins, matching `Allocator.hpp:69`'s idiom.

**Item 23.** Forwarding-pointer install writes three separate bitfields
(`:1139-1146`, also `:1250-1254`, `:1762-1766`), each a read-modify-write of
the same 64-bit word unless the optimiser merges them. Compose one word:

```cpp
uint64_t w = (uint64_t)Tag_Forward
           | ((uint64_t)encodeForwardPtr(new_obj, heap_base) << 7);
std::memcpy(obj, &w, sizeof(w));
```

The shift constant must be derived from the `Forward` bitfield layout
(`Heap.hpp:660-668`: `tag:5 | color:2 | forward_ptr:40 | unused:17`), with a
`static_assert` tying it to the struct so a layout change cannot silently
desync.

**Gate.** Self-compile output byte-identical; GC counters (minors, majors,
promoted) identical — these are deterministic per binary×tree
(`benchmarks/lss-opt.md:18-75`), so any movement means a behaviour change.

---

## W3 — Per-object dispatch (items 24–28)

`getObjectSize` (`AllocatorCommon.hpp:238-360`) is a 27-case switch that clang
lowers to a jump table — an indirect branch on a data-dependent tag sequence,
so it mispredicts. It is called **twice per survivor** (`NurserySpace.cpp:488`
and `:515` for the Cheney stride, `:1027` to size the copy) and `scanObject`'s
own switch (`:1368`) is a third dispatch on the same already-loaded tag.

**Item 24 — table-driven size.**

```cpp
struct TagSizeInfo { uint16_t base; uint8_t elem_shift; uint8_t flags; };
// size = base + (hdr->size << elem_shift), then round up to 8.
// flags bit 0: size field is a byte count already (Tag_Free).
inline constexpr TagSizeInfo kTagSize[32] = { /* one row per Tag */ };

inline size_t getObjectSize(void* obj) {
    const Header* h = getHeader(obj);
    const TagSizeInfo t = kTagSize[h->tag];
    size_t s = t.base + ((size_t)h->size << t.elem_shift);
    if (ECO_UNLIKELY(t.flags & 1)) s = h->size;
    return (s + 7) & ~7u;
}
```

Every existing case fits `base + size<<shift`: fixed-size tags use
`elem_shift = 0` with `base = sizeof(T)` and rely on `size` being irrelevant —
**that does not work**, because `hdr->size` is non-zero for fixed-size tags
(it carries a logical length for slices, ropes and split headers). Use a
per-row `elem_shift` of a sentinel value meaning "ignore size", or add a
`uint8_t elem_bytes` of 0. Concretely:

```cpp
size_t s = t.base + (size_t)h->size * t.elem_bytes;   // elem_bytes == 0 for fixed
```

A multiply by a table-loaded byte is 3 cycles and fully pipelined — still far
better than a mispredicted indirect branch. `Tag_Free` (`size` is the byte
count) and `Tag_Array` (capacity) remain the two special rows.

**Guard:** a `static_assert` per tag comparing the table row against the
existing `switch` result for a synthetic header, plus a unit test that walks
every `Tag` value. HEAP_003/HEAP_004 require the size logic to stay a pure
function of `Header.tag`; the table is that, more explicitly.

**Item 25.** `evacuate` computes the size at `:1027` to size the `memcpy`.
The Cheney loop then recomputes it for the stride. Thread it: have
`copyToSpace` record the size into the caller's local and have `scanObject`
return the stride, so the loop becomes
`scan_ptr_ += scanObject(scan_ptr_, ...)`.

**Item 26.** With #25 the `scanObject` switch is the only remaining dispatch
per object. Leave it — it does real per-tag work. What it should stop doing is
recomputing the size.

**Item 28 (old gen).** `markOneObject` (`OldGenSpace.cpp:1868`) evaluates
`walkStepFor(blocks_[blk_idx], getObjectSize(obj))`, and `walkStepFor`
(`:190-195`) **discards** the second argument whenever
`block.size_class < NUM_SIZE_CLASSES` — i.e. for every uniform page. Hoist:

```cpp
const BlockInfo& b = blocks_[blk_idx];
const size_t step = (b.size_class < NUM_SIZE_CLASSES)
    ? classToSize(b.size_class)
    : getObjectSize(obj);
```

---

## W4 — Slot scanning (items 29–32)

### Item 29/30 — iterate only the boxed slots

The `Custom` (`:1400`), `Record` (`:1412`) and `Closure` (`:1431`) loops test
every slot — Int, Float and Char included — with a bitmap reload, a shift, a
mask, a compare and a call. The bitmap cannot be hoisted by the compiler
because `evacuateUnboxable` writes through `Unboxable&` into the same object.

`pointerMaskFromKindBitmap` (`Heap.hpp:279-286`) already derives the 1-bit
mask, but it loops per slot, so it is not usable as-is on the hot path.
Replace with a branchless bit trick — for a 2-bit-per-slot bitmap, slot i is
boxed iff both bits are clear:

```cpp
// even bits of ~b, ANDed with odd bits of ~b, compacted to 1 bit per slot
inline uint64_t boxedMask(uint64_t b, unsigned n) {
    uint64_t lo = ~b & 0x5555555555555555ULL;        // even bits set where bit0 clear
    uint64_t hi = (~b >> 1) & 0x5555555555555555ULL; // ... where bit1 clear
    uint64_t m  = lo & hi;                            // 1 at even position 2i
    m = _pext_u64(m, 0x5555555555555555ULL);          // compact (BMI2)
    return n >= 64 ? m : m & ((1ULL << n) - 1);
}
```

`_pext_u64` requires BMI2. The `release` preset already targets
`-march=x86-64-v3` (`CMakePresets.json`), which includes BMI2; the `build`
preset does not. Provide a portable fallback (the existing loop) selected by
`__BMI2__`, and keep both behind one `inline`.

Then:

```cpp
uint64_t m = boxedMask(c->unboxed, n);
while (m) {
    unsigned i = __builtin_ctzll(m);
    m &= m - 1;
    evacuate(c->values[i].p, oldgen, promoted_objects);
}
```

One bitmap load per object instead of one per slot, and unboxed slots cost
nothing at all.

**Item 31.** `ElmArray` (`:1546`, `:1583`) and `ListBacking` (`:1511`) have a
single *uniform* kind for the whole array, yet still route each element
through `evacuateUnboxable(elem, is_boxed, ...)`, re-testing the flag in the
callee. Hoist the test out and run a tight `evacuate`-only loop when boxed;
skip the loop entirely when not.

**Item 32 — "no boxed slots" header bit.** `Header.refcount : 15`
(`Heap.hpp:168`) is documented as *"Reference count (unused currently)"*.
Steal one bit as `no_boxed_slots`, set at allocation when the kind bitmap has
no zero-kind slot in range.

Then `scanObject` and `markChildren` can early-out before the tag dispatch:

```cpp
if (ECO_LIKELY(hdr->no_boxed_slots)) return;   // Int, Float, Char, String,
                                               // ByteBuffer, all-primitive
                                               // Custom/Record/Tuple/Array
```

**This is the riskiest item in the plan** and must be staged:

- The bit must be set on **every** allocation path — `initHeaderForTag`, the
  HEAP_034 inline-alloc header word composed by
  `value_enc::composeHeader` (so the compiler must compute it too), the
  region-slicing paths, kernel builders, `eco_pap_extend`'s copy, promotion's
  `memcpy` (which preserves it), and `PermanentSpace`'s deep copy.
- A stale *set* bit is a missed trace → use-after-free. A stale *clear* bit is
  merely slow. So the compile-time default must be **clear**, and setting it
  must be opt-in per path.
- Under `ECO_HEAP_VALIDATE`, ignore the bit and scan anyway, asserting that a
  set bit implies no boxed slot was found.
- Land the validator first, then the setters, then the early-out, as three
  commits.

Given the risk, gate W4-item-32 on W4-items-29/31 having measured a win; if
the mask loop already collapses the cost, the bit buys little.

---

## W5 — Minor-GC structure (items 33–37, 53, 55)

**Item 33 — delete the redundant loop.** Phase 2 (`:485-489`) is
`while (scanHasMore()) { scanObject(...); scan_ptr_ += getObjectSize(...); }`.
Phase 3's outer loop (`:510-520`) opens with an identical inner `while`.
Deleting Phase 2 is behaviour-preserving because phase 3 runs unconditionally
immediately after. Keep the `#if ECO_HEAP_VALIDATE` phase markers.

**Item 35 — `promoted_objects`.** Declared inside `minorGC` (`:418`), so it
mallocs and doubles from zero every cycle, during the pause. Make it a member
`std::vector<void*> promoted_buf_;` with `clear()` (not `shrink_to_fit`) at
cycle start so capacity is retained. It is `push_back`-ed at `:1070`, `:1225`,
`:1743` and index-walked at `:518`.

**Item 36 — root iteration order.** Phases 1a (`:424`) and 1c (`:445`) iterate
`std::unordered_set` in bucket order: a pointer chase per node, and roots
touched in random address order. Replace `RootSet::roots` and `jit_roots` with
sorted `std::vector`s plus a `bool dirty_` re-sort on first GC after a change.
`addRoot`/`removeRoot` are O(1) today and become O(log n) lookup + O(n)
erase — acceptable because registration is rare (literal interning and CAF
slots) while iteration is per-GC. **Measure the registration rate first**
(`RuntimeExports.cpp:688` is the hot registration site).

**Item 37 — `std::function` external scanners.** `RootSet.hpp:91-92` defines
`EvacuateFn = std::function<void(uint64_t&)>` and
`ExternalRootScanner = std::function<void(EvacuateFn)>` **taking the inner
function by value**. The lambda at `NurserySpace.cpp:474` captures
`[this, &oldgen, &promoted_objects]` = 24 bytes, which exceeds libstdc++'s
16-byte SBO, so it heap-allocates — per scanner, per GC — plus an indirect
call per root. Replace both with a C-style pair:

```cpp
using EvacuateFn = void (*)(void* ctx, uint64_t& slot);
struct ExternalRootScanner { void (*fn)(void* ctx, EvacuateFn, void* evacCtx); void* ctx; };
```

Seven registration sites to update: `Scheduler.cpp:56-71`,
`RuntimeExports.cpp:4396-4405` (list scratch stack, HEAP_040),
`PlatformRuntime.cpp:101`, `PortRuntime.cpp:260`, `HttpExports.cpp:292`,
`TimeEffectManager.cpp:78`.

**Item 53 — prefetch the Cheney scan.** The scan walks to-space linearly.
Maintain a second cursor `kPrefetchDistance` objects ahead and
`__builtin_prefetch(next)` each iteration. The stride is only known by
walking, so keep a small ring of the next few object addresses computed as the
loop advances. Start at distance 4; make it a `HeapConfig` knob for sweeping.

**Item 55 — per-object stats calls.** `GC_STATS_MINOR_INC_{SURVIVORS,PROMOTED}`
expand to out-of-line calls into `GCStats.cpp:448-456`, once per surviving and
once per promoted object, each doing a bounds check plus 2–3 counter
increments plus a `Tag_Custom` special case. Move the bodies into
`GCStats.hpp` as `inline`. Do **not** delete them: `objects_promoted` and the
LH1 per-tag retention histogram are the metric the whole Tier-2 promotion work
is ranked by (`benchmarks/tier2-opt.md` Run H).

**Item 34 — measurement, not a change.** The hybrid-DFS Cons path (`:1460`,
`:1657-1835`) traverses every list spine three times: `evacuateListSpine`
copies the cells, `evacuateListHeads` re-walks them, and the Cheney scan
reaches them anyway. `use_hybrid_dfs` is already a `HeapConfig` bool
(`AllocatorCommon.hpp:466`, default true), so this is a one-line A/B — run it
in the `gc-param-sweep-experiment` harness and record the answer rather than
guessing.

---

## W6 — Old-gen virgin-page bump (items 10, 15)

### Item 10 — bump virgin pages instead of pre-slicing them

`populateFromBlock` (`OldGenSpace.cpp:1235-1330`) takes a fresh 512 KiB page
and slices it into `num_cells = page_size / cell_bytes` cells — **21,845 for
a 24-byte class** — each getting an 8-byte header `memset` plus, for Tier-M
sizes, `next_in_class` + `prev_in_class` + a per-block thread link. The
allocator then pops those cells back off one at a time, in order.

Two kinds of space want two structures:

- **Recycled** space (holes from dead objects): arbitrary address, order and
  size. A free list is right, and **nothing here changes it** — sweep still
  coalesces, `pushSpanOnFreeLists` (`:2327-2380`) still carves runs into
  `classToSize` cells onto `free_lists_[cls]`.
- **Virgin** space (a page that never held an object): contiguous, consumed in
  address order. A bump cursor computes the same answers with no list.

**Design.** Add a per-class virgin cursor:

```cpp
struct VirginCursor { size_t block_index; char* ptr; char* end; };
VirginCursor virgin_[NUM_SIZE_CLASSES];   // ptr == nullptr => none
```

`allocateFromSizeClass` (`:917`) gains a step between (1) and today's (2):

```
(1) tryPopFromFreeList(cls)                      — recycled, reuse first (UNCHANGED)
(1b) virgin_[cls].ptr + cellSize <= .end  →  bump, return            (NEW)
(1c) claim a page from unassigned_blocks_ into virgin_[cls], goto 1b (NEW)
(2..7) today's splitting / sweep-on-demand / bag-page / panic ladder (UNCHANGED)
```

Reuse-before-grow is preserved: the free-list pop stays step 1, which is what
`plans/sweep-on-demand-allocation.md` requires. A page is bump-filled exactly
once, while virgin; after its first sweep it is recycled space forever.

**The block keeps `size_class = cls`,** so `walkStepFor` (`:190`) still gives
sweep a fixed stride and the mark bitmap is unchanged. Nothing becomes
"mixed". This is the difference from an earlier "promotion PLAB" idea, which
tagged destinations `NUM_SIZE_CLASSES` and lost fixed-stride sweep.

**The enabling field already exists.** HEAP_024 defines
`BlockInfo.end_of_objects` with exactly the two meanings needed:
`BlockInfo.end` for fully-populated pages (`populateFromBlock:1275`) and the
bump frontier for bump-filled blocks (`allocateForEvacuation:3805`, which is
already a working bump allocator — just only reachable from the dead
compaction path). Sweep walks `[start, end_of_objects)`, so the un-bumped tail
is never parsed and needs no headers.

**The case to get right: a page half-bumped when a GC fires.**

- `startMark` must not treat the virgin tail as live or dead — it is outside
  `end_of_objects`, so mark never sees it. Verify `resetBufferMetaForMark`
  (`:1880`) and `finalizeMetaAfterMark` (`:1892`) use `end_of_objects`, not
  `end`.
- Sweep must **not** reset `end_of_objects`; dead cells in the swept prefix go
  to the free list as normal, and `virgin_[cls]` keeps its cursor.
- `reclaimAllDeadBlocksFromMeta` (`:3403`) may release a block whose
  `live_bytes == 0` — if that block is a live virgin cursor, the cursor must
  be invalidated. Add that check.
- `maybeShrinkCapacity` (`:2869`) likewise.

Test: `GCVirginPageTest` — fill a class partway from a virgin page, force a
major GC, assert `end_of_objects` unchanged, assert the cursor still allocates
contiguously afterwards, assert swept cells from the prefix reappear on the
free list.

**Item 15.** `tryAllocateBySplittingLarger` (`:977-1077`) first-fit scans
larger size-class lists cell by cell; each list is unbounded. With item 10 in
place this path is hit far less often (virgin space no longer routes through
splitting), so **measure before optimising it** — it may become cold enough to
leave alone.

Flag: `ECO_VIRGIN_BUMP=0` disables (default OFF until measured).

---

## W7 — Promotion-path sweep coupling (item 14)

`OldGenSpace::allocate:662-665` drives `lazySweep(cls, sweep_work_budget)`
whenever `gc_phase_ == Sweeping` — including when the caller is promotion
inside a minor GC. The code's own comment at `:673-676` names this **"the
dominant source of minor GC outliers"**.

`g_in_minor_gc` is already maintained (`NurserySpace.cpp:377`, `:881`) and
already consulted for stats attribution (`:692`). Gate the sweep drive on it:

```cpp
if (gc_phase_ == GCPhase::Sweeping && !g_in_minor_gc) {
    lazySweep(sizeClass(size), config_->sweep_work_budget);
}
```

**This is a policy change, not a pure win.** Sweep work deferred out of the
minor pause still has to happen, and `plans/sweep-on-demand-allocation.md`'s
sweep-before-grow discipline exists to stop the heap growing while unswept
garbage remains. Promotion that skips sweeping may fall through to
`allocateFromBagPage` and grow committed capacity sooner, pulling majors
forward.

So: measure **minor-GC pause distribution** (the 39-bucket histogram in
`GCStats.hpp:99-113` already exists) *and* majors-per-run together. Accept
only if the outlier tail shrinks without majors increasing.

---

## W8 — Mark-side data structures (items 38, 40, 51, 52, 54)

Also the prerequisite for parallel marking (working-list #57–#63), which is
the largest single algorithmic win available (mark = 92.4% of major GC).

**Item 40 — flatten `mark_bits_`.** Today `std::vector<std::vector<uint8_t>>`
(`OldGenSpace.hpp:514`): one heap allocation and one pointer indirection per
block, and `isMarkedInBlock` / `setMarkBitInBlock` / `testAndClearMarkBitInBlock`
(`hpp:1006/1021/1041`) each re-check `block_index >= blocks_.size()`,
`blocks_[i].is_large` and `byte_index >= bits.size()` — four branches per bit
operation.

Replace with one arena plus a per-block offset:

```cpp
std::vector<uint8_t> mark_arena_;        // all blocks' bitmaps, contiguous
std::vector<uint32_t> mark_offset_;      // parallel to blocks_
```

Block bitmap size is `bitmapBytesForBlock` (already exists). Because blocks
are fixed-size pages, the offset is `block_index * bytesPerPageBitmap` for
regular blocks; large blocks keep the existing single-byte
`large_block_mark_`. That makes the offset a multiply, not a lookup, and the
bounds checks collapse to one.

**Item 38 — `nursery_visited_`.** `std::unordered_set<void*>`
(`OldGenSpace.hpp:478`) gets one malloc plus a hash per distinct live nursery
object, inside the mark pause. Major GC must not write colours into nursery
headers, hence the side set. Replace with a bitmap over the nursery extent:
the nursery is a contiguous slice pair (HEAP_042) with known base and
capacity, and objects are 8-byte aligned, so `(addr - base) >> 3` indexes a
bit. `capacity/8/8` bytes = 1 MiB per 64 MiB side. Allocate once at
`initialize`, `memset` at `startMark`.

**Item 51.** `Allocator::isInNursery` (`Allocator.cpp:434-436`) is an
out-of-line cross-TU call — TLS `tl_heap_` then `nursery_.contains` — invoked
twice per marked object (`OldGenSpace.cpp:1784` in `pushMarkRoot`, `:1839` in
`markOneObject`) for what is two range compares. Hoist the nursery bounds into
the `MarkContext` that `plans/blockindexfor-and-mark-stack-perf.md` already
proposes, and compare inline.

**Item 52.** `markOneObject:1869` does
`buffer_meta_[blk_idx].live_bytes += step` — a scattered read-modify-write
into a third array, on top of the object header and the mark bit. For the
single-threaded case, accumulate into a small per-block cache keyed on the
last-touched index (marking has strong block locality); for the parallel case
this becomes per-worker accumulation merged at the barrier (#59), so
**implement it as per-accumulator from the start**.

**Item 54 — mark prefetching.** `gc_handbook/02-mark-sweep.md §2.6`: insert a
FIFO of 8–32 entries between the mark stack and the scan, prefetching each
object as it enters the FIFO and processing from the far end.
`plans/blockindexfor-and-mark-stack-perf.md` already caches the block index on
the mark-stack entry; the FIFO composes with it. Do this **after** item 40 —
prefetching into a pointer-chased bitmap helps much less than into a flat one.

---

## W9 — Old-gen bookkeeping (items 41–47)

All O(n²) or repeated-walk fixes. Low risk, low individual value, but they
compound on a multi-GB heap and they are the difference between a major GC
that scales and one that does not.

**Item 41.** `fixupIndicesAfterBlockMove` (`:3150`) walks **all** of
`buffer_meta_` per released block, and `reclaimAllDeadBlocksFromMeta` (`:3403`)
and `maybeShrinkCapacity` (`:2869`) release blocks in a loop → O(released ×
#blocks). Fix: maintain `buffer_meta_` indexed *by* block index rather than
carrying a `block_index` field, so a swap-remove of `blocks_[i]` is a
swap-remove of `buffer_meta_[i]` with no scan. If the field must stay, batch
the fixup: collect all moves, then do one pass.

**Item 42.** `releaseBlockToAllocator` (`:3258-3271`) iterates the entire
`large_body_index_` hash map per released block, plus a linear scan of
`free_large_blocks_` (`:3228-3235`). Add a per-block list of large-body ids so
the release touches only its own.

**Item 43.** `transitionToSweeping` (`:2469-2475`) walks every free cell in
the heap to clear a rare `age == 0b01` sentinel, then immediately discards the
lists. Since the lists are being discarded, the sentinel only matters for
cells that survive into the next cycle — track those on a small side list when
`freeLargeBodyCell` sets the sentinel, and walk only that.

**Item 44 — NOT a simple deletion.** The bulk mark-bitmap zero at `:1548-1551`
has a documented reason (`:1537-1547`): the "bitmap is zero between cycles"
invariant breaks when the mutator pops a cell off a free list mid-sweep —
`initObjectHeader` sets the bit but sweep has already passed that block. The
fix is to **restore the invariant**, by clearing the mark bit in the
free-list pop path (`finalizePoppedCell`), then deleting the bulk zero. Verify
under `ECO_HEAP_VALIDATE` with an assertion that the arena is all-zero at
`startMark` before removing the memset.

**Item 45.** `allocateFromEmptyRegularBlocks` (`:1396`) linearly scans every
block per large allocation. Maintain a free-block list.

**Item 46.** `markLargeBodySeen` (`:4289`) does an `unordered_map` lookup per
split-header scanned, called from `NurserySpace.cpp:1620`/`:1626`;
`promoteLargeHeader` (`:4301-4315`) linearly scans `nursery_owned_bodies_` per
promoted header. Store the `LargeBodyId` **in the header object itself** —
`Tag_LargeStringHeader`/`Tag_LargeByteHeader` are 16 bytes
(`static_assert` at `Heap.hpp:469`) with a spare `Header` word; the id fits in
the unused `refcount` bits. Then both operations are O(1) with no table.

**Item 47.** The sweep inner loop does `large_body_index_.find(sweep_cursor_)`
per pinned string/bytebuffer cell (`:2653`), described in its own comment as a
*"defensive idempotent guard"*. With item 46's in-header id this becomes a
field read.

---

## W10 — Stackmap lookup (item 56)

`StackMap::findRecord` (`StackMap.cpp:292`) does an `unordered_map` lookup per
stack frame, including frames that can never match (GC entry, allocator
internals). Acknowledged as deferred at
`plans/stackmap-unwinder-gc-roots.md:133`.

The walk runs at **every** minor GC as well as every major
(`ThreadLocalHeap.cpp:530`, `:587`). Cheap improvements, in order:

1. Sort the record keys once at parse and binary-search — better cache
   behaviour than a hash on a table that is never mutated after startup.
2. Record the `[lo, hi)` address range of all statepoint return addresses at
   parse time and range-check before searching; runtime/allocator frames fall
   outside and skip the lookup entirely.
3. Only if still visible: a small direct-mapped cache keyed on the low bits of
   the return address. Stack shapes repeat heavily across GCs.

---

## Validation

Protocol from `guides/perf-tune-loop.md` and `benchmarks/lss-opt.md:18-75`.

**Per package:**

1. `--target check` for C++-only packages (W0, W1, W2, W3, W4, W5, W7, W8,
   W9, W10). W6 is also C++-only. None of this changes `.mlir`, so
   `--target full` is not required — this is the CLAUDE.md carve-out that
   `inline-bump-state-tls.md:120` relied on.
2. E2E green, flag-on and flag-off.
3. **Self-compile output byte-identical**, and **GC counters identical**
   (minor count, major count, objects promoted, promoted MB). Those counters
   are deterministic per binary×tree — proven at n=6 in
   `benchmarks/lss-opt.md` Run R — so any movement is a behaviour change and
   must be explained before the package lands. W1, W6 and W7 are the
   exceptions: they deliberately change allocation/sweep timing, so for those
   record the new counters and justify them.
4. Heap-validate build green (mandatory for W1, W4-item-32, W6, W8).
5. Cold Stage-7a wall A/B, **census-off**. `inline-bump-state-tls.md:152`
   records that quoting a census-on delta would have been a measurement error.
   Record wall, max RSS, minors, majors, promoted MB, `Total GC/Alloc time`,
   `out.mlir` size.

**Disposition rule.** Several of these will be flat, as
`inline-bump-state-tls` was. A flat-but-correct package that deletes work
still ships — that is the precedent set by `inline-bump-state-tls`,
`stringLengthOp` (−0.12%) and `appendSplit` (+0.80%), all default-on. But it
is recorded as **flat**, not as a win, and the wall number goes in
`benchmarks/`.

---

## Risks

**R1 — Most of this is instruction-count reasoning on a memory-bound
workload.** `inline-bump-state-tls.md:181` is explicit: *"the self-compile is
GC- and memory-bound (135 s of 460 s in the allocator alone), so ALU/call
cycles on the allocation path are not the critical resource."* Expect several
packages to measure flat. W1 (measured 5.6%), W4 (removes memory traffic, not
just ALU) and W8 (enables parallel marking) are the ones with a mechanism
beyond instruction count.

**R2 — W4 item 32 can cause use-after-free.** A `no_boxed_slots` bit that is
wrongly set means an object's children are never traced. Staged landing plus a
validator that ignores the bit is mandatory, and the default must be clear.

**R3 — W1.2 touches the compiled-code allocation fast path.** `bump_.end` is
consumed by `expandInlineAllocs` (HEAP_034) and by `applyCapacityHoisting`
(CGEN_074). A third meaning for a bump miss must be handled in **both**
`allocateSlow` and `ensureNursery`, and HEAP_041's "exactly one meaning"
wording amended.

**R4 — W6 and W7 change allocation and sweep timing**, so they move major-GC
counts. Judge them on majors-per-run and RSS together with wall, never wall
alone. `plans/gc-mark-driven-live-lazy-sweep.md` and
`plans/sweep-on-demand-allocation.md` are the policy context.

**R5 — W9 item 44 is not the deletion the working list implied.** The bulk
zero guards a real invariant break. Restore the invariant first.

**R6 — W5 item 36 trades registration cost for iteration cost.** Measure the
root registration rate before converting `unordered_set` to sorted vectors;
`RuntimeExports.cpp:688` (literal interning) is the hot registration site and
may be hotter than assumed.

**R7 — W3's size table must stay in lockstep with the `Tag` enum.** HEAP_004
requires every new heap type to update `getObjectSize`; a table makes that a
silent row-missing bug rather than a compile error. Add a
`static_assert(std::size(kTagSize) == Tag_Forward + 1)` and a test that walks
every tag.

---

## Sequencing

```
W0 ──────────────────────────────────────────► (free, land immediately)
W1.3 (investigate) ─► W1.1 ─► W1.2            (biggest measured cost)
W2 ─► W3 ─► W4(29,31) ─► W4(32)               (minor-GC inner loop)
W5                                             (independent)
W6 ─► W7                                       (old-gen allocation policy)
W8(40) ─► W8(38,51,52) ─► W8(54)              (also unblocks parallel mark)
W9                                             (independent)
W10                                            (independent)
```

W0, W5, W9 and W10 have no dependencies and can land at any time. W8 item 40
gates the rest of W8 and is the prerequisite for working-list #58. W1.3's
investigation may make W1.2 unnecessary, so run it first.
