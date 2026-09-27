/**
 * Common Definitions for Allocator Components.
 *
 * This file contains shared constants, types, and utilities used across
 * the allocator subsystem (NurserySpace, OldGenSpace, Allocator).
 *
 * Key contents:
 *   - Sizing constants: Heap size, nursery size, AllocBuffer size.
 *   - Color enum: Tri-color marking states (White, Grey, Black).
 *   - Utility functions: getHeader(), getObjectSize().
 */

#ifndef ECO_ALLOCATOR_COMMON_H
#define ECO_ALLOCATOR_COMMON_H

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include "Heap.hpp"

// Enable extra GC assertions and nursery invariants in debug builds.
// Normally set via CMake (-DECO_GC_DEBUG=1); this provides a safe fallback.
#ifndef ECO_GC_DEBUG
#define ECO_GC_DEBUG 0
#endif

// Heap-validator switch. Independent of ECO_GC_DEBUG. Gates the always-on
// stale-HPointer detection (write/read/arg-side hooks, free-region
// poisoning), the per-container bitmap-mismatch tripwires, the post-GC
// heap-integrity walker, the from-space pre-evacuation walk, the
// forward-chain depth assert, and the old-gen / BBoP invariant audits.
// Off by default — these are hot-path checks. Turn on via CMake
// (-DECO_HEAP_VALIDATE=ON) for diagnostic runs (heap-profile, stress).
#ifndef ECO_HEAP_VALIDATE
#define ECO_HEAP_VALIDATE 0
#endif

