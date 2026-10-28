// The settings every part of the collector reads, and the one function that says how many bytes a heap
// object occupies.
//
// The nursery, the old generation, the per-thread heaps and the process `Allocator` are separate
// components, but they share two things that must agree exactly. This header holds both.
//
// The first is the footprint of an object. A collector walks memory object by object: a sweep steps from
// one header to the next, and a copy needs to know how many bytes to move. As `allocator/Heap` states, an
// object's footprint is a function of its header word alone. `getObjectSizeFromHeader` is that function,
// and every walker strides by it. Because it reads nothing past the header, it can also size an object
// from a copy of its header taken earlier, which is what a parallel minor collection does once the header
// in place has been overwritten by a claim (`allocator/MinorWork` owns that protocol).
//
// The second is the configuration. `HeapConfig` is a plain record with one field per tunable, and the
// constants above it are the defaults those fields start from. The `Allocator` copies a config, resolves
// its automatic choices with `resolveNurseryRegions`, and checks it with `validate`, which throws
// `std::invalid_argument` for a config the collector cannot run.
//
// Some vocabulary the settings use:
//   - The heap is one reserved range of address space, `max_heap_size` bytes. The old generation takes
//     the bottom of it and the nursery region the top; how many bytes the nursery region gets is
//     `nurseryRegionBytes`, and the old generation's cap is the rest.
//   - An allocation buffer, `alloc_buffer_size` bytes, is the unit the nursery grows by (a block) and
//     the size of the pages the old generation takes from the `Allocator`.
//   - The large-object threshold (LOT, `large_object_threshold`) is the size from which an allocation
//     takes the large-object path. A large object that cannot hold pointers is placed in the old
//     generation and pinned. One that can is placed in the nursery if it is small enough, and otherwise
//     in the young large-object space (YLOS), where it stays young but is never copied.
//   - The nursery runs in one of two modes. The semi-space nursery gives each heap a slot: a pair of
//     equal slices, one in the low half of the nursery region and one in the high half, which take
//     turns as from-space and to-space. The region nursery gives each heap a slot of several extents
//     (an eden and survivor extents) in which survivors age in place until a tenure job promotes them.
//
// Most of the file is the constants and the fields of `HeapConfig`, in the same order and grouped the same
// way: heap-wide, strings, nursery, old generation, sweep pacing. Rules cited by id (HEAP_*, GC_DET_*)
// are in design_docs/invariants.csv in the eco repository.

#ifndef ECO_ALLOCATOR_COMMON_H
#define ECO_ALLOCATOR_COMMON_H

#include <atomic>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include "Heap.hpp"

/// Whether extra collector assertions and nursery invariant checks are compiled in: 1 on, 0 off. The
/// CMake option of the same name defines it as 1; it defaults to 0 here.
#ifndef ECO_GC_DEBUG
#define ECO_GC_DEBUG 0
#endif

/// Whether the heap validator is compiled in: 1 on, 0 off, independent of `ECO_GC_DEBUG`. The CMake option
/// of the same name defines it as 1; it defaults to 0 here, because the checks it enables sit on hot paths.
/// Among what it gates in this file are `validateExtKinds` and the default of the eden flip.
#ifndef ECO_HEAP_VALIDATE
#define ECO_HEAP_VALIDATE 0
#endif

