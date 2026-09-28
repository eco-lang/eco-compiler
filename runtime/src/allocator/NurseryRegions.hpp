#pragma once

// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md P§3.2-P§3.4,
// P§3.11; HEAP_069/HEAP_070): the region nursery's data structures.
//
// A heap owns n extents of one capacity at a power-of-two stride X in its
// slot block: eden (two alternating edens with eden flip) and three survivor
// extents that rotate through the roles fill -> fresh -> hand-over ->
// tenuring -> retire -> free. See NurseryRegion.cpp for the minor and the
// tenure job.

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

enum class XState : uint8_t { Free, Fresh, Tenuring };

// A pointer's role (P§3.4). Inside a minor: Eden, Hand, HandBuilders, Retire,
// Fill; between minors: Eden, Fresh, Tenuring. Everything else in the heap's
// slot block is Stale (a Free survivor extent, the quarantined eden, past
// capacity). NotMine = outside the slot block (old gen, permanent space,
// other heaps' nurseries).
enum class Role : uint8_t { NotMine, Eden, Hand, HandBuilders, Retire, Fill, Fresh, Tenuring, Stale };

inline const char* roleName(Role r) {
    switch (r) {
        case Role::NotMine: return "NotMine";
        case Role::Eden: return "Eden";
        case Role::Hand: return "Hand";
        case Role::HandBuilders: return "HandBuilders";
        case Role::Retire: return "Retire";
        case Role::Fill: return "Fill";
        case Role::Fresh: return "Fresh";
        case Role::Tenuring: return "Tenuring";
        case Role::Stale: return "Stale";
    }
    return "?";
}

struct Extent {
    char*    base = nullptr;          // slot_base + k * X
    unsigned k = 0;                   // index in the slot block
    XState   state = XState::Free;
    char*    surv_top = nullptr;      // survivors [base, surv_top): objects and Tag_Free fillers
    char*    bld_lo = nullptr;        // builders [bld_lo, bld_hi), filled bump-down
    char*    bld_hi = nullptr;        // == base + capacity when this extent was the fill
    uint32_t gen = 0;                 // shadow generation, bumped at each hand-over
    uint64_t gen_minor = 0;           // the minor that filled it (G_j: j)
    size_t   obj_bytes = 0;           // object bytes in [base, surv_top) (fillers excluded)
    size_t   bld_bytes = 0;           // object bytes in [bld_lo, bld_hi)
    size_t   hw = 0;                  // highest surv_top - base ever (RSS estimate)
    uint32_t class_count[NUM_SIZE_CLASSES] = {};   // survivor objects per size class (the grant input)
    std::vector<HPointer> lb_bodies;  // bodies whose header was copied into this extent (P§3.14)
    std::vector<void*>    ylos_gen;   // YLOS objects first reached (non-builder) at gen_minor

    void clearContents() {
        surv_top = base;
        bld_lo = bld_hi = base;
        obj_bytes = bld_bytes = 0;
        for (auto& c : class_count) c = 0;
        lb_bodies.clear();
        ylos_gen.clear();
    }
};

// Per-worker region state of a minor (merged in worker-index order).
struct RegionWorker {
    std::vector<void*>     S;          // Hand targets from roots / builders / hand-over YLOS
    std::vector<uint64_t*> H;          // slots (in fill copies / young YLOS) that point into Hand
    uint32_t class_count[NUM_SIZE_CLASSES] = {};
    std::vector<HPointer>  lb_bodies;  // bodies of headers copied into the fill this minor
    std::vector<void*>     ylos_gen;   // YLOS first reached (non-builder) this minor
    uint64_t resolved = 0;             // references into Retire resolved through its shadow
    uint64_t n_bld = 0, b_bld = 0;     // builder copies
    uint64_t n_fill = 0, b_fill = 0;   // survivor copies into the fill's survivor part
    uint64_t ylos_handover_reached = 0;
    uint64_t under16 = 0;              // copies < 16 bytes (L6 census)
    void reset() {
        S.clear();
        H.clear();
        for (auto& c : class_count) c = 0;
        lb_bodies.clear();
        ylos_gen.clear();
        resolved = n_bld = b_bld = n_fill = b_fill = ylos_handover_reached = under16 = 0;
    }
};