namespace Elm {

class Allocator;

// Tri-color marking states for mark-and-sweep GC.
enum class Color : u32 {
    White = 0,   // Not yet marked (potential garbage).
    Grey = 1,    // Marked but children not yet scanned.
    Black = 2    // Marked and all children scanned.
};

// ============================================================================
// Default Configuration Constants
// ============================================================================
// Every HeapConfig field's default initializer pulls its value from one of
// these constants — keep them in sync. Grouped by scope: heap-wide, string /
// rope heuristics, nursery, then old generation. HeapConfig declares its
// fields in the same order.

// ---- Heap-wide ----

// OS page size for mmap(MAP_FIXED) alignment of old-gen large-block extents.
// mmap rejects MAP_FIXED requests whose address or length is not a page
// multiple, so the allocator's bump pointer must advance in multiples of the
// OS's page size — not a smaller "logical page". Darwin on Apple Silicon uses
// 16 KiB pages (`sysctl hw.pagesize`); Linux on x86-64/aarch64 and Darwin on
// x86-64 use 4 KiB. We can't make this dynamic without unwinding a lot of
// constexpr math, so pin it at compile time per platform and assert at
// allocator init that getpagesize() matches.
#if defined(__APPLE__) && defined(__aarch64__)
constexpr size_t OS_PAGE_SIZE = 16384;
#else
constexpr size_t OS_PAGE_SIZE = 4096;
#endif

// Reserved virtual address space for the heap (24 GiB; 20 GiB old gen +
// 4 GiB nursery under the default split below).
constexpr size_t DEFAULT_MAX_HEAP_SIZE = 24ULL * 1024 * 1024 * 1024;

// Address space given to the NURSERY region, both halves together, when
// HeapConfig::nursery_region_bytes is left at 0 (HEAP_043). The policy is
// min(this, max_heap_size / 2), so the default degrades to the legacy half
// split on heaps smaller than 8 GiB (every unit-test config) and takes
// effect on the real 24 GiB reservation: 4 GiB nursery / 20 GiB old gen.
//
// 4 GiB = 2 GiB per side = 8 slice slots at the default 256 MiB slice, i.e.
// 8 concurrently-alive ThreadLocalHeaps at full growth — while a
// self-compile was measured to use exactly one 512 MiB nursery and 3.98 GiB
// of old-gen high-water, so the old gen goes from 3x to 5x its observed
// peak and the nursery keeps 4x the slots a single-threaded program needs.
constexpr size_t DEFAULT_NURSERY_REGION_BYTES = 4ULL * 1024 * 1024 * 1024;

// Size of one AllocBuffer / nursery block / old-gen BBoP page in bytes.
constexpr size_t ALLOC_BUFFER_SIZE = 512 * 1024;

// Allocations of this size or larger bypass the nursery and are pinned in old gen (also triggers split-header path for strings/byte buffers).
constexpr size_t LARGE_OBJECT_THRESHOLD = 8 * 1024;

// threaded-gc-04b placement of large pointer-bearing objects: one no larger
// than min(nursery capacity / divisor, max size) goes in the nursery, a larger
// one in the young large-object space (YLOS). Divisor 0 = never the nursery;
// max size 0 = no fixed bound.
constexpr u32 LARGE_PTR_NURSERY_DIVISOR = 8;
// 128 KiB chosen by experiment E1 (plans/threaded-gc-04b-young-large-objects.md
// P§5a/P§9): best or tied on wall and GC time at 80 KB, 800 KB and 8 MB arrays.
constexpr size_t LARGE_PTR_NURSERY_MAX_SIZE = 128 * 1024;

// ---- String / rope heuristics ----

// Concat results <= this many UTF-16 code units flatten to a single leaf; larger totals build a Tag_StringRope.
constexpr size_t STRING_FLATTEN_LIMIT = 32 * 1024;

// slice() ranges <= this many UTF-16 code units flatten directly instead of allocating a Tag_StringSlice.
constexpr size_t STRING_TINY_SLICE_LIMIT = 128;

// Bytes.Decode.string builds a zero-copy Tag_StringUtf8View for valid all-ASCII
// payloads at least this many bytes; shorter valid-ASCII input copies a small
// Tag_StringUtf8Leaf (mirrors MAKE_BYTEBUFFER_SLICE_MIN_LEN).
constexpr size_t UTF8_VIEW_MIN_LEN = 32;

// Master switch for creating any UTF-8 String form (view or leaf). When false,
// every creation path falls back to the UTF-16 forms — a config-only rollback.
constexpr bool UTF8_STRINGS_ENABLED = true;

// Rope tree depth above which the rebalance heuristic flags the rope (rebalance itself is TODO).
constexpr u32 ROPE_MAX_HEIGHT = 32;

// Leaf count above which the rebalance heuristic checks for too-many-small-leaves (paired with ROPE_MIN_LEAF_SIZE).
constexpr u32 ROPE_LEAF_COUNT_LIMIT = 64;

// Average leaf size below which a rope at/over ROPE_LEAF_COUNT_LIMIT is flagged as a rebalance candidate.
constexpr u32 ROPE_MIN_LEAF_SIZE = 128;

// ---- Nursery ----

// Initial nursery size in blocks (must be even; split into from/to semi-spaces).
constexpr size_t NURSERY_BLOCK_COUNT = 256;

// Hard upper bound on adaptive nursery growth, in blocks (must be even).
  // Tuned 2026-09-22 (plans/gc-param-sweep/combinations-2026-09-22-results.md):
  // 1024 -> 512 (nursery ceiling 512 -> 256 MiB), worth -17.6 s alone. Measured together as one config on the Stage-7 self-compile:
  // 233.8 s -> 195.8 s (-16.3 %), GC 115.5 -> 85.4 s, output byte-identical.
constexpr size_t NURSERY_MAX_BLOCKS = 512;

// Nursery occupancy fraction that triggers a minor GC.
constexpr float NURSERY_GC_THRESHOLD = 0.95f;

// Post-minor-GC to-space occupancy above which the nursery requests more blocks.
constexpr float NURSERY_GROWTH_THRESHOLD = 0.20f;

// Minor-GC survivals required before an object is promoted to old gen (header age field is 2 bits).
  // Tuned 2026-09-22 (plans/gc-param-sweep/combinations-2026-09-22-results.md):
  // 2 -> 1, halving nursery survivor copies (1.371 B -> 0.747 B), -17.7 s alone. Measured together as one config on the Stage-7 self-compile:
  // 233.8 s -> 195.8 s (-16.3 %), GC 115.5 -> 85.4 s, output byte-identical.
constexpr u32 PROMOTION_AGE = 1;

// Enable two-pass DFS spine copying for Cons lists during minor GC (else BFS for all types).
constexpr bool USE_HYBRID_DFS = true;

// ---- Old generation ----

// Initial committed bytes of the old generation at startup.
constexpr size_t INITIAL_OLD_GEN_SIZE = 16 * 1024 * 1024;

// Old-gen committed/cap fraction above which a major GC is scheduled (must exceed MAJOR_GC_TARGET_UTILIZATION).
  // Tuned 2026-09-22 (plans/gc-param-sweep/combinations-2026-09-22-results.md):
  // 0.85 -> 0.95 (majors 10 -> 5), -11.8 s alone; SATURATES here (0.97/0.99 identical). Measured together as one config on the Stage-7 self-compile:
  // 233.8 s -> 195.8 s (-16.3 %), GC 115.5 -> 85.4 s, output byte-identical.
constexpr float MAJOR_GC_INITIATING_OCCUPANCY = 0.95f;

// Fraction of the old-gen cap (= half the max_heap_size reservation) at which
// the GlobalPressure trigger schedules a major GC. Historically this was
// hard-coded as initiating_occupancy/3 (~0.28), which on a 24 GB default
// reservation fired at ~3.4 GB committed — 92% of all majors on compile
// workloads whose live set never neared the cap, and 56% of their wall clock.
// Decoupled and raised to the anti-ballooning-backstop role: 0.85 of cap.
// (Run K, benchmarks/runtime-calls.md: majors 103 -> 12, flag-on self-compile
// wall 13:44 -> 6:27, RSS +1.7%.) The Occupancy and GarbageFraction triggers
// keep bounding per-thread crowding and garbage accumulation below this bar.
constexpr float MAJOR_GC_GLOBAL_PRESSURE_FRACTION = 0.85f;

// Post-major-GC live/committed target; the old-gen cap is grown to keep utilization below this.
constexpr float MAJOR_GC_TARGET_UTILIZATION = 0.50f;

// Fraction of old-gen committed that, once allocated since the last major, schedules another (0.0 disables).
constexpr float MAJOR_GC_GARBAGE_FRACTION = 0.70f;

// On releaseOldGenBlock, also madvise(MADV_DONTNEED) to drop physical RSS (virtual mapping is retained either way).
constexpr bool DECOMMIT_ON_OLDGEN_RELEASE = true;

// threaded-gc-03 (plans/threaded-gc-03-helper-threads.md, HEAP_058-060,
// GC_DET_001): GC helper threads. Mode 0 = off (today's inline path, no pool),
// 1 = sync (helper jobs run inline at their post point: the reference),
// 2 = concurrent (jobs run on the GCHelperPool). ECO_GC_THREAD=0|1|2 overrides.
constexpr uint32_t GC_THREAD_MODE = 2;               // default-on (plan Step 12)
constexpr uint32_t GC_HELPER_THREADS = 1;
constexpr int32_t  GC_HELPER_CPU = -1;                 // -1 = no pinning
// U1 deferred decommit: a released extent is discarded once it has stayed
// unused past this many pause ends (UINT32_MAX = never, except under the cap).
// E1: no finite value in {0, 4, 16, 64, 256} came within 10 % of "never" on
// refaults (reuse spreads over a whole major cycle), so the pause-end clock is
// off by default and the major clock below bounds retention instead.
constexpr uint32_t DECOMMIT_DELAY_SYNCS = UINT32_MAX;
constexpr size_t   DECOMMIT_PENDING_MAX_BYTES = 0;     // 0 = no cap
// ...or once it has stayed unused past this many MAJOR GCs (0 = off). E1
// (plan §9): reuse of released blocks spreads over a whole major cycle, so a
// delay counted in majors is the unit that keeps the refault savings.
constexpr uint32_t DECOMMIT_DELAY_MAJORS = 1;
// U2 commit-ahead: bytes kept committed + populated above the old-gen bump.
// E2: 128 MiB is the smallest window that covered every fresh commit of the
// self-compile (32 MiB missed 26 %); 512 MiB gained nothing and cost RSS.
constexpr size_t   COMMIT_AHEAD_BYTES = size_t{128} << 20;   // 0 = off

// threaded-gc-02 (plans/threaded-gc-02-bitmap-allocation.md, HEAP_054): allocate
// uniform size-class cells straight from the mark bitmap through a per-class
// cursor, and gap-sweep mixed blocks, instead of the header-walking lazy sweep.
constexpr bool OLD_GEN_BITMAP_ALLOC = true;

// threaded-gc-05b (plans/threaded-gc-05b-parallel-marking.md, HEAP_064): the
// old-gen mark work of an incremental cycle runs on gc_mark_threads markers
// (0 = auto: min(cap, available CPUs); 1 = serial reference). Boxed arrays and
// list backings longer than MARK_CHUNK_ELEMS slots are scanned in chunks.
// DEFAULT auto, capped at 16, from experiments E2/E3 (plan P§10): self-compile
// in-pause slice mark 9.76 s -> 1.30 s, worst pause = the minor floor (189 ms).
constexpr uint32_t GC_MARK_THREADS = 0;
constexpr uint32_t GC_MARK_THREADS_CAP = 16;
constexpr uint32_t MARK_CHUNK_ELEMS = 1024;

// threaded-gc-05c (plans/threaded-gc-05c-concurrent-marking.md, HEAP_065):
// concurrent marking. CONC_MARK 0 = off (05b in-pause slices), 1 = sync (the
// whole mark in the t0 pause: the determinism reference), 2 = concurrent
// (background markers between pauses; the mutator assists when late).
// ECO_GC_CONC_MARK=0|1|2 and ECO_GC_CONC_MARK_THREADS override.
// DEFAULT-ON (plan P§10): mode 2, auto background markers capped at 4 (E2: the
// smallest B with zero assists and closings on the self-compile; B = 2 needed
// assists), priority 0 = inherit (E4: nice 10 / 19 / SCHED_IDLE let a starved
// marker stall the closing join -- up to 9.5 s under 24 spinning co-runners),
// assist lag 8 (E2: the largest lag with zero assists).
constexpr uint32_t CONC_MARK = 2;
constexpr uint32_t CONC_MARK_THREADS = 0;          // 0 = auto: min(cap, CPUs - 1)
constexpr uint32_t CONC_MARK_THREADS_CAP = 4;
constexpr int32_t  CONC_MARK_PRIORITY = 0;         // 0 inherit, 1..19 nice, 20 SCHED_IDLE
constexpr uint32_t CONC_MARK_ASSIST_LAG = 8;       // grace, in cycle steps

// threaded-gc-05c Part B (P§3.11): heap-relative trigger pacing.
// HEADROOM_MARGIN > 0 enables the Headroom trigger -- DEFAULT 1.5 (E9/E10: it
// never fires at the self-compile's 20 GB cap, and at an 11 GB cap it started
// the late cycle earlier: peak 94.4 % -> 81.5 % of the cap, same majors).
// LIVE_BUDGET_PACED reaches the LiveBudget at the handoff instead of t0 (E9:
// peak spread over the gf sweep 44.5 % -> 6.4 %, but +2 majors at gf 0.65 --
// the plan's "+1 at every point" rule rejects it as a default).
// GARBAGE_BACKSTOP > 0 raises the garbage-fraction threshold to it while
// LiveBudget is on (E9: 36 % spread, non-monotone in k -- rejected).
constexpr double MAJOR_GC_HEADROOM_MARGIN = 1.5;
constexpr bool   MAJOR_GC_LIVE_BUDGET_PACED = false;
constexpr float  MAJOR_GC_GARBAGE_BACKSTOP = 0.0f;

// threaded-gc-05a (plans/threaded-gc-05a-incremental-marking.md, HEAP_063):
// spread the major-GC mark over the minor GCs after the trigger. Requires
// OLD_GEN_BITMAP_ALLOC. SLICES = T (0 = the whole cycle inside the t0 pause).
// DEFAULT-ON with T = 32 from experiment E1 (plan P§10): self-compile max
// pause 4.83 s -> 336 ms (triple medians), old-gen peak +1.6 %, wall flat.
constexpr bool     INCREMENTAL_MARK = true;
constexpr uint32_t INCREMENTAL_MARK_SLICES = 32;
constexpr size_t   INCREMENTAL_MARK_MIN_SLICE_UNITS = 16384;   // ~0.7 ms at 41 ns/object
constexpr double   INCREMENTAL_MARK_PREDICT_GROWTH = 1.25;
constexpr double   INCREMENTAL_MARK_FINISH_FRACTION = 0.95;

// threaded-gc-02 D1b: a uniform block is demoted to mixed at the end of mark
// iff live_bytes <= DEMOTE_LIVE_FRACTION * totalBytes. 0.5 is the former
// hard-coded `live * 2 <= total`; 0.0 = never demote. 0.3 chosen from E1
// (plan §9 item 9): steady 7 majors, peak ~1 GB below 0.5.
constexpr double DEMOTE_LIVE_FRACTION = 0.3;

// threaded-gc-02: in bitmap mode the garbage-fraction trigger's denominator is
// min(committed, GARBAGE_DENOM_CAP * committed at the last major). 0 = uncapped
// (the legacy denominator, current committed) — the default: with LiveBudget
// bounding the peak, a cap of 2 only added a major (plan §9 item 7).
constexpr double GARBAGE_DENOM_CAP = 0.0;

// threaded-gc-02 (both modes; defaults from the plan's §9 item 7 sweep, k = 4.5 and
// r = 1.5 chosen 2026-09-25): a LiveBudget major fires when
// bytes allocated since the last major reach MAJOR_GC_LIVE_BUDGET * live_ref,
// live_ref = min(L_i, LIVE_GROWTH_BOUND * L_{i-1}) (L = mark-derived live at
// the end of mark). 0 disables each.
constexpr double MAJOR_GC_LIVE_BUDGET = 4.5;
constexpr double LIVE_GROWTH_BOUND = 1.5;

// Default cap on bytes committed to uniform small-class pages before splitting larger free cells.
constexpr size_t DEFAULT_SMALL_CLASS_HEAP_BUDGET = 1024ULL * 1024 * 1024;

// ---- Old-gen sweep & mark pacing ----

// Bytes of lazy-sweep work the allocator does per slow-path invocation (per slice).
constexpr size_t SWEEP_WORK_BUDGET = 4096;

// Bytes of sweep work `finishMarkAndSweep` runs synchronously before returning (seeds free lists for the first allocations).
constexpr size_t INITIAL_SWEEP_BUDGET = SWEEP_WORK_BUDGET * 16;

// Incremental marking work ratio: bytes marked per byte allocated during the marking phase.
constexpr size_t MARK_WORK_RATIO = 2;

// Base proportionality factor for the per-allocation sweep budget (bytes swept per byte requested), pre pressure scaling.
constexpr double SWEEP_BYTES_PER_ALLOC_BYTE = 2.0;

// Soft cap on the per-allocation sweep budget BEFORE pressure scaling (1 MiB).
constexpr size_t MAX_SWEEP_BYTES_PER_ALLOC = 1u << 20;

// Hard cap applied AFTER pressure scaling and unswept-ratio boost (4 MiB).
constexpr size_t MAX_SWEEP_BYTES_HARD = 4u << 20;

// Pressure thresholds on committedToCapRatio: each step picks the matching SWEEP_SCALE_*.
constexpr double SWEEP_CAP_RATIO_LOW    = 0.50;
constexpr double SWEEP_CAP_RATIO_MEDIUM = 0.75;
constexpr double SWEEP_CAP_RATIO_HIGH   = 0.90;

// Per-allocation sweep budget multipliers, indexed by pressure step (must be non-decreasing and >= 1.0).
constexpr double SWEEP_SCALE_LOW    = 1.0;
constexpr double SWEEP_SCALE_MEDIUM = 2.0;
constexpr double SWEEP_SCALE_HIGH   = 4.0;
constexpr double SWEEP_SCALE_CRIT   = 8.0;

// Unswept-block fraction above which the per-allocation sweep budget gets a SWEEP_UNSWEPT_SCALE boost.
constexpr double SWEEP_UNSWEPT_RATIO_BOOST = 0.50;

// Multiplier applied on top of pressure scaling when the unswept-block fraction is above the boost threshold.
constexpr double SWEEP_UNSWEPT_SCALE = 2.0;

// Per-slice budget for the panic-path sweeper (drives lazy sweep to completion before declaring OOM).
constexpr size_t PANIC_SWEEP_SLICE_BYTES = 1u << 20;

// ---- Old-gen free-list layout (compile-time, not runtime-configurable) ----
// These size class-counts compile into static array dimensions
// (e.g. OldGenSpace::free_lists_[NUM_SIZE_CLASSES]) and the corresponding
// telemetry buckets in GCStats, so they cannot be moved into HeapConfig
// without converting those arrays to dynamic containers.

// Number of small-cell size classes: 8 B steps from 8 up through MAX_SMALL_SIZE.
constexpr size_t NUM_SMALL_CLASSES = 32;

// Largest cell size served by a small class (last small class is exactly this many bytes).
constexpr size_t MAX_SMALL_SIZE = 256;

// First medium class size in bytes; subsequent medium classes are powers-of-two from here.
constexpr size_t MEDIUM_CLASS_BASE = 512;

// Medium-class slots reserved at compile time; the runtime cap depends on large_object_threshold.
constexpr size_t NUM_MEDIUM_CLASSES_MAX = 8;

// Total fixed-size class count; sizes the per-class free-list array.
constexpr size_t NUM_SIZE_CLASSES = NUM_SMALL_CLASSES + NUM_MEDIUM_CLASSES_MAX;

// Returns the header of a heap object.
inline Header *getHeader(void *obj) { return static_cast<Header *>(obj); }

// threaded-gc-04b (HEAP_062): may an object with this tag hold heap pointers?
// Only these tags are pointer-free by construction; everything else (including
// a Tag_Array that happens to hold unboxed values — the tag cannot tell) is
// treated as pointer-bearing, so a large one is young (nursery or YLOS).
inline bool tagMayHoldPointers(uint32_t tag) {
    return tag != Tag_Int && tag != Tag_Float && tag != Tag_Char &&
           tag != Tag_String && tag != Tag_ByteBuffer;
}

// Returns the size of a heap object in bytes (8-byte aligned).
inline size_t getObjectSize(void *obj) {
    Header *hdr = getHeader(obj);

    size_t size;
    switch (hdr->tag) {
        case Tag_Int:
            size = sizeof(ElmInt);
            break;
        case Tag_Float:
            size = sizeof(ElmFloat);
            break;
        case Tag_Char:
            size = sizeof(ElmChar);
            break;
        case Tag_String:
            size = sizeof(ElmString) + hdr->size * sizeof(u16);
            break;
        case Tag_StringSlice:
            // Fixed-size view: header.size is the logical UTF-16 length, not
            // a byte count. The slice itself is a fixed struct.
            size = sizeof(ElmStringSlice);
            break;
        case Tag_StringRope:
            // Fixed-size concat-tree node: header.size is the total logical
            // UTF-16 length; the rope struct itself has fixed footprint.
            size = sizeof(ElmStringRope);
            break;
        case Tag_Tuple2:
            size = sizeof(Tuple2);
            break;
        case Tag_Tuple3:
            size = sizeof(Tuple3);
            break;
        case Tag_Cons:
            size = sizeof(Cons);
            break;
        case Tag_ConsChunk:
            size = sizeof(ConsChunk);
            break;
        case Tag_ListBacking:
            // header.size is the capacity in ELEMENTS (like Tag_Array); the
            // footprint covers the whole element array, live or slack.
            size = sizeof(ListBacking) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_Custom:
            size = sizeof(Custom) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_Record:
            size = sizeof(Record) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_DynRecord:
            size = sizeof(DynRecord) + hdr->size * sizeof(HPointer);
            break;
        case Tag_FieldGroup:
            size = sizeof(FieldGroup) + hdr->size * sizeof(u32);
            break;
        case Tag_Closure:
            size = sizeof(Closure) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_Process:
            size = sizeof(Process);
            break;
        case Tag_Task:
            size = sizeof(Task);
            break;
        case Tag_Forward:
            size = sizeof(Forward);
            break;
        case Tag_Free:
            // Free cells store their full byte size directly in header.size.
            // Already 8-byte aligned at the time the cell was created.
            size = hdr->size;
            break;
        case Tag_ByteBuffer:
            // Header size field stores byte count.
            size = sizeof(ByteBuffer) + hdr->size * sizeof(u8);
            break;
        case Tag_Array: {
            // Size based on CAPACITY (header.size), not length: the heap
            // object occupies bytes for the full capacity reserved at
            // allocation time, so sweep must walk by capacity to land on
            // the next object's header. Iterating only `length` elements
            // is for marking/copying/fixup — but the heap footprint and
            // the per-object stride during sweep both need capacity.
            // W0 item 27: hdr->size IS arr->header.size, already loaded above.
            size = sizeof(ElmArray) + hdr->size * sizeof(Unboxable);
            break;
        }
        case Tag_LargeStringHeader:
            // Fixed-size split header. header.size carries the body's logical
            // UTF-16 length (not a byte count for this object).
            size = sizeof(LargeStringHeader);
            break;
        case Tag_LargeByteHeader:
            // Fixed-size split header. header.size carries the body's logical
            // byte count (not a byte count for this object).
            size = sizeof(LargeByteHeader);
            break;
        case Tag_ByteBufferSlice:
            // Fixed-size view: header.size is the logical byte count, not the
            // struct footprint. Mirrors the Tag_StringSlice case above; without
            // it a 24-byte slice was mis-sized as sizeof(Header)=8, corrupting
            // GC evacuation/scan stride (HEAP_004).
            size = sizeof(ElmByteBufferSlice);
            break;
        case Tag_StringUtf8View:
            // Fixed-size byte view; header.size is the logical unit count, not
            // the footprint. Mirrors Tag_StringSlice / Tag_ByteBufferSlice.
            size = sizeof(ElmStringUtf8View);
            break;
        case Tag_StringUtf8Leaf:
            // Inline ASCII bytes: 1 byte per unit. Footprint derives from
            // header.size exactly like Tag_String (but u8, not u16).
            size = sizeof(ElmStringUtf8Leaf) + hdr->size * sizeof(u8);
            break;
        default:
            size = sizeof(Header);
            break;
    }

    // All heap objects are 8-byte aligned.
    return (size + 7) & ~7;
}

// ============================================================================
// Nursery slice estate (HEAP_042)
// ============================================================================

/**
 * One ThreadLocalHeap's nursery address estate: two mirrored fixed-size
 * slices of the low and high nursery regions, at the same slot index.
 *
 * `capacity` is the LOGICAL extent length of EACH side — the semi-space a
 * NurserySpace actually bump-allocates and evacuates into, and the only
 * quantity GC semantics (membership bounds, threshold, growth) may consult.
 * It is one value because both sides always grow together.
 *
 * Distinct from it, and deliberately NOT exposed here: the slot's physical
 * *retained commit*, kept privately by the Allocator so a released slot's
 * pages can be reused by the next heap that claims the slot (the Issue-#40
 * respawn path). Retained commit may exceed `capacity` — those pages are
 * dormant, not part of any extent.
 */
struct NurserySlicePair {
    char*  low_base  = nullptr;   // slice base in the low nursery region
    char*  high_base = nullptr;   // mirrored slice base in the high region
    size_t capacity  = 0;         // logical extent bytes, per side
    size_t slot      = 0;         // slot index (bookkeeping / release)
};

// ============================================================================
// Heap Configuration
// ============================================================================

/**
 * Configuration for heap and allocator parameters.
 *
 * All fields have sensible defaults from the constants above. Users can
 * override any field before passing to Allocator::initialize().
 */
struct HeapConfig {
    // ---- Heap-wide ----