namespace Elm {

class Allocator;

/// The mark colour of a heap object, as stored in its header's `color` field.
///
/// The values are written into headers, so they must not be renumbered.
enum class Color : u32 {
    White = 0,   ///< Not marked in the current cycle.
    Grey = 1,    ///< Marked, with children not yet scanned.
    Black = 2    ///< Marked, with children scanned.
};

// ============================================================================
// Default Configuration Constants
// ============================================================================
// Each constant here is the default of the `HeapConfig` field of the matching name, unless its comment says
// otherwise, and they are grouped as `HeapConfig` groups its fields.

// ---- Heap-wide ----

/// The operating system page size, in bytes, fixed at compile time: 16 KiB on Apple arm64, 4 KiB on every
/// other target.
///
/// Old-gen extents are rounded up to a multiple of it, and `HeapConfig::validate` requires an allocation
/// buffer to be at least this size. Nothing in this file checks it against the page size of the running
/// system.
#if defined(__APPLE__) && defined(__aarch64__)
constexpr size_t OS_PAGE_SIZE = 16384;
#else
constexpr size_t OS_PAGE_SIZE = 4096;
#endif

/// The default size of the heap's address-space reservation, in bytes (24 GiB: a 4 GiB nursery region and
/// a 20 GiB old generation under the default split).
constexpr size_t DEFAULT_MAX_HEAP_SIZE = 24ULL * 1024 * 1024 * 1024;

/// The most address space the default split gives the nursery region, both halves together, in bytes.
///
/// When `HeapConfig::nursery_region_bytes` is 0 the region is the smaller of this and half the heap
/// (HEAP_043), so a heap under 8 GiB is split evenly and a larger one gives the rest to the old generation.
/// At the default 96 MiB slice this is 21 semi-space slots per half.
constexpr size_t DEFAULT_NURSERY_REGION_BYTES = 4ULL * 1024 * 1024 * 1024;

/// The default size of an allocation buffer, in bytes: one nursery block and one old-gen page.
constexpr size_t ALLOC_BUFFER_SIZE = 512 * 1024;

/// The default large-object threshold, in bytes. An allocation of this size or more takes the
/// large-object path described in the file comment, and a String or Bytes this large is split into a
/// header object and a separate body.
constexpr size_t LARGE_OBJECT_THRESHOLD = 8 * 1024;

/// The default divisor of the nursery's capacity that bounds which large pointer-bearing objects go to the
/// nursery rather than the YLOS. 0 sends all of them to the YLOS.
constexpr u32 LARGE_PTR_NURSERY_DIVISOR = 8;
/// The default fixed bound, in bytes, on a large pointer-bearing object placed in the nursery, applied as
/// well as the divisor. 0 means no fixed bound.
constexpr size_t LARGE_PTR_NURSERY_MAX_SIZE = 128 * 1024;

// ---- String / rope heuristics ----

/// The default length, in UTF-16 code units, up to which the result of a String concatenation is built as
/// one flat string; a longer result is built as a rope (`Tag_StringRope`).
constexpr size_t STRING_FLATTEN_LIMIT = 128 * 1024;

/// The default length, in UTF-16 code units, up to which a String slice is copied into a flat string
/// instead of being made a `Tag_StringSlice` view.
constexpr size_t STRING_TINY_SLICE_LIMIT = 128;

/// The default length, in bytes, from which decoding a valid all-ASCII String from Bytes makes a
/// zero-copy `Tag_StringUtf8View`; shorter input is copied into a `Tag_StringUtf8Leaf`.
constexpr size_t UTF8_VIEW_MIN_LEN = 32;

/// Whether String operations may create the UTF-8 String forms (views and leaves) by default. When false,
/// they create only the UTF-16 forms.
constexpr bool UTF8_STRINGS_ENABLED = true;

/// The default of a setting that has no effect: no code reads `HeapConfig::rope_max_height`. It is kept
/// so that a configuration naming it is still accepted.
constexpr u32 ROPE_MAX_HEIGHT = 32;

/// The default of a setting that has no effect, as `ROPE_MAX_HEIGHT`.
constexpr u32 ROPE_LEAF_COUNT_LIMIT = 64;

/// The default of a setting that has no effect, as `ROPE_MAX_HEIGHT`.
constexpr u32 ROPE_MIN_LEAF_SIZE = 128;

// ---- Nursery ----

/// The default initial size of a semi-space nursery, in blocks across both semi-spaces.
constexpr size_t NURSERY_BLOCK_COUNT = 256;

/// The default limit on a nursery's growth, in blocks across both semi-spaces. It also sets the size of a
/// semi-space slice and of a region-nursery extent.
constexpr size_t NURSERY_MAX_BLOCKS = 384;

/// The default fraction of the nursery that may fill before a minor collection runs.
constexpr float NURSERY_GC_THRESHOLD = 0.95f;

/// The default fraction of to-space that survivors may fill after a minor collection before the nursery
/// asks to grow.
constexpr float NURSERY_GROWTH_THRESHOLD = 0.20f;

/// The default number of minor collections an object survives before it is promoted to the old
/// generation. The header's age field is 2 bits, so `validate` accepts 1 to 3.
constexpr u32 PROMOTION_AGE = 1;

/// Whether a minor collection copies a list spine depth first by default, so that the cells of a list
/// land next to each other; when false every object is copied breadth first.
constexpr bool USE_HYBRID_DFS = true;

// ---- Old generation ----

/// The default number of bytes the old generation commits at startup.
constexpr size_t INITIAL_OLD_GEN_SIZE = 16 * 1024 * 1024;

/// The default occupancy trigger: the fraction of the old generation's committed bytes that allocation may
/// fill before a major collection is scheduled. It is also the occupancy above which the old generation
/// grows after a major collection, so it must exceed `MAJOR_GC_TARGET_UTILIZATION`.
constexpr float MAJOR_GC_INITIATING_OCCUPANCY = 0.95f;

/// The default global-pressure trigger: the fraction of the old-gen cap that the old generation's bytes in
/// use may reach before a major collection is scheduled. It is a backstop against the heap growing towards
/// the cap; the occupancy and garbage triggers schedule the ordinary collections.
constexpr float MAJOR_GC_GLOBAL_PRESSURE_FRACTION = 0.85f;

/// The default fraction of the old generation's capacity that live data should fill after a major
/// collection. The old generation is resized towards live bytes divided by this.
constexpr float MAJOR_GC_TARGET_UTILIZATION = 0.50f;

/// The default garbage trigger: a major collection is scheduled once the old generation's allocated bytes,
/// less those found live after the last sweep, reach this fraction of its committed bytes. 0 disables it.
constexpr float MAJOR_GC_GARBAGE_FRACTION = 0.70f;

/// The default budget for allocation made directly in the old generation (split large bodies, young large
/// objects, pinned large objects) between minor collections, as a multiple of the nursery's minor-collection
/// threshold. Once it is reached, the next allocation runs a minor collection. The budget is also capped at
/// 1/32 of the old-gen cap. 0 disables it.
constexpr double DIRECT_ALLOC_MINOR_BUDGET = 1.0;

/// The default number of empty large-object-space blocks kept for reuse after a major collection. Empty
/// blocks beyond this many may be released, down to the old generation's minimum size.
constexpr size_t LOS_EMPTY_KEEP = 2;

/// Whether releasing an old-gen block also discards its physical pages by default. The address range stays
/// reserved either way.
constexpr bool DECOMMIT_ON_OLDGEN_RELEASE = true;

/// The default GC helper-thread mode (HEAP_058 to HEAP_060, GC_DET_001). 0 runs page work inline with no
/// helper pool; 1 posts it as helper jobs but runs each inline where it is posted, which is the reference
/// behaviour; 2 runs the jobs on the `GCHelperPool`. `ECO_GC_THREAD` overrides it.
constexpr uint32_t GC_THREAD_MODE = 2;
/// The default number of GC helper threads.
constexpr uint32_t GC_HELPER_THREADS = 1;
/// The default CPU the helper threads are pinned to; -1 means no pinning.
constexpr int32_t  GC_HELPER_CPU = -1;
/// The default number of page-work sync points a released old-gen extent stays unused before its pages are
/// discarded.
/// `UINT32_MAX` turns this clock off; `DECOMMIT_DELAY_MAJORS` then bounds how long pages are kept.
constexpr uint32_t DECOMMIT_DELAY_SYNCS = UINT32_MAX;
/// The default limit, in bytes, on released extents waiting to be discarded; 0 means no limit.
constexpr size_t   DECOMMIT_PENDING_MAX_BYTES = 0;
/// The default number of major collections a released old-gen extent stays unused before its pages are
/// discarded; 0 turns this clock off.
constexpr uint32_t DECOMMIT_DELAY_MAJORS = 1;
/// The default number of bytes above the old generation's bump that are committed and populated ahead of
/// use at each page-work sync point; 0 turns it off.
constexpr size_t   COMMIT_AHEAD_BYTES = size_t{128} << 20;

/// Whether the old generation allocates by default from the mark bitmap (HEAP_054): blocks of one size
/// class hand out cells through a per-class cursor over the bitmap, and mixed blocks are swept for gaps.
/// When false the old generation uses the header-walking lazy sweep.
constexpr bool OLD_GEN_BITMAP_ALLOC = true;

/// The default number of threads marking the old generation inside a pause (HEAP_064). 0 means automatic:
/// the smaller of `GC_MARK_THREADS_CAP` and the available CPUs. 1 is the serial reference.
constexpr uint32_t GC_MARK_THREADS = 0;
/// The default limit on the automatic number of in-pause markers.
constexpr uint32_t GC_MARK_THREADS_CAP = 16;
/// The number of slots from which a boxed array or list backing is marked in chunks of this many slots,
/// except in a serial snapshot at the start of a mark cycle. It is not a `HeapConfig` field.
constexpr uint32_t MARK_CHUNK_ELEMS = 1024;

/// The default number of threads copying survivors in a minor collection (HEAP_067, HEAP_068). 0 means
/// automatic: the smaller of `GC_MINOR_THREADS_CAP` and the available CPUs. 1 is the serial Cheney copy.
/// `ECO_GC_MINOR_THREADS` overrides it.
constexpr uint32_t GC_MINOR_THREADS = 0;
/// The default limit on the automatic number of minor-collection workers.
constexpr uint32_t GC_MINOR_THREADS_CAP = 8;
/// The default size, in bytes, of a minor-collection worker's local allocation buffer (LAB): the private
/// run of to-space a worker copies survivors into.
constexpr size_t   MINOR_LAB_BYTES = 8 * 1024;
/// The default number of from-space object bytes below which a minor collection runs on one worker.
constexpr size_t   MINOR_PARALLEL_MIN_BYTES = 4ULL * 1024 * 1024;
/// Whether minor-collection workers prefetch the children of the object they copy, by default.
constexpr bool     MINOR_PREFETCH_CHILDREN = true;
/// The default order in which a parallel minor collection processes copied objects: true is first in,
/// first out (breadth first), false is last in, first out (depth first). The order decides which objects
/// end up next to each other.
constexpr bool     MINOR_FIFO_ORDER = false;
/// The number of slots in one chunk when a parallel minor collection splits a large array. It is not a
/// `HeapConfig` field.
constexpr uint32_t MINOR_CHUNK_ELEMS = 1024;
/// The number of list cells a parallel minor collection copies in one run along a spine. It is not a
/// `HeapConfig` field.
constexpr uint32_t MINOR_SPINE_RUN = 512;

/// The default nursery mode (HEAP_069, HEAP_070). 0 is the semi-space nursery. 1 is the region nursery,
/// and a config that cannot run it fails `validate`. 2 is automatic: `resolveNurseryRegions` turns it into
/// 1, and throws for a config that cannot run the region nursery; it never chooses 0.
/// `ECO_NURSERY_REGIONS` overrides it.
constexpr uint32_t NURSERY_REGIONS = 2;
/// The default eden flip setting: 1 gives each region-nursery heap two edens instead of one, 0 one, and
/// -1 two only when `ECO_HEAP_VALIDATE` is on. `ECO_NURSERY_EDEN_FLIP` overrides it.
constexpr int32_t  NURSERY_REGION_EDEN_FLIP = -1;
/// The default tenure mode. 1 runs the tenure job inside the pause that hands it over; 2 runs it on the
/// heap's tenure collector thread while the mutator runs. `ECO_TENURE_MODE` overrides it.
constexpr uint32_t TENURE_MODE = 2;
/// The default number of threads for a tenure job run inside a pause: 1 is the exact engine, 0 uses the
/// minor collection's worker count.
constexpr uint32_t TENURE_SYNC_THREADS = 1;
/// What the default does about a tenure job still running when its results are needed: 0 waits for it,
/// 1 stops it and finishes it in the pause.
constexpr uint32_t TENURE_HELP = 1;
/// The default number of threads that finish a late tenure job: 0 uses the minor collection's worker count.
constexpr uint32_t TENURE_HELP_THREADS = 0;
/// The default scheduling priority of a tenure collector thread: 0 inherits the creator's.
constexpr int32_t  TENURE_PRIORITY = 0;
/// The default number of slots to heal above which a tenure job may heal them on several threads.
constexpr size_t   HEAL_PARALLEL_MIN = 65536;
/// The default log2 of the bytes one shadow-table word covers in the region nursery: 4 is 16 bytes, 3 is
/// 8 bytes. A 16-byte granule requires every surviving object to be at least 16 bytes. Every layout is at
/// least 16 bytes except a String, Bytes or UTF-8 leaf of length 0, and none of those is allocated: the
/// empty ones are the Empty constant.
constexpr uint32_t SHADOW_GRANULE_LOG2 = 4;
/// The default number of tenure collector threads per heap in tenure mode 2. 1 is the exact engine; more
/// than 1 runs the concurrent parallel engine.
constexpr uint32_t TENURE_COLLECTOR_THREADS = 1;
/// The default order in which the exact tenure engine promotes: true is breadth first, false depth first.
constexpr bool     TENURE_FIFO_ORDER = false;

/// The default concurrent-marking mode (HEAP_065). 0 marks in slices inside pauses; 1 runs the whole mark in
/// the pause that starts the cycle, which is the reference behaviour; 2 runs background markers between
/// pauses, and the mutator helps when they fall behind. `ECO_GC_CONC_MARK` overrides it.
constexpr uint32_t CONC_MARK = 2;
/// The default number of background markers. 0 means automatic: the smaller of `CONC_MARK_THREADS_CAP` and
/// one less than the available CPUs. `ECO_GC_CONC_MARK_THREADS` overrides it.
constexpr uint32_t CONC_MARK_THREADS = 0;
/// The default limit on the automatic number of background markers.
constexpr uint32_t CONC_MARK_THREADS_CAP = 4;
/// The default scheduling priority of a background marker: 0 inherits, and on Linux 1 to 19 is a nice
/// value and 20 is `SCHED_IDLE`.
constexpr int32_t  CONC_MARK_PRIORITY = 0;
/// The default number of mark-cycle steps background markers may fall behind before the mutator helps.
constexpr uint32_t CONC_MARK_ASSIST_LAG = 8;

/// The default margin of the headroom trigger. A mark cycle starts once committed bytes, plus this multiple
/// of the allocation predicted for the cycle, would reach the finish fraction of the cap. 0 disables it.
constexpr double MAJOR_GC_HEADROOM_MARGIN = 1.5;
/// Whether the live-budget trigger is paced by default, so that the budget is reached when the cycle ends
/// rather than when it starts.
constexpr bool   MAJOR_GC_LIVE_BUDGET_PACED = true;
/// The default garbage backstop. When it is above 0 and the live-budget trigger is on, the garbage trigger
/// uses the larger of this and `MAJOR_GC_GARBAGE_FRACTION`.
constexpr float  MAJOR_GC_GARBAGE_BACKSTOP = 0.0f;

/// Whether a major collection's mark is spread over the minor collections that follow its start, by
/// default (HEAP_063). It requires bitmap allocation.
constexpr bool     INCREMENTAL_MARK = true;
/// The default number of minor collections an incremental mark is spread over; 0 marks the whole cycle in
/// the pause that starts it.
constexpr uint32_t INCREMENTAL_MARK_SLICES = 32;
/// The default least amount of mark work, in the mark loop's work units, that one incremental slice does.
constexpr size_t   INCREMENTAL_MARK_MIN_SLICE_UNITS = 16384;
/// The default least factor by which the previous mark cycle's work is scaled to predict the work of the
/// next one; the occupancy growth since the previous cycle is used instead when it is larger.
constexpr double   INCREMENTAL_MARK_PREDICT_GROWTH = 1.25;
/// The default fraction of the old-gen cap that the old generation's bytes in use may reach before a
/// running mark cycle is due to finish early. The headroom trigger aims to start a cycle so that it ends
/// below this line. It must exceed the global-pressure fraction.
constexpr double   INCREMENTAL_MARK_FINISH_FRACTION = 0.95;

/// The default fraction of a single-size-class block that may be live at the end of a mark for the block to
/// be turned into a mixed block. 0 turns this off.
constexpr double DEMOTE_LIVE_FRACTION = 0.3;

/// The default cap on the garbage trigger's denominator under bitmap allocation, as a multiple of the bytes
/// committed at the last major collection; 0 means no cap, so the denominator is the bytes committed now.
constexpr double GARBAGE_DENOM_CAP = 0.0;

/// The default live-budget factor. A major collection is scheduled once the old generation's allocated
/// bytes, less those found live after the last sweep, reach this multiple of the live bytes found by the
/// last mark. 0 disables the trigger.
constexpr double MAJOR_GC_LIVE_BUDGET = 3.0;
/// The default limit on how much the live figure used by the live-budget trigger may grow from one mark to
/// the next, as a multiple of the previous one; 0 means no limit.
constexpr double LIVE_GROWTH_BOUND = 1.5;

/// The default limit, in bytes, on memory committed to pages of small size classes before the old
/// generation prefers splitting larger free cells.
constexpr size_t DEFAULT_SMALL_CLASS_HEAP_BUDGET = 1024ULL * 1024 * 1024;

// ---- Old-gen sweep pacing ----

/// The default number of bytes of lazy sweep the old generation does in one slice of its allocation slow
/// path.
constexpr size_t SWEEP_WORK_BUDGET = 4096;

/// The default number of bytes swept before a mark-and-sweep returns, which seeds the free lists for the
/// allocations that follow.
constexpr size_t INITIAL_SWEEP_BUDGET = SWEEP_WORK_BUDGET * 16;

/// The default number of bytes swept per byte requested, before the pressure scale is applied.
constexpr double SWEEP_BYTES_PER_ALLOC_BYTE = 2.0;

/// The default upper bound, in bytes, on one allocation's sweep budget before the pressure scale.
constexpr size_t MAX_SWEEP_BYTES_PER_ALLOC = 1u << 20;

/// The default upper bound, in bytes, on one allocation's sweep budget after every scale is applied.
constexpr size_t MAX_SWEEP_BYTES_HARD = 4u << 20;

/// The defaults of the old generation's committed-to-cap ratios at which the sweep budget moves to the
/// next pressure step: below low, the low scale applies; below medium, the medium; below high, the high;
/// otherwise the critical scale.
constexpr double SWEEP_CAP_RATIO_LOW    = 0.50;
constexpr double SWEEP_CAP_RATIO_MEDIUM = 0.75;
constexpr double SWEEP_CAP_RATIO_HIGH   = 0.90;

/// The defaults of the factors the sweep budget is multiplied by at each pressure step.
constexpr double SWEEP_SCALE_LOW    = 1.0;
constexpr double SWEEP_SCALE_MEDIUM = 2.0;
constexpr double SWEEP_SCALE_HIGH   = 4.0;
constexpr double SWEEP_SCALE_CRIT   = 8.0;

/// The default fraction of blocks still unswept above which the sweep budget is multiplied by
/// `SWEEP_UNSWEPT_SCALE` as well.
constexpr double SWEEP_UNSWEPT_RATIO_BOOST = 0.50;

/// The default factor applied to the sweep budget when the unswept fraction is above its threshold.
constexpr double SWEEP_UNSWEPT_SCALE = 2.0;

/// The default number of bytes swept per slice when the old generation sweeps to completion before
/// declaring itself out of memory.
constexpr size_t PANIC_SWEEP_SLICE_BYTES = 1u << 20;

// ---- Old-gen free-list layout (compile-time, not runtime-configurable) ----
// These sizes are array dimensions, such as the old generation's free lists per size class and the
// matching statistics buckets, so they are not `HeapConfig` fields.

/// The number of small size classes, which go in 8-byte steps from 8 bytes up to `MAX_SMALL_SIZE`.
constexpr size_t NUM_SMALL_CLASSES = 32;

/// The cell size of the largest small size class, in bytes.
constexpr size_t MAX_SMALL_SIZE = 256;

/// The cell size of the first medium size class, in bytes; each medium class after it doubles.
constexpr size_t MEDIUM_CLASS_BASE = 512;

/// The most medium size classes there can be. How many are in use depends on `large_object_threshold`.
constexpr size_t NUM_MEDIUM_CLASSES_MAX = 8;

/// The most size classes there can be, small and medium together.
constexpr size_t NUM_SIZE_CLASSES = NUM_SMALL_CLASSES + NUM_MEDIUM_CLASSES_MAX;

/// Returns the header of the heap object at `obj`. `obj` must be the start of a heap object.
inline Header *getHeader(void *obj) { return static_cast<Header *>(obj); }

/// Returns whether an object with tag `tag` may hold heap pointers, which decides where a large one is
/// placed (HEAP_062).
///
/// Only Int, Float, Char, String and ByteBuffer are pointer-free by their tag. Every other tag counts as
/// pointer-bearing, including an array whose values happen to be unboxed, because the tag cannot tell.
inline bool tagMayHoldPointers(uint32_t tag) {
    return tag != Tag_Int && tag != Tag_Float && tag != Tag_Char &&
           tag != Tag_String && tag != Tag_ByteBuffer;
}

/// Returns the number of bytes, rounded up to a multiple of 8, occupied by an object whose header word is
/// `*hdr`.
///
/// It reads only the tag, the size and, for a Custom or Record, the count of extension kind words in
/// `unboxed`, all of which are in the header word. So `hdr` may point to a copy of the header rather than
/// to the object. The unit of `size` depends on the tag, as `allocator/Heap` defines: elements for the
/// variable-length objects, the cell's byte size for `Tag_Free`, and a logical length, which does not
/// affect the footprint, for slices, views, ropes and the header objects of split Strings and Bytes. A
/// `Tag_Forward` word is 8 bytes. An unknown tag also gives 8.
inline size_t getObjectSizeFromHeader(const Header *hdr) {

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
            size = sizeof(ElmStringSlice);
            break;
        case Tag_StringRope:
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
            // header.size is the capacity, so the slack after the live elements is counted.
            size = sizeof(ListBacking) + hdr->size * sizeof(Unboxable);
            break;
        case Tag_Custom:
            // HEAP_019/HEAP_077: the K = hdr->unboxed extension kind words follow values[size].
            size = sizeof(Custom) + (size_t(hdr->size) + hdr->unboxed) * sizeof(Unboxable);
            break;
        case Tag_Record:
            size = sizeof(Record) + (size_t(hdr->size) + hdr->unboxed) * sizeof(Unboxable);
            break;
        case Tag_DynRecord:
            size = sizeof(DynRecord) + hdr->size * sizeof(HPointer);
            break;
        case Tag_FieldGroup:
            size = sizeof(FieldGroup) + hdr->size * sizeof(u32);
            break;
        case Tag_Closure:
            // Unlike Custom and Record, a Closure's header.size already counts its extension kind words.
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
            // A free cell's header.size is its byte size, already a multiple of 8.
            size = hdr->size;
            break;
        case Tag_ByteBuffer:
            size = sizeof(ByteBuffer) + hdr->size * sizeof(u8);
            break;
        case Tag_Array: {
            // header.size is the capacity, not the length: a sweep must step over the whole
            // allocation to reach the next header.
            size = sizeof(ElmArray) + hdr->size * sizeof(Unboxable);
            break;
        }
        case Tag_LargeStringHeader:
            size = sizeof(LargeStringHeader);
            break;
        case Tag_LargeByteHeader:
            size = sizeof(LargeByteHeader);
            break;
        case Tag_ByteBufferSlice:
            size = sizeof(ElmByteBufferSlice);
            break;
        case Tag_StringUtf8View:
            size = sizeof(ElmStringUtf8View);
            break;
        case Tag_StringUtf8Leaf:
            size = sizeof(ElmStringUtf8Leaf) + hdr->size * sizeof(u8);
            break;
        default:
            size = sizeof(Header);
            break;
    }

