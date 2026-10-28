#pragma once

// The data a heap's region nursery keeps: where its extents are, what each one is being used for, what a minor
// collection hands to the next tenure job, and that job.
//
// In region mode a heap's nursery is a fixed number of extents of equal capacity in one slot of the nursery
// region, each starting a power-of-two stride after the one before (`NurserySliceSet`). One or two of them are
// eden, where the mutator allocates. The other k + 2, where k is the tenure age (1 to 3,
// `HeapConfig::regionTenureAge`), are survivor extents. A minor collection copies what survives in eden into a
// survivor extent and never promotes. Survivors are promoted to the old generation later, a whole extent at a
// time, by a tenure job.
//
// A survivor extent is reused in a fixed rotation. Writing m for the current minor collection:
//
// - The minor copies eden's live objects into a Free extent, the fill (generation m). Its survivor part grows up
//   from the start of the extent; its builder area, which holds objects still under construction, grows down
//   from the end of the extent's capacity.
// - When the minor ends the fill becomes Young with age 1, and every other Young extent ages by one.
// - The Young extent whose age is k when minor m starts, the hand-over extent (generation m - k), becomes
//   Tenuring when the minor ends, and a tenure job is launched to promote its live objects.
// - At the next minor that extent, now tenured, is the retiring extent (generation m - k - 1 seen from that
//   minor). References into it are redirected to the promoted copies, and it becomes Free.
//
// Between minors at most k + 1 survivor extents are in use, so one is Free for the next fill.
//
// With two eden extents (eden flip), eden alternates between them at each minor, so the eden just evacuated
// lies unused until the next minor. With one, eden is reused in place.
//
// The objects a tenure job promotes are visible to Elm while it runs, so it may not write them. Where each one
// was copied is kept off the object, in the extent's shadow: an array of shadow entries, one per granule, whose
// format `tenurework` (TenureWork.hpp) defines. Each use of an extent as Tenuring gets a new shadow generation,
// so entries left from earlier uses read as unvisited.
//
// Nearly every decision a region minor makes depends on what a nursery address is: eden, the fill, the
// hand-over extent, and so on. `RegionState::roleOf` answers that in constant time from a table indexed by
// extent, and `region::Role` lists the answers.
//
// The operations on this data are members of `NurserySpace`, which owns the `RegionState`: the minor is in
// NurseryRegion.cpp and the tenure job in NurseryTenure.cpp. HEAP_069 and HEAP_070 state the rules.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include "AllocatorCommon.hpp"
#include "OldGenSpace.hpp"
#include "P1Census.hpp"
#include "ReservedArray.hpp"
#include "TenureWork.hpp"

