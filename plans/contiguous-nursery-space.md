# Contiguous nursery space: one extent per semi-space, and a right-sized old-gen/nursery address split

**Status: COMPLETE — IMPLEMENTED, GATED AND BENCHMARKED 2026-08-09. All
five steps landed; all six correctness gates PASSED; Run O recorded in
benchmarks/tier2-opt.md. Verdict **KEEP**: wall FLAT (both arm pairs split
by leg, as the §0 caution prior predicted), kept for the non-wall wins —
nursery slow-path entries **417,585 → 316 (1,321×)**, **RSS −2.56%**, the
deletion of the entire block apparatus, and trigger fidelity that is
EXACTLY unchanged (871 minors / 10 majors / 4 grow events / byte-identical
`out.mlir` on every leg). M1 (contiguous per-heap slice extents) and M2 (configurable
old-gen/nursery split, default 4 GiB nursery / 20 GiB old gen on the 24 GiB
reservation) are both in the tree and DEFAULT-ON with no env flag: M2's
rollback is a config key (`nursery_region_bytes: "12G"` restores the legacy
layout bit-for-bit), M1's is a revert of its single commit (§9). The block
apparatus — block vectors, per-block indices, the clamp-vs-exhaustion
disambiguator, the tail-gap tracking (`block_end_of_objects_`,
`advanceScanIfNeeded`, `verifyToSpaceBlockEndOfObjects`) and the
`nursery_block_advances` counter — is deleted, not ported. Invariants
HEAP_042/043 landed; HEAP_034/041 amended; THEORY.md, the theory doc and
the gc-diagnostics recipe swept. Gates so far: unit suite **1628/1628**,
full E2E `--target full` **1628/1628**. See §4's per-step as-built logs;
the one design correction the tests forced is in Step 2's deviation note.**

**Census status (Step 1, 2026-08-09) — see §3.3's C0 MEASURED block. Both
decisions it gated resolved: (a) the minors-drift term is ZERO (mean
abandoned tail 47.7 B ⇒ 0.059 cycles), so gate 5 is exact equality at 871
minors / 10 majors / 4 grow events, not a slack band; (b) `trig_press=0
trig_alloc=0` with an old-gen peak of 3.97 GiB against a 10.2 GiB trip —
the address split costs Stage 7a nothing today, M2 ships as pure geometry,
and its 4 GiB default is confirmed (20 GiB old-gen cap = 5.0× the observed
peak).**

**Original status: PLANNED (grounded 2026-08-09 via a five-reader fan-out
over the allocator, codegen backend, platform layer, invariants and prior
plans, then adversarially verified; all anchors code-read that session —
re-grep before editing, treat line numbers as "near here"). Scope:
SINGLE-THREADED implementation; multi-threading is DISCUSSED (§7) but
explicitly not implemented. Sequencing: land the §3.3 census FIRST (zero
risk) — its numbers pick M2's default region size and calibrate the
minors-drift gate.**

File paths: allocator = `runtime/src/allocator/`; codegen =
`runtime/src/codegen/`; tests = `test/allocator/`.

## 0. The idea, and the honest expectation