    // Reserved virtual address space for the heap.
    size_t max_heap_size = DEFAULT_MAX_HEAP_SIZE;

    // Bytes of that reservation given to the NURSERY region (both low and
    // high halves together); the old generation gets the rest (HEAP_043).
    // 0 (the default) selects the default policy in nurseryRegionBytes():
    // min(DEFAULT_NURSERY_REGION_BYTES, max_heap_size / 2).
    //
    // The default is deliberately lopsided in the old gen's favour: a
    // nursery is capped at nursery_max_block_count * alloc_buffer_size per
    // heap (512 MiB at defaults, measured to be exactly what a self-compile
    // uses) while the old generation's cap is a hard wall on a monotonic
    // commit bump. Splitting the reservation evenly gave the nursery ~24x
    // more address space than one heap can use and cost the old gen half
    // the heap. See plans/contiguous-nursery-space.md M2.
    size_t nursery_region_bytes = 0;

    // Size of one AllocBuffer / nursery block / old-gen BBoP page in bytes.
    size_t alloc_buffer_size = ALLOC_BUFFER_SIZE;

    // Allocations of this size or larger bypass the nursery and are pinned in old gen.
    size_t large_object_threshold = LARGE_OBJECT_THRESHOLD;

    // Large pointer-bearing objects (threaded-gc-04b): nursery when the size
    // is <= min(nursery capacity / divisor, max size), else the YLOS.
    // Divisor 0 = always the YLOS; max size 0 = no fixed bound.
    u32 large_ptr_nursery_divisor = LARGE_PTR_NURSERY_DIVISOR;
    size_t large_ptr_nursery_max_size = LARGE_PTR_NURSERY_MAX_SIZE;