    return (size + 7) & ~7;
}

/// Returns the number of bytes occupied by the heap object at `obj`, as `getObjectSizeFromHeader` computes
/// it from the object's header in place. This is a plain read, not the atomic one `loadHeaderRelaxed` makes.
inline size_t getObjectSize(void *obj) {
    return getObjectSizeFromHeader(getHeader(obj));
}

#if ECO_HEAP_VALIDATE
/// Checks the extension kind words of the Custom or Record at `obj` (HEAP_019, HEAP_077), and does nothing
/// for an object with any other tag.
///
/// `header.unboxed` must equal the number of extension words the object's size calls for, and the bits
/// past the last field's kind in the last word must be 0. On a failure it prints a line naming `where` and
/// the object to stderr and aborts. It exists only when `ECO_HEAP_VALIDATE` is on.
inline void validateExtKinds(const void* obj, const char* where) {
    const Header* h = static_cast<const Header*>(obj);
    if (h->tag != Tag_Custom && h->tag != Tag_Record) return;
    const bool isC = h->tag == Tag_Custom;
    const u32 cap = isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS;
    const u32 k = extWords(h->size, cap);
    const u64* ext = isC ? customExtWords(static_cast<const Custom*>(obj))
                         : recordExtWords(static_cast<const Record*>(obj));
    bool bad = h->unboxed != k;
    if (!bad && k) {
        const u32 used = (h->size - cap) - (k - 1) * SLOTS_PER_EXT_WORD;   // slots in the last word, 1..32
        if (used < SLOTS_PER_EXT_WORD && (ext[k - 1] >> (2 * used)) != 0) bad = true;
    }
    if (bad) {
        std::fprintf(stderr,
                     "[heap-validate] %s: %s %p size=%u unboxed(K)=%u expected K=%u\n",
                     where, isC ? "Custom" : "Record", obj, h->size, unsigned(h->unboxed), k);
        std::abort();
    }
}
#endif