The nursery is a semi-space copying collector built from 512 KiB blocks
(`ALLOC_BUFFER_SIZE`, AllocatorCommon.hpp:77). `bump_.end` is a PER-BLOCK
limit, so an object can never straddle a block boundary and every 512 KiB of
allocation takes the slow path (`allocateSlow` block advance, or compiled
code's `eco_alloc_inline_slow` / `eco_ensure_nursery_slow`). Measured on
Stage 7a (this plan's C0 census, §3.3): **312,952 block advances + 104,633
ensure misses against 871 minor GCs** — the slow path is entered ~360× more
often than GC requires.

**M1 — contiguous from-space:** make each semi-space ONE contiguous VA
extent, so `bump_.end` becomes the threshold-clamped end of the ENTIRE
from-space. Slow entries collapse from ~313 K to ~871 (= minors). Blocks are
already handed out sequentially from a contiguous reserved region and the
recycling freelists are empty for the whole lifetime of a normal
single-threaded process (§1.4) — contiguity holds today BY ACCIDENT; M1 makes
it hold BY CONSTRUCTION via fixed-size per-heap slices of the nursery region.

**M2 — re-divide the address space:** `nursery_offset = heap_reserved / 2`
(Allocator.cpp:215) gives old gen 12 GiB and the nursery 12 GiB of a 24 GiB
reservation. A single-threaded process can touch at most 512 MiB of the
nursery region (**4.17%** of it, §1.1) while old gen is the side that
actually hits its wall (GlobalPressure trigger at 0.85 × 12 GiB = 10.2 GiB,
hard wall at 12 GiB). Make the split configurable and move it: old gen gets
the reservation minus a right-sized nursery region.

**Caution prior (tier pattern ×9, and this arc's own Run N):** wall follows
RETENTION, not allocation-path shape. The slow entries being deleted amount
to **~1 per 20,800 allocations** (advances only; ~1 per 15,600 counting the
104,633 ensure misses too — ≈99.994% fast-path hit rate, measured §3.3) —
small absolute time. The honest case for M1 is: slow-entry elimination, a large NET CODE
DELETION (the whole per-block iteration/tail-gap apparatus, §2.2),
strictly simpler HEAP_041 semantics (the clamp-vs-exhaustion disambiguator
and the index-rewind fail-soft both dissolve), STRONGER validators
(full-prefix from-space walks become legal — no tail gaps exist), and
un-conflated trigger telemetry (a slow entry now MEANS a GC trigger). The
base expectation for the C2 wall is FLAT; the decision rule in §5 treats
flat as a keep on simplification grounds, per the capacity-hoisting
precedent. M2's wall effect on Stage 7a is likely nil (old-gen peak likely
≪ 10.2 GiB — census §3.3 confirms); M2 is about larger workloads and about
not lying to ourselves with a 50/50 split neither side wants.

## 1. Ground truth (2026-08-09, code-read)

### 1.1 Address-space layout, and the TWO independent halvings

- `Allocator::initialize()` (Allocator.cpp:168-222): reserves
  `max_heap_size` (default 24 GiB, `DEFAULT_MAX_HEAP_SIZE`
  AllocatorCommon.hpp:74) below `HPOINTER_ADDRESS_LIMIT` = 2^43 (Heap.hpp:66,74)
  via `reserveAddressSpaceBelow` — POSIX: `mmap PROT_NONE,
  MAP_NORESERVE, MAP_FIXED_NOREPLACE`, probing 1 TB-aligned bases
  (PlatformVirtualMemory_posix.cpp:24-48); Win64: `VirtualAlloc MEM_RESERVE`
  (…_win32.cpp:16-41). **`nursery_offset = heap_reserved / 2`**
  (Allocator.cpp:215). Old gen = `[heap_base, +nursery_offset)`; nursery =
  the top half, itself halved into a low region
  `[nursery_offset, +nursery_space/2)` and a high region (Allocator.cpp:451-454,
  510-514). Defaults: old gen 12 GiB; nursery 6 GiB low + 6 GiB high.
- **Second, independent halving:** `OldGenSpace::committedToCapRatio`
  (OldGenSpace.cpp:795-804) divides per-thread committed by
  `config_->max_heap_size / 2` — NOT by `nursery_offset` (comment :791-794
  calls it a "stand-in for the global old-gen cap"). Consumers: the
  sweep-budget pressure steps (`computeSweepBudgetForAlloc`,
  OldGenSpace.cpp:826-837; `SWEEP_CAP_RATIO_*` 0.50/0.75/0.90) and
  `shouldPreferBagForSmallClass` (:574-582). **M2 must move both halvings
  together** or sweep pacing silently misprices pressure.
- Major-GC triggers (`evaluateMajorGCTrigger`, OldGenSpace.cpp:2720-2785;
  priority Occupancy > GlobalPressure > GarbageFraction):
  1. **Occupancy** (per-thread): `allocated_bytes / getCommittedBytes()
     >= 0.85` (`MAJOR_GC_INITIATING_OCCUPANCY`).
  2. **GlobalPressure** (the ONLY trigger coupled to the address split):
     global `old_gen_in_use_bytes_ / getOldGenMaxBytes() >= 0.85`
     (`MAJOR_GC_GLOBAL_PRESSURE_FRACTION`), where `getOldGenMaxBytes()`
     returns `nursery_offset` (Allocator.hpp:227) — trip point 10.2 GiB
     today. History: this constant's raise from ~0.28 was Run K (majors
     103 → 12; AllocatorCommon.hpp:136-145).
  3. **GarbageFraction** (per-thread): `(allocated − post_sweep_live) /
     committed >= 0.70`.
  4. **Alloc-failure** (hard): old-gen allocate() returns null →
     `majorGC()` + retry, only in `allocateLargePinned`
     (ThreadLocalHeap.cpp:327-341).
  Post-major, `adjustCapacityAfterMajorGC` (OldGenSpace.cpp:2787-2831)
  grows/shrinks the per-thread region toward `live / 0.50`
  (`MAJOR_GC_TARGET_UTILIZATION`), clamped to `getOldGenMaxBytes()`; when
  global committed/cap ≥ the pressure fraction the shrink HYSTERESIS is
  overridden — shrink is FORCED even inside the band (:2901-2905 comment,
  :2929 guard `!global_pressure && (...)`). Trigger attribution is already recorded:
  `major_gc_{occupancy,alloc_failure,garbage,global_pressure}_triggers`
  (GCStats.hpp:400-411, printed GCStats.cpp:1022-1031) — §3.3's census reads
  these, no new instrumentation needed.
- The old-gen cap is consumed by a **monotonic high-water bump**
  (`old_gen_committed`, never decremented — Allocator.cpp:662-672); released
  blocks recycle via `old_gen_free_blocks_` first-fit without moving the
  bump. So "old gen hits the cap" = lifetime high-water, not live bytes.
- `Allocator::reset(new_config)` (Allocator.cpp:766-801) never re-reserves
  or recomputes `nursery_offset` — **first init wins for process lifetime**
  (test comments TestHelpers.cpp:73-75 confirm this is known/relied on).
  After a reset with a different `max_heap_size`, `nursery_offset` and
  `committedToCapRatio`'s `max_heap_size/2` diverge — a pre-existing trap M2
  inherits and must not widen.
- Reservation-size implications (for anyone tempted to just raise
  `max_heap_size`, which is ALREADY runtime-tunable via `ECO_HEAP_CONFIG`
  key `max_heap_size`, HeapConfigJson.cpp:161-202): PROT_NONE+MAP_NORESERVE
  reservations carry no Linux commit charge and Windows MEM_RESERVE is
  near-free, but **RLIMIT_AS counts reserved address space** — a 64 GiB
  reserve fails outright under a lower `ulimit -v`. M2 therefore re-divides
  the EXISTING 24 GiB by default rather than growing it.
- `PermanentSpace` precedent: a separate 8 GiB reservation OUTSIDE
  `[heap_base, +heap_reserved)` but below 2^43 (PermanentSpace.cpp:40-56) —
  proof that a disjoint-reservation nursery is representable (parked in
  §2.8; it would amend HEAP_012's "unified heap address range" wording).

### 1.2 The block machinery being replaced

- Acquisition (`acquireNurseryBlockLow/High`, Allocator.cpp:435-548, under
  `thread_mutex_`): exact-size freelist scan, else commit at
  `region_base + committed_` and bump. Sequential acquisitions are
  physically adjacent. Freelists (`nursery_{low,high}_freelist_`,
  Allocator.hpp:277-278) are fed by exactly ONE caller: `~NurserySpace()`
  (NurserySpace.cpp:71-85, Issue #40 — spawn-heavy = repeated
  initThread/cleanupThread cycles, §1.4).
- `NurserySpace` (per ThreadLocalHeap, by value — ThreadLocalHeap.hpp:206):
  two `std::vector<char*>` block sets `low_blocks_`/`high_blocks_`, 128
  blocks per side initially (`NURSERY_BLOCK_COUNT` 256 total = 64 MiB/side),
  growth +50% per event to `NURSERY_MAX_BLOCKS` 1024 total (= 256 MiB/side),
  symmetric-or-abort — the abort LEAKS the acquired blocks
  (NurserySpace.cpp:561-569). Growth inserts sorted (:571-580).
- Per-block bump limit: `computeAllocEndForBlock` (NurserySpace.cpp:413-431)
  clamps `bump_.end` to min(block end, proactive-threshold trip), where the
  trip is `threshold_total_bytes_ = capacity × nursery_gc_threshold` (0.95)
  and `already_full = current_from_idx_ × block_size_`; an already-past-
  threshold state fail-softs to the full block end. `allocateSlow`
  (:271-323) disambiguates a miss via `bump_.end >= block_end`: genuine
  exhaustion → advance (`GC_STATS_NURSERY_BLOCK_ADVANCE`), abandoning the
  current block's tail; clamped → signal GC. `ensureHeadroom` (:330-360)
  replicates the same walk without allocating (HEAP_041);
  `failSoftUnclampCurrentBlock` (:362-393) must rewind `current_from_idx_`
  by linear-searching for the block containing `bump_.ptr` before unclamping.
- To-space mirrors it: `copyToSpace` (:437-466) advances blocks and records
  `block_end_of_objects_[current_to_idx_]` so the Cheney scan
  (`advanceScanIfNeeded`, :479-495) can skip each abandoned block's
  UNINITIALIZED TAIL GAP; `verifyToSpaceBlockEndOfObjects` (:2223-2256)
  audits that bookkeeping under ECO_HEAP_VALIDATE; `clearToSpaceFreeRegion`
  (:2115-2128) zeroes the free region per block (load-bearing — ghost-header
  protection, comment :795-800). Phase-5 swap (:1105-1121):
  `current_from_idx_ = current_to_idx_`, `bump_.ptr = copy_ptr_`,
  `bump_.end = computeAllocEndForBlock(...)`.
- The abandoned-tail fact that matters for trigger fidelity: today
  `bytesAllocated()` (:397-404) counts abandoned tails as allocated
  (`current_from_idx_ × block_size_`), so the threshold trips slightly
  EARLIER in real-object terms than a gap-free space would. §3.3 measures
  total tail waste; §6's minors gate uses it.

### 1.3 The compiled-code ABI — what may and may not change

- `NurseryBump{char* ptr; char* end;}` at offsets 0/8 is static_assert-pinned
  ABI (NurserySpace.hpp:47-52); these ARE the allocator's working fields.
  `eco_bump_state()` (RuntimeExports.cpp:183-193) exports the address,
  declared `memory(none)+gc-leaf+speculatable` (address CSE legal).
- `expandInlineAllocs` (EcoBackend.cpp:991-1116) emits per HEAP_034 marker:
  `call eco_bump_state` → load ptr@+0 / load end@+8 → plain GEP top+SIZE
  (SIZE constant ≤ 4096) → `icmp ugt` → fast: store newTop / slow:
  statepointed `eco_alloc_inline_slow(SIZE)` → phi. CGEN_074-covered markers
  emit the unchecked form (load/GEP/store — no end read at all). The ensure
  diamond (HEAP_041, EcoBackend.cpp:2241-2268) is the same compare with a
  cold `eco_ensure_nursery_slow(runBytes)`.
- **KEY GROUNDING RESULT: compiled code breaks NOTHING under the
  end-of-from-space redefinition.** The emitted IR never computes
  `end − ptr` beyond the single unsigned compare, never loads or derives
  block size, block starts, or indices, and never assumes
  `end − ptr ≤ 512 KiB`. A bigger `end` only means fewer misses. No IR test
  pins a distance (test/codegen/inline_alloc_tuple.mlir checks symbols
  only). The 1:2^20 branch weights stay valid (misses get RARER). The only
  512-KiB references in codegen are comments (EcoBackend.cpp:145-146,
  :963-965, :1031-1033, :2236-2238) — rewrite them, no behavior change.
- Runtime helpers behind the slow edges:
  `eco_alloc_inline_slow` (RuntimeExports.cpp:202-212) = `allocateFast`
  (block-advance retry, no GC) then `allocateSlowRaw`
  (ThreadLocalHeap.cpp:230-252: one `minorGC()` + retry + HEAP_017 abort;
  asserts size < `large_object_threshold`, never routes to old gen).
  Contract to compiled code: returns UNINITIALIZED nursery storage, never
  null — **unchanged by this plan**. `eco_ensure_nursery_slow`
  (RuntimeExports.cpp:227-231) → `ThreadLocalHeap::ensureNursery`
  (:254-282): ensure → GC+ensure → `failSoftUnclampCurrentBlock`+ensure →
  abort. Ladder shape unchanged; two of its three rungs simplify (§2.6).
- Everything that DOES assume block-granular `end` is runtime-internal:
  `allocateSlow`'s disambiguator, `ensureHeadroom`'s loop,
  `failSoftUnclampCurrentBlock`'s index rewind, `computeAllocEndForBlock`,
  `bytesAllocated`, the to-space machinery, and the validate-only walkers
  (inventory in §2.2).

### 1.4 Threading reality (why "single-threaded" is the true v1 target)

- One `ThreadLocalHeap` per `std::thread::id` via `Allocator::initThread()`
  (Allocator.cpp:240-272), cached in `constinit thread_local tl_heap_`.
  Exhaustive call-site audit: AOT binaries (eco_entry.cpp:103; the one Elm
  thread via pthread_create :330), embed hosts (eco_embed.cpp:190),
  `ecoc` (ecoc.cpp:331), the JIT test runner (EcoRunner.cpp:231, sequential
  cycles), and the synthetic benchmark driver (main.cpp:651-725,
  `--threads N`) — **the benchmark driver is the ONLY path where more than
  one heap is alive simultaneously**. A normal Elm program has exactly one
  heap over its lifetime. The three service workers (Timer/Http/Wait) never
  touch HPointers; Elm `Process.spawn` creates green processes on the same
  OS thread (Scheduler.cpp:426-436).
- Consequently the nursery block freelists are EMPTY for the whole lifetime
  of a normal process (sole feeder is `~NurserySpace`), and each side's
  blocks are one contiguous ascending run. Even Issue-#40 recycling
  (sequential heap lifecycles) preserves address order — only CONCURRENT
  heaps interleave acquisitions. This is the "accidental contiguity" M1
  turns into a guarantee.
- Cross-thread references cannot exist (HEAP_007; values cross threads as
  plain bytes — PORT_004, PortRuntime.cpp:110-113, 446-462). GC of one
  thread never stops others; there is no STW machinery at all. `OldGenSpace`
  is per-thread by value (ThreadLocalHeap.hpp:207) carving interleaved
  blocks from the shared old-gen region under `thread_mutex_`.

### 1.5 Counters and the motivating numbers

- `nursery_block_advances` (GCStats.hpp:89, bumped at NurserySpace.cpp:297
  and :358) and `ensure_slow_calls` (GCStats.hpp:84, bumped
  ThreadLocalHeap.cpp:261). Trap: NurserySpace, OldGenSpace and
  ThreadLocalHeap keep SEPARATE GCStats objects — advances live on
  `nursery.getStats()`, ensure calls on the heap's.
- Stage 7a baseline — **re-measured by this plan's C0 (§3.3), superseding
  the memory note**: **312,952 advances / 104,633 ensure calls / 871
  minors** (359.3 advances per minor cycle, ~360×); ~1 slow entry per
  20,800 allocations. Cross-check: 312,952 × 512 KiB = 164.06 GB ≈ 6.5 B
  objects at ~25 B mean — matches TRUE ALLOC 6.52 B against the reported
  18,545.61 MB (the standard counters are inline-alloc-blind by 8.8×).
  Post-M1 expectation: advances counter DELETED; total slow entries ≈
  minors (871) + ensure misses.
- Capacity-hoisting Run N context (plans/capacity-check-hoisting.md §12):
  minors 871 ≡ 871, majors 10, `eco_alloc_inline_slow` static sites −68.7%,
  wall FLAT. The next free benchmark name in benchmarks/tier2-opt.md is
  **Run O** — verify before claiming (§5).

### 1.6 Traps found while grounding (pre-existing, inherited or fixed here)

1. `wouldExceedThreshold` (NurserySpace.cpp:433-435) has ZERO callers
   repo-wide — delete with the rewrite.
2. `NurserySpace::reset` (:176-228) clears the block vectors WITHOUT
   releasing them — a leak on every test-path reconfigure. The extent
   rewrite fixes this for free (release the slice, §2.2).
3. `nursery_max_block_count` is NEVER validated against the nursery region
   (AllocatorCommon.hpp:538-551 checks only evenness/ordering); exhaustion
   surfaces as runtime nullptr + the asymmetric-growth leak. §3.1 adds the
   missing validation.
4. Dead code: the second `total >= large_object_threshold` block in
   `allocateRegionSlow` (ThreadLocalHeap.cpp:300-316) is unreachable — an
   identical `if` at :289-298 returns first (and asserts instead of
   majorGC-retrying). Not this plan's to fix; noted so nobody "fixes" it
   into the M1 diff.
5. `isNurseryNearFull` (ThreadLocalHeap.cpp:700-704) uses CONFIGURED
   capacity (`config_->nurserySize()/2`), ignoring growth — pre-existing
   wart; M1 switches it to the live `from_capacity_bytes_`. Its REAL
   consumers (verification finding): the safepoint-gating sites
   (ThreadLocalHeap.cpp:452,466) sit behind `__eco_safepoint_poll`, which
   has ZERO call sites repo-wide (declaration RuntimeExports.h:541,
   definition RuntimeExports.cpp:3981; the compiler emits no polls —
   Expr.elm:4501) — dead in every real binary; the one LIVE caller is the
   synthetic benchmark driver via `Allocator::isNurseryNearFull`
   (Allocator.cpp:387-389 → main.cpp:477, threshold 0.9). So the switch is
   observable only in the driver's GC-pacing loop — note it in the C2
   protocol if `--threads` arms are run.
6. `major_gc_global_pressure_fraction` has no `validate()` range check
   (only a JSON parse clamp) — tighten while §3.1 is in `validate()` anyway.
7. `__eco_safepoint_poll` is a dead export (see 5). Out of scope here —
   noted so nobody mistakes the §2.6 `isNurseryNearFull` change for a
   compiled-code behavior change.

## 2. Design — M1: contiguous per-heap nursery slices

### 2.1 The slice layer (Allocator)

Replace per-512 KiB block hand-out with fixed-size per-heap SLICES of the
nursery region. Two quantities that MUST stay distinct (verification
finding — the first draft conflated them): a heap's **capacity** (logical
extent length; what GC semantics, membership bounds and the threshold see)
vs a slot's **retained commit** (physical pages ever committed at that
slot; slice-layer-private, invisible to NurserySpace).

- `slice_bytes = min((nursery_max_block_count / 2) × alloc_buffer_size,
  per_side_region_bytes)` — the config-derived max-growth size (default
  1024/2 = 512 blocks per side × 512 KiB = **256 MiB per side**), CLAMPED
  to the runtime region so small-heap configs (e.g. OldGenCapacityTest's
  64 MiB heap / 64 KiB buffers with the default 1024-block cap) get a
  usable slot instead of a startup fatal; the per-heap growth ceiling is
  `min(slice_bytes, configured max)` so a clamp never RAISES a config's
  cap. One heap owns TWO slices at mirrored slot indices: low slice k at
  `[low_region_base + k·slice_bytes, +slice_bytes)`, high slice k likewise.
  Slice bases are page-aligned because `heap_base` is (mmap) and
  slice_bytes is an `alloc_buffer_size` multiple, with `alloc_buffer_size
  ≥ OS_PAGE_SIZE` validate-enforced (AllocatorCommon.hpp:560-565) — do NOT
  lean on region bases being "GiB-aligned" (the reserve fallback path is
  only page-aligned).