    // ---- String / rope heuristics ----

    // Concat results <= this many UTF-16 code units flatten to a single leaf; larger totals build a rope.
    size_t string_flatten_limit = STRING_FLATTEN_LIMIT;

    // slice() ranges <= this many UTF-16 code units flatten directly instead of allocating a slice.
    size_t string_tiny_slice_limit = STRING_TINY_SLICE_LIMIT;

    // Min byte length for Bytes.Decode.string to build a zero-copy UTF-8 view
    // (shorter valid-ASCII decodes copy a small UTF-8 leaf).
    size_t utf8_view_min_len = UTF8_VIEW_MIN_LEN;

    // Master switch: when false, no UTF-8 String form is ever created.
    bool utf8_strings_enabled = UTF8_STRINGS_ENABLED;

    // Rope tree depth above which the rebalance heuristic flags the rope.
    u32 rope_max_height = ROPE_MAX_HEIGHT;

    // Leaf count above which the rebalance heuristic checks for too-many-small-leaves.
    u32 rope_leaf_count_limit = ROPE_LEAF_COUNT_LIMIT;

    // Average leaf size below which a rope at/over rope_leaf_count_limit is flagged as a rebalance candidate.
    u32 rope_min_leaf_size = ROPE_MIN_LEAF_SIZE;