/// How `Allocator::acquireOldGenBlock` may treat a released extent whose discard has been posted to a helper
/// thread (HEAP_058, HEAP_059).
///
/// `Allowed` reuses the first released extent that fits, and may wait for its discard to finish.
/// `AvoidUnderPromo` is for a caller that holds the promotion lock of a parallel promotion with more than
/// one worker, and so must not wait. When page work is posting discards, it takes a fitting extent whose
/// discard can still be cancelled, else fresh address space, and only when the old-gen cap leaves no fresh
/// space does it reuse an extent whose discard may have to be waited for.
enum class AcquireWait : uint8_t { Allowed, AvoidUnderPromo };

/// Returns the header word of the object at `obj`, read as one relaxed atomic access.
///
/// A header can be read and written by two threads at once: a young large object's header is aged or
/// promoted by one thread while a sweep on another steps over it. The bit-fields of a header are one memory
/// location, so both sides use whole-word relaxed atomics, `loadHeaderRelaxed` and `storeHeaderRelaxed`. No
/// ordering is needed because the ageing or promoting writer never changes the tag, the size or the pin bit,
/// which are all a sweep reads. The copy paths read headers plainly, through `getObjectSize`.
inline Header loadHeaderRelaxed(const void* obj) {
    auto* w = static_cast<uint64_t*>(const_cast<void*>(obj));   // atomic_ref<const T> is not C++20
    return std::bit_cast<Header>(std::atomic_ref<uint64_t>(*w).load(std::memory_order_relaxed));
}
/// Writes `h` as the header word of the object at `obj`, as one relaxed atomic store. `loadHeaderRelaxed`
/// says when the ageing or promoting writer needs this and what it does not order.
inline void storeHeaderRelaxed(void* obj, Header h) {
    std::atomic_ref<uint64_t>(*static_cast<uint64_t*>(obj))
        .store(std::bit_cast<uint64_t>(h), std::memory_order_relaxed);
}