- New API (replaces `acquireNurseryBlockLow/High`,
  `releaseNurseryBlockLow/High` and both freelists; same `thread_mutex_`
  discipline):

```cpp
struct NurserySlicePair {          // one heap's nursery address estate
    char*  low_base;               // slice base in the low region
    char*  high_base;              // mirrored slice base in the high region
    size_t capacity;               // logical extent bytes, ONE value for
                                   // BOTH sides (equal by construction —
                                   // this is what makes the §2.7 swap
                                   // assert trivial)
    size_t slot;                   // slot index (bookkeeping)
};
// Claims a free slot with capacity = initial. Commits ONLY
// max(0, initial - retained_commit[slot]) fresh bytes per side — never
// re-commitAt an already-committed range: commitAt is a MAP_FIXED
// anonymous re-map (PlatformVirtualMemory_posix.cpp:60-65) that would
// DISCARD the retained pages, defeating retention and corrupting the
// committed accounting. Loud fatal on slot exhaustion, naming the two
// config knobs that size the geometry (§3.1). Thread-safe.
NurserySlicePair acquireNurserySlicePair(size_t initial);
// Raises capacity by delta (a multiple of alloc_buffer_size) on BOTH
// sides, committing only the portion above retained_commit[slot], and
// only up to the heap's growth ceiling. Returns false — changing
// NOTHING — if either side's fresh commit fails. Symmetry by
// construction: no asymmetric-growth abort, no leak.
bool growNurserySlicePair(NurserySlicePair& pair, size_t delta);
// Returns the slot to the free list. retained_commit[slot] keeps the
// high-water commit so an Issue-#40 respawn reuses committed pages —
// same physical-memory behavior as today's freelists. A respawned
// heap's capacity still starts at ITS configured initial (retained
// commit above capacity is dormant, not part of any extent).
void releaseNurserySlicePair(const NurserySlicePair& pair);
```

- **`Allocator::reset(new_config)` rebuilds the slot table from the
  (immutable, first-init-wins) region + the NEW config and DROPS every
  `retained_commit` record** — the extent analogue of today's freelist
  clear + counter zeroing (Allocator.cpp:793-799). Retention is only
  valid while slice geometry is unchanged; the unit-test suite flips
  `alloc_buffer_size` between 512 KiB and 16 KiB across resets
  (TestHelpers.cpp:13-24, :64-88), which moves every slot base — stale
  records would skip-commit unmapped pages (PROT_NONE fault). Accepting
  re-commit after reset is the safe, test-only cost.
- `nursery_low_committed_` / `nursery_high_committed_` remain as committed
  byte totals (dumpHeapState and the heap-trace milestones keep working);
  they become sums of retained commits over slots rather than region bumps.
- Slot count per side = `per_side_region_bytes / slice_bytes`. Under
  today's 6 GiB sides that is 24 slots — today's bound AT MAX GROWTH.
  Honesty note (verification finding): heaps that never grow past the
  64 MiB initial fit ~96-wide today; fixed slices trade that peak
  ungrown concurrency for guaranteed contiguity (24 @ default). The only
  >1-heap path is the benchmark driver (§1.4); `--threads N` for
  N ∈ (24, 96] regresses to the loud fatal even at the LEGACY split —
  carried as a §8 risk with its config mitigation. Under M2's shrunk
  region the bound tightens further (§3.1 table).
- Contiguity, and something today lacks: each heap's cached bounds
  (`low_base_/low_end_/…`) become EXACT. Today `contains()` /
  `isInFromSpace()` span `[front(), back()+block_size)` which "may include
  small gaps between blocks" (NurserySpace.hpp:206-207) — with concurrent
  heaps those bounds span OTHER heaps' blocks. Slices make the membership
  tests airtight per-heap. (Hardening, not a bug fix: no cross-heap
  pointers exist to be misjudged, HEAP_007.)

### 2.2 NurserySpace on extents: the collapse

Fields DELETED: `low_blocks_`, `high_blocks_`, `current_from_idx_`,
`current_to_idx_`, `scan_block_idx_`, `block_end_of_objects_`,
`block_size_` (geometry moves to the slice pair + capacity bytes).
Fields KEPT with unchanged meaning: `bump_` (ABI), `from_is_low_`,
`copy_ptr_`/`copy_end_`, `scan_ptr_`, `low_base_/low_end_/high_base_/
high_end_` (now authoritative extent bounds = **base + CAPACITY**, never
the slot's physical retained commit — membership tests must not widen past
the logical extent), `from_capacity_bytes_`, `threshold_total_bytes_`,
`growth_threshold_`, `gc_threshold_`, root set, stats, validate flags,
`minor_color_`. Both sides' capacities are the single
`NurserySlicePair.capacity` (§2.1), so from/to capacity equality is
structural.

Method-by-method (exhaustive inventory verified by repo-wide grep — the
per-block fields appear ONLY in NurserySpace.{hpp,cpp}; the only test user
of `NurserySpaceTestAccess` is EnsureHeadroomTest.cpp):

| Method | Today | Becomes |
|---|---|---|
| `initialize` ×2 (NurserySpace.cpp:87-174) | 128-iteration acquire loops + `std::sort` | one `acquireNurserySlicePair(initial_capacity)`; no sort |
| `reset` (:176-228) | clear vectors (LEAKS blocks, §1.6.2) + reacquire | release slice pair + reacquire — leak fixed |
| destructor (:71-85) | per-block release loops | one `releaseNurserySlicePair` |
| `updateBounds` (:230-246) | front()/back() derivation | bounds = base / base+capacity per side. If folded into callers, the callers are EXACTLY: both `initialize`s, `reset`, and `checkAndGrow` — growth is the one MID-LIFE capacity change and today's checkAndGrow calls updateBounds at :583 precisely because `isInFromSpace/isInToSpace/contains` drive evacuate's forwarding decisions; §2.5 keeps that call |
| `Allocator::reset` (Allocator.cpp:766-801) | zeroes committed counters + clears both freelists | rebuilds slot table + drops retained commits (§2.1) — the freelist-clear's replacement, NOT an optional nicety |
| `allocate` (:248-269) | bump vs clamped per-block end | **byte-for-byte unchanged** — the fast path is the point |
| `allocateSlow` (:271-323) | advance-or-signal disambiguator | stats bracket + `return nullptr` (a miss now always means GC; §2.3) |
| `ensureHeadroom` (:330-360) | advance loop with clamp guard | single compare: `(size_t)(bump_.end - bump_.ptr) >= n` |
| `failSoftUnclampCurrentBlock` (:362-393) | index rewind + per-block unclamp | one line: `bump_.end = from_base + from_capacity_bytes_` (rename `failSoftUnclamp`) |
| `bytesAllocated` (:397-404) | idx×block + offset | `bump_.ptr - from_base` |
| `computeAllocEndForBlock` (:413-431) | per-block clamp + already-full fail-soft | `computeAllocEnd()` (§2.3) — fail-soft clause SURVIVES in extent form |
| `wouldExceedThreshold` (:433-435) | dead | deleted |
| `copyToSpace` (:437-466) | bump + block advance + tail-gap record | pure bump + overflow assert |
| `scanHasMore` (:468-477) | block-index compare | `scan_ptr_ < copy_ptr_` |
| `advanceScanIfNeeded` (:479-495) | tail-gap skip | deleted (call sites :754, :782 drop) |
| `checkAndGrow` (:497-605) | ±N blocks, sorted insert, asymmetric-abort leak | §2.5 |
| minorGC to-space reset (:664-680) | indices + `block_end_of_objects_` fill | `copy_ptr_ = scan_ptr_ = to_base; copy_end_ = to_base + to_capacity` |
| phase-5 swap (:1105-1121) | index transfer + guarded end recompute | `from_is_low_ = !from_is_low_; refreshCapacityCaches(); bump_.ptr = copy_ptr_; bump_.end = computeAllocEnd();` |
| `clearToSpaceFreeRegion` (:2115-2128) | per-block memsets | ONE `memset(copy_ptr_, 0, to_end - copy_ptr_)` — stays UNCONDITIONAL (load-bearing ghost-header net) |
| `poisonOldFromSpaceUsedRegion` (:2149-2163) | per-block poison | one memset over `[from_base, bump_.ptr)` (validate-only) |
| `preEvacuationFromSpaceWalk` (:2176-2213) | CURRENT block only (prior blocks have tail gaps) | walks the ENTIRE prefix `[from_base, bump_.ptr)` — **strictly stronger validator** |
| `verifyToSpaceBlockEndOfObjects` (:2223-2256) + `findBlockContaining` (:2266-2277) | tail-gap audit | deleted (call at :1093 drops) |
| `isInFromSpaceAllocatedRegion` / `isInToSpaceAllocatedRegion` (:2279-2312) | block search + role logic | `p >= base && p < bump_.ptr` (resp. `copy_ptr_`) |
| `debugAssertValidNurseryPointer` (:2314-2384) | per-block diagnostic dump | kept; dump becomes two extent lines. All external callers (Allocator.cpp:409,829; RuntimeExports.cpp:1679; kernel `alloc::validateNurseryHPtr` sites) are signature-stable |
| evacuate / scanObject / list-spine family (:1193-2109) | via `isIn*`/`copyToSpace`/`contains` only | untouched except through those primitives |

GCStats coupling: delete `nursery_block_advances` +
`GC_STATS_NURSERY_BLOCK_ADVANCE` (GCStats.hpp:89, :727-728, AND the
ENABLE_GC_STATS=0 no-op stub at :788; GCStats.cpp:745, 936, 1633) — the
plan's success metric is precisely that this quantity is now structurally
zero. Keep `ensure_slow_calls`, `nursery_grow_events`,
`nursery_size_bytes` (producers re-expressed) — and rewrite the two KEPT
counters' doc comments that reference deleted machinery:
GCStats.hpp:79-84 (defines `ensure_slow_calls`' expected magnitude as a
share of `nursery_block_advances`) and :69-71 (documents
`nursery_size_bytes` as a block-count product).

### 2.3 `bump_.end` semantics, and the disambiguator's fate

```cpp
// end for the CURRENT from-space extent: min(extent end, proactive-GC
// threshold trip), with the already-full fail-soft carried over from
// computeAllocEndForBlock: if survivors left by the previous GC already
// sit at/past the threshold, tripping it again cannot free anything new
// (no allocation has happened since), so use the full extent and let
// genuine exhaustion drive the GC. Prevents post-GC trigger loops.
char* NurserySpace::computeAllocEnd() const {
    size_t already = static_cast<size_t>(bump_.ptr - fromBase());
    if (already >= threshold_total_bytes_)
        return fromBase() + from_capacity_bytes_;      // fail-soft
    return fromBase() + threshold_total_bytes_;
}
```

Called at exactly the sites that set `bump_` today: initialize/reset (ptr =
base ⇒ end = base + threshold), and the phase-5 swap (ptr = copy_ptr_ ⇒
fail-soft iff survivors ≥ threshold).

**Trigger equivalence argument (why minors stay ~identical):** with
`nursery_gc_threshold` < 1.0 the byte-precise threshold trip fires BEFORE
space exhaustion in both designs, at the same `threshold_total_bytes_` of
bytesAllocated. THREE timing inputs shift (verification enumerated all
three — the first draft claimed only one):