    // ---- Nursery ----

    // Initial nursery size in blocks (even; split into from/to semi-spaces).
    size_t nursery_block_count = NURSERY_BLOCK_COUNT;

    // Hard upper bound on adaptive nursery growth, in blocks (even; >= nursery_block_count).
    size_t nursery_max_block_count = NURSERY_MAX_BLOCKS;

    // Nursery occupancy fraction that triggers a minor GC.
    float nursery_gc_threshold = NURSERY_GC_THRESHOLD;

    // Post-minor-GC to-space occupancy above which the nursery requests more blocks.
    float nursery_growth_threshold = NURSERY_GROWTH_THRESHOLD;

    // Minor-GC survivals required before an object is promoted to old gen.
    u32 promotion_age = PROMOTION_AGE;

    // Enable two-pass DFS spine copying for Cons lists during minor GC (else BFS for all types).
    bool use_hybrid_dfs = USE_HYBRID_DFS;

    // ---- Old generation ----

    // Initial committed bytes of the old generation at startup.
    size_t initial_old_gen_size = INITIAL_OLD_GEN_SIZE;

    // Old-gen committed/cap fraction above which a major GC is scheduled (must be > target_utilization).
    float major_gc_initiating_occupancy = MAJOR_GC_INITIATING_OCCUPANCY;

    // Global-committed/cap fraction at which the GlobalPressure trigger fires (anti-ballooning backstop).
    float major_gc_global_pressure_fraction = MAJOR_GC_GLOBAL_PRESSURE_FRACTION;

    // Post-major-GC live/committed target; the old-gen cap is grown to stay below this.
    float major_gc_target_utilization = MAJOR_GC_TARGET_UTILIZATION;

    // Fraction of old-gen committed allocated-since-last-major that schedules another major (0.0 disables).
    float major_gc_garbage_fraction = MAJOR_GC_GARBAGE_FRACTION;

    // On releaseOldGenBlock, also madvise(MADV_DONTNEED) to drop physical RSS.
    bool decommit_on_oldgen_release = DECOMMIT_ON_OLDGEN_RELEASE;

    // threaded-gc-03: helper-thread mode and the page-work users (see the
    // constants above). Modes 1/2 route decommit through PageWork (HEAP_059)
    // and may keep a commit-ahead window (HEAP_060).
    uint32_t gc_thread_mode = GC_THREAD_MODE;
    uint32_t gc_helper_threads = GC_HELPER_THREADS;
    int32_t  gc_helper_cpu = GC_HELPER_CPU;
    uint32_t decommit_delay_syncs = DECOMMIT_DELAY_SYNCS;
    size_t   decommit_pending_max_bytes = DECOMMIT_PENDING_MAX_BYTES;
    uint32_t decommit_delay_majors = DECOMMIT_DELAY_MAJORS;
    size_t   commit_ahead_bytes = COMMIT_AHEAD_BYTES;

    // threaded-gc-02 (HEAP_054): bitmap allocation for uniform blocks + gap
    // sweep for mixed blocks. Off = the legacy header-walking lazy sweep.
    bool old_gen_bitmap_alloc = OLD_GEN_BITMAP_ALLOC;

    // threaded-gc-05b (HEAP_064): parallel marking.
    uint32_t gc_mark_threads = GC_MARK_THREADS;
    uint32_t gc_mark_threads_cap = GC_MARK_THREADS_CAP;

    // threaded-gc-05c (HEAP_065): concurrent marking.
    uint32_t conc_mark = CONC_MARK;
    uint32_t conc_mark_threads = CONC_MARK_THREADS;
    uint32_t conc_mark_threads_cap = CONC_MARK_THREADS_CAP;
    int32_t  conc_mark_priority = CONC_MARK_PRIORITY;
    uint32_t conc_mark_assist_lag = CONC_MARK_ASSIST_LAG;
    // threaded-gc-05c Part B: trigger pacing (P§3.11).
    double major_gc_headroom_margin = MAJOR_GC_HEADROOM_MARGIN;
    bool   major_gc_live_budget_paced = MAJOR_GC_LIVE_BUDGET_PACED;
    float  major_gc_garbage_backstop = MAJOR_GC_GARBAGE_BACKSTOP;

    // threaded-gc-05a (HEAP_063): incremental mark cycle.
    bool     incremental_mark = INCREMENTAL_MARK;
    uint32_t incremental_mark_slices = INCREMENTAL_MARK_SLICES;
    size_t   incremental_mark_min_slice_units = INCREMENTAL_MARK_MIN_SLICE_UNITS;
    double   incremental_mark_predict_growth = INCREMENTAL_MARK_PREDICT_GROWTH;
    double   incremental_mark_finish_fraction = INCREMENTAL_MARK_FINISH_FRACTION;

    // threaded-gc-02 D1b: demote a uniform block to mixed at the end of mark
    // iff live_bytes <= demote_live_fraction * totalBytes. In [0, 1];
    // 0.0 = never demote (explicit early return); 1.0 = demote every block.
    double demote_live_fraction = DEMOTE_LIVE_FRACTION;

    // threaded-gc-02: bitmap-mode cap on the garbage-fraction denominator, as
    // a multiple of committed at the last major; 0 = uncapped.
    double garbage_denom_cap = GARBAGE_DENOM_CAP;

    // threaded-gc-02: LiveBudget trigger (see MAJOR_GC_LIVE_BUDGET); 0 = off.
    double major_gc_live_budget = MAJOR_GC_LIVE_BUDGET;
    double live_growth_bound = LIVE_GROWTH_BOUND;

    // Cap on bytes committed to uniform small-class pages before splitting larger free cells (0 disables).
    size_t small_class_heap_budget_bytes = DEFAULT_SMALL_CLASS_HEAP_BUDGET;

    // Cell-size cap that defines "small" for budgeting; allocations larger than this are not budgeted.
    size_t small_class_cell_max_bytes = LARGE_OBJECT_THRESHOLD;

    // ---- Old-gen sweep & mark pacing ----

    // Bytes of lazy-sweep work the allocator does per slow-path invocation.
    size_t sweep_work_budget = SWEEP_WORK_BUDGET;

