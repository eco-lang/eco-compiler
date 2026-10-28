#ifndef ECO_NURSERYSPACE_H
#define ECO_NURSERYSPACE_H

// The young generation of one heap: the space new Elm objects are allocated in, and the minor collection that
// empties it.
//
// Most objects die young, so the nursery is cheap to allocate in and cheap to collect. Allocation is a bump of one
// pointer against one limit, and a minor collection costs in proportion to what survives, not to what was
// allocated. A survivor is copied out, so the space it leaves is reused without any free-list work. A copy
// normally adds one to the object's age (the `age` field of its header); a builder's age does not change. An object
// whose age has reached the configured promotion age is promoted: copied into the old generation (`OldGenSpace`)
// instead.
//
// The nursery is in one of two modes for its whole life, chosen by `HeapConfig::nursery_regions`.
//
// - Semi-space mode is the default. The nursery is two extents of equal capacity (HEAP_042), from-space and
//   to-space. The mutator allocates in from-space. A minor collection copies the live objects of from-space into
//   to-space, or promotes them, and the two then swap roles, so allocation resumes just past the survivors. The
//   copies left at the start of the new from-space are the survivor prefix.
// - Region mode (HEAP_069, HEAP_070) is described in `NurseryRegions.hpp`, which defines its data. In short: the
//   mutator allocates in eden, a minor collection copies eden's survivors into survivor extents and never
//   promotes, and a whole survivor extent is later promoted at once by a tenure job, which may run on a background
//   collector thread between minors.
//
// A minor collection in semi-space mode runs on the calling thread alone, or on a gang of helper threads when the
// old generation is configured for more than one minor thread, enough has been allocated, and to-space is certain
// to hold the copies whatever space the threads waste (`chooseMinorWorkers`). Threads copying at
// once agree on who copies each object through the claim protocol that `MinorWork.hpp` defines. Each copies into a
// LAB (local allocation buffer) of to-space, so the survivors can end up interleaved with fillers: dead objects with
// tag `Tag_Free` that cover the unused tails of LABs (HEAP_068). Every decision the nursery takes from how full it is
// counts object bytes, which exclude fillers, so that it does not depend on how many threads copied.
//
// There is no write barrier and no remembered set. Elm values are immutable, so an object normally refers only to
// objects at least as old as itself, but kernel code that mutates objects, and objects still under construction
// (builders, HEAP_BUILDER_001), can make an old object refer to a young one. A minor collection therefore scans
// every object it promotes and keeps alternating between scanning to-space and scanning what it promoted until
// both are exhausted.
//
// Young large objects (the YLOS) live in the old generation's address space and never move, but are young. A minor
// collection reaches them in place and scans them.
//
// Most of this header is private machinery of the minor collection, in three groups that share the `MinorWorker`
// slots: the serial copier (`evacuate`, `scanObject`), the parallel copier (the functions ending in `P`, defined in
// NurseryParallel.cpp) and the region minor and tenure job (the functions ending in `R`, and those named
// `tenure*`, defined in NurseryRegion.cpp and NurseryTenure.cpp).

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>
#include "AllocatorCommon.hpp"
#include "MarkWork.hpp"
#include "MinorWork.hpp"
#include "NurseryRegions.hpp"
#include "P1Census.hpp"
#include "GCStats.hpp"
#include "OldGenSpace.hpp"
#include "RootSet.hpp"
#include "StackMapRoots.hpp"

namespace Elm {

class Allocator;
class ThreadLocalHeap;
class NurserySpaceTestAccess;

/// The young generation of one heap, and its minor collector.
///
/// A `NurserySpace` holds no address space until its private `initialize` is called by a friend. After that it
/// owns a slice pair of the nursery region (semi-space mode) or a slice set (region mode), obtained from the
/// `Allocator`, and releases it when destroyed. It cannot be copied or moved, and compiled code holds the address
/// of its allocation state. In region mode the owner must call `tenureTeardown` before destroying it, because the
/// destructor does not stop the tenure collector.
///
/// Helper threads that a minor collection or a tenure job uses are started and joined inside it. The exception is
/// the tenure collector in region mode, which runs a job between minors until `tenureJoin` waits for it.
class NurserySpace {
public:
    /// Creates a nursery that holds no address space; a friend must call `initialize` before it is used.
    NurserySpace();
    /// Releases the nursery's address space. In region mode the owner must have called `tenureTeardown` first.
    ~NurserySpace();

    /// The nursery's allocation state: the next free byte and the limit allocation may not pass.
    ///
    /// These are the fields allocation works on, not a copy of them. Compiled code allocates inline against them
    /// through the address `bumpState` returns, so the layout, `ptr` at offset 0 and `end` at offset 8, must not
    /// change. `end` is already lowered to the point at which a minor collection is due, so a single comparison
    /// `ptr + size <= end` decides both that the object fits and that no collection is due. `end` below `ptr` is
    /// legal and means that a collection is due.
    struct NurseryBump {
        char* ptr;
        char* end;
    };
    static_assert(offsetof(NurseryBump, ptr) == 0 && offsetof(NurseryBump, end) == 8,
                  "NurseryBump layout is ABI for the inline-alloc expansion");

    /// Returns the address of the allocation state, which stays valid for the nursery's lifetime.
    NurseryBump* bumpState() { return &bump_; }

    /// Allocates `size` bytes, rounded up to a multiple of 8, and returns them, or returns null when they do not
    /// fit below `end`. It never collects itself: on null the caller must run a minor collection and retry. The
    /// bytes are not cleared.
    void *allocate(size_t size);

    /// Returns the roots this nursery's collections start from.
    RootSet& getRootSet() { return root_set; }

#if ENABLE_GC_STATS
    /// Returns this nursery's collection statistics.
    const GCStats& getStats() const { return stats; }
    /// Returns this nursery's collection statistics, for update.
    GCStats& getStats() { return stats; }
#endif

#if ECO_HEAP_VALIDATE
    // Public in validate builds so that free functions in NurserySpace.cpp can call them.

    /// Returns whether `ptr` lies between the start of the allocation extent (from-space, or eden in region mode)
    /// and the bump pointer.
    bool isInFromSpaceAllocatedRegion(void* ptr) const;
    /// Returns whether `ptr` lies in the part of to-space copied into so far by the running minor. Always false in
    /// region mode.
    bool isInToSpaceAllocatedRegion(void* ptr) const;
#endif

private:
    const HeapConfig* config_;      ///< Not owned; must outlive the nursery. Set by `initialize` and `reset`.
    Allocator* allocator_;          ///< Not owned. The source of the nursery's address space.

    // Semi-space mode: the two extents. `slice_.capacity` is the length of each, so they are equal by construction.
    NurserySlicePair slice_;
    bool from_is_low_;              ///< Whether from-space is the low extent. Always true in region mode.

