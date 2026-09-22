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

### Line-number provenance — read before using any citation

Line numbers were taken against the tree of **2026-09-21**. On **2026-09-22**
Phase 1 of the sibling plan (`gc-root-registration-cost.md`, the TLS shadow
stack) landed and modified nine allocator files: `RootSet.{hpp,cpp}`,
`RuntimeExports.cpp`, `ThreadLocalHeap.cpp`, `AllocatorCommon.hpp`,
`Allocator.cpp`, `HeapHelpers.hpp`, `Heap.hpp`, `NurserySpace.cpp`.

Spot-checked drift in those files is **−1 to +6 lines** (e.g.
`NurserySpace::evacuate` `:919`→`:918`; the `promoted_objects` vector
`:418`→`:412`; `clearToSpaceFreeRegion`'s call site `:533`→`:536`;
`Header.refcount` `Heap.hpp:168`→`:171`). `OldGenSpace.{hpp,cpp}`,
`GCStats.{hpp,cpp}` and `StackMap.cpp` are **unchanged**, so every W3/W7/W8/W9
citation into those files is still exact.

Every citation in this plan names the **function** as well as the line —
trust the name, re-locate the line. Two premises were re-verified after the
landing and still hold verbatim: item 36 (`roots`/`jit_roots` are still
`std::unordered_set`, `RootSet.hpp:312-313`) and item 37
(`ExternalRootScanner` is still `std::function<void(EvacuateFn)>` taking the
inner function by value, `:297-298`, with the 24-byte capturing lambda still at
`NurserySpace.cpp:477`).

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
| **W4** | Slot scanning | 29–31 (**32 gated**) | *bound* | medium |
| **W5** | Minor-GC structure | 33,34,35,37,53,55 (**36 closed**) | *bound* | low |
| **W6** | Old-gen virgin-page bump | 10, 15 (counter first) | *bound* | medium |
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

### Which tags are actually exposed (static narrowing — do this first, it is free)

The exposure is not "every allocation". It is exactly those tags whose **scan
extent is `hdr->size` with no separate fill counter**, because only those trace
slots the mutator has not written yet. Walking `scanObject` (`:1358-1636`):

| tag | scan extent | exposed? |
|---|---|---|
| `Custom`, `Record`, `Closure`, `DynRecord` | `hdr->size` = full field count | **yes** |
| `Tuple2`, `Tuple3`, `Cons`, `ConsChunk` | fixed slot count | **yes** |
| `FieldGroup` | `hdr->size` | **yes** |
| `Array` | `arr->length`, **not** capacity (`:1582`) | no — `allocArray` sets `length = 0` (`HeapHelpers.hpp:1660`) and it grows only as slots are filled |
| `ListBacking` | `[hd, hdr->size)` = whole capacity | no — `listBacking` memsets its own element area for boxed kinds (`HeapHelpers.hpp:684`) |
| `String`, `ByteBuffer`, `StringUtf8Leaf`, `Int`, `Float`, `Char` | pointer-free | no |
| slices / ropes / split headers | fixed, 1–2 slots | **yes** |

Two findings worth stating plainly:

- **`Array` is safe by construction**, and the `length`/`capacity` split is
  precisely why. `getObjectSize` strides by capacity (`AllocatorCommon.hpp:322`)
  while the scan iterates `length`, so the uninitialised tail is stepped over
  and never read. That is the pattern the exposed tags lack.
- **`ListBacking` was already fixed locally**, with the rationale written down
  at `HeapHelpers.hpp:663-666`. Somebody already hit this once and solved it for
  one tag.

So the instrumentation below only needs to cover the "yes" rows, and the second
half of the problem — the **per-object kind bitmap word at offset 8**
(`Custom.ctor|unboxed`, `Record.unboxed`, `Closure.unboxed`), which
`initHeaderForTag` does not clear — applies only to `Custom`, `Record` and
`Closure`.

### Investigation

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