1. **From-space tail waste (minors DOWN):** today's bytesAllocated counts
   abandoned block tails (§1.2), so today trips slightly EARLIER in
   real-object terms; each extent cycle fits slightly more objects.
   Δminors = **total** tail waste / threshold_total (the run total already
   contains the per-cycle count — do NOT multiply by minors again).
   **MEASURED (§3.3 C0): 14,939,912 B total / 255,013,683 B = 0.059
   cycles ⇒ ZERO.** The mean abandoned tail is 47.7 B, because a tail is
   only what the non-fitting object could not use.
2. **Fail-soft quantization (minors DOWN):** today's already-full test is
   block-quantized (`current_from_idx_ × block_size_`, undercounting
   survivors by up to one partial block); `computeAllocEnd`'s is
   byte-precise, so the extent form fail-softs in strictly more states.
   Bounded by block_size / threshold_total = **0.2% of one cycle** at the
   measured 256 MiB/side capacity — sub-cycle, i.e. also zero.
3. **Growth-occupancy input (minors possibly UP — the one to watch):**
   today's checkAndGrow occupancy numerator counts to-space block
   quantization waste (`current_to_idx_ × block_size_` + partial,
   NurserySpace.cpp:501-506); the extent version counts pure survivor
   bytes. A cycle where gap bytes push occupancy across the 0.20 growth
   boundary grows today but NOT under M1 ⇒ the nursery stays smaller for
   subsequent cycles ⇒ minors drift UP. This remains the ONLY mechanism
   that can move minors upward (and M1's only plausible wall mechanism,
   §5) — but it is the same 47.7 B-scale phenomenon as item 1, on the
   evacuation side, against a 0.20 × 256 MiB ≈ 51 MB decision threshold:
   parts per million. C0 banks the reference `grow_events=4`.

Gate 5 therefore compares `nursery_grow_events` A-vs-B FIRST (must be 4): a
grow-event delta is the sanctioned explanation for any minors drift, and
with all three terms measured sub-cycle the minors requirement is
**exactly 871**, not a slack band. Majors are untouched by M1.

The clamp-vs-exhaustion disambiguator, the block-advance arm, and the
index-rewind fail-soft — the three subtlest pieces of HEAP_041 — all
dissolve: a fast-path miss has exactly ONE meaning (the threshold trip, or
under fail-soft the extent end) and exactly one response (minor GC). The
tiny-config corner (`threshold_total_bytes_ < n`, reachable only in test
heaps) survives and is still escaped by `failSoftUnclamp` in the ensure
ladder.

### 2.4 Minor GC / Cheney simplifications

To-space is one extent: `copyToSpace` is a pure bump with the existing
equal-capacity overflow assert (impossible by construction — from/to
capacities are equal at all times, asserted in §2.7). The Cheney scan is the
textbook two-pointer loop (`scan_ptr_ < copy_ptr_`). The entire tail-gap
apparatus — `block_end_of_objects_`, `advanceScanIfNeeded`,
`verifyToSpaceBlockEndOfObjects` — exists ONLY because to-space was
block-quantized; it is deleted, not ported. `clearToSpaceFreeRegion`'s
single memset keeps zeroing freshly-grown pages (kernel-zero already;
memset faults them in — pre-existing behavior today per comment :798-800;
a high-water-mark zeroing optimization is a §2.8 lead, NOT taken now).

### 2.5 Growth

Phase-4 `checkAndGrow`, re-based on bytes:

- occupancy = `(copy_ptr_ − to_base) / to_capacity`; return if
  ≤ `nursery_growth_threshold` (0.20). (Note the numerator delta vs
  today's block-quantized accounting — §2.3 item 3.)
- `delta = round_to_alloc_buffer(to_capacity / 2)` clamped to
  `growth_ceiling − capacity` (§2.1: ceiling = min(slice_bytes, configured
  max); last step fills the ceiling exactly; at the ceiling, return).
- `growNurserySlicePair(pair, delta)`: raises capacity on BOTH sides or
  neither (§2.1). On false: skip growth this cycle (no leak — strict
  improvement over today's asymmetric-abort leak). On success —
  **in this order, and none optional**: re-derive the membership bounds
  (`updateBounds` equivalent: `low_end_`/`high_end_` from the new
  capacity) + `refreshCapacityCaches()` + stats + heap-trace line. The
  bounds refresh is LOAD-BEARING (verification blocker): today's
  checkAndGrow calls `updateBounds()` at NurserySpace.cpp:583 because
  `isInFromSpace/isInToSpace/contains` drive evacuate's
  forward-or-ignore decisions — stale bounds after growth would make the
  NEXT minor GC treat objects in the grown region as non-nursery and skip
  evacuating them (silent corruption). A NurseryContiguityTest case pins
  it: grow, allocate into the grown region, minor GC, assert survival.

Growth remains quantized in `alloc_buffer_size` units so
`nursery_block_count` / `nursery_max_block_count` keep their EXACT config
meaning (capacity in 512 KiB units) — every existing `ECO_HEAP_CONFIG` file
and the heap-profile.py sweep corpus stay valid. There is still no shrink
path (unchanged; §2.8).

### 2.6 Runtime helpers

- `eco_alloc_inline_slow`: the `allocateFast` block-advance retry is now a
  guaranteed miss (the C++ compare tests the same clamped `end` the inline
  compare just failed) — call `allocateSlowRaw` directly. Compiled-code
  contract (uninitialized storage, never null, statepointed) unchanged.
- `ThreadLocalHeap::ensureNursery` ladder keeps its exact shape
  (ensure → minorGC+ensure → failSoftUnclamp+ensure → HEAP_017 abort); rungs
  1 and 3 become one-liners. `GC_STATS_ENSURE_SLOW_CALL` stays.
- `isNurseryNearFull` switches to live capacity (§1.6.5 — observable only
  in the benchmark driver; the safepoint path is dead code).

### 2.7 Structural self-checks

- Swap-time asserts: `bump_.ptr >= fromBase() && bump_.ptr <= bump_.end &&
  bump_.end <= fromBase() + from_capacity_bytes_`. From/to capacity
  equality needs no runtime assert — both sides share the single
  `NurserySlicePair.capacity` (§2.1), so it is structural; assert it once
  in the slice layer instead (capacity ≤ growth ceiling ≤ slice_bytes,
  capacity a multiple of alloc_buffer_size).
- Slice-layer asserts: slot geometry (base page alignment, retained_commit
  ≤ slice_bytes and a multiple of alloc_buffer_size); reset drops all
  retained commits (§2.1).
- ECO_HEAP_VALIDATE upgrade — with its cost stated: the pre-evacuation
  walk covers the FULL allocated prefix (it was restricted to the current
  block solely because of tail gaps — NurserySpace.cpp:2177-2183), and the
  post-GC to-space child check (:809-937) becomes a single-range walk.
  This is O(bytes allocated this cycle) per minor vs today's O(≤512 KiB) —
  up to ~500× more validator work per minor at the growth cap, in a
  validate build that already cannot finish Stage 7a. NOT free
  (verification finding): gate 2 watches build-val suite time, and if it
  regresses materially the full walk gets an env knob defaulting to a
  since-last-GC prefix.

### 2.8 Explicitly out of scope in v1

Separate nursery reservation outside the main heap (would amend HEAP_012);
nursery capacity SHRINK; any multi-threading implementation (§7 is
discussion); dynamic/heterogeneous slice sizing; zero-page high-water
tracking in `clearToSpaceFreeRegion`; any MLIR/codegen change beyond comment
rewrites (the ABI is untouched by design).

## 3. Design — M2: re-dividing the address space

### 3.1 One knob, both halvings

New `HeapConfig` field + `ECO_HEAP_CONFIG` key **`nursery_region_bytes`**
(byte-size string like the others; default **0 = legacy half-split** — the
config-level escape hatch that makes M2 independently and instantly
revertible):

- `Allocator::initialize()`: `nursery_offset = nursery_region_bytes == 0
  ? heap_reserved / 2 : heap_reserved − nursery_region_bytes;` (still
  computed ONCE, first-init-wins, same as today — §1.1's reset trap is
  inherited unchanged, not widened).
- `committedToCapRatio` (OldGenSpace.cpp:795-804): re-point at the real
  cap — but NOT naively (verification finding: a bare
  `getOldGenMaxBytes()` breaks OldGenSweepBudgetTest BY DESIGN — that
  test's whole mechanism is tuning the denominator per-suite via an 8 MiB
  `max_heap_size` while `nursery_offset` is first-init-wins at 12 GiB, so
  the ratio would pin to ~0 and the pressure-step assertions r0/r1/r2
  trivialize). Spec: `getOldGenMaxBytes()` returns
  `min(nursery_offset, configDerivedOldGenCap(config_))` where
  `configDerivedOldGenCap = max_heap_size − effective_nursery_region`
  (legacy: `max_heap_size / 2`), and `committedToCapRatio` uses THAT. This
  repairs the §1.1 divergence-after-reset trap in both directions (a
  smaller reset config gets a proportionally smaller cap; the cap never
  exceeds the reserved region), keeps sweep pressure priced against the
  real cap, and keeps OldGenSweepBudgetTest's tunable denominator working
  unchanged. Verifying that test stays green is a named Step-3
  deliverable, not a hoped-for detector.
- `validate()` additions (AllocatorCommon.hpp §2 block). UNCONDITIONAL
  (lands in Step 2 with M1 — the §1.6.3 closure must cover the legacy
  split, where `nursery_region_bytes` = 0, or the whole M1-only window is
  unvalidated): `nursery_block_count × alloc_buffer_size / 2` (initial
  per-side) ≤ the effective per-side slice (§2.1's clamped slice_bytes,
  computed with the legacy split when the knob is 0). Note the MAX-growth
  cap deliberately stays soft — §2.1 clamps it to the region rather than
  rejecting configs, preserving today's behavior where an oversized
  `nursery_max_block_count` merely stops growing early.
  IF NONZERO: `nursery_region_bytes` a multiple of
  `2 × alloc_buffer_size`, ≥ `nursery_max_block_count × alloc_buffer_size`
  (≥ 1 unclamped slot per side), ≤ `max_heap_size / 2` (old gen never
  shrinks below half — conservative floor, revisit if ever needed);
  `initial_old_gen_size < max_heap_size − nursery_region_bytes`; the
  existing `nurserySize() < max_heap_size/2` check re-based on the actual
  region. Both cases: range-check `major_gc_global_pressure_fraction`
  (§1.6.6).
- Comment sweep (grounded list): Allocator.cpp:9-12, Allocator.hpp:26-27,
  :271 ("heap midpoint"), AllocatorCommon.hpp:73, :136-145 (GlobalPressure
  history math), :508, :659-665, OldGenSpace.hpp:787 + OldGenSpace.cpp:791-797,
  `ECO_OLDGEN_DEBUG`'s `heap_hi` note (OldGenSpace.cpp:2398-2400 — already
  cap-relative, verify only).

Default **CONFIRMED by C0** (§3.3: old-gen peak 3.97 GiB in-use / 3.98 GiB
high-water, zero pressure- or alloc-failure-attributed majors; nursery
saturates at 512 MiB): **`nursery_region_bytes = 4 GiB`** → old-gen cap
20 GiB (+67%) = 5.0× the observed peak, GlobalPressure trip 10.2 → 17 GiB,
per-side nursery region 2 GiB = 8 slices:

| | today | M1 only | M1 + M2 @ 4 GiB |
|---|---|---|---|
| old-gen cap | 12 GiB | 12 GiB | 20 GiB |
| GlobalPressure trip (0.85) | 10.2 GiB | 10.2 GiB | 17 GiB |
| nursery region | 12 GiB | 12 GiB | 4 GiB |
| max concurrent heaps @ 256 MiB/side | 24 | 24 slots | 8 slots |
| single-threaded nursery usable | 512 MiB | 512 MiB | 512 MiB |

Per-thread Occupancy and GarbageFraction triggers are committed-based and
unchanged; GlobalPressure and the alloc-failure wall move out by 8 GiB;
the `adjustCapacityAfterMajorGC` grow clamp and the forced-shrink
hysteresis override (§1.1) both key off `getOldGenMaxBytes()` and follow
automatically.

### 3.2 What M2 does and does not claim

**CONFIRMED by C0 (§3.3):** no trigger change for Stage 7a — peak old-gen
in-use 3.97 GiB is 39% of the 10.2 GiB trip, and `trig_press` /
`trig_alloc` are both 0, so none of the 10 majors is address-split
attributable. M2 is therefore pure geometry here with a nil wall
expectation. The durable claims are: workloads
with > 10 GiB of old-gen high-water stop paying artificial majors and stop
hitting a 12 GiB wall while 11.5 GiB of nursery address space sits idle;
and the geometry finally reflects reality (nursery per-thread need is
512 MiB, measured, capped, and now validated).

### 3.3 Census C0 (LAND FIRST — measurement only, zero risk)

One Stage 7a self-compile with `ENABLE_GC_STATS`, plus two temporary
counters (deleted at ship):

1. **Trigger attribution + old-gen peaks** (existing counters): the four
   `major_gc_*_triggers`, `major_gc_count`, and BOTH old-gen peaks — they
   are different quantities gating different walls (§1.1):
   `getOldGenCommittedBytes()` peak (in-use; what GlobalPressure trips on)
   AND the `old_gen_committed` high-water bump (what the hard
   alloc-failure wall at Allocator.cpp:609/:741 trips on). Decides §3.1's
   default: if zero majors are GlobalPressure/alloc-failure attributed and
   BOTH peaks ≪ 10.2 GiB, M2 ships as pure geometry with a nil Stage 7a
   wall expectation.
2. **Tail waste** (temp counter): at both advance sites, accumulate
   `block_end − bump_.ptr` (resp. the `ensureHeadroom` advance's abandoned
   remainder). Yields the §6 minors-drift bound: predicted Δminors ≈
   (RUN-TOTAL tail_waste) / threshold_total_bytes_ — the per-cycle count is
   already inside the total, so do not multiply by minors (see §3.3's
   formula correction).
3. **Advance/ensure baseline** (existing counters): reproduce
   advances / minors / ensure_slow_calls on the same tree the C2 arms build
   from, so before/after is apples-to-apples.

Reporting format (house pattern, one stderr line, machine-parseable):
`[nursery-census] minors=%llu majors=%llu adv=%llu ensure=%llu tailB=%llu
oldgen_inuse_peakB=%llu oldgen_hiwaterB=%llu trig_occ=%llu trig_press=%llu
trig_garb=%llu trig_alloc=%llu grow_events=%llu nursery_sizeB=%llu`
(the last two were added while building it — the growth model is the §2.3
item-3 risk's own telemetry).

Lifecycle (verification finding — the first draft contradicted its own
landing order): the tail-waste counter and the `adv=`/`tailB=` fields are
instrumented at the two block-advance sites that **Step 2 deletes**. The
census machinery is therefore C0-only by construction: it lives in the
Step-1 commit, produces arm-A numbers, and DIES IN the Step-2 commit
(which removes its host code). Step 5's cleanup covers only whatever
survives (the attribution/peak reporting, if kept).

### C0 MEASURED (2026-08-09) — BOTH DECISIONS RESOLVED

Stage 7a per §5's protocol (cold `eco-stuff`, `ECO_MONO_ENGINE=subst`,
`ECO_NURSERY_CENSUS=1`); warmup and measured legs produced **byte-identical
counters**, so the census is deterministic:

```
[nursery-census] minors=871 majors=10 adv=312952 ensure=104633 tailB=14939912
  oldgen_inuse_peakB=4264390656 oldgen_hiwaterB=4277346304
  trig_occ=8 trig_press=0 trig_garb=2 trig_alloc=0
  grow_events=4 nursery_sizeB=536870912
```

Supporting figures (measured leg): wall **3:37.42**, max RSS 5,144,044 kB,
objects allocated 379,941,572, bytes allocated 18,545.61 MB, promoted
372,493,275 (98.0%), GC/alloc time 85.42 s, `out.mlir` 12,955,155 B.
**Every one of these matches Run N's hoist leg exactly** (wall 3:37.44, RSS
5,144,296 kB, identical alloc/minors/promoted/majors, `cmp`-identical
`out.mlir`) — the census instrumentation costs nothing measurable, and this
leg therefore doubles as **C2 arm A, already banked**.