    // W7 item 14: divisor applied to sweep_work_budget when the allocation is a
    // PROMOTION, i.e. when the caller is inside a minor GC. OldGenSpace::allocate
    // drives lazy sweep whenever gc_phase_ == Sweeping, and the code's own
    // comment names that "the dominant source of minor GC outliers" — but the
    // work still has to happen, and sweep-before-grow exists to stop the heap
    // growing while unswept garbage remains. So this THROTTLES rather than gates.
    //   1 = today (no throttle)     8 = conservative     0 = full gate, no sweep
    // Default 1: unchanged behaviour until a measurement says otherwise.
    size_t minor_sweep_divisor = 1;

    // Bytes of sweep work finishMarkAndSweep runs synchronously before returning.
    size_t initial_sweep_budget = INITIAL_SWEEP_BUDGET;

    // NO EFFECT (W0 item 13). Its only reader was the allocation-paced marking
    // branch in OldGenSpace::allocate, which was dead (gc_phase_ is never
    // Marking) and has been removed. Kept as an accepted key so existing
    // heap-config files still parse; validate() still rejects 0.
    size_t mark_work_ratio = MARK_WORK_RATIO;

    // Base proportionality factor for the per-allocation sweep budget (bytes swept per byte requested).
    double sweep_bytes_per_alloc_byte = SWEEP_BYTES_PER_ALLOC_BYTE;

    // Soft cap on the per-allocation sweep budget BEFORE pressure scaling.
    size_t max_sweep_bytes_per_alloc = MAX_SWEEP_BYTES_PER_ALLOC;

    // Hard cap applied AFTER pressure scaling and unswept-ratio boost.
    size_t max_sweep_bytes_hard = MAX_SWEEP_BYTES_HARD;

    // Pressure thresholds on committed/cap ratio (must satisfy 0 < low < medium < high < 1).
    double sweep_cap_ratio_low    = SWEEP_CAP_RATIO_LOW;
    double sweep_cap_ratio_medium = SWEEP_CAP_RATIO_MEDIUM;
    double sweep_cap_ratio_high   = SWEEP_CAP_RATIO_HIGH;

    // Per-allocation sweep-budget multipliers per pressure step (must be non-decreasing and >= 1.0).
    double sweep_scale_low    = SWEEP_SCALE_LOW;
    double sweep_scale_medium = SWEEP_SCALE_MEDIUM;
    double sweep_scale_high   = SWEEP_SCALE_HIGH;
    double sweep_scale_crit   = SWEEP_SCALE_CRIT;

    // Unswept-block fraction above which the per-allocation sweep budget gets a sweep_unswept_scale boost.
    double sweep_unswept_ratio_boost = SWEEP_UNSWEPT_RATIO_BOOST;

    // Multiplier applied on top of pressure scaling when the unswept-block fraction exceeds the boost threshold.
    double sweep_unswept_scale = SWEEP_UNSWEPT_SCALE;

    // Per-slice budget for the panic-path sweeper.
    size_t panic_sweep_slice_bytes = PANIC_SWEEP_SLICE_BYTES;

    // Derived value: total nursery size in bytes.
    size_t nurserySize() const { return nursery_block_count * alloc_buffer_size; }

    // ---- Nursery slice geometry (HEAP_042) ----
    //
    // The nursery region is carved into fixed-size per-heap SLICES, one pair
    // (low + high) per ThreadLocalHeap, so every semi-space is a single
    // contiguous extent. These helpers are the single source of truth for
    // that geometry and are shared by Allocator::rebuildNurserySliceTable and
    // validate() — keep them in agreement.

    // Bytes of address space given to the nursery, both regions together.
    // The old-gen cap is the complement: max_heap_size - this.
    size_t nurseryRegionBytes() const {
        if (nursery_region_bytes != 0) return nursery_region_bytes;
        // Default policy: the constant, but never more than half the heap —
        // so small heaps (every unit-test config) keep the legacy 50/50
        // split and only a reservation big enough to matter gets the
        // lopsided one.
        const size_t half = max_heap_size / 2;
        return DEFAULT_NURSERY_REGION_BYTES < half ? DEFAULT_NURSERY_REGION_BYTES
                                                   : half;
    }

    // Config-derived old-gen address-space cap (the complement of the
    // nursery region). Allocator::getOldGenMaxBytes() reports
    // min(this, the live nursery_offset) so a reconfigure that shrinks the
    // heap scales the cap down without ever exceeding the reservation.
    size_t oldGenCapBytes() const { return max_heap_size - nurseryRegionBytes(); }

    // Per-side (low or high) nursery region size.
    size_t nurseryRegionPerSideBytes() const { return nurseryRegionBytes() / 2; }

    // Per-side slice size: the config's max-growth size, CLAMPED to the
    // region (so a small heap with a large block cap still gets one usable
    // slot instead of zero) and rounded down to an alloc_buffer_size
    // multiple (so growth quantization and page alignment both hold).
    size_t nurserySliceBytes() const {
        const size_t want = (nursery_max_block_count / 2) * alloc_buffer_size;
        size_t s = want < nurseryRegionPerSideBytes()
                       ? want : nurseryRegionPerSideBytes();
        if (alloc_buffer_size != 0) s -= s % alloc_buffer_size;
        return s;
    }

    // Per-side bytes a nursery starts with (half of nurserySize()).
    size_t nurseryInitialPerSideBytes() const {
        return (nursery_block_count / 2) * alloc_buffer_size;
    }

    // Default constructor uses in-class member initializers.
    HeapConfig() = default;