    /// The capacity each extent may grow to: the smaller of the allocator's slice size and the configured maximum.
    size_t growth_ceiling_bytes_;

    // The address ranges `contains` tests. In semi-space mode they are the two extents exactly. In region mode the
    // low range is the heap's whole slot of the nursery region and the high range is empty (both null).
    char* low_base_;
    char* low_end_;
    char* high_base_;
    char* high_end_;

    NurseryBump bump_;

    /// The serial minor's queue of promoted objects still to scan, kept across minors so its capacity is reused.
    std::vector<void*> promoted_buf_;

    // The serial minor's to-space cursors, meaningful only during a minor: the copy pointer, its limit and the
    // Cheney scan pointer. `copy_ptr_` keeps its value after the minor; `checkAndGrow` reads it.
    char* copy_ptr_;
    /// The bump pointer as the last minor left it, that is the end of the survivor prefix.
    char* survivor_end_ = nullptr;
    // The filler bytes (HEAP_068) inside the survivor prefix `[fromBase(), survivor_end_)`, and inside the to-space
    // prefix the running minor is building. Both are 0 after a serial minor and in region mode.
    size_t filler_bytes_ = 0;
    size_t filler_bytes_to_ = 0;
    char* copy_end_;
    char* scan_ptr_;

    /// The occupancy after a minor, as a fraction of capacity, above which the nursery grows. From the config.
    float growth_threshold_;

    /// The fraction of capacity, in object bytes, at which a minor collection becomes due. From the config.
    float gc_threshold_;

    // Config and allocator values that do not change between minors, copied here by `refreshCapacityCaches` so
    // that the per-object paths do not reach through `config_` and `allocator_`.
    Elm::u32 promotion_age_ = 1;
    bool use_hybrid_dfs_ = true;
    char* heap_base_ = nullptr;
    size_t heap_reserved_ = 0;

    /// The capacity of one extent in bytes: `slice_.capacity`, or the slice set's capacity in region mode.
    size_t from_capacity_bytes_;
    uint64_t minor_seq_ = 0;
public:
    /// Returns the capacity of one extent in bytes (from-space, or eden in region mode).
    size_t capacityBytes() const { return from_capacity_bytes_; }
    /// Returns how many minor collections this nursery has started, in either mode (HEAP_076).
    uint64_t minorSeq() const { return minor_seq_; }
    /// Returns the number of object bytes in the nursery at which a minor collection becomes due.
    size_t minorThresholdBytes() const { return threshold_total_bytes_; }
    /// Makes a minor collection due now: the next allocation by any path, inline or not, misses and its caller
    /// collects. The collection sets a fresh limit. Returns false, changing nothing, if one was already due.
    bool requestMinor() {
        if (bump_.end <= bump_.ptr) return false;
        bump_.end = bump_.ptr;
        return true;
    }
    /// Calls `f` on every object of the survivor prefix in address order, skipping fillers, and returns how many
    /// it visited. If `bytes_out` is not null, it receives their total size.
    ///
    /// Semi-space mode only; region mode uses `forEachYoung`. It must be called before anything is allocated after
    /// a minor collection, when the bump pointer is still at the end of the survivor prefix. It asserts this, that
    /// the walk ends exactly at the bump pointer, and that the fillers it skipped add up to the recorded figure.
    // TLA-REGION(NSH.forEachSurvivor) begin
    template <typename F> size_t forEachSurvivor(F&& f, size_t* bytes_out = nullptr) {
        assert(bump_.ptr == survivor_end_ &&
               "IM7: nursery allocated since the last minor; the survivor prefix is not exact");
        char* p = fromBase();
        char* const end = bump_.ptr;
        size_t n = 0;
        size_t fillers = 0;
        while (p < end) {
            const size_t sz = getObjectSize(p);
#if ECO_HEAP_VALIDATE
            if (getHeader(p)->tag > Tag_Forward || sz == 0 || p + sz > end) {
                std::fprintf(stderr, "[heap-validate] IM7: bad survivor at %p (tag %u, size %zu)\n",
                             static_cast<void*>(p), (unsigned)getHeader(p)->tag, sz);
                std::fflush(stderr);
                std::abort();
            }
#endif
            if (getHeader(p)->tag == Tag_Free) {
                fillers += sz;
            } else {
                f(static_cast<void*>(p));
                ++n;
            }
            p += sz;
        }
        assert(p == end && "IM7: survivor walk overran bump_.ptr");
        assert(fillers == filler_bytes_ && "HEAP_068: survivor-prefix fillers != filler_bytes_");
        if (bytes_out) *bytes_out = static_cast<size_t>(end - fromBase()) - fillers;
        return n;
    }
    // TLA-REGION(NSH.forEachSurvivor) end
    /// Returns whether nothing has been allocated since the last minor collection: in region mode, whether eden is
    /// empty.
    bool survivorPrefixExact() const {
        if (rg_) return bump_.ptr == rg_->eden_base;
        return bump_.ptr == survivor_end_;
    }

    // Region mode (HEAP_069, HEAP_070).

    /// Returns whether the nursery is in region mode.
    bool regionMode() const { return rg_ != nullptr; }
    /// Returns the region nursery's state, or null in semi-space mode. Valid until the nursery is reset or destroyed.
    RegionState* regionState() { return rg_.get(); }
    /// Returns the region nursery's state, or null in semi-space mode. Valid until the nursery is reset or destroyed.
    const RegionState* regionState() const { return rg_.get(); }
    /// Calls `f` on every young object, skipping fillers, and returns how many it visited. If `bytes_out` is not
    /// null, it receives their total size.
    ///
    /// In semi-space mode this is `forEachSurvivor`. In region mode the young objects are the survivor parts of the
    /// Young and Tenuring extents and the builder area of the Young extent of age 1. It must be called before
    /// anything is allocated after a minor collection, when eden is empty, and asserts this.
    template <typename F> size_t forEachYoung(F&& f, size_t* bytes_out = nullptr);
    /// Waits for the tenure job, if one is launched and not yet merged, finishing it on this thread or the minor's
    /// gang if it was stopped or never ran, and then merges its results into the heap. Does nothing in semi-space
    /// mode or when there is no such job.
    ///
    /// `why` is 0 at the start of a minor collection and 1 before a stop-the-world major collection.
    /// With 2 the merge is made without `heal` (see `mergeJob`) and any remaining work runs on this thread alone.
    /// If `rec` is not null, the wait and merge times are added to it.
    void tenureJoin(OldGenSpace& oldgen, int why, MinorGCRecord* rec = nullptr);
    /// Builds the tenure job for the extent that the minor collection just ended handed over, and runs it or starts
    /// it. Does nothing in semi-space mode, when no extent was handed over, or when the job for this minor is already
    /// launched. Aborts if the previous job is not merged.
    ///
    /// With `tenure_mode` 2 the job runs on the heap's tenure collector thread while the mutator runs, and
    /// `tenureJoin` collects it. Otherwise, and also with mode 2 when the old generation cannot grant the job all the
    /// space it may need, the job runs to completion before this returns.
    void tenureLaunch(OldGenSpace& oldgen);
    /// Stops the tenure collector, finishes and merges any job left on this thread without `heal`,
    /// and destroys the collector. Does nothing in semi-space mode.
    void tenureTeardown(OldGenSpace& oldgen);
    /// Returns where a stop-the-world major collection must treat `obj` as living: the old-generation copy if `obj`
    /// is in the survivor part of the Tenuring extent and its job is merged, otherwise `obj` itself. Aborts if such
    /// an object has no copy. Region mode only.
    void* majorRedirect(void* obj) const;
    /// Turns into fillers the objects in the survivor part of every Young extent that the stop-the-world major
    /// collection just marked did not reach (`OldGenSpace::majorReachedNursery`, HEAP_074). Builder areas and the
    /// Tenuring extent are left alone. Region mode only; aborts if called inside a minor collection or while a
    /// tenure job is unmerged.
    void zapDeadAfterMajor(OldGenSpace& og);
    /// Returns the largest object, in bytes, that may be allocated in the nursery: the largest old-generation size
    /// class in region mode, since a survivor must be promotable by class, and `SIZE_MAX` in semi-space mode.
    size_t regionLargeCap() const { return region_large_cap_; }