**1. Tail waste is 47.7 bytes per advance — the minors-drift term is
ZERO.** `tailB` = 14,939,912 B over 312,952 advances = **47.74 B mean
abandoned tail**. Of course it is: the tail is only the bytes the
non-fitting object could not use, and the objects are 16–32 B. Per cycle:
312,952/871 = 359.3 advances × 47.74 B = **17.1 KB of waste against a
~255 MB threshold budget = 67 ppm**. Correct prediction (see the formula
note below): Δminors = total_tail_waste / threshold_total =
14,939,912 / 255,013,683 = **0.059 cycles**. So M1 must produce **exactly
871 minors**; gate 5 hardens from "symmetric slack" to "identical, or
explain". §2.3 item 2 (fail-soft quantization, bounded by
block_size/threshold_total = 0.2% of one cycle) is likewise sub-cycle, and
item 3's to-space quantization is the SAME 47.7 B-scale phenomenon on the
evacuation side (its abandoned to-space tails are also < one object each,
against a 51 MB growth-decision threshold) — so the growth-timing risk,
while still the only mechanism that can push minors UP, is measured to be
parts-per-million. This is a materially stronger position than the plan
assumed.

**Formula correction:** §2.3/§6 said "minors × tail_waste/threshold_total".
That is only right if `tail_waste` is the PER-CYCLE figure. The census
reports the RUN TOTAL, so the prediction is `tail_waste / threshold_total`
outright (the `minors ×` factor is already inside the total). Both readings
give 0.059 cycles here; the wording is fixed in §2.3 and gate 5.

**2. The address split costs Stage 7a nothing today — M2 is pure
geometry.** Old-gen **in-use peak 4,264,390,656 B (3.97 GiB)** and
**commit high-water 4,277,346,304 B (3.98 GiB)** — 33% of the 12 GiB cap
and **39% of the 10.2 GiB GlobalPressure trip**. Attribution:
`trig_press=0`, `trig_alloc=0` — **not one of the 10 majors is
address-split-attributable** (8 occupancy, 2 garbage-fraction, both
per-thread committed-based and untouched by M2). So M2 ships with a nil
Stage 7a wall expectation exactly as §3.2 predicted, and its case rests
entirely on the durable argument: this workload already reaches 4 GiB of
old-gen high-water on a monotonic, never-rewinding bump — a 3× larger
compile trips GlobalPressure against a cap that is half the reservation
while the nursery cannot use more than 512 MiB of its own half.

**3. The 4 GiB default is confirmed, and the nursery SATURATES its cap.**
`nursery_sizeB` = 536,870,912 = **512 MiB = the `NURSERY_MAX_BLOCKS` cap**,
reached in exactly `grow_events=4` (128→192→288→432→512 blocks per side,
+50% per event, last step truncated to the cap — the §2.5 growth model
reproduced exactly). Consequences: (a) §2.1's `slice_bytes` = 256 MiB/side
is right-sized — this workload consumes a whole slice, so fixed slices
waste no address space here; (b) under M2 @ 4 GiB the old-gen cap becomes
20 GiB = **5.0× the observed peak** (vs 3.0× today) while the nursery keeps
8 slots — comfortable on both sides.

**4. Volume cross-check.** 312,952 advances × 512 KiB = **164.06 GB** of
from-space traversed vs 18,545.61 MB reported by the (inline-alloc-blind)
counter — an 8.8× gap, i.e. ~6.5 B true objects at ~25 B mean, matching the
known TRUE ALLOC 6.52 B. Slow-entry rate: **~1 per 20,800 allocations**
counting advances only, **~1 per 15,600** counting all slow entries
(adv + ensure = 417,585). Fast-path hit rate ≈ 99.994%. (`adv` here is
312,952 vs the 312,942 in project memory — the counters are deterministic
within a binary; the 10-entry difference is measurement context, not
noise, and is immaterial.)

**Post-M1 expectation for these fields:** `adv` deleted (structurally
zero), `ensure` ≈ the miss count that remains once a miss can only mean a
GC trigger, `minors` 871 exactly, `majors` 10, growth 4 events to 512 MiB.

## 4. Implementation spec and landing order

Steps land in order; each compiles + suite-greens before the next.

### Step 1 — census C0 ✅ LANDED 2026-08-09

**As built.** Three TEMPORARY `GCStats` fields (`nursery_tail_waste_bytes`,
`oldgen_inuse_peak_bytes`, `oldgen_hiwater_bytes`) + the
`GC_STATS_NURSERY_TAIL_WASTE` macro (both ENABLE_GC_STATS branches),
recorded at the two advance sites in `NurserySpace::allocateSlow` and
`::ensureHeadroom` — the tail is captured BEFORE `bump_.ptr` moves and
only when the advance actually takes a new block, so it tracks
`nursery_block_advances` one-for-one. `Allocator` gained
`old_gen_in_use_peak_` + `noteOldGenInUsePeak()` called at the three
`old_gen_in_use_bytes_` increment sites (block reuse, fresh block, initial
region) and cleared in `reset()`, plus two accessors; `getCombinedStats()`
overwrites the two peak fields from the live allocator (they are
allocator-global, not per-thread — `combine()` merges them by max, tail
waste by sum). `GCStats::reset()` clears all three.

**Deviation from the original spec, deliberate:** the census line is
printed to stderr from `GCStats::print()` **gated on `ECO_NURSERY_CENSUS`**
(unset/`0` = silent) rather than unconditionally. The counters themselves
are always-on cold-path adds. Rationale: the E2E suites compare stderr, and
an unconditional line would have made a measurement-only step
behavior-visible. Zero-risk by construction.

Results in §3.3's C0 MEASURED block. The census leg reproduced Run N's
figures exactly (including a `cmp`-identical `out.mlir`), so it doubles as
C2 arm A. Deterministic: warmup and measured legs emitted byte-identical
counter lines.

**Original spec:** Temp counters + the stderr line behind
`ENABLE_GC_STATS`; run per §3.3; record results IN THIS FILE (§3.3 gets a
"C0 MEASURED" block). No behavior change; suite green vacuously.

### Step 2 — slice layer + extent rewrite (M1) ✅ LANDED 2026-08-09