    // Validates all configuration parameters.
    // Throws std::invalid_argument with descriptive message on validation failure.
    void validate() const {
        // ========== 1. Basic Size Constraints ==========

        if (max_heap_size == 0) {
            throw std::invalid_argument("max_heap_size must be > 0");
        }

        if (initial_old_gen_size == 0) {
            throw std::invalid_argument("initial_old_gen_size must be > 0");
        }

        if (alloc_buffer_size == 0) {
            throw std::invalid_argument("alloc_buffer_size must be > 0");
        }

        // threaded-gc-05b
        if (gc_mark_threads > 64) {
            throw std::invalid_argument("gc_mark_threads must be <= 64");
        }
        if (gc_mark_threads_cap < 1 || gc_mark_threads_cap > 64) {
            throw std::invalid_argument("gc_mark_threads_cap must be in [1, 64]");
        }
        // threaded-gc-05c
        if (conc_mark > 2) {
            throw std::invalid_argument("conc_mark must be 0, 1 or 2");
        }
        if (conc_mark_threads > 63) {
            throw std::invalid_argument("conc_mark_threads must be <= 63");
        }
        if (conc_mark_threads_cap < 1 || conc_mark_threads_cap > 63) {
            throw std::invalid_argument("conc_mark_threads_cap must be in [1, 63]");
        }
        if (conc_mark_priority < 0 || conc_mark_priority > 20) {
            throw std::invalid_argument("conc_mark_priority must be in [0, 20]");
        }
        if (conc_mark_assist_lag > 4096) {
            throw std::invalid_argument("conc_mark_assist_lag must be <= 4096");
        }
        if (!(major_gc_headroom_margin >= 0.0 && major_gc_headroom_margin <= 8.0)) {
            throw std::invalid_argument("major_gc_headroom_margin must be in [0, 8]");
        }
        if (!(major_gc_garbage_backstop == 0.0f ||
              (major_gc_garbage_backstop > major_gc_garbage_fraction &&
               major_gc_garbage_backstop < 1.0f))) {
            throw std::invalid_argument(
                "major_gc_garbage_backstop must be 0 or in (major_gc_garbage_fraction, 1)");
        }
        // threaded-gc-05a
        if (incremental_mark && !old_gen_bitmap_alloc) {
            throw std::invalid_argument(
                "incremental_mark requires old_gen_bitmap_alloc");
        }
        if (incremental_mark_slices > 4096) {
            throw std::invalid_argument("incremental_mark_slices must be <= 4096");
        }
        if (incremental_mark_min_slice_units < 1) {
            throw std::invalid_argument("incremental_mark_min_slice_units must be >= 1");
        }
        if (!(incremental_mark_predict_growth >= 1.0 &&
              incremental_mark_predict_growth <= 4.0)) {
            throw std::invalid_argument("incremental_mark_predict_growth must be in [1, 4]");
        }
        if (!(incremental_mark_finish_fraction >
                  static_cast<double>(major_gc_global_pressure_fraction) &&
              incremental_mark_finish_fraction <= 1.0)) {
            throw std::invalid_argument(
                "incremental_mark_finish_fraction must be in "
                "(major_gc_global_pressure_fraction, 1]");
        }
        if (!(demote_live_fraction >= 0.0 && demote_live_fraction <= 1.0)) {
            throw std::invalid_argument("demote_live_fraction must be in [0, 1]");
        }
        // threaded-gc-03
        if (gc_thread_mode > 2) {
            throw std::invalid_argument("gc_thread_mode must be 0, 1 or 2");
        }
        if (gc_helper_threads == 0 || gc_helper_threads > 64) {
            throw std::invalid_argument("gc_helper_threads must be in [1, 64]");
        }
        if (gc_helper_cpu < -1) {
            throw std::invalid_argument("gc_helper_cpu must be >= -1");
        }
        if (commit_ahead_bytes % OS_PAGE_SIZE != 0) {
            throw std::invalid_argument(
                "commit_ahead_bytes must be a multiple of the OS page size");
        }
        if (!(garbage_denom_cap == 0.0 || garbage_denom_cap >= 1.0)) {
            throw std::invalid_argument("garbage_denom_cap must be 0 or >= 1");
        }
        if (!(major_gc_live_budget >= 0.0)) {
            throw std::invalid_argument("major_gc_live_budget must be >= 0");
        }
        if (!(live_growth_bound == 0.0 || live_growth_bound >= 1.0)) {
            throw std::invalid_argument("live_growth_bound must be 0 or >= 1");
        }

        if (nursery_block_count == 0) {
            throw std::invalid_argument("nursery_block_count must be > 0");
        }

        // ========== 2. Heap Partitioning Constraints ==========
        // Heap is split: [0, max/2) = old gen, [max/2, max) = nursery.

        size_t old_gen_space = oldGenCapBytes();

        if (initial_old_gen_size >= old_gen_space) {
            throw std::invalid_argument(
                "initial_old_gen_size must be < the old-gen region "
                "(max_heap_size - nursery_region_bytes)");
        }

        // The INITIAL nursery must fit its own region (the per-side slice
        // check below is the sharp form; this keeps the coarse guard too).
        if (nurserySize() >= nurseryRegionBytes()) {
            throw std::invalid_argument(
                "nursery total size must be < nursery_region_bytes "
                "(the nursery must fit its own region)");
        }

        // Split sanity (HEAP_043). 0 means the legacy half split.
        if (nursery_region_bytes != 0) {
            if (nursery_region_bytes % (2 * alloc_buffer_size) != 0) {
                throw std::invalid_argument(
                    "nursery_region_bytes must be a multiple of "
                    "2 * alloc_buffer_size (it is split into two "
                    "block-quantized halves)");
            }
            if (nursery_region_bytes < nursery_max_block_count * alloc_buffer_size) {
                throw std::invalid_argument(
                    "nursery_region_bytes must admit at least one unclamped "
                    "slice per side "
                    "(>= nursery_max_block_count * alloc_buffer_size)");
            }
            if (nursery_region_bytes > max_heap_size / 2) {
                throw std::invalid_argument(
                    "nursery_region_bytes must be <= max_heap_size / 2 "
                    "(the old gen never gets less than half the heap)");
            }
        }

        // ========== 3. Nursery Block Constraints ==========
        // Nursery is split into two semi-spaces (from and to).

        if (nursery_block_count % 2 != 0) {
            throw std::invalid_argument(
                "nursery_block_count must be even (split into from-space and to-space)");
        }

        if (nursery_block_count < 2) {
            throw std::invalid_argument(
                "nursery_block_count must be >= 2 (at least 1 block per semi-space)");
        }

        if (nursery_max_block_count == 0) {
            throw std::invalid_argument("nursery_max_block_count must be > 0");
        }

        if (nursery_max_block_count % 2 != 0) {
            throw std::invalid_argument(
                "nursery_max_block_count must be even (split into from-space and to-space)");
        }

        if (nursery_block_count > nursery_max_block_count) {
            throw std::invalid_argument(
                "nursery_block_count must be <= nursery_max_block_count "
                "(initial size cannot exceed the adaptive-growth cap)");
        }

        // Slice geometry (HEAP_042): each heap's semi-space is the committed
        // prefix of ONE fixed-size slice, so the region must admit at least
        // one slice per side and a slice must hold the initial nursery.
        // nursery_max_block_count is deliberately NOT rejected when it
        // overshoots the region — nurserySliceBytes() clamps it, preserving
        // today's behaviour where an oversized growth cap merely stops
        // growing early rather than failing to boot.
        if (nurserySliceBytes() == 0) {
            throw std::invalid_argument(
                "nursery region is too small for one slice per side "
                "(need at least alloc_buffer_size per side)");
        }

        if (nurseryInitialPerSideBytes() > nurserySliceBytes()) {
            throw std::invalid_argument(
                "nursery_block_count too large for the nursery region: the "
                "initial per-side nursery must fit one slice "
                "(nursery_block_count/2 * alloc_buffer_size <= "
                "min(nursery_max_block_count/2 * alloc_buffer_size, "
                "nursery region / 4))");
        }

        // ========== 4. AllocBuffer Constraints ==========

        // Lower bound is the OS page size: mmap(MAP_FIXED) operates in
        // page-sized units, so a sub-page BBoP would either fail to map
        // exactly the requested extent or leave the bump pointer mis-aligned
        // for the next acquire. 4 KiB on Linux / Darwin x86-64; 16 KiB on
        // Darwin arm64 (Apple Silicon).
        constexpr size_t MIN_BUFFER_SIZE = OS_PAGE_SIZE;
        if (alloc_buffer_size < MIN_BUFFER_SIZE) {
            throw std::invalid_argument(
                "alloc_buffer_size must be >= the OS page size "
                "(4 KiB on x86-64, 16 KiB on Apple Silicon)");
        }

        if (alloc_buffer_size > old_gen_space) {
            throw std::invalid_argument(
                "alloc_buffer_size must be <= max_heap_size / 2 "
                "(can't exceed old gen space)");
        }

        // Old gen is sliced into BBoP pages of `alloc_buffer_size` at init.
        if (initial_old_gen_size % alloc_buffer_size != 0) {
            throw std::invalid_argument(
                "initial_old_gen_size must be a multiple of alloc_buffer_size "
                "(old gen is sliced into pages at init time)");
        }

        // ========== 4b. Large-Object Threshold Constraints ==========

        if (large_object_threshold < sizeof(Header)) {
            throw std::invalid_argument(
                "large_object_threshold must be >= sizeof(Header)");
        }
        if (large_object_threshold > old_gen_space) {
            throw std::invalid_argument(
                "large_object_threshold must be <= the old-gen region "
                "(can't exceed old gen space)");
        }
        // Any object below large_object_threshold is allocated in the
        // nursery, where the unit of allocation is a single block of
        // alloc_buffer_size bytes. The semi-space evacuator can only
        // copy an object that fits in a single block. So every object
        // routed through the nursery — i.e. every object whose aligned
        // size is < large_object_threshold — must also be < alloc_buffer_size.
        // The simplest sufficient invariant: large_object_threshold <=
        // alloc_buffer_size. Otherwise an allocation in the gap would
        // either fail to allocate or fail to evacuate after one minor GC.
        if (large_object_threshold > alloc_buffer_size) {
            throw std::invalid_argument(
                "large_object_threshold must be <= alloc_buffer_size "
                "(otherwise objects in [alloc_buffer_size, "
                "large_object_threshold) take the nursery path but cannot "
                "fit in a single nursery block)");
        }

        if (large_ptr_nursery_max_size % 8 != 0) {
            throw std::invalid_argument(
                "large_ptr_nursery_max_size must be a multiple of 8");
        }

        // ========== 5. Promotion Constraints ==========

        if (promotion_age < 1) {
            throw std::invalid_argument(
                "promotion_age must be >= 1 (must survive at least 1 GC)");
        }

        if (promotion_age > 3) {
            throw std::invalid_argument(
                "promotion_age must be <= 3 (header age field is 2 bits)");
        }

        // ========== 6. Threshold Constraints ==========

        if (nursery_gc_threshold <= 0.0f || nursery_gc_threshold > 1.0f) {
            throw std::invalid_argument(
                "nursery_gc_threshold must be in (0.0, 1.0]");
        }

        if (nursery_growth_threshold <= 0.0f ||
            nursery_growth_threshold >= 1.0f) {
            throw std::invalid_argument(
                "nursery_growth_threshold must be in (0.0, 1.0)");
        }

        if (major_gc_initiating_occupancy <= 0.0f ||
            major_gc_initiating_occupancy >= 1.0f) {
            throw std::invalid_argument(
                "major_gc_initiating_occupancy must be in (0.0, 1.0)");
        }

        if (major_gc_target_utilization <= 0.0f ||
            major_gc_target_utilization >= 1.0f) {
            throw std::invalid_argument(
                "major_gc_target_utilization must be in (0.0, 1.0)");
        }

        if (major_gc_initiating_occupancy <= major_gc_target_utilization) {
            throw std::invalid_argument(
                "major_gc_initiating_occupancy must be > "
                "major_gc_target_utilization");
        }

        if (major_gc_global_pressure_fraction <= 0.0f ||
            major_gc_global_pressure_fraction > 1.0f) {
            throw std::invalid_argument(
                "major_gc_global_pressure_fraction must be in (0.0, 1.0]");
        }

        if (major_gc_garbage_fraction < 0.0f ||
            major_gc_garbage_fraction >= 1.0f) {
            throw std::invalid_argument(
                "major_gc_garbage_fraction must be in [0.0, 1.0)");
        }

        // ========== 7. Small-Class Block Budget ==========
        //
        // small_class_heap_budget_bytes can be set to any value. When it
        // exceeds the old-gen cap (max_heap_size / 2), the heuristic is
        // effectively unbounded: small-class allocations always prefer
        // bag-first until the cap itself is hit. The default of 1 GiB is
        // well within the default 12 GiB old-gen cap; smaller test heaps
        // simply get the unbounded behaviour, which still respects
        // committedToCapRatio < 1.0.

        // FreeCell footprint: Header + a pointer link. The small-class
        // cell-size cap must be at least this so any class included in the
        // budget can legitimately host a FreeCell on its free list.
        constexpr size_t MIN_FREE_CELL_FOOTPRINT = sizeof(Header) + sizeof(void*);
        if (small_class_cell_max_bytes != 0 &&
            small_class_cell_max_bytes < MIN_FREE_CELL_FOOTPRINT) {
            throw std::invalid_argument(
                "small_class_cell_max_bytes must be >= sizeof(FreeCell)");
        }
        // Note: small_class_cell_max_bytes may exceed large_object_threshold.
        // Allocations below LOT but at/below small_class_cell_max_bytes still
        // route through fixed-size cell classes; cells larger than the
        // requested size simply waste the slack space.

        // ========== 8. Old-gen Sweep & Mark Pacing ==========

        if (sweep_work_budget == 0) {
            throw std::invalid_argument("sweep_work_budget must be > 0");
        }
        if (initial_sweep_budget < sweep_work_budget) {
            throw std::invalid_argument(
                "initial_sweep_budget must be >= sweep_work_budget "
                "(at least one slice per startup pass)");
        }
        if (mark_work_ratio < 1) {
            throw std::invalid_argument("mark_work_ratio must be >= 1");
        }
        if (sweep_bytes_per_alloc_byte <= 0.0) {
            throw std::invalid_argument(
                "sweep_bytes_per_alloc_byte must be > 0.0");
        }
        if (max_sweep_bytes_per_alloc < sweep_work_budget) {
            throw std::invalid_argument(
                "max_sweep_bytes_per_alloc must be >= sweep_work_budget "
                "(soft cap below one slice would degenerate)");
        }
        if (max_sweep_bytes_hard < max_sweep_bytes_per_alloc) {
            throw std::invalid_argument(
                "max_sweep_bytes_hard must be >= max_sweep_bytes_per_alloc "
                "(hard cap is applied AFTER pressure scaling)");
        }
        if (panic_sweep_slice_bytes < sweep_work_budget) {
            throw std::invalid_argument(
                "panic_sweep_slice_bytes must be >= sweep_work_budget");
        }

        // Pressure thresholds: 0 < low < medium < high < 1.
        if (sweep_cap_ratio_low <= 0.0 || sweep_cap_ratio_high >= 1.0) {
            throw std::invalid_argument(
                "sweep_cap_ratio_{low,high} must lie in (0.0, 1.0)");
        }
        if (!(sweep_cap_ratio_low < sweep_cap_ratio_medium &&
              sweep_cap_ratio_medium < sweep_cap_ratio_high)) {
            throw std::invalid_argument(
                "sweep_cap_ratio_low < sweep_cap_ratio_medium < "
                "sweep_cap_ratio_high required");
        }

        // Pressure scales: non-decreasing and >= 1.0.
        if (sweep_scale_low < 1.0) {
            throw std::invalid_argument("sweep_scale_low must be >= 1.0");
        }
        if (!(sweep_scale_low <= sweep_scale_medium &&
              sweep_scale_medium <= sweep_scale_high &&
              sweep_scale_high <= sweep_scale_crit)) {
            throw std::invalid_argument(
                "sweep_scale_{low,medium,high,crit} must be non-decreasing");
        }

        // Unswept boost: ratio in (0, 1), scale >= 1.0.
        if (sweep_unswept_ratio_boost <= 0.0 ||
            sweep_unswept_ratio_boost >= 1.0) {
            throw std::invalid_argument(
                "sweep_unswept_ratio_boost must be in (0.0, 1.0)");
        }
        if (sweep_unswept_scale < 1.0) {
            throw std::invalid_argument(
                "sweep_unswept_scale must be >= 1.0 (scale never shrinks the budget)");
        }
    }
};

} // namespace Elm

#endif // ECO_ALLOCATOR_COMMON_H