namespace Elm {

namespace gc { class GCBackgroundGang; }

namespace region {

/// The largest number of survivor extents a heap can have: k + 2 for the largest tenure age, 3.
constexpr int kMaxSurv = 5;

/// Where a survivor extent is in its rotation.
///
/// The fill keeps the state `Free` until its minor ends.
enum class XState : uint8_t { Free, Young, Tenuring };

/// What a nursery address is, as `RegionState::roleOf` reports it.
///
/// Which roles occur depends on whether a minor is running.
///
/// During a minor: `Eden` is the current eden extent. `Fill` is the fill. `Hand` is the hand-over extent.
/// `Retire` is the retiring extent. `Age` is any other Young extent. `PrevBuilders` is the builder area of the
/// previous fill, the Young extent of age 1, which the minor evacuates like eden; with k = 1 that extent is the
/// hand-over extent.
///
/// Between minors: `Eden` is the current eden extent. `Fresh` is the Young extent of age 1. `Aged` is a Young
/// extent of age 2 or more. `Tenuring` is the Tenuring extent.
///
/// At any time, `NotMine` is an address outside this heap's extents: the old generation, permanent space,
/// another heap's nursery. `Stale` is the rest of this heap's extents: a Free survivor extent, the eden extent
/// not in use, and any offset at or past an extent's capacity. Apart from the previous fill's during a minor, a
/// builder area has the role of its extent.
enum class Role : uint8_t { NotMine, Eden, Hand, PrevBuilders, Age, Retire, Fill, Fresh, Aged, Tenuring, Stale };

/// Returns the name of the enumerator `r`, for diagnostics, or "?" for a value outside the enumeration.
inline const char* roleName(Role r) {
    switch (r) {
        case Role::NotMine: return "NotMine";
        case Role::Eden: return "Eden";
        case Role::Hand: return "Hand";
        case Role::PrevBuilders: return "PrevBuilders";
        case Role::Age: return "Age";
        case Role::Aged: return "Aged";
        case Role::Retire: return "Retire";
        case Role::Fill: return "Fill";
        case Role::Fresh: return "Fresh";
        case Role::Tenuring: return "Tenuring";
        case Role::Stale: return "Stale";
    }
    return "?";
}

/// One survivor extent: its place among the heap's extents, its place in the rotation, and what the minor that
/// last filled it recorded about its contents.
///
/// The survivor part is [`base`, `surv_top`) and the builder area [`bld_lo`, `bld_hi`). Every member is public,
/// and nothing checks that the two ranges lie inside the extent.
struct Extent {
    char*    base = nullptr;          ///< The extent's first byte.
    unsigned k = 0;                   ///< The extent's index among all the heap's extents, eden included.
    XState   state = XState::Free;
    unsigned age = 0;                 ///< For a Young extent, minors ended since it was the fill (1 to k); else 0.
    char*    surv_top = nullptr;      ///< The end of the survivor part: survivors and `Tag_Free` fillers.
    char*    bld_lo = nullptr;        ///< The start of the builder area, which was filled downward.
    char*    bld_hi = nullptr;        ///< The end of the extent's capacity at the minor that filled it.
    /// The shadow generation of the extent's latest use as Tenuring, 0 before its first. Kept modulo 2^21, it never
    /// returns to 0: on wrap the shadow is cleared and the generation starts again at 1.
    uint32_t gen = 0;
    uint64_t gen_minor = 0;           ///< `RegionState::minor_seq` of the minor that filled the extent.
    size_t   obj_bytes = 0;           ///< Object bytes in the survivor part, fillers excluded.
    size_t   bld_bytes = 0;           ///< Object bytes in the builder area.
    size_t   hw = 0;                  ///< The largest `surv_top - base` over every use of the extent, for stats.
    /// Survivor objects per old-generation size class in the survivor part. The tenure job's grant is sized from it.
    uint32_t class_count[NUM_SIZE_CLASSES] = {};
    /// The bodies of the large String and Bytes headers copied into the survivor part.
    std::vector<HPointer> lb_bodies;
    /// The young large objects that the filling minor reached first, and not as builders. They age with the
    /// extent's survivors.
    std::vector<void*>    ylos_gen;
    /// The tenure job's mark bitmap over the survivor part, one bit per 8 bytes, used while the extent ages
    /// (age 2 or more at a launch). A launch sizes and clears it, and the job keeps a pointer to its data.
    std::vector<uint64_t> mark_bits;