**As built.** Allocator: `NurserySlicePair` (in AllocatorCommon.hpp, so
NurserySpace can hold one without including Allocator.hpp) +
`rebuildNurserySliceTable` / `acquireNurserySlicePair` /
`growNurserySlicePair` / `releaseNurserySlicePair` + a
`NurserySliceSlot{in_use, retained_low, retained_high}` table; both block
free-lists and the four block acquire/release functions deleted.
`Allocator::reset` now rebuilds the slot table (the freelist-clear's
replacement). NurserySpace: the §2.2 collapse as specified —
`initializeFromConfig` shared by both `initialize` overloads, `reset` now
releases before re-acquiring (leak fixed), `allocateSlow` reduced to the
stats bracket + `return nullptr`, `ensureHeadroom` to one comparison,
`failSoftUnclamp` to one line, `computeAllocEnd` keeping the already-full
fail-soft, `copyToSpace` a pure bump, `scanHasMore` the two-pointer test;
`advanceScanIfNeeded`, `verifyToSpaceBlockEndOfObjects`,
`findBlockContaining`, `wouldExceedThreshold` and `block_end_of_objects_`
deleted outright. Growth re-derives bounds before the capacity caches.
`isNurseryNearFull` switched to live capacity. GCStats:
`nursery_block_advances` + its macro + both no-op stubs deleted; the
old-gen in-use-peak / commit-high-water pair KEPT as permanent telemetry
(they answer HEAP_043's question and were invisible before) and printed in
the Major GC section. All comment sites in §4's list swept.

**Deviation — a fourth trigger delta, found by the new tests, not by the
plan.** The plan's §2.3 enumerated three timing deltas; there is a fourth
that is a CORRECTNESS issue rather than a drift: the block design's
threshold arithmetic was block-QUANTIZED (`already_full = idx *
block_size`, an undercount) and backed by a block advance, so a post-GC
clamp always left at least a block of room. A byte-exact clamp over one
extent can leave less room below the threshold than the requested object,
and collecting again cannot help — no allocation has happened since. That
aborted `ThreadLocalHeap::allocate`'s "nursery is full" assert in the new
fail-soft test. Fix: the same fail-soft rung `ensureNursery` already had
(`failSoftUnclamp` + one retry) is now present in all THREE nursery
allocation paths — `allocate`, `allocateSlow`, `allocateSlowRaw`. This is
folded into the HEAP_041 amendment (§10.1) because it is part of the same
contract.

Tests: `EnsureHeadroomTest` rewritten (its four block-structural
assertions re-expressed; the advance-counting non-vacuity assertions died
with the counter; case (d) repurposed from "abandoned tails don't trip the
walker" to "the full-prefix walk parses an unchecked-bump workload"), new
`NurseryContiguityTest` with the five cases §4 specified. Suite
**1628/1628** (1623 baseline + 5 new).

**Original spec:**

Allocator: `NurserySlicePair` + the three functions + the reset slot-table
rebuild (§2.1); delete the two block freelists +
`acquireNurseryBlockLow/High`/`releaseNurseryBlockLow/High`.
NurserySpace: the §2.2 collapse (incl. the growth bounds-refresh, §2.5).
ThreadLocalHeap/RuntimeExports: §2.6. GCStats: §2.2 counter deletions +
kept-counter comment rewrites. The UNCONDITIONAL validate() check (§3.1)
lands here, not in Step 3. The Step-1 census instrumentation is deleted by
this commit (§3.3 lifecycle). Comment sweep (all sites verified present):
EcoBackend.cpp:145-146, :963-965, :1006, :1031-1033, :1083, :2236-2238,
:2249-2251; RuntimeExports.h:165; RuntimeExports.cpp:181, :196-197,
:205-207, :214-226; ThreadLocalHeap.cpp:172-177 (names
computeAllocEndForBlock + the deleted wouldExceedThreshold);
NurserySpace.hpp:20-52 class/ABI docs; AllocatorCommon.hpp:591-606 (the
`large_object_threshold <= alloc_buffer_size` check STAYS —
`alloc_buffer_size` remains the old-gen page quantum, HEAP_022/023 — but
its nursery-fit justification paragraph is rewritten).

Tests: rewrite `EnsureHeadroomTest.cpp` (the only `NurserySpaceTestAccess`
user): `assertBumpCoherent` → "ptr ≤ end ≤ extent end"; the
advance-counting assertions die with the counter; the clamp-goes-to-GC and
tiny-config fail-soft tests survive re-expressed; the abandoned-tail
validate-walker test (d) is MOOT — repurpose as a full-prefix-walk test.
`NurserySpaceTestAccess`: drop `fromBlockCount/toBlockCount/lowBlockCount/
highBlockCount/currentFromIdx/blockSize/fromBlockAt`, add `fromBase/
fromCapacity/toBase`. New `NurseryContiguityTest`: slice acquire/release/
reacquire retains the slot's commit while capacity restarts at initial
(§2.1's capacity-vs-retained split, both directions: initial < retained
and initial > retained); **Allocator::reset with a DIFFERENT
alloc_buffer_size then reacquire** (the geometry-flip crash class —
retained records must be gone); growth extends in place (extent base
pointer-stable across grow, capacity increases, both sides equal) AND
**post-growth GC correctness: grow, allocate into the grown region, minor
GC, assert survival** (the §2.5 bounds-refresh blocker's pin); grow
failure leaves capacities untouched; bump-bounds asserts;
`computeAllocEnd` fail-soft when survivors ≥ threshold; `reset` no longer
leaks (slot returns to the free list). Tiny heaps configured
programmatically (never via `ECO_HEAP_CONFIG` env — pollutes the test
binary).

Gates before Step 3: unit suite; `cmake --build build --target full`;
heap-validate tree `/work/build-val` `--target full` (suite baseline is
1623/1623 green — any regression is this step's).

### Step 3 — address re-division (M2) ✅ LANDED 2026-08-09

**As built.** `HeapConfig::nursery_region_bytes` (+ the
`nursery_region_bytes` JSON key), `nurseryRegionBytes()` and
`oldGenCapBytes()` helpers, `nursery_offset = heap_reserved -
nurseryRegionBytes()`, `getOldGenMaxBytes()` = `min(nursery_offset,
config-derived cap)`, `committedToCapRatio` re-pointed at it. validate()
gained the split rules plus the unconditional one-slice check and the
`major_gc_global_pressure_fraction` range check. Layout comments swept in
Allocator.{cpp,hpp} and AllocatorCommon.hpp.

**Deviation — the default is a POLICY, not a constant.** The plan proposed
`nursery_region_bytes = 4 GiB` as the field default. That is wrong for any
small heap: every unit-test config sets `max_heap_size = 64 MiB`, and a
4 GiB nursery region fails validation there (it exceeds the whole heap).
The field therefore defaults to **0 = "default policy"**, and
`nurseryRegionBytes()` resolves it as
`min(DEFAULT_NURSERY_REGION_BYTES, max_heap_size / 2)` — 4 GiB on the real
24 GiB reservation, and the legacy half split on anything below 8 GiB. An
explicit value is still honoured and validated. Verified geometry:

| config | nursery region | old-gen cap | slots/side | GlobalPressure trip |
|---|---|---|---|---|
| default 24 GiB | 4.00 GiB | 20.00 GiB | 8 | **17.00 GiB** |
| explicit `12G` (legacy) | 12.00 GiB | 12.00 GiB | 24 | 10.20 GiB |
| test heap 64 MiB | 32 MiB | 32 MiB | 2 | (unchanged) |

Suite **1628/1628** with M1+M2 together.

**Original spec:** §3.1 exactly: config key + parse + the nonzero-gated validate() rules;
`nursery_offset` formula; the `min()`-capped `getOldGenMaxBytes()` +
`committedToCapRatio` re-plumb **with OldGenSweepBudgetTest green as a
named deliverable** (its tunable-denominator mechanism must survive — see
§3.1); comment sweep. Default stays 0 (legacy) until Step 4's benchmark;
flipping the default to 4 GiB is a one-line follow-up commit gated on C2 +
the census attribution.

### Step 4 — bootstrap gate + benchmark (Run O)

Per §5/§6. Record results in benchmarks/tier2-opt.md as **Run O** (verify
the letter is still free) and back-fill §5 here.

### Step 5 — ship checklist

§10: invariant amendments + new rows + doc sweep; delete whatever census
reporting survived Step 2 (§3.3 lifecycle — the advance-site counters are
already gone); update project memory (`nursery-block-boundary-slowpath.md`
closes; `eco-opt-tier-roadmap.md` gains the outcome line).

## 5. Benchmark (C2 — Run O)

Three arms, standard protocol (Stage 7a self-compile, cold subst
`ECO_MONO_ENGINE=subst`, `/usr/bin/time -v`, cold `eco-stuff` per leg,
warm-up leg discarded, interleaved ≥3 per side, `ECO_HEAP_CONFIG` pinned,
minors AND majors recorded with every wall — walls are meaningless without
them):

- **A** HEAD (block nursery, legacy split) — **ALREADY BANKED**: the C0
  census leg (§3.3) is a Run-N-equivalent leg (wall 3:37.42, RSS
  5,144,044 kB, `out.mlir` 12,955,155 B `cmp`-identical, all GC counters
  matching Run N's hoist leg), taken with the census binary. Re-run only
  for same-day pairing if B/C land on a different day (day-drift lesson).
- **B** M1 only: the new binary run with
  `ECO_HEAP_CONFIG=benchmarks/heapcfg/legacy-split.json`
  (`nursery_region_bytes: "12G"` — the legacy 50/50 layout).
- **C** M1+M2: the SAME binary at its default config (4 GiB nursery /
  20 GiB old gen).

**One binary, two config legs** (an as-built improvement on the plan's
three-build sketch): because M2 is a config key, B and C differ ONLY in
heap geometry, so A→B isolates the extent rewrite and B→C isolates the
split with no rebuild between them and no lowering difference to confound
either comparison.

Per-leg non-wall record: minors, majors + per-trigger attribution,
`ensure_slow_calls`, peak RSS, `nursery_grow_events`. Expectations: B vs A
minors equal-or-slightly-lower (bounded by the C0 tail-waste prediction),
majors identical; C vs B majors identical-or-lower with the delta fully
explained by GlobalPressure/alloc-failure attribution.

### RUN O MEASURED (2026-08-09) — FLAT wall, KEEP; gate 5 exact

| leg | wall | max RSS | minors | majors (occ/garb/press/alloc) | grow | max nursery | ensure calls | old-gen cap | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| **A** measured (block, legacy) | 3:37.42 | 5,144,044 kB | 871 | 10 (8/2/0/0) | 4 | 512 MB | **104,633** | 12,288 MB | 12,955,155 B |
| **B** measured (M1, legacy) | **3:34.83** | 5,035,292 kB | 871 | 10 (8/2/0/0) | 4 | 512 MB | **316** | 12,288 MB | ≡ A |
| **C** measured (M1+M2) | **3:36.18** | 5,012,240 kB | 871 | 10 (8/2/0/0) | 4 | 512 MB | **316** | 20,480 MB | ≡ A |
| A warmup | 3:39.83 | 5,144,820 kB | — | — | — | — | — | — | — |
| B warmup | 3:42.20 | 5,134,464 kB | 871 | 10 (8/2/0/0) | 4 | 512 MB | 315 | 12,288 MB | ≡ A |
| C warmup | 3:36.11 | 5,012,120 kB | 871 | 10 (8/2/0/0) | 4 | 512 MB | 316 | 20,480 MB | ≡ A |

**Wall: FLAT, as the §0 caution prior predicted.** A→B splits by leg
(measured −1.19%, warmup +1.08%; mean ≈ −0.05%) — the same
pair-splits-therefore-flat signature as Run L. B→C likewise splits
(measured +0.63%, warmup −2.74%), which is exactly right: M2 is pure
geometry and the census already showed it changes no trigger on this
workload. **Decision: KEEP** per §5's rule.

**Gate 5 passes EXACTLY, on all six legs**: minors 871, majors 10 with
attribution 8 occupancy / 2 garbage-fraction / 0 global-pressure / 0
alloc-failure, `nursery_grow_events` 4, maximum nursery 512.00 MB — every
value identical to arm A. The three C0-measured drift terms were sub-cycle
and the outcome is that nothing drifted at all. `out.mlir` is
`cmp`-identical to arm A on both arms, so the workload is constant and the
runtime rewrite perturbs no compiler output.

**The headline is the slow-path collapse.** Nursery slow-path entries per
Stage 7a run:

| | arm A (block) | arm B/C (contiguous) |
|---|---|---|
| block advances | 312,952 | **0** (structurally — the counter is deleted) |
| ensure cold calls | 104,633 | **316** |
| **total** | **417,585** | **316** — a **1,321× reduction** |

316 sits *below* the 871 minors because an ensure diamond only misses when
a covered run's budget exceeds the remaining headroom; the other GCs are
driven by ordinary `allocate()` misses. Under the block design the same
counter was dominated by boundary crossings that had nothing to do with
collection — which was the whole complaint.

**Unbudgeted bonus: RSS −2.56%** (5,144,044 → 5,012,240 kB, arm A →
arm C; arm B is between them and both contiguous legs beat A on warmup and
measured alike). Not predicted by the plan. The plausible mechanism is the
elimination of abandoned tail gaps plus exact extents, but it is a
measurement, not an explanation — do not quote a cause.

**Counting artifact (expected, same class as Run N's):** `Objects
allocated` reads 379,941,572 (A) vs 379,768,314 (B/C), −0.046%. The
counter is inline-alloc-blind: under the block design, an inline-alloc
slow call satisfied by a *block advance* passed through the counted C++
`NurserySpace::allocate` path; now those allocations are served by the
inline bump instead, which is not counted. Two runs of the SAME binary and
config differ by 164 on this counter anyway (arm B warmup vs measured), so
it is not a retention signal. Minors/majors/grow-events are the trustworthy
figures and they are identical.

Decision rule: wall ≥ ~0.5% better ⇒ keep and say so; **FLAT ⇒ KEEP** — the
deliverable is the deletion of the block apparatus, the simplified HEAP_041
semantics, the stronger validators, and honest telemetry (precedent: Run N
kept flat-wall for non-wall wins); regression > ~0.5% ⇒ bisect B vs C (C is
a config flip), and if B regresses, investigate before any revert decision.
The fast path is byte-identical, so the ONE plausible M1 wall mechanism is
growth timing (§2.3 item 3: the growth-occupancy numerator loses to-space
quantization waste ⇒ possibly fewer/later grows ⇒ smaller nursery ⇒ more
minors) — which is why `nursery_grow_events` is a per-leg record and gate 5
consults it first. If `--threads` arms are ever added, note the
`isNurseryNearFull` driver-cadence delta (§1.6.5) before comparing.

## 6. Correctness gates

**ALL SIX GATES PASSED (2026-08-09).**

1. **PASSED** — `--target full` **1628/1628** (1623 pre-existing + 5 new
   contiguity cases).
2. **PASSED** — `/work/build-val` (`-DECO_HEAP_VALIDATE=ON`)
   `--target full` **1628/1628** with every validator active, including
   the upgraded full-prefix pre-evacuation walk, the poison/stale-pointer
   detector and the post-GC to-space child check; `--target ecoc` also
   built there. No measurable suite-time regression from the wider walk,
   so the §2.7 env-knob contingency was not needed.
3. **PASSED** — `--target bootstrap` reaches the self-hosting fixed point
   byte-for-byte: `eco-compiler-boot` ≡ `eco-compiler-boot-2`
   (65,209,776 B) and `eco-compiler-boot.mlir` ≡ `eco-compiler-boot-2.mlir`
   ≡ Stage 5's `eco-compiler.mlir` (13,411,308 B). The runtime rewrite
   perturbs no compiler output at any stage.
4. **PASSED** — ABI stasis: the `NurseryBump` static_assert is untouched,
   `inline_alloc_tuple.mlir` is in the green suite, and the compiled-code
   contract kept its three symbols with unchanged signatures
   (`eco_alloc_inline_slow` lost only its internal pre-GC retry, which is
   invisible from IR).
5. **PASSED EXACTLY** — see §5's Run O table: 871 minors, 10 majors with
   attribution 8/2/0/0, 4 grow events, 512 MB max nursery, on all six legs.
6. **PASSED** — the rewritten `EnsureHeadroomTest`, the new
   `NurseryContiguityTest` (5 cases) and the existing `NurserySpaceTest`
   property tests are all in the 1628.

1. Full E2E: `cmake --build build --target full` (serially; never
   `--target check` here — the rewrite touches no `.mlir` but full is the
   standard gate and cheap insurance against stale artifacts).
2. Heap-validate leg: `/work/build-val` (`cmake --preset build -B
   /work/build-val -DECO_HEAP_VALIDATE=ON`), `--target full` + `--target
   ecoc`; suite must stay 1623/1623 in BOTH trees. The upgraded full-prefix
   pre-evacuation walk (§2.7) must be exercised — confirm nonzero walk
   coverage via a validate-build spot run, not just suite green.
3. Bootstrap to fixed point: `--target bootstrap`, Stage 8c byte-identical
   (`eco-compiler-boot` ≡ `eco-compiler-boot-2`). The runtime rewrite must
   not perturb compiler OUTPUT at all — any `.mlir` diff is an instant
   stop-the-line.
4. ABI stasis: `NurseryBump` static_assert untouched;
   `test/codegen/inline_alloc_tuple.mlir` green; no new symbols in the
   compiled-code contract (`eco_bump_state` / `eco_alloc_inline_slow` /
   `eco_ensure_nursery_slow` signatures and semantics-as-seen-from-IR
   unchanged).
5. Trigger fidelity, now that C0 has measured all three drift terms as
   sub-cycle (§3.3): **minors must be exactly 871, majors exactly 10 with
   attribution 8 occupancy / 2 garbage / 0 pressure / 0 alloc-failure, and
   `nursery_grow_events` exactly 4 to a 512 MiB maximum nursery.** Check
   `grow_events` FIRST — a delta there is the only sanctioned explanation
   for any minors movement (§2.3 item 3). Any other drift = stop and
   explain before trusting walls.
6. Unit suites: rewritten EnsureHeadroomTest + new NurseryContiguityTest +
   existing NurserySpaceTest property tests (its DFS-locality assertion
   only gets easier — no inter-block copy gaps), GCPressureTest untouched.

## 7. Multi-threading considerations (discussion only — nothing here is
implemented by this plan)

The four options, against the code as it exists (§1.4: per-thread
`NurserySpace` AND per-thread `OldGenSpace` over one shared reservation; no
STW; no write barriers; HEAP_007 no cross-thread heap pointers; PORT_004
values cross threads as bytes):

1. **Nursery per thread (status quo — KEEP, and M1 is built for it).** The
   zero-synchronization bump fast path IS the HEAP_034/CGEN_074 design;
   `eco_bump_state`'s `memory(none)` address-CSE story requires a
   thread-stable, uncontended bump struct. Thread-local minor GC is sound
   precisely because of HEAP_007. The slice layer gives every heap its own
   contiguous estate, so per-thread contiguity is INDEPENDENT of thread
   count — this is the answer to "how do multiple nurseries stay
   contiguous": not by interleaving blocks carefully, but by pre-carving
   disjoint per-heap slices from the region and committing inward.
2. **Nursery shared between threads — REJECT.** Either an atomic bump
   (contended cache line on the hottest two words in the system; the inline
   diamond becomes a CAS loop; `memory(none)` and the unchecked CGEN_074
   bump both die) or per-thread TLABs carved from the shared space — which
   re-introduces exactly the per-buffer boundary slow path M1 deletes, plus
   refill synchronization. Worse, minor GC of a shared nursery requires
   stopping ALL mutators (no safepoint/STW machinery exists; GC triggers
   are allocation-slow-path-only by design). Nothing in Elm semantics wants
   this: no shared mutable state exists to justify it.
3. **Old gen per thread (status quo — KEEP for now).** Promotion stays
   local and lock-free (block acquisition aside); majors are per-thread
   with no rendezvous. Costs, honestly stated: per-thread old-gen block
   sets interleave in the shared region (fragmentation of the region, not
   of any heap); the global cap needs the GlobalPressure trigger as a
   backstop against one thread crowding others; a dead thread's promoted
   data dies with its heap (fine under HEAP_007 — nothing else can
   reference it).
4. **Old gen shared between threads — DEFER, but this is the interesting
   one.** Elm immutability means a shared old gen needs no mutation write
   barrier; the hard parts are allocation synchronization (the BBoP page
   structure already partitions naturally — per-thread pages with a shared
   page allocator is a small step from today) and a shared major GC (STW
   parallel mark, or concurrent mark — both large, neither needed while
   ports copy bytes). The payoff would be zero-copy hand-off of promoted
   immutable structures between threads (a future actor/worker story), at
   which point HEAP_005/HEAP_007 and the promotion rules need a
   cross-thread rethink. Decision: keep per-thread old gen until a concrete
   zero-copy consumer exists; M2 keeps the door open (the shared old-gen
   REGION with per-thread spaces is already the right substrate for either
   choice).

What this plan does NOW to keep those doors open: slices are slot-indexed
and symmetric (a future shared-nursery experiment could still carve TLABs
from a slice); the old-gen cap plumbing is centralized behind
`getOldGenMaxBytes()` (§3.1 removes the last bypass); and nothing in M1
assumes heap count == 1 — it assumes only per-heap slice ownership, which
`thread_mutex_` already serializes.

## 8. Risks / kill conditions

- **Hidden reliance on block granularity or tail gaps.** Most likely
  residence: validate-only walkers and EnsureHeadroomTest's structural
  assumptions — both rewritten by §2.2/§4 Step 2. Detector: build-val suite
  (gate 2) + the upgraded full-prefix walk. Kill: none — fix forward;
  Step 2 is one revertible commit.
- **Trigger drift beyond the tail-waste bound.** Would mean the §2.3
  equivalence argument missed a case (e.g., an unaccounted interaction with
  the fail-soft clause). Detector: gate 5 (C0-calibrated minors bound).
  Decision: stop, explain, only then trust walls.
- **Mid-GC growth commit failure.** `growNurserySlicePair` fails ⇒ skip
  growth; strictly better than today's leak-and-abort. Detector: heap-trace
  line + `nursery_grow_events` stall. Not a kill condition.
- **Slot exhaustion under `--threads N` benchmarks — under M1 ALONE, not
  just M2.** Fixed 256 MiB slices bound concurrency at 24 even at the
  legacy split, vs ~96 never-growing 64 MiB heaps today; M2's 4 GiB
  default tightens it to 8. Any `--threads N` run with N > slots hits the
  loud fatal (which names both knobs). Mitigation: raise
  `nursery_region_bytes` / `max_heap_size` or lower
  `nursery_max_block_count` in the bench config; revisit the M2 default if
  the driver's standard configs exceed 8. Product exposure: none known —
  the driver is the only concurrent-heap path (§1.4).
- **The two halvings move apart.** If §3.1's `committedToCapRatio` re-plumb
  is skipped or partial, sweep pacing misprices pressure at exactly the
  moment the cap moves. Detector: OldGenSweepBudgetTest is a NAMED Step-3
  deliverable under the `min()`-capped spec (a naive re-plumb fails it, a
  skipped one leaves the halvings apart — either way the test is the
  tripwire). Kill: M2 does not ship without it.
- **RSS regression from `clearToSpaceFreeRegion`'s single memset.** It
  zeroes the same bytes the per-block loop did — no delta by construction;
  listed only because "one big memset" invites suspicion. Detector: peak
  RSS in C2 arms.
- **Windows/macOS page geometry.** Slice bases and all commit sizes are
  512 KiB-quantized ⇒ multiples of both 4 KiB and 16 KiB pages. `commitAt`
  contracts unchanged. Detector: mac-build/win-build CI presets.

## 9. Rollback

- **M2** is config-gated at runtime: `nursery_region_bytes = 0` (or absent)
  is bit-for-bit the legacy geometry; the default flip is its own one-line
  commit. Instant, no rebuild.
- **M1** is a structural replacement WITHOUT an env flag — a deliberate
  deviation from house convention, stated plainly: the legacy and extent
  designs cannot share `NurserySpace` internals without maintaining two
  complete heap structures behind every method (the dual-path cost is the
  bug surface), the compiled-code ABI is untouched (the usual reason for
  runtime flags — mixed-binary compatibility — does not apply), and trigger
  semantics are argued equivalent and gated numerically (gate 5). Rollback
  = `git revert` of the single Step-2 commit. The census (Step 1) and M2
  (Step 3) are independent and survive a Step-2 revert.

## 10. Ship checklist (only on a C2 keep)

### 10.1 Invariant amendments ✅ LANDED 2026-08-09

Applied as specified below, plus one clause the Step-2 tests forced into
HEAP_041: the fail-soft rung is required in ThreadLocalHeap's three
nursery allocation paths, not only in `ensureNursery` (Step 2's deviation
note). Spec kept for the record:

- **HEAP_034**: "end is pre-clamped to min(block end, proactive-GC
  threshold trip) by computeAllocEndForBlock" → "min(from-space end,
  proactive-GC threshold trip) by computeAllocEnd"; clause (c)'s "tries
  block advance (allocateFast) then minor GC" → "performs minor GC via
  ThreadLocalHeap::allocateSlowRaw" (the allocateFast hop is deleted); the
  bump-state clause's "(updated at init/reset/block-advance/post-minor-GC
  by construction)" → "(updated at init/reset/post-minor-GC by
  construction)". Layout/compare/slow-call clauses otherwise unchanged.
- **HEAP_041**: rewrite the middle — delete the block-advance sentence, the
  disambiguator sentence, and the index-rewind parenthetical; new text:
  "A miss against the clamped end means the proactive threshold has tripped
  (or, under the already-full fail-soft, the from-space is exhausted);
  the sequence is: one minor GC, then the fail-soft unclamp of the
  from-space end (tiny-config corner where threshold_total_bytes_ < n),
  then abort (HEAP_017)." Keep: n's constraints, the VOID-after-statepoint
  clause, the second-exception-to-HEAP_011 framing.
- **HEAP_011 / FORBID_HEAP_002 / CGEN_074 / CGEN_072**: texts survive as
  written (verified — no block-granular claims).
- **THEORY.md** — four sites, not one (verification found three more):
  the capacity-model paragraph gains "the guarantee window is the whole
  from-space extent" and loses the block-transition wording; :53-63 (the
  two-region design described as low_blocks_/high_blocks_ block sets);
  :191 (physical commit "via acquireNurseryBlockLow()/High()" — deleted
  functions); :399-403 (GC state-variable list naming current_from_idx_,
  current_to_idx_, scan_block_idx_ — deleted fields).
- **design_docs/theory/heap_representation_theory.md:554**: describes the
  `block_end_of_objects_` Cheney tail-gap cutoff — restrict the claim to
  old-gen `end_of_objects` tracking (HEAP_024), which survives.
- **guides/gc-diagnostics.md:210-250, :421**: a paste-in diagnostic recipe
  written directly against low_blocks_/current_from_idx_/block_size_ —
  rewrite against the extent fields or delete the recipe.
- Scope note: §2.2's "per-block fields appear ONLY in NurserySpace.{hpp,cpp}"
  claim holds for CODE; comments/docs are exactly the sites above.

### 10.2 New invariant rows ✅ LANDED (HEAP_042 / HEAP_043 verified free)

**As built**, the two rows differ from the drafts below: HEAP_042 gained the
slice-geometry CLAMP, the reset-drops-retained-commit rule, the
capacity-vs-retained_commit split, the growth bounds-refresh obligation and
the loud slot-exhaustion fatal; HEAP_043 gained the default POLICY
(`min(DEFAULT_NURSERY_REGION_BYTES, max_heap_size/2)`, so small heaps keep
the legacy split) and the `min()`-capped `getOldGenMaxBytes()` contract.
HEAP_034 and HEAP_041 were amended per §10.1 plus the fail-soft-rung
clause the Step-2 tests forced. Drafted text kept for the record:

```
HEAP_042;Runtime_Heap;ContiguousNursery;enforced;Each NurserySpace semi-space is a single contiguous VA extent [base, base+capacity): the LOGICAL prefix of a fixed-size per-heap slice of the nursery region (slice_bytes = min(nursery_max_block_count/2 * alloc_buffer_size, per-side region) per side; low and high slices at mirrored slot indices; acquire/grow/release via Allocator::{acquire,grow,release}NurserySlicePair under thread_mutex_). Capacity is ONE value per pair (both sides equal by construction), quantized to alloc_buffer_size, and bounded by min(slice_bytes, configured max); membership bounds and all GC semantics are defined by CAPACITY. Physical retained_commit per slot is slice-layer-private, monotone up to slice_bytes, may exceed a respawned heap's capacity (dormant pages), is never re-commitAt'd (MAP_FIXED re-map discards pages), and is DROPPED wholesale by Allocator::reset (slot table rebuilt from the new config against the first-init region). Growth raises capacity on both sides or neither and MUST refresh membership bounds before the next GC decision. bump_.end = min(extent end, proactive-threshold trip) via computeAllocEnd with the already-full fail-soft; there is NO block advance - a bump miss always signals minor GC; to-space evacuation is a pure bump with no tail gaps, so the Cheney scan is the two-pointer scan_ptr_ < copy_ptr_ loop and validate walkers cover full allocated prefixes. Plan plans/contiguous-nursery-space.md;NurserySpace.hpp|NurserySpace.cpp|Allocator.cpp|HEAP_034|HEAP_041|HEAP_007
HEAP_043;Runtime_Heap;AddressSpaceDivision;enforced;The old-gen/nursery address split is configuration, not a constant: nursery_offset = max_heap_size - nursery_region_bytes (nursery_region_bytes = 0 means the legacy half split), computed once at first Allocator::initialize (first init wins for process lifetime, including across reset). Every old-gen cap consumer must route through Allocator::getOldGenMaxBytes(), which returns min(nursery_offset, config-derived cap) so a smaller reset config scales its cap while never exceeding the reserved region; in particular OldGenSpace::committedToCapRatio must NOT derive the cap from config max_heap_size/2 directly. validate() enforces unconditionally that the initial per-side nursery fits the effective slice, and for nonzero nursery_region_bytes: a multiple of 2*alloc_buffer_size, >= nursery_max_block_count*alloc_buffer_size (one unclamped slot per side), <= max_heap_size/2. Plan plans/contiguous-nursery-space.md;Allocator.cpp|OldGenSpace.cpp|AllocatorCommon.hpp|HEAP_042
```

### 10.3 Docs and memory ✅ LANDED 2026-08-09

Doc sweep done, all sites the verification named: THEORY.md ×4 (the
two-region design paragraph, the physical-commit bullet, the GC
state-variable list, the HEAP_034 bump-diamond paragraph),
design_docs/theory/heap_representation_theory.md:554 (the
`block_end_of_objects_` paragraph, now scoped to the old gen's surviving
HEAP_024 tracking), guides/gc-diagnostics.md (the paste-in nursery-dump
recipe, rewritten to two extent ranges and marked as already-in-tree).
C0 temp counters deleted with their host sites; the old-gen in-use-peak /
commit-high-water pair KEPT (permanent HEAP_043 telemetry, printed in the
Major GC section). Remaining: benchmarks/tier2-opt.md Run O entry and the
memory updates, both after §5's arms.

## 11. Grounding log (findings that shaped or overturned the first sketch)

1. **Compiled code is structurally indifferent to the `end` redefinition**
   (§1.3) — the enabling result; without it this plan would be an ABI
   migration instead of a runtime-internal rewrite.
2. **A second halving hides in `committedToCapRatio`**
   (OldGenSpace.cpp:795-804) — M2 as first sketched (move `nursery_offset`
   only) would have silently mispriced sweep pressure; §3.1 moves both.
3. **The freelists are empty in every normal process** (sole feeder
   `~NurserySpace`; §1.4) — "contiguity is an accident" overstates the
   danger single-threaded, but concurrent heaps DO interleave, which is
   what makes the slice layer (not a coalesce-and-assert hack) the right
   mechanism.
4. **`reset()` leaks nursery blocks today** (§1.6.2) — discovered by the
   inventory; fixed as a by-product of slice release.
5. **`wouldExceedThreshold` is dead code** (§1.6.1).
6. **`nursery_max_block_count` was never validated against the region**
   (§1.6.3) — M2's validate() work closes it.
7. **The entire tail-gap apparatus is per-block collateral** — its four
   pieces (`block_end_of_objects_`, `advanceScanIfNeeded`,
   `verifyToSpaceBlockEndOfObjects`, the current-block-only validate walk)
   delete rather than port; the validate walk gets STRONGER.
8. **Minors are NOT exactly preserved** — abandoned-tail accounting means
   the block design trips the threshold slightly early; the drift is
   downward and boundable by a one-counter census (§2.3/§3.3). The first
   sketch claimed "identical minors"; the gate now says
   "equal-or-predictably-lower".
9. **EnsureHeadroomTest is the ONLY `NurserySpaceTestAccess` user**
   repo-wide, and four of its assertions are block-structural — the test
   rewrite is a first-class Step-2 deliverable, not cleanup.
10. **`main.cpp --threads` is the only concurrent-heap path** — the slot
    count reduction under M2 is a benchmark-driver concern, not a product
    concern; sized accordingly (§8).
11. **312,942 / 871 lived only in project memory** — hoisted into §1.5, and
    since superseded by C0's own measurement (312,952 / 104,633 / 871).
12. **The already-full fail-soft clause must survive** in extent form
    (§2.3) — dropping it re-creates the post-GC trigger-loop the
    nursery-threshold-fast-path plan fixed; HEAP_041's history is the
    warning label.

Adversarial-verification findings folded in (items 13-19; four reviewers,
2026-08-09 — every §2.2 anchor, the IR-indifference claim, the
allocateFast-retry-drop, Run O, and HEAP_042/043 availability verified
independently):

13. **BLOCKER — growth must refresh membership bounds** (§2.5): the first
    draft's growth sequence omitted the `updateBounds()` today's
    checkAndGrow performs at NurserySpace.cpp:583; stale bounds would make
    the next minor GC silently skip evacuating the grown region. Now a
    named ordering + a pinning test.
14. **BLOCKER — slice geometry vs the config lifecycle**: slice_bytes is
    config-derived, the region first-init-wins, and the unit-test suite
    flips geometry across `Allocator::reset` constantly — an unclamped
    slice fatals OldGenCapacityTest-class configs at startup, and stale
    retained-commit records after a geometry flip skip-commit unmapped
    pages (SIGSEGV). Fixed by the §2.1 clamp + reset-drops-everything rule.
15. **MAJOR — capacity ≠ retained commit**: the draft's single `committed`
    field conflated logical extent with physical pages; re-commitAt of
    retained ranges would DISCARD them (MAP_FIXED anonymous re-map).
    Split into pair.capacity vs slot retained_commit (§2.1), bounds
    defined by capacity only.
16. **MAJOR — the trigger argument has THREE deltas, not one** (§2.3):
    tail waste (down), fail-soft quantization (down), and the
    growth-occupancy input (UP-capable — the one plausible M1 wall
    mechanism). Gate 5 consults `nursery_grow_events` first. **C0 then
    measured all three as sub-cycle** (§3.3: mean abandoned tail 47.7 B ⇒
    Δminors 0.059 cycles), so gate 5 tightened to exact equality instead of
    a slack band — the verification finding made the gate right, and the
    census made it strict.
17. **MAJOR — a naive committedToCapRatio re-plumb breaks
    OldGenSweepBudgetTest by design** (first-init 12 GiB denominator pins
    the ratio to ~0): `getOldGenMaxBytes()` = min(nursery_offset,
    config-derived cap) keeps the test's tunable denominator AND repairs
    the reset-divergence trap both directions (§3.1).
18. **Doc sweep was materially incomplete**: three more THEORY.md sites,
    heap_representation_theory.md:554, and the gc-diagnostics.md paste-in
    recipe all describe deleted machinery (§10.1).
19. **Two honesty corrections**: the motivating ratio is ~1 slow entry per
    ~21 K allocations (not 62 K — the memory note fails its own volume
    cross-check), and M1 trades peak UNGROWN concurrency ~96 → 24 slots
    (parity holds only at max growth); the `isNurseryNearFull` "safepoint
    gating" consumers are dead code (`__eco_safepoint_poll` has zero call
    sites) — the one live consumer is the benchmark driver (§1.6.5).