// The tenure job (P§3.11). Built at the end of the hand-over minor m (after
// the cycle decision), run in that pause (mode 1) or on the heap's tenure
// collector during epoch m (mode 2), joined and merged at the start of
// minor m+1 (or of a STW major, or at teardown).
struct TenureJob {
    enum class State : uint8_t { None, Built, Running, Done, Merged };
    State state = State::None;
    int x = -1;                       // survivor extent index (0..2) being tenured
    char* base = nullptr;
    char* surv_top = nullptr;
    uint32_t gen = 0;
    uint64_t* shadow = nullptr;       // the extent's shadow data (never moves)
    unsigned shadow_shift = 3;        // granule log2
    uint64_t hand_minor = 0;          // the minor that built it
    tenurework::SerialState st;       // starts, heal (kept for the merge), YLOS snapshot, progress
    const char* ylos_lo = nullptr;    // snapshot bounding box
    const char* ylos_hi = nullptr;
    OldGenSpace::TenureGrant grant;   // exact engine only
    bool grant_used = false;          // the exact engine allocated from it
    bool parallel_used = false;       // the parallel engine finished it (in a pause)
    bool conc_parallel = false;       // L3: B collector members are running it
    // Outputs, merged at the next tenureJoin.
    std::vector<HPointer> lb_promoted;
#if ENABLE_GC_STATS
    GCStats::MinorCopyCounts copies;  // promotion() per tenured object
#endif
    uint64_t busy_ns = 0, cpu_ns = 0;
    uint64_t stops = 0;
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    std::vector<void*> promoted_log;
#endif
    std::atomic<bool> stop{false};
    // Collector-side ranges (job-private copies: the collector reads no
    // mutator state).
    char* slot_lo = nullptr;
    char* slot_hi = nullptr;
};

// Stats for the "Region nursery / tenuring" block (P§3.20).
using RegionStats = RegionTenureStats;

}  // namespace region

// Everything the region nursery owns (NurserySpace::rg_; null in legacy mode).
struct RegionState {
    NurserySliceSet set;
    unsigned n_ext = 4;
    bool flip = false;
    unsigned eden_k[2] = {0, 0};
    unsigned eden_cur = 0;
    char* eden_base = nullptr;
    char* eden_dirty[2] = {nullptr, nullptr};   // bump high-water per eden since it was last cleared
    region::Extent x[3];
    ReservedArray<uint64_t> shadow[3];
    unsigned shadow_shift = 3;
    int fill = -1, hand = -1, retire = -1;      // valid inside a minor
    uint8_t role_of_k[8] = {};
    size_t stride_log2 = 0;
    size_t stride_mask = 0;
    size_t hand_bld_off = SIZE_MAX;             // HandBuilders start offset of the Hand extent
    size_t S_m = 0;                             // object bytes survived at the last minor
    std::atomic<char*> bld_bottom{nullptr};     // the fill's builder bump (down)
    char* fill_base = nullptr;
    char* fill_end = nullptr;
    region::TenureJob job;
    std::vector<region::RegionWorker> rw;
    // The start set and heal list of the minor that just ended (the next
    // job's inputs; moved into it by tenureLaunch).
    std::vector<void*> pend_S;
    std::vector<uint64_t*> pend_H;
    OldGenSpace* tenure_og = nullptr;           // for the collector's job
    // The hand-over snapshot of generation-(m-1) YLOS for this minor (sorted).
    std::vector<tenurework::YlosEntry> hand_ylos;
    std::vector<uint8_t> hand_ylos_reached;
    region::RegionStats rs;
    uint64_t minor_seq = 0;
    uint64_t last_minor_end_ns = 0;
    std::unique_ptr<gc::GCBackgroundGang> collector;
    bool in_minor = false;
#if P1_CENSUS_COMPILED
    struct CensusObj { char* obj; uint32_t size; uint64_t hash; uint8_t builder; };
    std::vector<CensusObj> census;
    uint64_t census_epoch = 0;
#endif

    region::Role roleOf(const void* p) const {
        const uintptr_t d = reinterpret_cast<uintptr_t>(p) - reinterpret_cast<uintptr_t>(set.slot_base);
        if (d >= (static_cast<uintptr_t>(n_ext) << stride_log2)) return region::Role::NotMine;
        const unsigned k = static_cast<unsigned>(d >> stride_log2);
        const size_t off = d & stride_mask;
        if (off >= set.capacity) return region::Role::Stale;
        const region::Role r = static_cast<region::Role>(role_of_k[k]);
        if (r == region::Role::Hand && off >= hand_bld_off) return region::Role::HandBuilders;
        return r;
    }
    bool contains(const void* p) const { return roleOf(p) != region::Role::NotMine; }
    int extentOf(const void* p) const {   // survivor extent index (0..2) or -1
        const uintptr_t d = reinterpret_cast<uintptr_t>(p) - reinterpret_cast<uintptr_t>(set.slot_base);
        if (d >= (static_cast<uintptr_t>(n_ext) << stride_log2)) return -1;
        const unsigned k = static_cast<unsigned>(d >> stride_log2);
        for (int i = 0; i < 3; ++i) if (x[i].k == k) return i;
        return -1;
    }
    uint64_t* shadowWord(int xi, const void* obj) {
        const size_t i = static_cast<size_t>(static_cast<const char*>(obj) - x[xi].base) >> shadow_shift;
        return shadow[xi].data() + i;
    }
    void rebuildRoles(bool in_minor_roles);
};

}  // namespace Elm