    /// Empties the extent: no survivors, an empty builder area at `base`, zero counts, and no large-body or
    /// young-large-object records. The other members are left as they are.
    void clearContents() {
        surv_top = base;
        bld_lo = bld_hi = base;
        obj_bytes = bld_bytes = 0;
        for (auto& c : class_count) c = 0;
        lb_bodies.clear();
        ylos_gen.clear();
    }
};

/// What one worker of a region minor records, merged into the fill and the heap's lists in worker-index order
/// when the drain ends.
struct RegionWorker {
    /// Objects of the hand-over extent referred to by roots, by builders, or by young large objects of the
    /// hand-over generation. The tenure job starts from them.
    std::vector<void*>     S;
    /// Slots that point into the hand-over extent, in survivor copies or in young large objects reached as
    /// young. The merge rewrites them to the promoted copies.
    std::vector<uint64_t*> H;
    /// Objects in the ageing extents, or young large objects of the ageing generations, that this minor reached.
    /// The tenure job's mark starts from them.
    std::vector<void*>     SA;
    uint32_t class_count[NUM_SIZE_CLASSES] = {};   ///< As `Extent::class_count`, for this worker's copies.
    std::vector<HPointer>  lb_bodies;  ///< As `Extent::lb_bodies`, for this worker's copies.
    std::vector<void*>     ylos_gen;   ///< As `Extent::ylos_gen`, for this worker's first reaches.
    uint64_t resolved = 0;             ///< References into the retiring extent redirected through its shadow.
    uint64_t n_bld = 0, b_bld = 0;     ///< Builder copies: count and bytes.
    uint64_t n_fill = 0, b_fill = 0;   ///< Copies into the fill's survivor part: count and bytes.
    uint64_t ylos_handover_reached = 0;   ///< Young large objects of the hand-over generation first reached.
    uint64_t under16 = 0;              ///< Survivor copies smaller than 16 bytes.
    /// Empties the lists and zeroes the counts, for a new minor.
    void reset() {
        S.clear();
        H.clear();
        SA.clear();
        for (auto& c : class_count) c = 0;
        lb_bodies.clear();
        ylos_gen.clear();
        resolved = n_bld = b_bld = n_fill = b_fill = ylos_handover_reached = under16 = 0;
    }
};

/// The heap's tenure job: the promotion of one Tenuring extent's live objects to the old generation, with its
/// inputs, its progress and its outputs. One record is reused for every job.
///
/// `NurserySpace::tenureLaunch` builds the job when a minor has handed an extent over. It runs the job at once,
/// in that pause, under `tenure_mode` 1, and also under mode 2 when the old generation cannot grant the blocks
/// the extent needs. Otherwise it launches the job on the heap's collector gang, where it runs while Elm code
/// does. `NurserySpace::tenureJoin` waits for the job or finishes it in a pause, then merges its outputs into
/// the heap; `NurserySpace::tenureTeardown` does the same without rewriting the heal slots. A minor that starts
/// with a retiring extent whose job is not Merged aborts.
///
/// While the job runs on the collector gang, its threads use the record; `tenureJoin` joins the gang before it
/// reads the outputs.
struct TenureJob {
    /// Where the job is in its life. `Built` is seen only inside `tenureLaunch`, while the inputs are filled
    /// in. `Done` means finished with outputs not yet merged. After `Merged`, `x`, `gen` and `shadow` still
    /// describe the Tenuring extent, so references into it can be redirected until it retires.
    enum class State : uint8_t { None, Built, Running, Done, Merged };
    State state = State::None;
    int x = -1;                       ///< The index in `RegionState::x` of the extent tenured; -1 before the first job.
    // The tenured extent's start, survivor-part end and shadow generation, copied at launch.
    char* base = nullptr;
    char* surv_top = nullptr;
    uint32_t gen = 0;
    /// The extent's shadow entries, `RegionState::shadow[x].data()`, which stay at one address for as long as
    /// the `RegionState` lives. Null before the first job.
    uint64_t* shadow = nullptr;
    unsigned shadow_shift = 3;        ///< log2 of the shadow granule, in bytes.
    uint64_t hand_minor = 0;          ///< `RegionState::minor_seq` at launch; stops a second launch in one minor.
    /// The exact engine's state: inputs (start objects, heal slots, young-large-object snapshots), progress and
    /// counts. The heal slots are kept for the merge.
    tenurework::SerialState st;
    /// The lowest start and highest end of the young large objects in `st.ylos`; `ylos_lo` is null when there
    /// are none. A cheap test before a search.
    const char* ylos_lo = nullptr;
    const char* ylos_hi = nullptr;
    /// The old-generation blocks granted for this job's copies. The exact engine and the collector members of a
    /// parallel job allocate from it. The pause-only parallel engine returns what is left of it before it runs.
    OldGenSpace::TenureGrant grant;
    bool grant_used = false;          ///< Set when the exact engine has run.
    bool parallel_used = false;       ///< Set when a parallel engine (pause or collector) has finished the job.
    bool conc_parallel = false;       ///< Set when several collector members run the job; cleared when it is finished.
    // Outputs and counts, read at the merge.
    std::vector<HPointer> lb_promoted;   ///< The bodies of the large headers this job promoted.
#if ENABLE_GC_STATS
    GCStats::MinorCopyCounts copies;  ///< Counts of the copies the job made.
#endif
    uint64_t busy_ns = 0, cpu_ns = 0;   ///< Time spent running the job: wall and collector CPU, in nanoseconds.
    uint64_t stops = 0;               ///< Times the exact engine returned because it was asked to stop.
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    std::vector<void*> promoted_log;   ///< Every copy the job made, for the checks at the merge.
#endif
    /// Set to ask the exact engine on the collector to stop between items; cleared at launch.
    std::atomic<bool> stop{false};
    // This heap's extents, as [slot_lo, slot_hi), copied at launch so that the job's threads test an address
    // against the job record and not against `RegionState`.
    char* slot_lo = nullptr;
    char* slot_hi = nullptr;
    /// One ageing extent as the job's mark sees it: its survivor part [`base`, `top`) and its mark bitmap,
    /// which is `Extent::mark_bits.data()` and stays valid until the next launch.
    struct AgeRange { char* base; char* top; uint64_t* bits; };
    /// The ageing extents, `age[0]` to `age[n_age - 1]`: the Young extents of age 2 or more at launch.
    AgeRange age[kMaxSurv] = {};
    int n_age = 0;
    /// The lowest start and highest end of the young large objects in `st.age_ylos`, as `ylos_lo` and `ylos_hi`
    /// are for `st.ylos`.
    const char* age_ylos_lo = nullptr;
    const char* age_ylos_hi = nullptr;
};

/// The region nursery's statistics. Another name for `RegionTenureStats`, not a new type.
using RegionStats = RegionTenureStats;

}  // namespace region

/// Everything a heap's region nursery owns: the extents' geometry, the survivor extents and their shadows, the
/// role table, the state of a minor in progress, what a minor hands to the next tenure job, the job, and the
/// collector gang that runs it.
///
/// `NurserySpace` owns it, and has none in semi-space mode. The defaults are placeholders: the owning
/// `NurserySpace` sets the geometry when it creates the state. The state cannot be copied or moved. While a
/// job runs, the collector gang's threads use `job`, `tenure_og`, the shadows and the ageing extents' mark
/// bitmaps. The workers of a minor each write their own `rw` entry, take builder space through `bld_bottom`,
/// and set `hand_ylos_reached` under a lock `NurserySpace` holds.
struct RegionState {
    NurserySliceSet set;                        ///< The address range of all `n_ext` extents.
    unsigned n_ext = 4;                         ///< The number of extents: `n_surv` survivor extents plus the edens.
    unsigned tenure_age = 1;                    ///< k: the age at which a Young extent is handed over.
    unsigned n_surv = 3;                        ///< The number of survivor extents, k + 2.
    bool flip = false;                          ///< Whether two eden extents alternate.
    unsigned eden_k[2] = {0, 0};                ///< The extent indices of the two edens; both 0 without flip.
    unsigned eden_cur = 0;                      ///< Which of `eden_k` is the current eden.
    char* eden_base = nullptr;
    /// The highest address each eden has been allocated up to; it is lowered only when edens are cleared.
    char* eden_dirty[2] = {nullptr, nullptr};
    region::Extent x[region::kMaxSurv];         ///< The survivor extents; the first `n_surv` are in use.
    /// Each survivor extent's shadow, one entry per granule of its stride, reserved once and committed to cover
    /// the extent's capacity as it grows.
    ReservedArray<uint64_t> shadow[region::kMaxSurv];
    unsigned shadow_shift = 3;                  ///< log2 of the shadow granule, in bytes.
    /// The indices in `x` of the fill, the hand-over extent and the retiring extent during a minor. -1 between
    /// minors, and for a role no extent has in this minor.
    int fill = -1, hand = -1, retire = -1;
    /// The index in `x` of the previous fill, the Young extent of age 1, during a minor; with k = 1 it equals
    /// `hand`. -1 between minors or when there is none.
    int prev = -1;
    /// The role of each extent, indexed by extent index, as `region::Role` values. Eight entries cover the
    /// largest heap, 7 extents.
    uint8_t role_of_k[8] = {};
    size_t stride_log2 = 0;
    size_t stride_mask = 0;
    unsigned prev_k = ~0u;                      ///< The extent index of `prev` during a minor, else `~0u`.
    /// The offset of `prev`'s builder area within its extent during a minor, else `SIZE_MAX`.
    size_t prev_bld_off = SIZE_MAX;
    /// The object bytes the last minor left in the fill, survivors and builders. Eden's allocation limit and the
    /// decision to grow are computed from it.
    size_t S_m = 0;
    /// During a minor, the lowest address of the fill's builder area so far; workers take builder space by
    /// subtracting from it.
    std::atomic<char*> bld_bottom{nullptr};     // the fill's builder bump (down)
    // The fill's first byte and the end of its capacity, during a minor.
    char* fill_base = nullptr;
    char* fill_end = nullptr;
    region::TenureJob job;
    /// One record per minor worker, indexed by worker, sized for the largest worker count.
    std::vector<region::RegionWorker> rw;
    // What the minor that just ended found for the next tenure job: its start objects, heal slots and the
    // sources of the ageing extents' mark. `NurserySpace::tenureLaunch` moves them into the job, or clears
    // them when no extent was handed over.
    std::vector<void*> pend_S;
    std::vector<uint64_t*> pend_H;
    std::vector<void*> pend_SA;
    /// The old generation the current job promotes into, set at launch; null before the first. It must outlive
    /// the job.
    OldGenSpace* tenure_og = nullptr;
    /// The young large objects of the hand-over generation still live when this minor started, sorted by
    /// address, and beside it which of them this minor has reached.
    std::vector<tenurework::YlosEntry> hand_ylos;
    std::vector<uint8_t> hand_ylos_reached;
    /// The young large objects, still live when this minor started, of every Young extent other than the
    /// hand-over extent, sorted by address.
    std::vector<tenurework::YlosEntry> age_ylos;
    region::RegionStats rs;
    uint64_t minor_seq = 0;                     ///< The number of region minors started, the current one included.
    /// When the last minor ended, by `GCStats::nowSinceProcessStartNs`; 0 before the first.
    uint64_t last_minor_end_ns = 0;
    /// The tenure collector gang, created at the first launch onto a collector; null until then.
    std::unique_ptr<gc::GCBackgroundGang> collector;
    bool in_minor = false;
#if P1_CENSUS_COMPILED
    /// One object recorded by the census: its address, size, content hash, and whether it was a builder.
    struct CensusObj { char* obj; uint32_t size; uint64_t hash; uint8_t builder; };
    /// The survivors hashed at the end of the last minor, checked again before the next merge to detect a
    /// write to an object that has survived a minor.
    std::vector<CensusObj> census;
    uint64_t census_epoch = 0;                  ///< The old generation's major epoch when `census` was recorded.
#endif