5. For each reported site, classify: (a) a safepoint genuinely falls between
   the header write and the last field store, or (b) the object is a
   `builder`-bit object, which HEAP_BUILDER_001 *deliberately* exposes to
   tracing while half-built. Class (b) cannot be closed by compiler work — a
   builder is traced by design — so those sites need the `listBacking`
   treatment (zero the slot area at allocation), not a safepoint fix.

**Decision rule.** If every class-(a) site is closable and every class-(b) site
is given a local memset, delete the bulk zeroing entirely and keep the poison
fill under `ECO_HEAP_VALIDATE` as the permanent regression guard. If class (a)
is large, W1.2 is the answer and this investigation still pays for itself by
telling you so cheaply.

**Do this investigation before W1.2** — it may make W1.2 unnecessary, the
static narrowing above is free, and the instrumentation is ~30 lines.

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

**Item 20 — branch hints.** `NurserySpace.cpp` contains no `__builtin_expect`
at all. House style is the **raw builtin**, not a macro — there are six uses
(`Allocator.hpp:69`, `Allocator.cpp:938`, `HeapHelpers.hpp:639`,
`RuntimeExports.cpp:382`, `:4876`) and no `ECO_LIKELY` exists. Match that;
introducing macros is a separate style change and should not ride along here.

Hints to place, with the direction argued rather than assumed:

| site | hint | why |
|---|---|---|
| `ptr.ptr_ind != 0` (`:920`), `ptr.ptr == 0` (`:922`) | unlikely | boxed slots dominate; constants are filtered by the bitmap in item 29 |
| `!isInFromSpace` after item 17's reorder | **likely** | in steady state most edges point at to-space, old gen or permanent |
| `hdr->tag == Tag_Forward` (`:993`) | likely | mid-scan, most in-from-space targets are already evacuated |
| promotion predicate (`:1041`) | unlikely | promotion is the minority per surviving object |

Note the two existing `Tag_Forward` hints point **opposite ways** —
`Allocator.hpp:69` says unlikely (a mutator deref, forwarding is the rare
post-GC window) while `RuntimeExports.cpp:4876` says likely (a chase loop that
only runs when already forwarded). Direction is context-dependent here too:
inside `evacuate` mid-scan it is likely, which is the opposite of the mutator
path it superficially resembles. Get this wrong and the hint costs rather than
pays, so put the reasoning in the comment.

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

**Item 32 — "no boxed slots" header bit. ⚠ GATED ON A MEASUREMENT THAT ALREADY
EXISTS; likely to be closed.** *(Re-assessed 2026-09-22 after a full header-writer
inventory.)*

The idea: steal one of the 15 unused `Header.refcount` bits (`Heap.hpp:171`,
bits [16,31); `builder` is bit 31) as `no_boxed_slots`, so `scanObject` and
`markChildren` can early-out before the tag dispatch. The inventory says the
mechanics are workable but the **addressable population is small and the two
dominant tags are excluded**.

### Which tags could ever set it

| tag | bitmap location | can set? |
|---|---|---|
| Int, Float, Char | none | **yes** — pointer-free by construction |
| String, StringUtf8Leaf, ByteBuffer | none | **yes** |
| `Tag_Free` | none | **yes** |
| Tuple2 / Tuple3 | `header.unboxed`, static at write | yes, when all slots primitive |
| Record | separate word at +8, constant on the inline path | inline path only |
| **Custom** | separate word at +8, and the non-inline path writes `unboxed = 0` as a **placeholder** later patched by `eco_set_unboxed` (`RuntimeExports.cpp:253-288`, `:1389`, `:1409`) | **inline path only, all-primitive only** |
| **Cons** | `header.unboxed` bits 1:0 describe the **head only**; `tail` is always `HPointer` | **never** |
| **ElmArray** | `allocArray` writes `unboxed = 0` as a placeholder; the kind is bound **lazily on first push** (`HeapHelpers.hpp:1857`, `:1876`, `if (idx == 0)`) and patched wholesale at 16 `JsArrayExports.cpp` sites plus `eco_array_set_fix_kind` | **never** |
| **Closure** | capture kinds written **incrementally across GC points** by `closureCapture` (`HeapHelpers.hpp:1968-2013`), so boxedness is not final until all captures land | **never** |