// ============================================================================
// Nursery slice estate (HEAP_042)
// ============================================================================

/// The address space one heap's semi-space nursery occupies: a slice of the low half of the nursery region
/// and the slice at the same slot in the high half.
///
/// The `Allocator` hands it out and grows it. `capacity` is the usable length of each slice, the same for
/// both because they grow together, and 0 after a failed acquire. The `Allocator` may have committed more
/// of a slot than `capacity`, keeping pages from an earlier heap in that slot for reuse; those pages are
/// not part of the nursery. The pointers are addresses inside the heap reservation, which outlives any heap.
struct NurserySlicePair {
    char*  low_base  = nullptr;
    char*  high_base = nullptr;
    size_t capacity  = 0;         ///< Usable bytes of each slice.
    size_t slot      = 0;
};

/// The address space one heap's region nursery occupies: `n` extents of the same `capacity`, in one slot of
/// the nursery region, each starting `1 << stride_log2` bytes after the one before.
///
/// The `Allocator` hands it out and grows it, all `n` extents together or none. `capacity` is 0 after a
/// failed acquire. The pointer is an address inside the heap reservation, which outlives any heap.
struct NurserySliceSet {
    char*    slot_base   = nullptr;
    size_t   stride_log2 = 0;
    unsigned n           = 0;
    size_t   capacity    = 0;    ///< Usable bytes of each extent.
    size_t   slot        = 0;
    /// Returns the start of extent `k`, which must be less than `n`.
    char* extent(unsigned k) const { return slot_base + (static_cast<size_t>(k) << stride_log2); }
};

// ============================================================================
// Heap Configuration
// ============================================================================

/// The settings of the heap and the collector.
///
/// A default-constructed config holds the defaults defined above. Any field may be changed before the
/// config is given to the `Allocator`, which copies it. Fields are public and are checked only when
/// `validate` is called; the `Allocator` calls `resolveNurseryRegions` and then `validate` on every config
/// it adopts. Where a field's meaning is given by the constant it defaults to, that constant's comment is
/// the description.
struct HeapConfig {
    // ---- Heap-wide ----

    /// The size of the heap's address-space reservation, in bytes.
    size_t max_heap_size = DEFAULT_MAX_HEAP_SIZE;

    /// The bytes of the reservation given to the nursery region, both halves together (HEAP_043). The old
    /// generation gets the rest. 0 chooses the default split, as `nurseryRegionBytes` says.
    size_t nursery_region_bytes = 0;

    size_t alloc_buffer_size = ALLOC_BUFFER_SIZE;

    size_t large_object_threshold = LARGE_OBJECT_THRESHOLD;

    /// A large pointer-bearing object goes to the nursery when its size is at most the nursery's capacity
    /// divided by `large_ptr_nursery_divisor` and at most `large_ptr_nursery_max_size`, and to the YLOS
    /// otherwise. A divisor of 0 sends every one to the YLOS; a max size of 0 means no fixed bound.
    u32 large_ptr_nursery_divisor = LARGE_PTR_NURSERY_DIVISOR;
    size_t large_ptr_nursery_max_size = LARGE_PTR_NURSERY_MAX_SIZE;

    // ---- String / rope heuristics ----

    size_t string_flatten_limit = STRING_FLATTEN_LIMIT;

    size_t string_tiny_slice_limit = STRING_TINY_SLICE_LIMIT;

    size_t utf8_view_min_len = UTF8_VIEW_MIN_LEN;

    bool utf8_strings_enabled = UTF8_STRINGS_ENABLED;