    /// Returns the role of address `p`, which may be any address, in constant time. An offset at or past an
    /// extent's capacity is `Stale`, and during a minor an address at or above `prev_bld_off` in the previous
    /// fill is `PrevBuilders`. Anything else in the extents takes its extent's entry in `role_of_k`.
    region::Role roleOf(const void* p) const {
        const uintptr_t d = reinterpret_cast<uintptr_t>(p) - reinterpret_cast<uintptr_t>(set.slot_base);
        if (d >= (static_cast<uintptr_t>(n_ext) << stride_log2)) return region::Role::NotMine;
        const unsigned k = static_cast<unsigned>(d >> stride_log2);
        const size_t off = d & stride_mask;
        if (off >= set.capacity) return region::Role::Stale;
        const region::Role r = static_cast<region::Role>(role_of_k[k]);
        if (k == prev_k && off >= prev_bld_off) return region::Role::PrevBuilders;
        return r;
    }
    /// Returns whether `p` lies in this heap's extents, at any offset within their strides.
    bool contains(const void* p) const { return roleOf(p) != region::Role::NotMine; }
    /// Returns the index in `x` of the survivor extent whose stride contains `p`, or -1 if none does. An offset
    /// past the extent's capacity still counts as inside it.
    int extentOf(const void* p) const {
        const uintptr_t d = reinterpret_cast<uintptr_t>(p) - reinterpret_cast<uintptr_t>(set.slot_base);
        if (d >= (static_cast<uintptr_t>(n_ext) << stride_log2)) return -1;
        const unsigned kk = static_cast<unsigned>(d >> stride_log2);
        for (unsigned i = 0; i < n_surv; ++i) if (x[i].k == kk) return static_cast<int>(i);
        return -1;
    }
    /// Returns the index in `x` of the Young extent of age 1, the fill of the last minor, or -1 if there is none.
    int freshIndex() const {
        for (unsigned i = 0; i < n_surv; ++i)
            if (x[i].state == region::XState::Young && x[i].age == 1) return static_cast<int>(i);
        return -1;
    }
    /// Returns the shadow entry for the object at `obj` in survivor extent `xi`. `obj` must lie within that
    /// extent's capacity; nothing checks it. The pointer stays valid as long as the `RegionState`.
    uint64_t* shadowWord(int xi, const void* obj) {
        const size_t i = static_cast<size_t>(static_cast<const char*>(obj) - x[xi].base) >> shadow_shift;
        return shadow[xi].data() + i;
    }
    /// Rebuilds `role_of_k`, `prev_k` and `prev_bld_off` from the extents. With `in_minor_roles`, the roles
    /// are those of a minor, taken from `fill`, `hand`, `retire` and `prev`, which must already be set;
    /// without it, they are those between minors. The eden not in use and every Free extent become `Stale`.
    void rebuildRoles(bool in_minor_roles);
};

}  // namespace Elm