`Cons` and `Custom` are **97.4% of everything promoted** (Run H). `Cons` is
structurally excluded and `Custom` only qualifies on the inline path with an
all-primitive bitmap. So the reachable population is roughly "boxed scalars and
strings" — which is exactly the set the retention census puts at ≤2.6%.

### The gate: a histogram that is already collected but not printed

The scan cost follows objects **scanned** (survivors + promoted), not promotion
alone, and the survived-by-tag distribution has never been reported — Run H
printed only `promoted_*_by_tag`. But `GCStats::recordSurvival(tag, bytes,
nfields)` already fills `survived_count_bytes_by_tag` alongside it.

**So the measurement is a reporting change, not an instrumentation change.**
Print the survived-by-tag histogram and read off the share of scanned objects
that are pointer-free scalars and strings.

- **≥15% of scanned objects** → item 32 is worth its risk; proceed with the
  staging below.
- **Below that** → **close the item.** The risk/benefit does not justify it,
  and items 29/31 already remove the per-slot cost that motivated it.

### If it proceeds — what the inventory changes

Two findings make it safer than first assumed:

1. **Default-off is free everywhere.** No producer writes `refcount` today, so
   every one of the ~60 header writers already emits 0 in that window. Only
   paths that must set 1 need editing; nothing needs a defensive clear.
2. **The regression test already exists.**
   `assertHeaderPreservedAcrossCopy` (`NurserySpace.cpp:909-914`,
   `ECO_HEAP_VALIDATE`) explicitly asserts `dst->refcount == src.refcount`
   across all six minor-GC copy sites (`:1055`, `:1131`, `:1220`, `:1239`,
   `:1738`, `:1757`). Stealing a refcount bit makes that assert the free
   invariant check for every evacuation and promotion.

Three hazards it surfaces:

3. **`composeHeader` has no parameter for bits [16,31)**
   (`EcoToLLVMInternal.h:305-320`) — a new argument plus **13 call sites**
   (6 in `EcoToLLVMHeap.cpp`, 6 in `EcoToLLVMValueAgg.cpp`, 1 in
   `EcoToLLVMClosures.cpp`). The inline and non-inline paths must change in
   lockstep or `ECO_INLINE_ALLOC=0` diverges.
4. **`installForwardingPointer` writes only `tag`**
   (`OldGenSpace.cpp:3864`, `NurserySpace.cpp:1141/1251/1763`), leaving the
   rest of the header live on the tombstone. Anything reading the bit off a
   `Tag_Forward` header sees the *dead* object's value. The early-out must be
   ordered after the forwarding check, not before.
5. **`PermanentSpace::promoteValue` (`PermanentSpace.cpp:295-311`) edits
   nothing after its memcpy** — not even `color`. It inherits the bit verbatim,
   which is correct only if the source was correct.

### Landing order (three commits, unchanged)

1. Field + `ECO_HEAP_VALIDATE` check that scans as today and asserts a set bit
   implies no boxed slot. Nothing sets it yet.
2. Setters for the unambiguous tags only (Int, Float, Char, String,
   StringUtf8Leaf, ByteBuffer, `Tag_Free`). Validator now exercises them.
3. The early-out, after a full self-compile and E2E under `ECO_HEAP_VALIDATE`
   with zero failures.

Order within W4: land **29 and 31 first**, then print the survived-by-tag
histogram, then decide 32. Both gates must pass — a pointer-free share ≥15% of
scanned objects, *and* items 29/31 not already having collapsed the per-slot
cost that motivated the bit. On current evidence 32 is more likely to be closed
than built, and that is a fine outcome: the inventory it required is reusable
for any future header-bit work (item 46 included).

---

## W5 — Minor-GC structure (items 33–35, 37, 53, 55; 36 closed)

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

**Item 36 — root iteration order. ✗ CLOSED, NOT WORTH DOING.**