    /// Has no effect: nothing reads it.
    u32 rope_max_height = ROPE_MAX_HEIGHT;

    /// Has no effect: nothing reads it.
    u32 rope_leaf_count_limit = ROPE_LEAF_COUNT_LIMIT;

    /// Has no effect: nothing reads it.
    u32 rope_min_leaf_size = ROPE_MIN_LEAF_SIZE;

    // ---- Nursery ----

    size_t nursery_block_count = NURSERY_BLOCK_COUNT;

    size_t nursery_max_block_count = NURSERY_MAX_BLOCKS;

    float nursery_gc_threshold = NURSERY_GC_THRESHOLD;

    float nursery_growth_threshold = NURSERY_GROWTH_THRESHOLD;

    /// The promotion age, and in the region nursery the tenure age as well.
    u32 promotion_age = PROMOTION_AGE;

    bool use_hybrid_dfs = USE_HYBRID_DFS;

    // ---- Old generation ----

    size_t initial_old_gen_size = INITIAL_OLD_GEN_SIZE;

    float major_gc_initiating_occupancy = MAJOR_GC_INITIATING_OCCUPANCY;

    float major_gc_global_pressure_fraction = MAJOR_GC_GLOBAL_PRESSURE_FRACTION;

    float major_gc_target_utilization = MAJOR_GC_TARGET_UTILIZATION;

    float major_gc_garbage_fraction = MAJOR_GC_GARBAGE_FRACTION;

    double direct_alloc_minor_budget = DIRECT_ALLOC_MINOR_BUDGET;

    size_t los_empty_keep = LOS_EMPTY_KEEP;

    bool decommit_on_oldgen_release = DECOMMIT_ON_OLDGEN_RELEASE;

    // GC helper threads and the page work they do (HEAP_059, HEAP_060).
    uint32_t gc_thread_mode = GC_THREAD_MODE;
    uint32_t gc_helper_threads = GC_HELPER_THREADS;
    int32_t  gc_helper_cpu = GC_HELPER_CPU;
    uint32_t decommit_delay_syncs = DECOMMIT_DELAY_SYNCS;
    size_t   decommit_pending_max_bytes = DECOMMIT_PENDING_MAX_BYTES;
    uint32_t decommit_delay_majors = DECOMMIT_DELAY_MAJORS;
    size_t   commit_ahead_bytes = COMMIT_AHEAD_BYTES;

    bool old_gen_bitmap_alloc = OLD_GEN_BITMAP_ALLOC;

    // Parallel marking inside a pause.
    uint32_t gc_mark_threads = GC_MARK_THREADS;
    uint32_t gc_mark_threads_cap = GC_MARK_THREADS_CAP;

    // Parallel minor collection.
    uint32_t gc_minor_threads = GC_MINOR_THREADS;
    uint32_t gc_minor_threads_cap = GC_MINOR_THREADS_CAP;
    size_t   minor_lab_bytes = MINOR_LAB_BYTES;
    size_t   minor_parallel_min_bytes = MINOR_PARALLEL_MIN_BYTES;
    bool     minor_prefetch_children = MINOR_PREFETCH_CHILDREN;
    bool     minor_fifo_order = MINOR_FIFO_ORDER;

    // The region nursery and its tenure jobs.
    uint32_t nursery_regions = NURSERY_REGIONS;
    int32_t  nursery_region_eden_flip = NURSERY_REGION_EDEN_FLIP;
    uint32_t tenure_mode = TENURE_MODE;
    uint32_t tenure_sync_threads = TENURE_SYNC_THREADS;
    uint32_t tenure_help = TENURE_HELP;
    uint32_t tenure_help_threads = TENURE_HELP_THREADS;
    int32_t  tenure_priority = TENURE_PRIORITY;
    size_t   heal_parallel_min = HEAL_PARALLEL_MIN;
    uint32_t shadow_granule_log2 = SHADOW_GRANULE_LOG2;
    uint32_t tenure_collector_threads = TENURE_COLLECTOR_THREADS;
    bool     tenure_fifo_order = TENURE_FIFO_ORDER;

    // Concurrent marking.
    uint32_t conc_mark = CONC_MARK;
    uint32_t conc_mark_threads = CONC_MARK_THREADS;
    uint32_t conc_mark_threads_cap = CONC_MARK_THREADS_CAP;
    int32_t  conc_mark_priority = CONC_MARK_PRIORITY;
    uint32_t conc_mark_assist_lag = CONC_MARK_ASSIST_LAG;
    // Pacing of the mark-cycle triggers.
    double major_gc_headroom_margin = MAJOR_GC_HEADROOM_MARGIN;
    bool   major_gc_live_budget_paced = MAJOR_GC_LIVE_BUDGET_PACED;
    float  major_gc_garbage_backstop = MAJOR_GC_GARBAGE_BACKSTOP;

    // Incremental marking.
    bool     incremental_mark = INCREMENTAL_MARK;
    uint32_t incremental_mark_slices = INCREMENTAL_MARK_SLICES;
    size_t   incremental_mark_min_slice_units = INCREMENTAL_MARK_MIN_SLICE_UNITS;
    double   incremental_mark_predict_growth = INCREMENTAL_MARK_PREDICT_GROWTH;
    double   incremental_mark_finish_fraction = INCREMENTAL_MARK_FINISH_FRACTION;

    /// In [0, 1]. 0 demotes no block; 1 demotes every single-size-class block.
    double demote_live_fraction = DEMOTE_LIVE_FRACTION;

    double garbage_denom_cap = GARBAGE_DENOM_CAP;

    // The live-budget trigger.
    double major_gc_live_budget = MAJOR_GC_LIVE_BUDGET;
    double live_growth_bound = LIVE_GROWTH_BOUND;

    /// 0 removes the limit.
    size_t small_class_heap_budget_bytes = DEFAULT_SMALL_CLASS_HEAP_BUDGET;

    /// The largest cell size, in bytes, counted against `small_class_heap_budget_bytes`. It defaults to the
    /// default large-object threshold, not to the field `large_object_threshold`.
    size_t small_class_cell_max_bytes = LARGE_OBJECT_THRESHOLD;

    // ---- Old-gen sweep pacing ----

    size_t sweep_work_budget = SWEEP_WORK_BUDGET;

    /// The divisor applied to the sweep work an allocation does when the allocation is a promotion inside a
    /// minor collection, so that sweeping adds less to the pause. 1 leaves the work unchanged and 0 skips
    /// it. It has no default constant.
    size_t minor_sweep_divisor = 1;

    size_t initial_sweep_budget = INITIAL_SWEEP_BUDGET;

    double sweep_bytes_per_alloc_byte = SWEEP_BYTES_PER_ALLOC_BYTE;

    size_t max_sweep_bytes_per_alloc = MAX_SWEEP_BYTES_PER_ALLOC;

    size_t max_sweep_bytes_hard = MAX_SWEEP_BYTES_HARD;

    // The pressure steps of the sweep budget.
    double sweep_cap_ratio_low    = SWEEP_CAP_RATIO_LOW;
    double sweep_cap_ratio_medium = SWEEP_CAP_RATIO_MEDIUM;
    double sweep_cap_ratio_high   = SWEEP_CAP_RATIO_HIGH;