    // Test controls for the region nursery. Each is off at 0 or false, and is set only between minors.

    /// Every n-th tenure start is skipped, so that a check for an untenured object must fire.
    uint64_t test_tenure_skip_start_every_ = 0;
    /// The merge leaves one reference unrewritten, so that a check must fire.
    bool test_heal_skip_one_ = false;
    /// The merge does not turn the dead objects of ageing extents into fillers, nor clear the slots of dead ageing
    /// young large objects.
    bool test_skip_zap_ = false;
    /// The region minor does not record as seen the large bodies held by the hand-over and ageing extents.
    bool test_no_body_remark_ = false;
    /// Every tenure job stops after this many items and is finished in the next pause.
    uint64_t test_tenure_force_stop_after_ = 0;
    /// The tenure job sleeps this many microseconds per item.
    uint64_t test_tenure_sleep_us_ = 0;
    /// Whether to record in `test_layout_` the old-generation address of every copy each merged job made.
    bool test_record_layout_ = false;
    /// The recorded addresses, with a marker word carrying the minor number before each job's.
    std::vector<uintptr_t> test_layout_;
private:
    /// The running job's copy addresses, moved into `test_layout_` at the merge.
    std::vector<uintptr_t> J_layout_;
    /// The region nursery's state. Null in semi-space mode.
    std::unique_ptr<RegionState> rg_;
    size_t region_large_cap_ = SIZE_MAX;
    /// Acquires the slice set and sets up region mode with an empty eden. Aborts if the slice set cannot be committed
    /// or the configured geometry is invalid.
    void initRegions();
    /// Releases the slice set and the region state. Does nothing in semi-space mode.
    void releaseRegions();
    /// Runs a region-mode minor collection. See `minorGC`.
    void minorGCRegion(OldGenSpace& oldgen, const StackMapRoots& stackmap_roots,
                       MinorGCRecord* rec);
    friend struct RegionEnvAccess;
private:

    /// The number of object bytes at which a minor collection becomes due: the capacity times `gc_threshold_`.
    size_t threshold_total_bytes_;

    RootSet root_set;

#if ENABLE_GC_STATS
    GCStats stats;
#endif

    /// The heap this nursery belongs to, or null if it was initialized from an `Allocator`. Not owned.
    ThreadLocalHeap* thread_heap_;

    /// Whether a minor collection is in progress, from just after it starts until it finishes. Set and cleared
    /// together with the old generation's own flag (`OldGenSpace::setInMinorGC`).
    bool minor_gc_running_ = false;

#if ECO_HEAP_VALIDATE
    /// Whether a minor collection is copying, which tells the stale-pointer check whether to-space is legal. Set
    /// for a narrower span than `minor_gc_running_`.
    bool in_minor_gc_ = false;
    /// Whether the serial minor is scanning a promoted object, whose children must all be old enough to promote.
    bool in_phase3_   = false;
#endif

#if P1_CENSUS_COMPILED
    // The survivor-write census (`P1Census.hpp`). At the end of each minor every survivor is hashed, and at the
    // start of the next each is hashed again. A difference is a write into an object that had already survived a
    // collection. Mode 1 counts these and mode 2 aborts.

    /// One survivor recorded by the census.
    struct CensusEntry {
        uint32_t offset_q;    ///< (obj - census_base_) / 8.
        uint32_t size;        ///< In bytes.
        uint64_t hash;
        uint32_t copy_off;    ///< Word offset of its copy in `census_copy_`, or `UINT32_MAX` if not copied.
        uint8_t  builder;     ///< Its builder bit when recorded. A builder may be written.
    };
    std::vector<CensusEntry> census_;
    std::vector<uint64_t>    census_copy_;   ///< Copies of the recorded survivors of at most 128 bytes.
    char* census_base_ = nullptr;
    int   census_forced_ = -1;               ///< -1 follows the census mode, 0 forces it off, 1 on (tests).
    uint64_t census_minor_seq_ = 0;
    /// A young large object recorded by the census. These never move, so they are recorded by address. The
    /// records are dropped if a major collection runs before the next minor.
    struct CensusYlosEntry {
        void*    obj;
        uint32_t size;
        uint64_t hash;
    };
    std::vector<CensusYlosEntry> census_ylos_;
    uint64_t census_ylos_epoch_ = 0;
    /// Returns whether the census runs: as forced by a test, otherwise as the census mode says.
    bool  censusEnabled() const;
    /// Records the survivors of the semi-space minor that just ended.
    void  censusRecord(OldGenSpace& oldgen);
    /// Hashes the recorded survivors again and counts, or aborts on, any that changed.
    void  censusCheck(OldGenSpace& oldgen);
#endif

    /// The colour of the current minor collection, flipped at its start. Every large body (HEAP_026) and young large
    /// object reached is stamped with it, and after the minor `OldGenSpace::sweepNurseryLargeBodies` sweeps the large
    /// bodies left with the other colour.
    bool minor_color_ = false;

    /// The serial minor's young large objects reached this minor that stay young, to be scanned in place. Cleared
    /// at the start of each minor.
    std::vector<void*> young_large_scan_;