The proposal was to replace `RootSet::roots` / `jit_roots` with sorted vectors
because iterating an `unordered_set` in bucket order is cache-hostile. The
premise was right; the magnitude is not. **Measured root counts on a
self-compile are `longLived=4 jit=0`** — `benchmarks/runtime-calls.md:1372-1400`
(Run AA, the `[gc-roots]` line from `GCStats.cpp:1787-1792`).

They used to be ~15–20K long-lived and 1,562 JIT. HEAP_036's CAF permanent
space collapsed them: `plans/caf-permanent-space.md:1-11` records
*"longLived ~15-20K → 4, jit 1,562 → 0"*, because interned literals are now
born in the GC-invisible `PermanentSpace` and `internLiteral` roots a slot only
on the old-gen fallback path (`RuntimeExports.cpp:632-636`).

Iterating a 4-element set twice per GC is not a cost. **Do not do this item.**

Two facts worth keeping from the investigation, because they change other
things:

- **`removeRoot` and `removeJitRoot` are never called in production** — the
  only callers are `main.cpp` (the `ecor` synthetic demo) and `test/allocator/*`.
  The sets are add-only and startup-dominated. If a future workload does grow
  them, a plain append-only `std::vector` is then the obvious structure, with
  no erase problem to solve.
- **This retroactively devalues item 39** (see W0): `collectRoots()`'s
  by-value copy is a copy of four elements, ~10–17 times per run. Still worth
  the one-line fix because it is free and wrong-looking, but it buys nothing
  measurable. Do not cite it as a win.

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

**Item 53 — prefetch the CHILDREN, not the scan stream.** *(Re-specified
2026-09-22; the original framing was wrong.)*

Prefetching the to-space walk itself is close to worthless: it is a forward
sequential stride, which the hardware prefetcher already covers. The miss that
actually costs is the **child header load** in `evacuate:958` — which is
exactly why item 17 exists, and why `NurserySpace::evacuate` carries 5.46–8.26%
self time while the scan loop does not appear in the profile at all.

So prefetch each object's boxed children before processing them. This composes
directly with item 29's boxed mask — walk the mask twice:

```cpp
uint64_t m = boxedMask(c->unboxed, n);
for (uint64_t t = m; t; t &= t - 1)                 // pass 1: issue prefetches
    __builtin_prefetch(Allocator::fromPointerRaw(c->values[__builtin_ctzll(t)].p));
for (uint64_t t = m; t; t &= t - 1)                 // pass 2: evacuate
    evacuate(c->values[__builtin_ctzll(t)].p, oldgen, promoted_objects);
```

`fromPointerRaw` is pure arithmetic under HEAP_028 (the HPointer word *is* the
address), so a prefetch costs a load, a mask and the prefetch itself — no
branch. **Do not filter constants or nulls first:** `__builtin_prefetch` of a
bogus address is architecturally harmless on x86-64 and the branch would cost
more than the wasted prefetch. Add a one-line comment saying so, because it
looks like a bug otherwise.

Highest value on the wide shapes — `Custom` (60.7% of retention) and `Record`
— where several children can be in flight at once. For `Cons` (36.7%) the two
slots give one miss hidden behind another. Skip the double pass when
`popcount(m) <= 1`.

Order: land **after** item 29, which supplies the mask. — measurable on its
own via the evacuate self-time row.

**Item 55 — per-object stats calls.** `GC_STATS_MINOR_INC_{SURVIVORS,PROMOTED}`
expand to out-of-line calls into `GCStats.cpp:448-456`, once per surviving and
once per promoted object, each doing a bounds check plus 2–3 counter
increments plus a `Tag_Custom` special case. Move the bodies into
`GCStats.hpp` as `inline`. Do **not** delete them: `objects_promoted` and the
LH1 per-tag retention histogram are the metric the whole Tier-2 promotion work
is ranked by (`benchmarks/tier2-opt.md` Run H).