    double sweep_scale_low    = SWEEP_SCALE_LOW;
    double sweep_scale_medium = SWEEP_SCALE_MEDIUM;
    double sweep_scale_high   = SWEEP_SCALE_HIGH;
    double sweep_scale_crit   = SWEEP_SCALE_CRIT;

    double sweep_unswept_ratio_boost = SWEEP_UNSWEPT_RATIO_BOOST;

    double sweep_unswept_scale = SWEEP_UNSWEPT_SCALE;

    size_t panic_sweep_slice_bytes = PANIC_SWEEP_SLICE_BYTES;

    /// Returns the initial size of a semi-space nursery in bytes, both semi-spaces together.
    size_t nurserySize() const { return nursery_block_count * alloc_buffer_size; }

    // ---- Nursery slice geometry (HEAP_042) ----
    //
    // In the semi-space nursery, each half of the nursery region is cut into fixed-size slices, and each
    // heap gets the slice at the same slot in both halves, so each semi-space is one contiguous extent. The
    // `Allocator` builds its slot table from these functions and `validate` checks against them.

    /// Returns the bytes of the reservation given to the nursery region, both halves together:
    /// `nursery_region_bytes` if it is not 0, and otherwise the smaller of `DEFAULT_NURSERY_REGION_BYTES`
    /// and half of `max_heap_size`.
    size_t nurseryRegionBytes() const {
        if (nursery_region_bytes != 0) return nursery_region_bytes;
        const size_t half = max_heap_size / 2;
        return DEFAULT_NURSERY_REGION_BYTES < half ? DEFAULT_NURSERY_REGION_BYTES
                                                   : half;
    }

    /// Returns the old-gen cap this config gives: the reservation less the nursery region.
    size_t oldGenCapBytes() const { return max_heap_size - nurseryRegionBytes(); }

    /// Returns the size of one half of the nursery region.
    size_t nurseryRegionPerSideBytes() const { return nurseryRegionBytes() / 2; }

    /// Returns the size of one semi-space slice: half of the nursery's growth limit, but no more than one half
    /// of the nursery region, rounded down to a multiple of `alloc_buffer_size`. It may be 0.
    size_t nurserySliceBytes() const {
        const size_t want = (nursery_max_block_count / 2) * alloc_buffer_size;
        size_t s = want < nurseryRegionPerSideBytes()
                       ? want : nurseryRegionPerSideBytes();
        if (alloc_buffer_size != 0) s -= s % alloc_buffer_size;
        return s;
    }

    /// Returns the initial size of one semi-space, half of `nurserySize`.
    size_t nurseryInitialPerSideBytes() const {
        return (nursery_block_count / 2) * alloc_buffer_size;
    }

    // ---- Region nursery geometry (HEAP_069) ----
    //
    // In the region nursery each heap gets one slot of `regionExtents` extents, each starting
    // `regionStrideBytes` after the one before.

    /// Returns whether each region-nursery heap has two edens: `nursery_region_eden_flip` if it is 0 or 1,
    /// and otherwise whether `ECO_HEAP_VALIDATE` is on.
    bool regionEdenFlip() const {
        if (nursery_region_eden_flip >= 0) return nursery_region_eden_flip != 0;
        return ECO_HEAP_VALIDATE != 0;
    }
    /// Returns the tenure age k: `promotion_age`, or 1 if it is 0. An object still live at the k-th minor
    /// collection after its first copy is tenured; until then it ages in place in a survivor extent.
    unsigned regionTenureAge() const { return promotion_age < 1 ? 1u : promotion_age; }
    /// Returns the number of survivor extents per heap, k + 2: the one being filled, k - 1 that hold ageing
    /// objects, the one being handed to the tenure job, and the one being retired.
    unsigned regionSurvivorExtents() const { return regionTenureAge() + 2; }
    /// Returns the number of extents per heap: the survivor extents plus one eden, or two with the eden flip.
    unsigned regionExtents() const { return regionSurvivorExtents() + (regionEdenFlip() ? 2u : 1u); }
    /// Returns the distance between extents: the smallest power of two, at least `OS_PAGE_SIZE`, that is no
    /// less than half the nursery's growth limit in bytes. Being a power of two lets the extent of an address
    /// be found with one shift.
    size_t regionStrideBytes() const {
        const size_t want = (nursery_max_block_count / 2) * alloc_buffer_size;
        size_t x = OS_PAGE_SIZE;
        while (x < want) x <<= 1;
        return x;
    }
    /// Returns how many region-nursery heaps fit in the nursery region; 0 means none does.
    size_t regionSlots() const {
        const size_t per = regionExtents() * regionStrideBytes();
        return per == 0 ? 0 : nurseryRegionBytes() / per;
    }
    /// Returns the smallest `max_heap_size` whose default nursery region holds `slots` region-nursery heaps of
    /// this config's geometry, assuming the region is half the heap.
    ///
    /// The result is right only when `nursery_region_bytes` is 0 and the result is below twice
    /// `DEFAULT_NURSERY_REGION_BYTES`, because above that the default region stops being half the heap. The
    /// stride grows with `nursery_max_block_count`, so a small result needs a small one.
    size_t minRegionHeapBytes(size_t slots = 1) const {
        return 2 * slots * regionExtents() * regionStrideBytes();
    }
    /// Returns `regionIncompatibility` as a message, or an empty string when the region nursery can run.
    /// When the reason is that no heap fits the region and `nursery_region_bytes` is 0, the message adds the
    /// smallest `max_heap_size` that fits one.
    std::string regionIncompatibilityMessage() const {
        const char* why = regionIncompatibility();
        if (!why) return std::string();
        std::string m = why;
        if (regionSlots() == 0 && nursery_region_bytes == 0) {
            m += " (this geometry needs max_heap_size >= " +
                 std::to_string(minRegionHeapBytes() >> 20) + " MiB, or a smaller nursery_max_block_count)";
        }
        return m;
    }

    /// Creates a config holding the default of every field.
    HeapConfig() = default;

    /// Returns why this config cannot run the region nursery, or a null pointer if it can. The string is a
    /// literal.
    ///
    /// The region nursery needs a promotion age from 1 to 3, bitmap allocation, an old-gen size class for
    /// every object below the large-object threshold, and room in the nursery region for at least one heap.
    const char* regionIncompatibility() const {
        if (promotion_age < 1 || promotion_age > 3) {
            return "nursery_regions = 1 requires promotion_age (the tenure age k) in 1..3";
        }
        if (!old_gen_bitmap_alloc) {
            return
                "nursery_regions = 1 requires old_gen_bitmap_alloc (the promotion grant "
                "allocates uniform bitmap cells)";
        }
        {
            // The largest medium class not above large_object_threshold, from the same series as
            // MEDIUM_CLASS_BASE; an object up to LOT - 8 bytes must fit a class.
            size_t largest = 256, cell = 512;
            for (int i = 0; i < 8 && cell <= large_object_threshold; ++i, cell <<= 1) largest = cell;
            if (large_object_threshold > largest + 8) {
                return
                    "nursery_regions = 1 requires large_object_threshold <= the largest "
                    "old-gen size class + 8 (a power of two in [512, 64K]): every nursery "
                    "object must have a size class (P§3.13)";
            }
        }
        if (regionSlots() == 0) {
            return
                "nursery_regions = 1: the nursery region is smaller than one heap slot "
                "(regionExtents() x the next power of two >= nursery_max_block_count / 2 "
                "x alloc_buffer_size); raise max_heap_size or nursery_region_bytes, or "
                "lower nursery_max_block_count";
        }
        return nullptr;
    }