    /// Sets up this nursery to allocate from `allocator`'s address space under `config`, with no owning heap.
    /// Both must outlive the nursery.
    void initialize(Allocator* allocator, const HeapConfig* config);

    /// Sets up this nursery for `heap`, under `config`, taking address space from the heap's `Allocator`. Both
    /// must outlive the nursery.
    void initialize(ThreadLocalHeap* heap, const HeapConfig* config);

    /// Acquires the address space for the configured mode and initial capacity, and sets up allocation in it.
    /// `allocator_` and `config_` must already be set.
    void initializeFromConfig();

    /// Runs a minor collection.
    ///
    /// Every object reachable from the roots (`root_set`, `stackmap_roots`) that lies in the nursery is copied, and
    /// every root and reference to it is updated. In semi-space mode an object whose age has reached the promotion
    /// age, and which is neither pinned nor a builder, is promoted into `oldgen` instead, and after the copy the
    /// nursery may grow and from-space and to-space swap. In region mode the collection runs as `NurseryRegions.hpp`
    /// describes. Afterwards the large bodies whose headers were not reached are swept
    /// (`OldGenSpace::sweepNurseryLargeBodies`). If `rec` is not null and phase timers are compiled in, the
    /// collection's measurements are written into it.
    void minorGC(OldGenSpace &oldgen, const StackMapRoots& stackmap_roots,
                 MinorGCRecord* rec = nullptr);

    /// When `ECO_NURSERY_BULK_CLEAR=1` is set, fills the part of to-space past the copies with zeroes. In validate
    /// builds, when `ECO_NURSERY_POISON=1` is set, fills it with the byte 0xD8 instead, so that an allocation that
    /// leaves a pointer field unwritten is caught. Otherwise does nothing.
    void clearToSpaceFreeRegion();

#if ECO_HEAP_VALIDATE
    /// Overwrites the allocated part of from-space with the byte 0xDD, so that a reference the minor did not update
    /// leads to data the checks reject.
    void poisonOldFromSpaceUsedRegion();

    /// Walks the allocated part of from-space and aborts at any header with an invalid tag or size, or a heap
    /// `Tag_Custom` with no fields (HEAP_044).
    void preEvacuationFromSpaceWalk();

    /// Aborts with a report if `ptr`, which must be in the nursery, is not where a live object can be: in
    /// semi-space mode, outside the allocated part of from-space and, during a minor, of to-space.
    void debugAssertValidNurseryPointer(void* ptr) const;
    /// Is the region-mode form of `debugAssertValidNurseryPointer`.
    void regionAssertValidPointer(void* ptr) const;
#endif

    /// Returns the start of the current from-space extent.
    inline char* fromBase() const { return from_is_low_ ? low_base_ : high_base_; }
    /// Returns the start of the current to-space extent.
    inline char* toBase()   const { return from_is_low_ ? high_base_ : low_base_; }

    /// Returns whether `ptr` is in this nursery's address space: either extent in semi-space mode, the whole slot
    /// in region mode.
    inline bool contains(void *ptr) const {
        char* p = static_cast<char*>(ptr);
        return (p >= low_base_ && p < low_end_) ||
               (p >= high_base_ && p < high_end_);
    }

    /// Returns whether `ptr` is in the from-space extent. In region mode this is the same as `contains`.
    inline bool isInFromSpace(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        if (from_is_low_) {
            return p >= low_base_ && p < low_end_;
        } else {
            return p >= high_base_ && p < high_end_;
        }
    }

    /// Returns whether `ptr` is in the to-space extent. Always false in region mode.
    inline bool isInToSpace(void* ptr) const {
        char* p = static_cast<char*>(ptr);
        if (from_is_low_) {
            return p >= high_base_ && p < high_end_;
        } else {
            return p >= low_base_ && p < low_end_;
        }
    }

    /// Sets the ends of both extents from their bases and the capacity. Must be called after every change of
    /// capacity, or a minor would not copy objects in the grown part.
    void updateBounds();

    /// Returns the bytes allocated since the last minor collection plus the survivors it left, fillers included.
    /// In region mode, the survivors' object bytes plus what eden holds.
    size_t bytesAllocated() const;
public:
    /// Returns `bytesAllocated()` without the fillers of the survivor prefix: the figure every sizing decision of the
    /// nursery uses.
    size_t objectBytesAllocated() const { return bytesAllocated() - filler_bytes_; }
    /// Returns the filler bytes in the survivor prefix.
    size_t fillerBytes() const { return filler_bytes_; }
private:

    /// Copies the config and allocator values cached in members, and recomputes the capacity and
    /// `threshold_total_bytes_` from the current extent size. Must be called after the capacity changes.
    void refreshCapacityCaches();

    /// Returns the limit for `bump_.end` from the current bump pointer.
    ///
    /// The limit is where the object bytes in the nursery reach `threshold_total_bytes_`, so that crossing it makes a
    /// minor collection due. If the survivors alone are already at or past that point, a collection could free
    /// nothing new, so the limit is the end of the extent instead and only filling it makes a collection due. In
    /// semi-space mode the limit is also the extent end when the threshold plus the survivor prefix's fillers would
    /// pass it.
    char* computeAllocEnd();

    /// Releases the nursery's address space, finishing any tenure job first, and sets it up again from scratch, under
    /// `new_config` if it is not null. Clears the root set and keeps the statistics.
    void reset(OldGenSpace &oldgen, const HeapConfig* new_config = nullptr);

    /// Returns null, which tells the caller of `allocate` to run a minor collection. In statistics builds it counts
    /// the time spent.
    void* allocateSlow(size_t size);

    /// Returns whether `n` bytes can be bump-allocated before a minor collection is due, allocating nothing. Code that
    /// checks once for several allocations relies on this (HEAP_041).
    bool ensureHeadroom(size_t n);

    /// Raises `bump_.end` to the end of what the extent can hold, ignoring the collection threshold. This lets a
    /// request larger than the threshold be met in a very small nursery, where collecting would never make room.
    void failSoftUnclamp();

    /// Returns `size` bytes of to-space for the serial minor's next copy. Asserts that to-space is not exhausted,
    /// which cannot happen because it is as large as from-space.
    void* copyToSpace(size_t size);

    /// Returns whether the serial minor has copies in to-space left to scan.
    bool scanHasMore() const;

    /// Grows both extents by about half when the survivors of the minor that just copied fill more than
    /// `growth_threshold_` of to-space, up to the growth ceiling. If the allocator refuses, nothing changes.
    void checkAndGrow();

    // The serial copier. Each updates its slot in place and appends what it promotes to `promoted_objects`.