**Item 34 — hybrid-DFS A/B (a two-run experiment, fully specified).** The
hybrid-DFS Cons path (`:1460`, `:1657-1835`) traverses every list spine three
times: `evacuateListSpine` copies the cells, `evacuateListHeads` re-walks them
in to-space re-loading each header, and the Cheney scan reaches them anyway.
It buys allocation contiguity for list spines — `Cons` is 36.7% of retention,
so the bet is not obviously wrong, but it has never been measured.

No code change is needed: `use_hybrid_dfs` is a `HeapConfig` bool
(`AllocatorCommon.hpp:466`, default true) settable from the
`ECO_HEAP_CONFIG` JSON (`HeapConfigJson.cpp`).

**Protocol.** Two cold Stage-7a self-compiles, census-off, one binary, configs
`{"use_hybrid_dfs": true}` and `{"use_hybrid_dfs": false}`.

**What must NOT move**, and this is what makes it a clean A/B: the flag changes
*evacuation order*, not *what survives*. Promotion is driven by `age`, so
minors, majors, objects promoted, promoted MB and `out.mlir` must all be
byte/count identical. If any of them moves, the experiment is invalid — stop
and find out why before reading the wall.

**Decision rule.** Turn it off if flag-off improves wall by ≥1% or GC time by
≥2% with those counters identical. Keep it on otherwise. Record the result in
`benchmarks/` either way — a confirmed "the locality does pay" is worth as
much as a removal, because it closes the question.

**Second-order effect to watch:** flag-off changes survivor layout in
to-space, which changes mutator cache behaviour after the GC. Max RSS should be
unchanged; if it moves, the layout change is doing something unmodelled.

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
- **Small-class budget accounting.** `populateFromBlock` credits
  `small_class_bytes_` via `onUniformBlockDedicated` (`:550-556`); the release
  path debits via `onBlockReleased` (`:558-567`). The virgin path claims pages
  without going through `populateFromBlock`, so it **must credit the same
  counter** or `shouldPreferBagForSmallClass` (`:574-582`) silently stops
  firing and the 1 GiB budget becomes inert. Under the self-compile config
  every size class counts as "small", so this is not an edge case. See item 15
  for the full interaction.

Test: `GCVirginPageTest` — fill a class partway from a virgin page, force a
major GC, assert `end_of_objects` unchanged, assert the cursor still allocates
contiguously afterwards, assert swept cells from the prefix reappear on the
free list.

**Item 15 — add the counter that does not exist, then decide.** *(Premise
corrected 2026-09-22.)*