    /// Turns `nursery_regions` = 2 (automatic) into 1, and leaves any other value alone.
    ///
    /// Throws `std::invalid_argument` with the reason if the config cannot run the region nursery; it never
    /// chooses the semi-space nursery, which must be asked for with `nursery_regions` = 0. Call it before
    /// `validate`.
    void resolveNurseryRegions() {
        if (nursery_regions != 2) return;
        if (regionIncompatibility()) {
            throw std::invalid_argument(
                "nursery_regions = 2 (auto): " + regionIncompatibilityMessage() +
                "; set nursery_regions = 0 to run the legacy nursery");
        }
        nursery_regions = 1;
    }

    /// Checks that the collector can run with this config, and throws `std::invalid_argument` naming the
    /// first rule broken if it cannot.
    ///
    /// The rules are ranges on single fields and relations between fields, among them: the initial old
    /// generation and the initial nursery fit their regions; an explicit `nursery_region_bytes` is at most
    /// half the heap; the large-object threshold is at most an allocation buffer, so that any object that
    /// takes the nursery path fits one nursery block; and with `nursery_regions` = 1, the region nursery can
    /// run. A config with `nursery_regions` = 2 is not checked against the region nursery, so call
    /// `resolveNurseryRegions` first.
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

        // Parallel marking.
        if (gc_mark_threads > 64) {
            throw std::invalid_argument("gc_mark_threads must be <= 64");
        }
        if (gc_mark_threads_cap < 1 || gc_mark_threads_cap > 64) {
            throw std::invalid_argument("gc_mark_threads_cap must be in [1, 64]");
        }
        // Parallel minor collection.
        if (gc_minor_threads > 64) {
            throw std::invalid_argument("gc_minor_threads must be <= 64");
        }
        if (gc_minor_threads_cap < 1 || gc_minor_threads_cap > 64) {
            throw std::invalid_argument("gc_minor_threads_cap must be in [1, 64]");
        }
        if (minor_lab_bytes < 4096 || minor_lab_bytes > 1024 * 1024 || minor_lab_bytes % 8 != 0) {
            throw std::invalid_argument("minor_lab_bytes must be a multiple of 8 in [4096, 1 MiB]");
        }
        // Concurrent marking and trigger pacing.
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
        // Incremental marking.
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
        // Helper threads and page work.
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
        // The old generation is the bottom of the reservation and the nursery region the top.

        size_t old_gen_space = oldGenCapBytes();

        if (initial_old_gen_size >= old_gen_space) {
            throw std::invalid_argument(
                "initial_old_gen_size must be < the old-gen region "
                "(max_heap_size - nursery_region_bytes)");
        }

        // A coarse form of the per-side slice check below.
        if (nurserySize() >= nurseryRegionBytes()) {
            throw std::invalid_argument(
                "nursery total size must be < nursery_region_bytes "
                "(the nursery must fit its own region)");
        }

        // An explicit split (HEAP_043); 0 chooses the default and needs no check.
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

        // Slice geometry (HEAP_042). A nursery_max_block_count too large for the region is not
        // rejected: nurserySliceBytes() clamps the slice, and the nursery stops growing early.
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

        // Allocation buffers are mapped with mmap(MAP_FIXED), which works in whole pages.
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

        // The old generation's initial commit is cut into pages of alloc_buffer_size.
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
        // An object below the threshold is allocated in the nursery, and a nursery can copy only an
        // object that fits one block.
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

        // Region nursery (HEAP_069, HEAP_070).
        if (nursery_regions > 2) {
            throw std::invalid_argument("nursery_regions must be 0, 1 or 2 (auto)");
        }
        if (nursery_region_eden_flip < -1 || nursery_region_eden_flip > 1) {
            throw std::invalid_argument("nursery_region_eden_flip must be -1, 0 or 1");
        }
        if (tenure_mode < 1 || tenure_mode > 2) {
            throw std::invalid_argument("tenure_mode must be 1 (sync) or 2 (concurrent)");
        }
        if (tenure_sync_threads > 64 || tenure_help_threads > 64) {
            throw std::invalid_argument("tenure_sync_threads / tenure_help_threads must be <= 64");
        }
        if (tenure_help > 1) {
            throw std::invalid_argument("tenure_help must be 0 (wait) or 1 (stop and finish)");
        }
        if (tenure_priority < 0 || tenure_priority > 20) {
            throw std::invalid_argument("tenure_priority must be in [0, 20]");
        }
        if (tenure_collector_threads < 1 || tenure_collector_threads > 32) {
            throw std::invalid_argument("tenure_collector_threads must be in [1, 32]");
        }
        if (shadow_granule_log2 != 3 && shadow_granule_log2 != 4) {
            throw std::invalid_argument("shadow_granule_log2 must be 3 or 4");
        }
        if (nursery_regions == 1) {
            if (regionIncompatibility()) throw std::invalid_argument(regionIncompatibilityMessage());
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

        if (!std::isfinite(direct_alloc_minor_budget) ||
            direct_alloc_minor_budget < 0.0 ||
            direct_alloc_minor_budget > 64.0) {
            throw std::invalid_argument(
                "direct_alloc_minor_budget must be in [0.0, 64.0]");
        }

        // ========== 7. Small-Class Block Budget ==========
        //
        // small_class_heap_budget_bytes may be any value; one above the old-gen cap never binds.

        // A free cell is a Header and a link pointer, so a class counted against the budget must be able
        // to hold one.
        constexpr size_t MIN_FREE_CELL_FOOTPRINT = sizeof(Header) + sizeof(void*);
        if (small_class_cell_max_bytes != 0 &&
            small_class_cell_max_bytes < MIN_FREE_CELL_FOOTPRINT) {
            throw std::invalid_argument(
                "small_class_cell_max_bytes must be >= sizeof(FreeCell)");
        }
        // small_class_cell_max_bytes may exceed large_object_threshold; that is not an error.

        // ========== 8. Old-gen Sweep & Mark Pacing ==========

        if (sweep_work_budget == 0) {
            throw std::invalid_argument("sweep_work_budget must be > 0");
        }
        if (initial_sweep_budget < sweep_work_budget) {
            throw std::invalid_argument(
                "initial_sweep_budget must be >= sweep_work_budget "
                "(at least one slice per startup pass)");
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

        if (sweep_scale_low < 1.0) {
            throw std::invalid_argument("sweep_scale_low must be >= 1.0");
        }
        if (!(sweep_scale_low <= sweep_scale_medium &&
              sweep_scale_medium <= sweep_scale_high &&
              sweep_scale_high <= sweep_scale_crit)) {
            throw std::invalid_argument(
                "sweep_scale_{low,medium,high,crit} must be non-decreasing");
        }

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