    /// Updates `ptr` to the object's new address if it refers to a from-space object, copying or promoting it first
    /// unless it has already been. A reference to a young large object reaches it (`reachYoungLarge`); any other
    /// reference, and an embedded constant or null, is left as it is.
    void evacuate(HPointer &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    /// Is `evacuate` for a slot that holds a raw address rather than an `HPointer`, as compiled code's globals do.
    /// Embedded constants and addresses outside the heap are left as they are.
    void evacuateJitPtr(uint64_t &ptr, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    /// Is `evacuate` for a slot that holds an `HPointer` as a plain 64-bit word.
    void evacuateValueSlot(uint64_t &encoded, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);
    /// Evacuates `val` if `is_boxed`, and otherwise does nothing.
    inline void evacuateUnboxable(Unboxable &val, bool is_boxed, OldGenSpace &oldgen,
                                  std::vector<void*> *promoted_objects) {
        if (is_boxed) evacuate(val.p, oldgen, promoted_objects);
    }

    /// Returns `size` bytes of the old generation for a serial promotion. Statistics builds can route this through
    /// worker 0 of a promotion context instead (`test_serial_promo_via_ctx_`).
    inline void* promoteAllocate(OldGenSpace& oldgen, size_t size) {
#if ENABLE_GC_STATS
        if (__builtin_expect(promo_w0_ != nullptr, 0))
            return oldgen.allocatePromotion(*promo_w0_, size, /*per_alloc_sweep=*/true);
#endif
        return oldgen.allocate(size);
    }
#if ENABLE_GC_STATS
    /// The promotion context worker the serial copier promotes through, or null to use `OldGenSpace::allocate`.
    /// Not owned; set only for the duration of one serial minor.
    OldGenSpace::PromoWorker* promo_w0_ = nullptr;
#endif
public:
    // Test controls for the semi-space minor. Each is off at 0 or false, and is set only between minors.

    /// Whether the serial minor promotes through a one-worker promotion context (statistics builds, bitmap old
    /// generation), which must place objects exactly as `OldGenSpace::allocate` does.
    bool test_serial_promo_via_ctx_ = false;
    /// Whether every minor runs on the parallel copier, even with one thread and little allocated (statistics
    /// builds, bitmap old generation).
    bool test_force_parallel_engine_ = false;
    /// Every n-th object a parallel worker copies is copied a second time, so that a check must fire.
    uint64_t test_minor_double_copy_every_ = 0;
    /// One unused LAB tail is left without a filler, so that a check must fire.
    bool test_minor_skip_filler_ = false;
private:

    // The parallel minor (HEAP_067).

    /// One thread's slot in a parallel minor or a parallel tenure run: its grey work, its LAB and its counts. Each
    /// slot is used by one thread at a time, apart from `deque`, which others steal from, and `priv`.
    struct MinorWorker {
        unsigned index = 0;                     ///< The slot's index, which is also its promotion worker's index.
        // The owner's private grey entries are stack[head, size). In LIFO order they are taken from the back; in
        // FIFO order (`fifo_order_`) from `head`, the order a serial Cheney scan would visit them.
        std::vector<uint64_t> stack;
        size_t head = 0;
        std::atomic<uint64_t> priv{0};          ///< The number of private entries. Stored, never loaded.
        uint64_t pops = 0;
        markwork::WorkStealingDeque deque{10};
        markwork::MarkerCounters ctr;
        minorwork::Lab lab;
        minorwork::LabCounters lc;
        GCStats::MinorCopyCounts copies;
        uint64_t n_surv = 0, b_surv = 0, n_prom = 0, n_ylos_prom = 0;
        uint64_t claim_races = 0, busy_waits = 0, spine_splits = 0, chunks = 0;
        uint64_t ylos_reach_calls = 0, ylos_scans = 0;
        uint64_t busy_ns = 0;
        uint64_t claims_won = 0;
        /// The large bodies this worker found live or promoted. They are recorded after the workers join, all
        /// promotions before all sightings.
        std::vector<HPointer> lb_seen, lb_promoted;
        std::vector<void*> ylos_young;          ///< Young large objects this worker reached that stay young.
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        std::vector<void*> promoted_log;
#endif
        /// Clears the per-run state and counts, keeping the allocated capacity.
        void resetRun();
    };
    struct MinorEnv;
    friend struct MinorEnv;
    struct RegionEnv;
    friend struct RegionEnv;
    struct TenureHeapEnv;
    friend struct TenureHeapEnv;
    struct TenureParEnv;
    friend struct TenureParEnv;

    // The region minor (NurseryRegion.cpp).

    /// The kind of slot or object a region-minor grey entry stands for, carried in the entry: a survivor copy, a
    /// young large object that stays young, a builder, a young large object of the hand-over generation, and a root.
    /// The kind decides where a reference into the hand-over extent is recorded.
    enum : uint32_t { kColSurv = 0, kColYoungYlos = 1, kColBuilder = 2, kColHandYlos = 3, kColRoot = 4 };
    /// Updates `slot` as the region minor requires, where `col` is the kind of what holds it: an eden object is
    /// copied into the fill (a builder into its builder area) and the slot set to the copy; a reference into the
    /// retiring extent is set to the tenured copy; a reference into the hand-over or an ageing extent is recorded
    /// for the tenure job; a young large object is reached. Anything else is left as it is.
    void evacuateR(MinorWorker& w, region::RegionWorker& rw, HPointer& slot, uint32_t col);
    /// Copies `obj`, which `w` has claimed and whose header word was `hw`, into the fill or its builder area, and
    /// publishes the forward word. Returns the copy. Aborts if `obj` has a nonzero age.
    void* copyClaimedR(MinorWorker& w, region::RegionWorker& rw, void* obj, uint64_t hw);
    /// Scans the grey entry `e` for `w`, evacuating the boxed fields it covers.
    void scanEntryR(MinorWorker& w, uint64_t e);
    /// Copies the uncopied list cells reached through `prev`'s tail one after another, up to `MINOR_SPINE_RUN` of
    /// them, then evacuates their heads. A longer run is left for the scan of its last copy. `col` is the kind of
    /// `prev`.
    void spineRunR(MinorWorker& w, region::RegionWorker& rw, Cons* prev, uint32_t col);
    /// Reaches `obj` if it is a young large object. A member of an ageing generation is recorded for the tenure job.
    /// Any other is queued for scanning on its first reach this minor, or on every reach if it is a builder; a new
    /// one also gets age 1 and joins this minor's generation. Locks `ylos_mu_`.
    void reachYoungLargeR(MinorWorker& w, region::RegionWorker& rw, void* obj);
    /// Returns the tenured copy of `t`, an object in the retiring extent's survivor part, and counts it in `rw` if
    /// `rw` is not null. Aborts if `t` is outside that part or has no copy.
    void* resolveRetire(void* t, region::RegionWorker* rw);
    /// Runs one region-minor gang member: `ctx` is the run's arguments, `member` the member's index.
    static void regionWorkerEntry(void* ctx, unsigned member);
    /// Applies the finished tenure job's results to the heap and marks it merged: returns its grant, transfers the
    /// large bodies it promoted and, if `heal`, promotes the young large objects it reached, rewrites the
    /// references recorded for it to the copies, turns the dead objects of its ageing extents into fillers and sets
    /// the pointer slots of the unreached young large objects of its ageing generation to Empty. Adds to `rec` if
    /// not null.
    void mergeJob(OldGenSpace& oldgen, bool heal, MinorGCRecord* rec);
    /// Runs the tenure job on this thread with its grant until it is done, or until `stop`, if not null, is set.
    /// Aborts if the job has no grant.
    void runJobExact(OldGenSpace& oldgen, const std::atomic<bool>* stop);
    /// Runs the tenure job's mark of its ageing extents, if not done yet: on this thread when `n` is 1, otherwise on
    /// up to `n` members of the old generation's gang.
    void finishJobMarkPhases(OldGenSpace& oldgen, unsigned n = 1);
    struct AgeParEnv;
    friend struct AgeParEnv;
    /// Runs one gang member of the ageing mark. `ctx` is the run's arguments.
    static void ageParEntry(void* ctx, unsigned member);
    /// Finishes the tenure job on up to `n` threads of the old generation's gang, allocating through a promotion
    /// context. Returns the job's unused grant first.
    void runJobParallel(OldGenSpace& oldgen, unsigned n);
    /// Runs the tenure job on the collector thread until it is done or stopped. `ctx` is the nursery. Only member 0
    /// works.
    static void tenureEntry(void* ctx, unsigned member);
    /// Runs one gang member of `runJobParallel`. `ctx` is the run's arguments.
    static void tenureParEntry(void* ctx, unsigned member);
    /// Runs one member of the tenure collector on a job shared by several members. `ctx` is the nursery.
    static void tenureConcEntry(void* ctx, unsigned member);
    /// Creates the slots `ws[0, n)` where missing and resets them for a run.
    void tenureParSetup(std::unique_ptr<MinorWorker>* ws, unsigned n);
    /// Creates and resets the slots `[B, V)` of `tenure_workers_` for helpers beyond the collector's `B` members,
    /// and adds the stopped run's counts to the statistics.
    void tenureParSetupExtra(unsigned B, unsigned V);
    /// Deals the tenure job's remaining work round-robin into the deques of `ws[0, n)`. No slot may be running.
    void tenureParDistribute(std::unique_ptr<MinorWorker>* ws, unsigned n);
    /// Adds the results of `ws[0, n)` to the job, in slot order, and resets the slots. Aborts if any slot still
    /// holds work.
    void tenureParCollect(std::unique_ptr<MinorWorker>* ws, unsigned n);
    /// Starts the tenure job on `B` members of the tenure collector, each with its own slot.
    void tenureConcLaunch(OldGenSpace& oldgen, unsigned B);
    /// Finishes a job started by `tenureConcLaunch` after its members have stopped: runs what is left on this
    /// thread when `on_this_thread`, otherwise on up to `help_n` members of the old generation's gang, then collects
    /// the results and folds the members' use of the grant back into it.
    void tenureConcFinish(OldGenSpace& oldgen, unsigned help_n, bool on_this_thread);
    // The state of a tenure job shared by several collector members.
    std::unique_ptr<MinorWorker> tenure_workers_[OldGenSpace::kMaxMinorWorkers];
    std::vector<OldGenSpace::TenureMemberCursor> tenure_mcs_;
    std::unique_ptr<markwork::SliceControl> tenure_ctl_;
    unsigned tenure_par_n_ = 0;
    /// Is `checkAndGrow` for region mode, judged on the object bytes that survived the last minor.
    void regionCheckAndGrow();
    /// Copies the region nursery's statistics into `stats`. Does nothing unless statistics are compiled in.
    void syncRegionStats();
    /// Checks the region nursery's state at the end of a minor (validate builds).
    void regionEndMinorValidate(OldGenSpace& oldgen);
#if P1_CENSUS_COMPILED
    /// Is `censusRecord` for region mode.
    void censusRecordRegion(OldGenSpace& oldgen);
    /// Is `censusCheck` for region mode.
    void censusCheckRegion(OldGenSpace& oldgen);
#endif
    /// The parallel minor's and parallel tenure runs' slots, created on first use and kept.
    std::unique_ptr<MinorWorker> minor_workers_[OldGenSpace::kMaxMinorWorkers];
    minorwork::ToSpace tospace_;
    /// The old generation of the parallel or region minor in progress, and null otherwise. Not owned.
    OldGenSpace* par_oldgen_ = nullptr;
    /// The promotion context of the parallel minor in progress, and null otherwise. Not owned.
    OldGenSpace::PromoCtx* par_ctx_ = nullptr;
    unsigned par_n_ = 0;
    /// Serialises the parallel and region minors' updates of young large objects' metadata.
    std::mutex ylos_mu_;
    /// The objects the last minor promoted (or the last tenure job tenured), which sizes the old-generation sweep
    /// done before the next parallel copy.
    size_t last_minor_promoted_ = 0;
    bool prefetch_children_ = false;  ///< From the config, read at the start of each parallel minor.
    bool fifo_order_ = false;         ///< Whether grey entries are taken oldest first. See `MinorWorker`.

    /// Returns how many threads the next minor copies with, or 0 for the serial copier: 0 when the old generation is
    /// set to one minor thread, when less than `minor_parallel_min_bytes` is allocated, or when the LABs' worst-case
    /// waste could overflow to-space. `test_force_parallel_engine_` overrides the first two.
    unsigned chooseMinorWorkers(OldGenSpace& oldgen);
    /// Runs the copying of a semi-space minor on `n` threads. Worker 0 evacuates every root before the others start,
    /// then all of them drain the grey work together.
    void minorGCParallel(OldGenSpace& oldgen, const StackMapRoots& stackmap_roots,
                         MinorGCRecord* rec, unsigned n);
    /// Runs one parallel-minor gang member. `ctx` is the run's arguments.
    static void minorWorkerEntry(void* ctx, unsigned member);
    /// Is `evacuate` for the parallel minor: claims and copies a from-space object or follows its forward word.
    /// `parent_old` says that what holds the slot was promoted, so that a child too young to promote is reported in
    /// validate builds.
    void evacuateP(MinorWorker& w, HPointer& slot, bool parent_old);
    /// Is `evacuateP` for a root that holds a raw address.
    void evacuateRawP(MinorWorker& w, uint64_t& raw);
    /// Copies or promotes `obj`, which `w` has claimed and whose header word was `hw`, and publishes the forward
    /// word. Returns the copy. Aborts if the old generation cannot allocate a promotion.
    void* copyClaimed(MinorWorker& w, void* obj, uint64_t hw, bool parent_old);
    /// Waits until the thread that claimed `obj` publishes its forward word, and returns that word.
    uint64_t waitPublishedP(MinorWorker& w, void* obj);
    /// Scans the grey entry `e` for `w`, evacuating the boxed fields it covers.
    void scanEntryP(MinorWorker& w, uint64_t e);
    /// Is `spineRunR` for the parallel minor.
    void spineRunP(MinorWorker& w, Cons* prev);
    /// Is `reachYoungLarge` for the parallel minor. Locks `ylos_mu_`.
    void reachYoungLargeP(MinorWorker& w, void* obj, bool parent_old);
    /// Adds `e` to `w`'s private grey entries, publishing half of them when there are enough.
    void pushGreyP(MinorWorker& w, uint64_t e);
    /// Moves half of `w`'s private entries to its deque, if it has at least 64 and the deque looks empty: the oldest
    /// half in LIFO order, the newest in FIFO order.
    void publishHalfP(MinorWorker& w);
    /// Moves all of `w`'s private entries to its deque.
    void publishAllP(MinorWorker& w);
    /// Writes at `p` a filler of `bytes` bytes. `bytes` must be at least 8 and fit in the header's size field.
    static void writeFiller(char* p, size_t bytes);

    /// Returns whether an object with header `hdr` is promoted when copied: its age has reached the promotion age
    /// and it is neither pinned nor a builder.
    inline bool shouldPromote(const Header* hdr) const {
        return hdr->age >= promotion_age_ && !hdr->pin && !hdr->builder;
    }
    /// Evacuates every boxed field of `obj` for the serial minor.
    void scanObject(void *obj, OldGenSpace &oldgen, std::vector<void*> *promoted_objects);

    /// Returns false if `obj` is not a young large object. Otherwise reaches it, unless it was already reached this
    /// minor, and returns true; its address never changes. Reaching stamps it with the minor's colour and then either
    /// promotes it in place, if it is not a builder and has reached the promotion age, queuing it on
    /// `promoted_objects` (or `young_large_scan_` if that is null), or ages it unless it is a builder and queues it on
    /// `young_large_scan_`.
    bool reachYoungLarge(void* obj, OldGenSpace& oldgen,
                         std::vector<void*>* promoted_objects);
#if ECO_HEAP_VALIDATE
    /// Aborts if any young large object is unpinned, is a builder with a nonzero age, or lies outside the young
    /// large objects' bounding box.
    void validateYoungLarge(OldGenSpace& oldgen) const;
    /// Aborts if any object in `promoted` still refers to a nursery object or a young large object.
    void validatePromotedHaveNoYoungChildren(OldGenSpace& oldgen,
                                             const std::vector<void*>& promoted) const;
#endif

    // Two-pass list copying for the serial minor: the cells of a list are copied one after another, so the copy
    // of the list is contiguous, and their heads after.

    /// Copies the list cells starting at `ptr` one after another until it meets a cell that is not in from-space,
    /// is already copied, or is not a cell, updating `ptr` and each tail. Returns the first copy (in to-space or
    /// the old generation), or null if none was made. Sets `needs_head_pass` if any copied head refers to an object.
    void* evacuateListSpine(HPointer &ptr, OldGenSpace &oldgen,
                            std::vector<void*> *promoted_objects,
                            bool &needs_head_pass);

    /// Evacuates the boxed heads of the copied cells starting at `first_cons`, following tails while they lead to
    /// cells in to-space or the old generation.
    void evacuateListHeads(void* first_cons, OldGenSpace &oldgen,
                           std::vector<void*> *promoted_objects);

    friend class Allocator;
    friend class ThreadLocalHeap;
    friend class OldGenSpace;
    friend class NurserySpaceTestAccess;
};

// ============================================================================
// Test Access Helper
// ============================================================================

/// Access to a `NurserySpace`'s private state, for tests only.
class NurserySpaceTestAccess {
public:
    /// Joins and merges the pending tenure job now, as at the start of a minor.
    static void tenureFlush(NurserySpace& nursery, OldGenSpace& oldgen) {
        nursery.tenureJoin(oldgen, 0, nullptr);
    }
    /// Returns the region state, or null in semi-space mode.
    static RegionState* region(NurserySpace& nursery) { return nursery.rg_.get(); }

    /// Returns `NurserySpace::contains`.
    static bool contains(const NurserySpace& nursery, void* ptr) {
        return nursery.contains(ptr);
    }

    /// Returns `NurserySpace::bytesAllocated`.
    static size_t bytesAllocated(const NurserySpace& nursery) {
        return nursery.bytesAllocated();
    }

    /// Returns `NurserySpace::isInFromSpace`.
    static bool isInFromSpace(const NurserySpace& nursery, void* ptr) {
        return nursery.isInFromSpace(ptr);
    }

    /// Returns `NurserySpace::isInToSpace`.
    static bool isInToSpace(const NurserySpace& nursery, void* ptr) {
        return nursery.isInToSpace(ptr);
    }

    /// Calls `NurserySpace::clearToSpaceFreeRegion`.
    static void clearToSpaceFreeRegion(NurserySpace& nursery) {
        nursery.clearToSpaceFreeRegion();
    }

    // Semi-space extents (HEAP_042).

    /// Returns the capacity of one extent in bytes.
    static size_t capacity(const NurserySpace& nursery) {
        return nursery.from_capacity_bytes_;
    }

    /// Returns the start of from-space.
    static char* fromBase(const NurserySpace& nursery) { return nursery.fromBase(); }
    /// Returns the start of to-space.
    static char* toBase(const NurserySpace& nursery)   { return nursery.toBase(); }

    /// Returns the end of from-space's capacity.
    static char* fromEnd(const NurserySpace& nursery) {
        return nursery.fromBase() + nursery.from_capacity_bytes_;
    }

    /// Returns the start of the extent the bump pointer allocates in: from-space, or the current eden in region
    /// mode (which with eden flip alternates between two extents).
    static char* allocBase(const NurserySpace& nursery) {
        return nursery.rg_ ? nursery.rg_->eden_base : nursery.fromBase();
    }
    /// Returns the end of that extent's capacity.
    static char* allocEnd(const NurserySpace& nursery) {
        return nursery.rg_ ? nursery.rg_->eden_base + nursery.rg_->set.capacity : fromEnd(nursery);
    }

    /// Returns the capacity each extent may grow to.
    static size_t growthCeiling(const NurserySpace& nursery) {
        return nursery.growth_ceiling_bytes_;
    }

    /// Returns the slot index of the semi-space slice pair.
    static size_t sliceSlot(const NurserySpace& nursery) {
        return nursery.slice_.slot;
    }

    /// Returns whether from-space is the low extent.
    static bool fromIsLow(const NurserySpace& nursery) { return nursery.from_is_low_; }

    /// Calls `NurserySpace::checkAndGrow`.
    static void checkAndGrow(NurserySpace& nursery) { nursery.checkAndGrow(); }

    // Capacity checks covering several allocations (HEAP_041).

    /// Returns `NurserySpace::ensureHeadroom`.
    static bool ensureHeadroom(NurserySpace& nursery, size_t n) {
        return nursery.ensureHeadroom(n);
    }

    /// Calls `NurserySpace::failSoftUnclamp`.
    static void failSoftUnclamp(NurserySpace& nursery) {
        nursery.failSoftUnclamp();
    }

    /// Returns the bytes between the bump pointer and its limit, the quantity `ensureHeadroom` tests, or 0 when the
    /// limit is below the bump pointer.
    static size_t headroom(const NurserySpace& nursery) {
        const uintptr_t p = reinterpret_cast<uintptr_t>(nursery.bump_.ptr);
        const uintptr_t e = reinterpret_cast<uintptr_t>(nursery.bump_.end);
        return e >= p ? static_cast<size_t>(e - p) : 0;
    }

    /// Returns the bump pointer.
    static char* bumpPtr(const NurserySpace& nursery) { return nursery.bump_.ptr; }
    /// Returns the bump limit.
    static char* bumpEnd(const NurserySpace& nursery) { return nursery.bump_.end; }
    /// Sets the bump limit to `end`.
    static void setBumpEnd(NurserySpace& nursery, char* end) { nursery.bump_.end = end; }
#if P1_CENSUS_COMPILED
    /// Forces the survivor-write census on or off for `nursery`.
    static void setSurvivorWriteCensus(NurserySpace& nursery, bool on) {
        nursery.census_forced_ = on ? 1 : 0;
    }
    /// The survivor-write census's counts.
    struct CensusCounts { uint64_t checked, mismatched, skipped_builder, ylos_checked; };
    /// Returns the survivor-write census's counts.
    static CensusCounts survivorWriteCensusCounts();
    /// Returns how many changed survivors the census found with tag `tag`, `sub` (the constructor of a
    /// `Tag_Custom`, an id for a closure's evaluator, otherwise 0) and first changed word `word` (0xFFFF when the
    /// survivor was not copied).
    static uint64_t survivorWriteCensusHits(int tag, uint32_t sub, uint16_t word);
    /// Clears the survivor-write census's counts.
    static void resetSurvivorWriteCensus();
#endif

    /// Advances the bump pointer by `bytes` without allocating through `allocate`, so that a test can place it at
    /// an exact offset.
    static void bumpBy(NurserySpace& nursery, size_t bytes) {
        nursery.bump_.ptr += bytes;
    }

    // Fillers and object bytes (HEAP_068).

    /// Appends a filler of `bytes` bytes to the survivor prefix, as a parallel minor's unused LAB tail would be, and
    /// recomputes the bump limit. Must be called right after a minor; `bytes` must be a multiple of 8 and at least 8.
    static void appendFillerAfterMinor(NurserySpace& nursery, size_t bytes) {
        assert(nursery.bump_.ptr == nursery.survivor_end_ && bytes >= 8 && bytes % 8 == 0);
        Header* h = reinterpret_cast<Header*>(nursery.bump_.ptr);
        std::memset(h, 0, sizeof(Header));
        h->tag = Tag_Free;
        h->size = static_cast<u32>(bytes);
        nursery.bump_.ptr += bytes;
        nursery.survivor_end_ = nursery.bump_.ptr;
        nursery.filler_bytes_ += bytes;
        nursery.bump_.end = nursery.computeAllocEnd();
    }
    /// Returns the filler bytes in the survivor prefix.
    static size_t fillerBytes(const NurserySpace& nursery) { return nursery.filler_bytes_; }
    /// Returns `NurserySpace::objectBytesAllocated`.
    static size_t objectBytesAllocated(const NurserySpace& nursery) {
        return nursery.objectBytesAllocated();
    }
    /// Runs `checkAndGrow` as if a minor had copied `raw` bytes into to-space, `fillers` of them fillers.
    static void checkAndGrowAt(NurserySpace& nursery, size_t raw, size_t fillers) {
        nursery.copy_ptr_ = nursery.toBase() + raw;
        nursery.filler_bytes_to_ = fillers;
        nursery.checkAndGrow();
        nursery.filler_bytes_to_ = 0;
    }

    /// Sets the bump limit `headroom` bytes past the bump pointer, as if the collection threshold lay there.
    static void clampEnd(NurserySpace& nursery, size_t headroom) {
        nursery.bump_.end = nursery.bump_.ptr + headroom;
    }
};

// TLA-REGION(NSH.forEachYoung) begin
template <typename F>
size_t NurserySpace::forEachYoung(F&& f, size_t* bytes_out) {
    if (!rg_) return forEachSurvivor(f, bytes_out);
    assert(bump_.ptr == rg_->eden_base && "IM7: eden is not empty; the young walk is not exact");
    size_t n = 0, bytes = 0;
    auto walk = [&](char* lo, char* hi) {
        for (char* p = lo; p < hi;) {
            const size_t sz = getObjectSize(p);
#if ECO_HEAP_VALIDATE
            if (getHeader(p)->tag > Tag_Forward || sz == 0 || p + sz > hi) {
                std::fprintf(stderr, "[heap-validate] IM7: bad young object at %p (tag %u, size %zu)\n",
                             static_cast<void*>(p), (unsigned)getHeader(p)->tag, sz);
                std::fflush(stderr);
                std::abort();
            }
#endif
            if (getHeader(p)->tag != Tag_Free) {
                f(static_cast<void*>(p));
                ++n;
                bytes += sz;
            }
            p += sz;
        }
    };
    // Dead objects in these extents have normally already been turned into fillers, by a merge or by
    // zapDeadAfterMajor.
    // Only the builder area of the age-1 extent can hold live builders.
    for (unsigned i = 0; i < rg_->n_surv; ++i) {
        region::Extent& X = rg_->x[i];
        if (X.state == region::XState::Young) {
            walk(X.base, X.surv_top);
            if (X.age == 1) walk(X.bld_lo, X.bld_hi);
        } else if (X.state == region::XState::Tenuring) {
            walk(X.base, X.surv_top);
        }
    }
    if (bytes_out) *bytes_out = bytes;
    return n;
}
// TLA-REGION(NSH.forEachYoung) end

} // namespace Elm

#endif // ECO_NURSERYSPACE_H