The working list said `tryAllocateBySplittingLarger` (`:987-1092`) first-fit
scans "larger size-class lists, each unbounded". **That is wrong for the
size-class path.** Line `:1027` is
`const size_t start_cls = std::max(target_cls, num_size_classes_);` — the walk
starts *at or above* `num_size_classes_`, so when called from
`allocateFromSizeClass` step (3) it never touches a uniform class list and
scans only the three mixed-only classes (16K/32K/64K at default config). The
comment at `:1010-1021` says why: `findBlockContaining` per cell is
O(#blocks) and "dominates Stage-7 mutator time", so uniform classes are
deliberately skipped.

Where the scan *is* potentially unbounded is the other caller:
`allocateFromBagPage` (`:1129`, `:1151`), where `start_cls == request_cls` so
the request's own class is included. That is the **primary** allocator for the
whole `[large_object_threshold, alloc_buffer_size)` band (routing doc at
`:605-612`), not a fallback. It is also reached from `tryAllocateFromFreeLists`
(`:795`), called twice per iteration by `sweepOnDemandAllocate` (`:885`,
`:901`).

**There is no counter for split hits anywhere** — `GCStats` has no
split-related field and `tryAllocateBySplittingLarger` contains no
`GC_STATS_*` macro. So step one is instrumentation, not optimisation:

- count entries, cells walked, and hits, split by caller (size-class step 3 /
  bag-page / sweep-on-demand);
- report cells-walked as a histogram, since the question is tail behaviour.

Decide only then. If the bag-page caller dominates and walks deep lists, the
fix is a per-class "largest available" hint or a segregated remainder list; if
it is shallow, close the item.

### Interaction with item 10 that must be settled first

`shouldPreferBagForSmallClass` (`:574-582`) disables the bag-first arm once
`small_class_bytes_ >= small_class_heap_budget_bytes` (default **1 GiB**,
`AllocatorCommon.hpp:180`), pushing those allocations onto splitting until a
major GC releases pages and the live census drops back. Under the self-compile
config (`compiler/cmake/bootstrap/build-kernel/heap-config.json:28-29`,
`small_class_cell_max_bytes == large_object_threshold == 8K`) **every size
class counts as "small"**, so the budget applies universally and 1 GiB against
a 12 GiB old-gen cap is a reachable ceiling.

`small_class_bytes_` is credited in `onUniformBlockDedicated` (`:550-556`) and
debited in `onBlockReleased` (`:558-567`). **Item 10's virgin-page path must
participate in that accounting** — if it claims pages without crediting
`small_class_bytes_`, the budget silently stops working and the splitting
fallback never engages; if it double-counts, bag-first shuts off early. Add
this to item 10's checklist and to `GCVirginPageTest`.

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

### Acceptance criteria

Three legs, cold Stage-7a, census-off: **A** = today, **B** = the full gate
above, **C** = the throttled fallback below. Every leg reports the 39-bucket
minor-pause histogram (`GCStats.hpp:99-113`, already recorded), majors-per-run,
peak RSS, and wall.

Accept **B** iff all three hold:

1. **p99 minor pause improves by ≥20%.** The histogram's top buckets are the
   claim being tested — the comment says outliers, so the mean is the wrong
   statistic. If the mean moves but p99 does not, the diagnosis was wrong.
2. **Major GC count does not increase.** Majors are 10–17 per run and each is
   ~5 s of mark, so one extra major erases a large pause win.
3. **Peak RSS does not increase by more than 5%.** This is the sweep-before-grow
   discipline showing up as committed capacity.

### Fallback if (2) or (3) fails — throttle rather than gate

Deferring *all* sweep work out of the minor pause is the aggressive reading.
The conservative one keeps the mutator-help property but caps the latency
contribution:

```cpp
if (gc_phase_ == GCPhase::Sweeping) {
    size_t budget = g_in_minor_gc
        ? config_->sweep_work_budget / config_->minor_sweep_divisor   // new knob, default 8
        : config_->sweep_work_budget;
    lazySweep(sizeClass(size), budget);
}
```

Add `minor_sweep_divisor` to `HeapConfig` so leg C is a config change, not a
rebuild, and so the `gc-param-sweep-experiment` harness can sweep it (1 = today,
∞ = full gate). **Run all three legs in one session** — the three-way comparison
is the deliverable, not a yes/no on B.

### Also fix the accounting while here

`sweepOnDemandAllocate` can burn up to `max_sweep_bytes_per_alloc` (4 MiB,
`AllocatorCommon.hpp:191`) inside a single allocation, and when that allocation
is a promotion the whole cost lands in minor-GC time. Whatever leg wins, add a
counter for *sweep bytes driven from inside a minor GC* so the next reader can
see the coupling directly instead of inferring it from a pause histogram.

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

**Item 54 — mark-stack FIFO prefetch buffer.** Unlike item 53's case, the mark
stack is LIFO with no spatial locality at all, so `gc_handbook/02-mark-sweep.md
§2.6`'s FIFO genuinely applies: interpose a ring between `mark_stack.pop_back()`
and `markOneObject`, prefetch on entry, process from the far end.

```cpp
// OldGenSpace::incrementalMark, replacing the pop/markOneObject pair at :1611
MarkStackEntry fifo[kMarkFifo];              // kMarkFifo = 16, power of two
size_t head = 0, tail = 0, fill = 0;

while (units_done < work_units) {
    while (fill < kMarkFifo && !mark_stack.empty()) {
        MarkStackEntry e = mark_stack.back(); mark_stack.pop_back();
        __builtin_prefetch(e.obj);           // header, and usually slot 0
        fifo[head] = e; head = (head + 1) & (kMarkFifo - 1); ++fill;
    }
    if (fill == 0) break;
    MarkStackEntry e = fifo[tail]; tail = (tail + 1) & (kMarkFifo - 1); --fill;
    if (markOneObject(e.obj, e.block_index)) ++units_done;
}
```

**Correctness note that makes this safe:** the mark bit is set on *push*, in
`pushMarkRoot` (`:1780-1804`), not on pop. So an object sitting in the FIFO is
already marked and cannot be enqueued twice — the buffer changes only the
*order* of processing, never the set. Say this in the commit message; it is the
question a reviewer will ask.

Two consequences to handle: `incrementalMark` is called in a loop until it
returns false (`:2012`), so the FIFO must be **drained before returning**, not
carried across calls — keep it a local. And `mark_stack_peak` telemetry
(`:2053`) now undercounts by up to `kMarkFifo`; either add `fill` or note it.

Order: land **after** item 40. Prefetching into a `vector<vector<uint8_t>>`
bitmap chases a pointer per probe, which is most of what the prefetch was
supposed to hide.

---

## W9 — Old-gen bookkeeping (items 41–47)

All O(n²) or repeated-walk fixes. Low risk, low individual value, but they
compound on a multi-GB heap and they are the difference between a major GC
that scales and one that does not.

**Item 41 — delete a dead field and the O(n²) loop it justifies.** *(Design
choice resolved 2026-09-22; it is smaller than either option first offered.)*

`fixupIndicesAfterBlockMove` (`OldGenSpace.cpp:3150-3213`, sole caller
`releaseBlockToAllocator:3356`) opens with

```cpp
for (auto& m : buffer_meta_) { if (m.block_index == old_idx) m.block_index = new_idx; }
```

and `reclaimAllDeadBlocksFromMeta` / `maybeShrinkCapacity` release blocks in a
loop → O(released × #blocks).

**`buffer_meta_` is already strictly parallel to `blocks_`.** Every mutation
keeps them index-identical: the four push sites (`:1203/:1209`, `:1293/:1300`,
`:1487/:1494`, `:3851/:3853`), the swap-remove (`:3322-3334`), the compaction
erase (`:4145-4147`) and `clear` (`:310/:311`). And
`BufferMetadata::block_index` is **written in three places** (`:1897`, `:2007`,
`:3157`) and **read nowhere** — the only read is the self-comparison inside
that loop. Every real consumer indexes `buffer_meta_[i]` with an index derived
from `blocks_` or `blockIndexFor()`.

So the fix is: **delete the field and delete the loop.** No restructuring.

What must **not** be deleted — the rest of the function patches other index
holders and is not O(#blocks): `evacuation_set_`, `free_large_blocks_`,
`evac_block_index_`, `sweep_buffer_index_`, `fixup_buffer_index_`
(`:3160-3168`), and the Tier-M `CellHandle::block_index` back-links
(`:3186-3212` — a *different* field that happens to share the name).

Two things to add while removing it, because the parallelism is currently
maintained by convention rather than enforced:

1. A debug assertion `buffer_meta_.size() == blocks_.size()` at the top of
   `resetBufferMetaForMark`, `prepareMetaForLazySweep` and
   `releaseBlockToAllocator`. Today `releaseBlockToAllocator` computes
   `meta_last` and `last` *separately* (`:3322` vs `:3329`), and ~20 read sites
   defensively guard with `i < buffer_meta_.size()` — those guards exist
   because the resize helpers only ever grow.
2. A note in `OldGenSpace.hpp` that the two vectors are index-identical by
   invariant. That is what makes the deletion safe, so it should be written
   down rather than rediscovered.

Latent bug this also removes: after the compaction `erase` loop (`:4138-4148`)
the surviving `block_index` values are stale and are only renormalised at the
next `resetBufferMetaForMark`. Harmless today because nothing reads them —
which is exactly the argument for deleting the field.

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
promoted header. Store the `LargeBodyId` **in the header object itself**, in
the unused `Header.refcount` bits, so both operations become O(1) with no table.

**Width problem, and the fix.** `LargeBodyId` is `uint32_t`
(`OldGenSpace.hpp:564`) but `Header.refcount` is only **15 bits**, so a naive
store silently truncates any id ≥ 32768. Ids are recycled through
`free_large_body_ids_` (`:577`), so the bound is the *concurrent* large-body
high-water mark rather than the lifetime total — at an 8 KiB
`large_object_threshold` that is ≥256 MiB of live large bodies before it can
bite. Plausible, but not guaranteed by anything.

So reserve a sentinel: `0` = "no id stored", `1..32766` = id + 1,
`0x7FFF` = "id too large, consult `large_body_index_`". `registerLargeBody`
(`:965`) writes the sentinel when the id does not fit; `markLargeBodySeen` and
`promoteLargeHeader` fall back to today's lookup on the sentinel. That keeps
the fast path for every realistic workload without a truncation bug hiding in
the tail. Assert under `ECO_HEAP_VALIDATE` that a stored id round-trips.

**Item 32 interaction:** item 32 also wants a bit out of `refcount` (bits
[16,31), `Heap.hpp:171`). Item 32 is now gated and more likely to be closed than
built, so **item 46 should not wait for it** — take 15 bits (ids `1..32766`,
`0` = none, `0x7FFF` = overflow) and put the split in one `constexpr` block in
`Heap.hpp`. If item 32 later proceeds it takes one bit back and narrows the id
field to 14, updating that one block and its `static_assert`.

Both items benefit from the same two facts the header-writer inventory turned
up: no producer writes `refcount` today, so the field is genuinely free; and
`assertHeaderPreservedAcrossCopy` (`NurserySpace.cpp:909-914`) already asserts
`refcount` equality across all six minor-GC copies, so whatever is stored there
is checked across every evacuation and promotion under `ECO_HEAP_VALIDATE` at
no extra cost.

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
The header-writer inventory reduced this risk materially — the field is
untouched by every producer, and `assertHeaderPreservedAcrossCopy` already
checks it across all six copy paths — but it also showed the reachable
population is small, which is why the item is now gated on the survived-by-tag
histogram rather than scheduled. **Two exclusions are structural and must not
be argued around:** `Cons` (the tail is always a pointer) and `ElmArray` /
`Closure` (their kind bitmaps are bound lazily, after allocation and across GC
points).

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
W0 ───────────────────────────────────────────────► (free, land immediately)
W1.3 (investigate) ─► W1.1 ─► W1.2                 (biggest measured cost)
W2 ─► W3 ─► W4(29,31) ─┬─► W4(32)                  (minor-GC inner loop)
                       └─► W5(53)                  (53 needs 29's boxed mask)
W5(33,34,35,37,55)                                  (independent)
W6(10) ─► W6(15 counter) ─► W7                      (old-gen allocation policy)
W8(40) ─► W8(38,51,52) ─► W8(54)                    (also unblocks parallel mark)
W9                                                  (independent)
W10                                                 (independent)
```

Cross-package dependencies, all introduced by the 2026-09-22 revision:

- **53 → 29.** Child prefetching walks the boxed mask item 29 builds. Landing
  53 first means writing the mask twice.
- **54 → 40.** Prefetching into a `vector<vector<uint8_t>>` bitmap chases a
  pointer per probe, which is most of what the prefetch should hide.
- **32 ↔ 46.** Both want bits out of `Header.refcount`; they must agree one
  field split in a single `constexpr` block.
- **15 → 10.** Item 10 changes how often splitting is reached *and* must
  participate in the small-class budget accounting that gates it.

W0, W9 and W10 have no dependencies. W8 item 40 gates the rest of W8 and is the
prerequisite for working-list #58 (parallel marking), which is the largest
algorithmic win available anywhere — so W8 has value beyond its own delta.
W1.3's investigation may make W1.2 unnecessary, so run it first.
