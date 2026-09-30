// M4 (plans/threaded-gc-tla-M4-promotion-bitmap.md §8): parallel promotion
// while a lazy sweep is pending. The register entries CR-001 (gc_phase_ written
// under promo_mu_, read by other workers without it), CR-002 (the gap sweep's
// plain word read / clearBit against a stashed cell's fetch_or), CR-014 (the
// tail completion's onSweepComplete on a worker) and CR-016 (the empty-block
// flip under promo_mu_) all need a sweep inside a parallel minor, which the
// other heap_driver scenarios never run.
//
//   gc-heap-tsan promo [seed [rounds [workers [jitter_us [exact [sweep_bytes]]]]]]
//
// (TSan build.) exact = 0 leaves out the exact-size Arrays (CR-016 corrupts the
// heap within a round or two, which hides the other entries); jitter_us = 0 is
// no jitter; sweep_bytes is the sweep slice (default 144: a few gap-sweep
// iterations per ladder hold; 4096 and up complete the sweep inside minors).
// PROMO_DEBUG=1 prints the sweep's progress around every minor.
//
// Each round builds an old population of several size classes (Ints 16 B,
// Tuple2 24 B, Tuple3 32 B, short strings), promotes it, drops most of it (so
// blocks are demoted to mixed and gap-swept; some die whole and the min-heap
// floor keeps them), runs a STW major (a lazy sweep is now pending) and then
// runs parallel minors that promote young trees (Tuple2 nodes over leaves of
// every class, so the gang's workers steal subtrees and promote in parallel),
// with a pointer-bearing Array of exactly alloc_buffer_size bytes as a leaf now
// and then (the exact-size promotion path, CR-016). The sweep budgets are small
// (144 bytes), so each ladder hold sweeps a few gap-sweep iterations; the
// pre-drain slice is off, so the workers do the sweeping. Every rooted value
// (every tree node and leaf) is checked after each minor.
//
// Odd rounds have a short backlog under a larger promotion volume.
//
// Not part of the default `gc-heap-tsan` run (which must print "heap_driver
// PASS" with no TSan warning): the scenario is expected to fail under TSan
// until CR-002, CR-001 (sweep_bytes >= 4096) and CR-016 (exact = 1) are fixed,
// and the validate-only V11 walk in lazySweep races too (M4 AUDIT.md); a debug
// assert on the ladder's bag rung can abort it. It runs only when the first
// argument is `promo`.
#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "ThreadLocalHeap.hpp"
#include "TlaTrace.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

using namespace Elm;

namespace {

[[noreturn]] void failP(const char* w, long long v = -1) {
    std::fprintf(stderr, "promo_sweep FAIL: %s %lld\n", w, v);
    std::exit(1);
}

struct PRoot {
    Allocator& a;
    HPointer h;
    int64_t id;   // the value encoded in the object
    int kind;     // 0 Int, 1 Tuple2, 2 Tuple3, 3 String, 4 Array
    PRoot(Allocator& al, HPointer v, int64_t i, int k) : a(al), h(v), id(i), kind(k) {
        a.getRootSet().addRoot(&h);
    }
    ~PRoot() { a.getRootSet().removeRoot(&h); }
};

constexpr int64_t kTag = 0x5EED0000;

HPointer makeObj(int kind, int64_t id, size_t array_cap) {
    switch (kind) {
        case 0: return alloc::allocInt(kTag + id);
        case 1: return alloc::tuple2(alloc::unboxedInt(kTag + id), alloc::unboxedInt(id), 0x5);
        case 2: return alloc::tuple3(alloc::unboxedInt(kTag + id), alloc::unboxedInt(id),
                                     alloc::unboxedInt(-id), 0x15);
        case 3: {
            const size_t len = 1 + static_cast<size_t>(id % 13);
            std::vector<u16> buf(len, static_cast<u16>('a' + id % 26));
            buf[0] = static_cast<u16>('A' + id % 26);
            return alloc::allocString(buf.data(), len);
        }
        default: return alloc::allocArray(array_cap);
    }
}

// A young tree for the TSan stress: Tuple2 nodes with two boxed fields over
// leaves of every class (makeObj's kinds 0-3), the first leaf an Array of
// exactly alloc_buffer_size bytes when `array_cap` is non-zero. Only the root
// is a RootSet root: worker 0 copies what the roots point at before the gang
// starts, so directly rooted young values would all be promoted by worker 0;
// the gang's workers steal subtrees and promote the rest in parallel.
HPointer youngMixed(int depth, int64_t& next, std::mt19937_64& rng, size_t& array_cap) {
    if (depth == 0) {
        if (array_cap != 0) {
            const size_t cap = array_cap;
            array_cap = 0;
            return makeObj(4, next++, cap);
        }
        const int kind = static_cast<int>(rng() % 4);
        return makeObj(kind, next++, 0);
    }
    HPointer l = youngMixed(depth - 1, next, rng, array_cap);
    PRoot keep_l(Allocator::instance(), l, 0, 0);   // rooted while the right side allocates
    HPointer r = youngMixed(depth - 1, next, rng, array_cap);
    return alloc::tuple2(alloc::boxed(keep_l.h), alloc::boxed(r), 0);
}

// youngMixed's shape and every leaf's self-check (makeObj's encodings).
void checkMixed(Allocator& a, HPointer p, int depth) {
    void* o = a.resolve(p);
    if (!o) failP("a tree node vanished", depth);
    const Header* h = getHeader(o);
    if (depth > 0) {
        if (h->tag != Tag_Tuple2 || h->unboxed != 0) failP("a tree node changed", depth);
        checkMixed(a, static_cast<Tuple2*>(o)->a.p, depth - 1);
        checkMixed(a, static_cast<Tuple2*>(o)->b.p, depth - 1);
        return;
    }
    bool ok = false;
    switch (h->tag) {
        case Tag_Int: ok = static_cast<ElmInt*>(o)->value >= kTag; break;
        case Tag_Tuple2: {
            const Tuple2* t = static_cast<Tuple2*>(o);
            ok = t->a.i == kTag + t->b.i;
            break;
        }
        case Tag_Tuple3: {
            const Tuple3* t = static_cast<Tuple3*>(o);
            ok = t->a.i == kTag + t->b.i && t->c.i == -t->b.i;
            break;
        }
        case Tag_String:
        case Tag_Array: ok = true; break;
        default: break;
    }
    if (!ok) failP("a tree leaf changed", h->tag);
}

void check(Allocator& a, const PRoot& r) {
    void* o = a.resolve(r.h);
    if (!o) failP("a rooted value vanished", r.id);
    const Header* h = getHeader(o);
    switch (r.kind) {
        case 0:
            if (h->tag != Tag_Int || static_cast<ElmInt*>(o)->value != kTag + r.id)
                failP("a rooted Int changed", r.id);
            break;
        case 1:
            if (h->tag != Tag_Tuple2 || static_cast<Tuple2*>(o)->a.i != kTag + r.id ||
                static_cast<Tuple2*>(o)->b.i != r.id)
                failP("a rooted Tuple2 changed", r.id);
            break;
        case 2:
            if (h->tag != Tag_Tuple3 || static_cast<Tuple3*>(o)->a.i != kTag + r.id ||
                static_cast<Tuple3*>(o)->c.i != -r.id)
                failP("a rooted Tuple3 changed", r.id);
            break;
        case 3:
            if (h->tag != Tag_String) failP("a rooted String changed", r.id);
            break;
        case 5:
            if (h->tag != Tag_Tuple2) failP("a rooted tree changed", r.id);
            break;
        case 6:
            checkMixed(a, r.h, static_cast<int>(r.id));
            break;
        default:
            if (h->tag != Tag_Array) failP("a rooted Array changed", r.id);
            break;
    }
}

}  // namespace

// The heap geometry and sweep knobs shared by the TSan stress and the M4 trace
// scenario (promo_trace in this file, trace builds only).
HeapConfig promoConfig(unsigned workers) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 4096;              // small blocks: few cells per block
    cfg.large_object_threshold = 2048;
    cfg.nursery_block_count = 64;
    cfg.nursery_max_block_count = 64;
    cfg.gc_minor_threads = workers;
    cfg.minor_lab_bytes = 4096;
    cfg.minor_parallel_min_bytes = 0;          // every minor is parallel
    cfg.initial_old_gen_size = 512 * 1024;     // the min-heap floor keeps all-dead blocks
    cfg.max_heap_size = 64ULL << 20;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = 0;
    cfg.incremental_mark = false;              // STW majors: no cycle overlaps the sweep
    cfg.nursery_regions = 0;                   // the legacy parallel minor (phase 6)
    cfg.promotion_age = 1;
    cfg.small_class_heap_budget_bytes = 0;     // no virgin block before sweep-on-demand
    cfg.minor_sweep_divisor = 0;               // no pre-drain slice: the workers sweep
    cfg.demote_live_fraction = 0.5;            // blocks up to half live are gap-swept (mixed)
    // A few gap-sweep iterations per slice, one slice per ladder hold: a hold
    // pushes more cells than it pops, so later holds batch-pop 1 + 16 cells into
    // the workers' stashes (finalized outside promo_mu_: CR-002's writer).
    cfg.sweep_work_budget = 144;
    cfg.initial_sweep_budget = 144;
    cfg.max_sweep_bytes_per_alloc = 144;
    cfg.max_sweep_bytes_hard = 144;
    cfg.panic_sweep_slice_bytes = 144;
    return cfg;
}

int promoSweepMain(int argc, char** argv) {
    const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 1;
    const int rounds = argc > 2 ? std::atoi(argv[2]) : 40;
    const unsigned workers = argc > 3 ? static_cast<unsigned>(std::atoi(argv[3])) : 4;
    if (argc > 4) setenv("ECO_GC_HELPER_JITTER_US", argv[4], 1);
    // Register CR-014 (plans/threaded-gc-register-repros-impl.md Step 29):
    // tail = 1 aims the workers' sweep-on-demand at the TAIL completion (an
    // 8-byte slice that ends exactly at the last block's end: onSweepComplete
    // on a worker inside the parallel minor). No exact Arrays, 8-byte slices, a
    // 32 MiB floor (no release swap-removes the last block), a fresh live bag
    // page last at every major, and the mutator pre-sweeps up to that page's
    // final slice, so the first worker ladder that sweeps on demand runs it
    // (before it could append a virgin block, which would move the completion
    // to the in-loop path).
    const bool tail = argc > 7 && std::atoi(argv[7]) != 0;
    const bool exact_arrays = !tail && (argc > 5 ? std::atoi(argv[5]) != 0 : true);
    const bool debug = std::getenv("PROMO_DEBUG") != nullptr;   // per-minor sweep progress
    HeapConfig cfg = promoConfig(workers);
    if (argc > 6) {   // the sweep slice (bytes): larger slices complete the sweep inside minors
        const size_t budget = std::strtoull(argv[6], nullptr, 10);
        cfg.sweep_work_budget = cfg.initial_sweep_budget = budget;
        cfg.max_sweep_bytes_per_alloc = cfg.max_sweep_bytes_hard = budget;
        cfg.panic_sweep_slice_bytes = budget;
    }
    if (tail) {
        cfg.sweep_work_budget = cfg.initial_sweep_budget = 8;
        cfg.max_sweep_bytes_per_alloc = cfg.max_sweep_bytes_hard = 8;
        cfg.panic_sweep_slice_bytes = 8;
        cfg.initial_old_gen_size = 32ULL << 20;
        cfg.max_heap_size = 256ULL << 20;   // the floor must lie below the old-gen region
    }
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    std::mt19937_64 rng(seed);
    // Tail mode: the bag object (a live mixed bag page appended last before
    // each major).
    std::unique_ptr<PRoot> bag;
    uint64_t tail_eligible = 0, tail_hits = 0, tail_hits_all = 0;
    // A pointer-bearing Array of exactly alloc_buffer_size bytes.
    const size_t array_cap = (cfg.alloc_buffer_size - sizeof(ElmArray)) / sizeof(Unboxable);
    std::vector<std::unique_ptr<PRoot>> old_set, young;
    int64_t next = 1;
    uint64_t exact = 0, sweeping_minors = 0, completed_in_minor = 0;
    for (int round = 0; round < rounds; ++round) {
        // Even rounds leave a long sweep backlog (many mixed blocks) that the
        // workers sweep a slice at a time; odd rounds a short one under a large
        // promotion volume, so the workers complete the sweep inside a parallel
        // minor (the in-loop and tail completions: CR-001, CR-014).
        const bool completion = (round % 2) == 1;
        if (completion && old_set.size() > 900) old_set.erase(old_set.begin(), old_set.end() - 600);
        // (1) An old population of every class, promoted.
        for (int i = 0; i < (completion ? 300 : 1500); ++i) {
            const int kind = static_cast<int>(rng() % 4);
            old_set.push_back(std::make_unique<PRoot>(a, makeObj(kind, next, 0), next, kind));
            ++next;
        }
        a.minorGC();
        a.minorGC();
        // (2) Most of it dies: runs of dead cells, some blocks all dead.
        std::vector<std::unique_ptr<PRoot>> keep;
        const unsigned mode = static_cast<unsigned>(rng() % 3);
        for (size_t i = 0; i < old_set.size(); ++i) {
            const bool live = mode == 0 ? (i % 3 == 0)
                            : mode == 1 ? (rng() % 5 == 0)
                            : ((i / 64) % 3 == 0 && i % 2 == 0);
            if (live) keep.push_back(std::move(old_set[i]));
        }
        old_set.swap(keep);
        keep.clear();   // the dropped roots die here, before the major
        if (tail) {
            // The bag object: a fresh bag page appended last (the previous
            // round's dies now).
            bag.reset();
            std::vector<u16> bchars(1900, u'b');
            bag = std::make_unique<PRoot>(a, alloc::allocString(bchars.data(), bchars.size()), next++, 3);
        }
        // (3) A STW major: a lazy sweep is pending afterwards.
        a.majorGC();
        if (tail) {
            // Pre-sweep on the mutator until one slice is left, ending at the
            // last block's end: then the first worker whose ladder reaches
            // sweep-on-demand in the next minors runs it, and (unless the gap
            // it pushes is of the worker's own class: the early exit) completes
            // the sweep on the tail path, onSweepComplete on that worker.
            OldGenSpace& og = h->getOldGen();
            const BlockTable& bt = OldGenSpaceTestAccess::getBlockTable(og);
            auto oneSliceLeft = [&]() {
                const size_t nb = bt.size();
                if (nb == 0 || OldGenSpaceTestAccess::getSweepBufferIndex(og) != nb - 1) return false;
                const BlockId last = bt.idAt(nb - 1);
                const char* cur = OldGenSpaceTestAccess::getSweepCursor(og);
                if (cur == nullptr || bt.meta(last).fully_swept || !OldGenSpaceTestAccess::demoted(og, last))
                    return false;
                char* start = bt.info(last).start;
                char* end = bt.info(last).end_of_objects;
                size_t len = 0;
                const uint8_t* bits = OldGenSpaceTestAccess::getMarkBitsForBlock(og, last, &len);
                const size_t from = static_cast<size_t>(cur - start) / 8, to = static_cast<size_t>(end - start) / 8;
                size_t first = to;
                for (size_t b = from; b < to && (b >> 3) < len; ++b)
                    if ((bits[b >> 3] >> (b & 7)) & 1u) { first = b; break; }
                if (first == to) return true;   // only the trailing gap
                // One live object at the cursor that ends the block.
                return first == from && start + first * 8 + getObjectSize(start + first * 8) >= end;
            };
            for (int g = 0; g < 1000000 && OldGenSpaceTestAccess::gcPhase(og) == GCPhase::Sweeping &&
                            !oneSliceLeft(); ++g)
                OldGenSpaceTestAccess::lazySweep(og, NUM_SIZE_CLASSES, 8);
        }
        // (4) Parallel minors that promote young trees (leaves of every class)
        //     while the sweep is pending; now and then an exact-size Array leaf.
        for (int m = 0; m < 6; ++m) {
            const int trees = completion ? 64 : 24;
            for (int i = 0; i < trees; ++i) {
                const int depth = 3 + static_cast<int>(rng() % 2);   // 15 or 31 objects
                // CR-016: an exact-size Array in every minor (was every other).
                size_t cap = (exact_arrays && i == 0) ? array_cap : 0;
                if (cap != 0) ++exact;
                young.push_back(std::make_unique<PRoot>(a, youngMixed(depth, next, rng, cap), depth, 6));
            }
            const bool was_sweeping = OldGenSpaceTestAccess::gcPhase(h->getOldGen()) == GCPhase::Sweeping;
            if (was_sweeping) ++sweeping_minors;
            OldGenSpace& og = h->getOldGen();
            if (debug)
                std::fprintf(stderr, "round %d minor %d: sweep index %zu of %zu blocks, pending %zu ->",
                             round, m, OldGenSpaceTestAccess::getSweepBufferIndex(og),
                             OldGenSpaceTestAccess::getSweepTotalBlocks(og),
                             OldGenSpaceTestAccess::getSweepPendingBlocks(og));
#if ENABLE_GC_STATS
            const uint64_t tail0 = OldGenSpaceTestAccess::bitmapStats(og).sweep_tail_in_promotion;
            const uint64_t tailall0 = OldGenSpaceTestAccess::bitmapStats(og).sweep_tail_completions;
#endif
            if (tail && was_sweeping) {
                const size_t nb = OldGenSpaceTestAccess::blockCount(og);
                const BlockId last = nb ? OldGenSpaceTestAccess::blockIdAt(og, nb - 1) : NO_BLOCK_ID;
                if (last.valid() && !OldGenSpaceTestAccess::getBlockTable(og).meta(last).fully_swept &&
                    OldGenSpaceTestAccess::demoted(og, last))
                    ++tail_eligible;
            }
            a.minorGC();
#if ENABLE_GC_STATS
            tail_hits += OldGenSpaceTestAccess::bitmapStats(og).sweep_tail_in_promotion - tail0;
            tail_hits_all += OldGenSpaceTestAccess::bitmapStats(og).sweep_tail_completions - tailall0;
#endif
            if (debug)
                std::fprintf(stderr, " index %zu, phase %d, old gen blocks %zu\n",
                             OldGenSpaceTestAccess::getSweepBufferIndex(og),
                             static_cast<int>(OldGenSpaceTestAccess::gcPhase(og)),
                             OldGenSpaceTestAccess::numBlocks(og));
            if (was_sweeping && OldGenSpaceTestAccess::gcPhase(h->getOldGen()) != GCPhase::Sweeping)
                ++completed_in_minor;
            for (const auto& r : young) check(a, *r);
            for (const auto& r : old_set) check(a, *r);
            // Half of the young set dies each minor; the rest is promoted next time.
            std::vector<std::unique_ptr<PRoot>> k2;
            for (auto& r : young)
                if (rng() % 2 == 0) k2.push_back(std::move(r));
            young.swap(k2);
        }
        // Keep the heap bounded.
        if (old_set.size() > 6000) old_set.erase(old_set.begin(), old_set.begin() + 3000);
        if (young.size() > 200) young.erase(young.begin(), young.begin() + 100);
    }
    const auto& pm = h->getNursery().getStats().pmin;
    std::printf("promo_sweep seed %llu: %d rounds, %u workers, parallel minors %llu, minors "
                "with a pending sweep %llu (sweep completed in %llu), exact-size arrays %llu, PASS\n",
                static_cast<unsigned long long>(seed), rounds, workers,
                static_cast<unsigned long long>(pm.minors_parallel),
                static_cast<unsigned long long>(sweeping_minors),
                static_cast<unsigned long long>(completed_in_minor),
                static_cast<unsigned long long>(exact));
    if (tail)
        std::printf("promo_sweep tail mode: minors with the last block unswept and mixed (tail-eligible) %llu, "
                    "tail completions inside a parallel minor (tail hits) %llu (all tail completions in minors %llu)\n",
                    static_cast<unsigned long long>(tail_eligible), static_cast<unsigned long long>(tail_hits),
                    static_cast<unsigned long long>(tail_hits_all));
    return 0;
}

#if !ECO_TLA_TRACE_ENABLED
// ============================================================================
// Register reproductions, Phase C (plans/threaded-gc-register-repros-impl.md
// Steps 17-20): deterministic TSan pairs. Two plain std::threads drive two
// promotion workers of ONE heap (no initThread: there is no thread affinity in
// allocatePromotion at gc_thread_mode 0), ordered by DetHandshake.hpp's relaxed
// atomics, so the only happens-before edges are the runtime's own locks.
//
//   gc-heap-tsan det-cr014-live              CR-014 NoRaceLive: flushCursorW vs
//                                            the tail completion's computeFragmentationStats
//   gc-heap-tsan det-cr001 {rf|wf} {inloop|tail}
//                                            CR-001: finalizeBitmapCellW's gc_phase_
//                                            read vs lazySweep's completion write
//   gc-heap-tsan det-cr002                   CR-002: nextSetBit's word read vs a
//                                            stashed cell's setMarkBitAtomic
//
// Exit: 0 clean, 3 NOT REACHED, 66 (TSan) a report. Each arm prints
// "<arm>: REACHED ..." or "<arm>: NOT REACHED: <why>".
// ============================================================================
#include "DetHandshake.hpp"

#include <thread>

namespace {

using OA = OldGenSpaceTestAccess;

int detNotReached(const std::string& arm, const char* why) {
    std::printf("%s: NOT REACHED: %s\n", arm.c_str(), why);
    std::fflush(stdout);
    return det::kNotReached;
}

void setBudgets(HeapConfig& cfg, size_t b) {
    cfg.sweep_work_budget = cfg.initial_sweep_budget = b;
    cfg.max_sweep_bytes_per_alloc = cfg.max_sweep_bytes_hard = b;
    cfg.panic_sweep_slice_bytes = b;
}

// A promoted cell as a pointer-free object (allocatePromotion leaves the
// caller to write the object, as copyClaimed does).
void formatCell(void* p, size_t sz) {
    std::memset(p, 0, sz);
    Header* h = getHeader(p);
    h->tag = Tag_ByteBuffer;
    h->size = static_cast<u32>(sz - sizeof(ByteBuffer));
}

// Step 17: the shared tail fixture. Blocks, in order:
//   U  class 64, uniform, 7/8 live, Queued (partialFront(c64));
//   I  class 16, uniform, 7/8 live, Queued: a second rung-1 block, so a worker
//      can make one allocation that finalizes UNDER promo_mu_ (a release edge
//      that orders its earlier fast-path reads before the other worker's lock);
//   M  class 32, alternate cells live (demoted, mixed), LAST.
// Then a STW major and a pre-sweep up to M's cell `stop`.
struct TailFixture {
    BlockId U, I, M;
    char* Ustart = nullptr;
    char* Mstart = nullptr;
    std::vector<std::unique_ptr<PRoot>> u, i, m;
};

int buildTail(Allocator& a, OldGenSpace& og, const std::string& arm, int stop, TailFixture& F) {
    const size_t c64 = OA::sizeClass(64), c32 = OA::sizeClass(32), c16 = OA::sizeClass(16);
    const size_t c128 = OA::sizeClass(128);
    if (OA::classToSize(c64) != 64 || OA::classToSize(c32) != 32 || OA::classToSize(c16) != 16)
        return detNotReached(arm, "size classes 16/32/64 are not exact");
    const size_t cap6 = (64 - sizeof(ElmArray)) / sizeof(Unboxable);
    for (int k = 0; k < 64; ++k) F.u.push_back(std::make_unique<PRoot>(a, alloc::allocArray(cap6), k, 4));
    a.minorGC();
    a.minorGC();
    for (int k = 0; k < 256; ++k) F.i.push_back(std::make_unique<PRoot>(a, makeObj(0, 50000 + k, 0), 50000 + k, 0));
    a.minorGC();
    a.minorGC();
    for (int k = 0; k < 128; ++k) F.m.push_back(std::make_unique<PRoot>(a, makeObj(2, 60000 + k, 0), 60000 + k, 2));
    a.minorGC();
    a.minorGC();
    auto oneBlock = [&](const std::vector<std::unique_ptr<PRoot>>& v, BlockId& id) {
        id = OA::blockOf(og, a.resolve(v[0]->h));
        for (const auto& r : v)
            if (OA::blockOf(og, a.resolve(r->h)) != id) return false;
        return id.valid();
    };
    if (!oneBlock(F.u, F.U) || OA::cellsIn(og, F.U) != 64) return detNotReached(arm, "U is not one 64-cell block");
    if (!oneBlock(F.i, F.I) || OA::cellsIn(og, F.I) != 256) return detNotReached(arm, "I is not one 256-cell block");
    if (!oneBlock(F.m, F.M) || OA::cellsIn(og, F.M) != 128) return detNotReached(arm, "M is not one 128-cell block");
    const BlockTable& bt = OA::getBlockTable(og);
    F.Ustart = bt.info(F.U).start;
    F.Mstart = bt.info(F.M).start;
    // (3) Drop: U and I keep 7/8 (uniform), M keeps the even cells (demoted).
    auto cellOf = [&](const PRoot& r, char* start, size_t cb) {
        return static_cast<size_t>(static_cast<char*>(a.resolve(r.h)) - start) / cb;
    };
    auto drop = [&](std::vector<std::unique_ptr<PRoot>>& v, char* start, size_t cb, auto dead) {
        std::vector<std::unique_ptr<PRoot>> keep;
        for (auto& r : v)
            if (!dead(cellOf(*r, start, cb))) keep.push_back(std::move(r));
        v.swap(keep);
    };
    drop(F.u, F.Ustart, 64, [](size_t k) { return k % 8 == 3; });
    drop(F.i, bt.info(F.I).start, 16, [](size_t k) { return k % 8 == 5; });
    drop(F.m, F.Mstart, 32, [](size_t k) { return k % 2 == 1; });
    a.majorGC();
    // (5) The post-major state.
    if (OA::gcPhase(og) != GCPhase::Sweeping) return detNotReached(arm, "no sweep pending after the major");
    if (!OA::demoted(og, F.M) || OA::demoted(og, F.U) || OA::demoted(og, F.I))
        return detNotReached(arm, "M is not demoted, or U/I are");
    if (OA::blockIdAt(og, OA::blockCount(og) - 1) != F.M) return detNotReached(arm, "M is not the last block");
    if (OA::partialFront(og, c64) != F.U || OA::partialFront(og, c16) != F.I)
        return detNotReached(arm, "U / I are not at the front of their partial queues");
    if (OA::cursorBlock(og, c64).valid() || OA::cursorBlock(og, c32).valid() ||
        OA::cursorBlock(og, c128).valid() || OA::cursorBlock(og, c16).valid())
        return detNotReached(arm, "a mutator cursor is open in c16/c32/c64/c128");
    if (OA::getFreeList(og, c128) != nullptr || OA::partialQueueLength(og, c128) != 0)
        return detNotReached(arm, "class 128 has a free cell or a queued block");
    for (size_t c = OA::numSizeClasses(og); c < NUM_SIZE_CLASSES; ++c)
        if (OA::getFreeList(og, c)) return detNotReached(arm, "a mixed-only class has a free cell (split rung)");
    // (6) Pre-sweep up to M's cell `stop`.
    char* const at = F.Mstart + static_cast<size_t>(stop) * 32;
    for (int g = 0; OA::getSweepCursor(og) != at; ++g) {
        if (g > 1000 || !OA::hasPendingSweepWork(og)) return detNotReached(arm, "the pre-sweep missed M's cell");
        OA::lazySweep(og, NUM_SIZE_CLASSES, 8);
    }
    if (OA::gcPhase(og) != GCPhase::Sweeping) return detNotReached(arm, "the pre-sweep completed the sweep");
    if (OA::getFreeList(og, c64) != nullptr || OA::getFreeList(og, c128) != nullptr)
        return detNotReached(arm, "class 64/128 has a free-list cell after the pre-sweep");
    return det::kClean;
}

HeapConfig detConfig(size_t budget) {
    HeapConfig cfg = promoConfig(1);   // gc_minor_threads 1: serial setup minors, deterministic blocks
    cfg.conc_mark = 0;
    cfg.demote_live_fraction = 0.6;
    setBudgets(cfg, budget);
    cfg.validate();
    return cfg;
}

Allocator& detInit(const HeapConfig& cfg) {
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    return a;
}

// Step 18: CR-014 NoRaceLive. T1 fills U's only chunk (8 free cells; the
// pending live bytes stay unflushed in its cursor), then makes one class-16
// allocation that finalizes under promo_mu_ (so T2's lock orders T1's earlier
// gc_phase_ reads: no CR-001 report here). T2's class-128 promotion sweeps M's
// last gap on demand with an 8-byte slice: the tail completion runs
// onSweepComplete -> computeFragmentationStats on T2 and reads U's live_bytes
// plainly. Then T1's 9th class-64 call exhausts its cursor and flushes
// (flushCursorW's atomic fetch_add) BEFORE it takes the lock.
int detCr014Live() {
    const std::string arm = "det-cr014-live";
    auto& a = detInit(detConfig(8));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    TailFixture F;
    if (int rc = buildTail(a, og, arm, 127, F)) return rc;
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    std::atomic<int> step{0};
    void* p1[9] = {};
    void* pi = nullptr;
    void* p2 = nullptr;
    std::thread t1([&] {
        auto& w = ctx.w[0];
        for (int i = 0; i < 8; ++i) {
            p1[i] = og.allocatePromotion(w, 64, false);
            if (p1[i]) formatCell(p1[i], 64);
        }
        pi = og.allocatePromotion(w, 16, false);   // I: rung 1 under promo_mu_
        if (pi) formatCell(pi, 16);
        det::post(step, 1);
        det::waitFor(step, 2);
        p1[8] = og.allocatePromotion(w, 64, false);   // cursorAllocateW -> flushCursorW (RACE), then the lock
        if (p1[8]) formatCell(p1[8], 64);
    });
    std::thread t2([&] {
        det::waitFor(step, 1);
        p2 = og.allocatePromotion(ctx.w[1], 128, false);   // ladder -> sweepOnDemandAllocate -> tail completion
        if (p2) formatCell(p2, 128);
        det::post(step, 2);
    });
    t1.join();
    t2.join();
    bool inU = true;
    for (int i = 0; i < 8; ++i) inU = inU && p1[i] && OA::blockOf(og, p1[i]) == F.U;
    const uint64_t bm = ctx.w[0].bm_allocs;
    const bool idle = OA::gcPhase(og) == GCPhase::Idle;
    const bool deferred = OA::sweepCompleteDeferred(og);
    const bool okI = pi && OA::blockOf(og, pi) == F.I;
    og.endParallelPromotion(ctx);
    if (!inU) return detNotReached(arm, "T1's first eight cells are not U's");
    if (!okI) return detNotReached(arm, "T1's class-16 cell is not I's");
    if (bm != 8) return detNotReached(arm, "T1's ninth call did not flush U's eight cells");
    if (!idle) return detNotReached(arm, "T2 did not complete the sweep");
    if (deferred) return detNotReached(arm, "the completion was in-loop (deferred), not the tail path");
    std::printf("%s: REACHED (T2 completed the sweep on the tail path while T1's U cursor held 8 unflushed "
                "cells; T1 flushed after it)\n", arm.c_str());
    return det::kClean;
}

// Step 19: CR-001, the race half. T1 claims U's chunk under the lock (call 1),
// then makes one fast-path allocation whose finalizeBitmapCellW reads
// gc_phase_ with no lock: after T2's completion write (rf) or before it (wf).
// inloop: B = 64, the in-loop completion write (deferred); tail: B = 8.
int detCr001(bool rf, bool inloop) {
    const std::string arm = std::string("det-cr001 ") + (rf ? "rf" : "wf") + (inloop ? " inloop" : " tail");
    auto& a = detInit(detConfig(inloop ? 64 : 8));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    TailFixture F;
    if (int rc = buildTail(a, og, arm, 127, F)) return rc;
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    std::atomic<int> step{0};
    void *p = nullptr, *q = nullptr, *p2 = nullptr;
    std::thread t1([&] {
        auto& w = ctx.w[0];
        p = og.allocatePromotion(w, 64, false);   // the lock; claims U's chunk
        if (p) formatCell(p, 64);
        if (rf) {
            det::post(step, 1);
            det::waitFor(step, 2);
            q = og.allocatePromotion(w, 64, false);   // fast path: finalizeBitmapCellW reads gc_phase_
        } else {
            q = og.allocatePromotion(w, 64, false);
            det::post(step, 1);
        }
        if (q) formatCell(q, 64);
    });
    std::thread t2([&] {
        det::waitFor(step, 1);
        p2 = og.allocatePromotion(ctx.w[1], 128, false);   // sweep-on-demand completes: gc_phase_ = Idle
        if (p2) formatCell(p2, 128);
        det::post(step, 2);
    });
    t1.join();
    t2.join();
    const bool okq = p && q && OA::blockOf(og, p) == F.U && OA::blockOf(og, q) == F.U;
    const bool idle = OA::gcPhase(og) == GCPhase::Idle;
    const bool deferred = OA::sweepCompleteDeferred(og);
    og.endParallelPromotion(ctx);
    if (!okq) return detNotReached(arm, "T1's cells are not U's");
    if (!idle) return detNotReached(arm, "T2 did not complete the sweep");
    if (inloop != deferred)
        return detNotReached(arm, inloop ? "the completion was not in-loop (deferred)"
                                         : "the completion was in-loop, not the tail path");
    std::printf("%s: REACHED (T2 completed the sweep %s; T1's fast-path finalize read gc_phase_ %s it)\n",
                arm.c_str(), inloop ? "in the loop" : "on the tail path", rf ? "after" : "before");
    return det::kClean;
}

// Step 20: CR-002. After the pre-sweep to M's cell 3, M's only class-32 free
// cell is g1 = cell 1 (bit 4) and the cursor is at cell 3 (bit 12): both in
// bitmap word 0. T1 batch-pops g1 under the lock and finalizes it after
// unlocking (setMarkBitAtomic: fetch_or on byte 0); T2 then sweeps on demand
// from bit 12 (nextSetBit's plain load of word 0).
int detCr002() {
    const std::string arm = "det-cr002";
    auto& a = detInit(detConfig(8));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    TailFixture F;
    if (int rc = buildTail(a, og, arm, 3, F)) return rc;
    const size_t c32 = OA::sizeClass(32);
    char* const g1 = F.Mstart + 32;
    FreeCell* head = OA::getFreeList(og, c32);
    if (reinterpret_cast<char*>(head) != g1 || head->next_in_class != nullptr)
        return detNotReached(arm, "M's cell 1 is not the only class-32 free cell");
    if (OA::partialQueueLength(og, c32) != 0) return detNotReached(arm, "class 32 has a queued block");
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    std::atomic<int> step{0};
    void *r1 = nullptr, *r2 = nullptr;
    std::thread t1([&] {
        r1 = og.allocatePromotion(ctx.w[0], 32, false);   // batch pop g1; finalize outside the lock
        det::post(step, 1);
        det::waitFor(step, 2);
        if (r1) formatCell(r1, 32);
    });
    std::thread t2([&] {
        det::waitFor(step, 1);
        r2 = og.allocatePromotion(ctx.w[1], 32, false);   // lazySweep(c32, 8) from bit 12: word 0
        det::post(step, 2);
    });
    t1.join();
    t2.join();
    if (r2) formatCell(r2, 32);
    og.endParallelPromotion(ctx);
    if (r1 != g1) return detNotReached(arm, "T1 did not take M's cell 1");
    if (r2 != F.Mstart + 3 * 32) return detNotReached(arm, "T2 did not sweep M's cell 3 on demand");
    std::printf("%s: REACHED (T1 finalized M's cell 1 outside the lock; T2's sweep read bitmap word 0 "
                "and took cell 3)\n", arm.c_str());
    return det::kClean;
}

}  // namespace

int promoDetMain(int argc, char** argv) {
    const std::string which = argv[0];
    if (which == "det-cr014-live") return detCr014Live();
    if (which == "det-cr002") return detCr002();
    if (which == "det-cr001") {
        const bool rf = !(argc > 1 && std::strcmp(argv[1], "wf") == 0);
        const bool inloop = !(argc > 2 && std::strcmp(argv[2], "tail") == 0);
        return detCr001(rf, inloop);
    }
    std::fprintf(stderr, "usage: gc-heap-tsan det-cr014-live | det-cr001 {rf|wf} {inloop|tail} | det-cr002\n");
    return 2;
}
#endif  // !ECO_TLA_TRACE_ENABLED

#if ECO_TLA_TRACE_ENABLED
// ============================================================================
// M4 trace validation (plans/threaded-gc-tla-M4-promotion-bitmap.md §8;
// test/tla/M4-promotion-bitmap/TracePromoBitmap.tla). Trace builds only:
//
//   gc-heap-trace promo <seed> [workers [trees [jitter_us]]]
//
// One parallel minor promotes `trees` young trees of 15 Tuple2s (24 B, the
// modelled size class) while a lazy sweep is pending over a mixed block M of
// alternating live and dead Tuple2s (so every gap is one cell of the class) and
// a queued uniform block of that class has free cells: the workers claim its chunks,
// then reach promo_mu_, sweep on demand, pop, batch-pop into their stashes and
// finalize stashed cells outside the lock. The runtime's m4.* hooks record the
// protocol; the header is the heap just before the minor, in the model's terms
// (cells are "block * 10000 + first mark bit", blocks "b<id>").
// ============================================================================
#include <algorithm>
#include <map>
#include <string>

namespace Elm { extern bool tla_m4; }

namespace {

constexpr int64_t kCellMul = 10000;
constexpr int64_t MARK_ALIGNMENT = 8;   // one mark bit per 8 heap bytes (OldGenSpace::MARK_ALIGNMENT)
int64_t cellId(uint32_t blk, int64_t bit) { return static_cast<int64_t>(blk) * kCellMul + bit; }
std::string blkName(uint32_t blk) { return "\"b" + std::to_string(blk) + "\""; }

struct Json {
    std::string s;
    bool first = true;
    void key(const char* k) { s += first ? "" : ","; first = false; s += "\""; s += k; s += "\":"; }
};

// pushSpanOnFreeLists' mixed packer (OldGenSpace.cpp), replayed: the cells of
// class `cls` a run of `bytes` at mark bit `bit0` becomes, highest address
// first (each cell is pushed at the list head, so the last one heads it).
std::vector<int64_t> packedCells(uint32_t blk, int64_t bit0, size_t bytes, size_t cls) {
    std::vector<int64_t> out;
    int64_t bit = bit0;
    while (bytes >= 16) {   // MIN_FREE_CELL_SIZE
        const size_t c = OldGenSpaceTestAccess::freeListClassFor(bytes);
        if (c >= NUM_SIZE_CLASSES) break;
        const size_t sz = OldGenSpaceTestAccess::classToSize(c);
        if (c == cls) out.push_back(cellId(blk, bit));
        bit += static_cast<int64_t>(sz / MARK_ALIGNMENT);
        bytes -= sz;
    }
    std::reverse(out.begin(), out.end());
    return out;
}

// The heap in the model's terms (MC constants of TracePromoBitmap.tla).
std::string snapshotHeader(Allocator& a, OldGenSpace& og, size_t cls, unsigned workers, uint64_t seed,
                           int promos) {
    const BlockTable& bt = OldGenSpaceTestAccess::getBlockTable(og);
    const size_t cb = OldGenSpaceTestAccess::classToSize(cls);
    const size_t stride = cb / MARK_ALIGNMENT;
    (void)a;
    auto setBits = [&](BlockId id) {
        size_t len = 0;
        const uint8_t* bits = OldGenSpaceTestAccess::getMarkBitsForBlock(og, id, &len);
        std::vector<int64_t> v;
        const size_t nbits = static_cast<size_t>(bt.info(id).end_of_objects - bt.info(id).start) / MARK_ALIGNMENT;
        for (size_t b = 0; b < nbits && (b >> 3) < len; ++b)
            if ((bits[b >> 3] >> (b & 7)) & 1u) v.push_back(static_cast<int64_t>(b));
        return v;
    };
    // The modelled blocks: uniform blocks of the class, mixed blocks the sweep
    // has not passed, and blocks holding the class's free cells.
    std::map<uint32_t, bool> modelled;   // id -> mixed
    for (size_t pos = 0; pos < bt.size(); ++pos) {
        const BlockId id = bt.idAt(pos);
        const BlockInfo& b = bt.info(id);
        if (b.is_large) continue;
        if (b.size_class == cls) modelled[id.v] = false;
        else if (b.size_class >= NUM_SIZE_CLASSES && !bt.meta(id).fully_swept) modelled[id.v] = true;
    }
    std::vector<int64_t> free_cells;
    for (FreeCell* f = OldGenSpaceTestAccess::getFreeList(og, cls); f != nullptr; f = f->next_in_class) {
        const BlockId id = OldGenSpaceTestAccess::blockOf(og, f);
        if (!modelled.count(id.v)) modelled[id.v] = bt.info(id).size_class >= NUM_SIZE_CLASSES;
        free_cells.push_back(cellId(id.v, (reinterpret_cast<char*>(f) - bt.info(id).start) / MARK_ALIGNMENT));
    }
    // The sweep's remaining iterations, from the cursor, in block order.
    Json items;
    std::map<uint32_t, std::vector<int64_t>> extra_cells;   // mixed blocks: gap cells of the class
    const size_t sidx = OldGenSpaceTestAccess::getSweepBufferIndex(og);
    const char* scur = OldGenSpaceTestAccess::getSweepCursor(og);
    std::string items_s = "[";
    bool first_item = true;
    for (size_t pos = sidx; pos < bt.size(); ++pos) {
        const BlockId id = bt.idAt(pos);
        const BlockInfo& b = bt.info(id);
        if (bt.meta(id).fully_swept) continue;
        if (b.is_large || b.size_class < NUM_SIZE_CLASSES) {
            std::fprintf(stderr, "promo trace: an unswept block that is not mixed\n");
            std::exit(1);
        }
        const std::vector<int64_t> live = setBits(id);
        const int64_t end_bit = (b.end_of_objects - b.start) / MARK_ALIGNMENT;
        int64_t cur = (pos == sidx && scur != nullptr) ? (scur - b.start) / MARK_ALIGNMENT : 0;
        auto item = [&](int64_t rs, size_t rb, int64_t l, bool end) {
            std::vector<int64_t> g = rb > 0 ? packedCells(id.v, rs, rb, cls) : std::vector<int64_t>{};
            for (int64_t c : g) extra_cells[id.v].push_back(c);
            items_s += first_item ? "" : ",";
            first_item = false;
            items_s += "{\"g\":[";
            for (size_t k = 0; k < g.size(); ++k) items_s += (k ? "," : "") + std::to_string(g[k]);
            items_s += "],\"l\":" + std::to_string(l < 0 ? 0 : cellId(id.v, l));
            items_s += ",\"e\":" + (end ? blkName(id.v) : std::string("\"none\""));
            items_s += ",\"rs\":" + std::to_string(rb > 0 ? rs : -1) + ",\"rb\":" + std::to_string(rb) + "}";
        };
        bool ended = false;
        for (int64_t l : live) {
            if (l < cur) continue;
            const size_t size = getObjectSize(b.start + l * MARK_ALIGNMENT);
            const int64_t next = l + static_cast<int64_t>(size / MARK_ALIGNMENT);
            item(cur, static_cast<size_t>(l - cur) * MARK_ALIGNMENT, l, next >= end_bit);
            ended = next >= end_bit;
            cur = next;
        }
        if (!ended) item(cur, static_cast<size_t>(end_bit - cur) * MARK_ALIGNMENT, -1, true);
    }
    items_s += "]";
    // Blocks: cells, set bits, units, live cells.
    std::string blocks_s = "[";
    std::string prealloc_s = "[";
    bool fb = true, fp = true;
    for (const auto& [bid, mixed] : modelled) {
        const BlockId id{bid};
        const BlockInfo& b = bt.info(id);
        std::vector<int64_t> cells;
        const std::vector<int64_t> set = setBits(id);
        std::string units_s = "[";
        if (!mixed) {
            const uint32_t n = OldGenSpaceTestAccess::cellsIn(og, id);
            for (uint32_t k = 0; k < n; ++k) cells.push_back(static_cast<int64_t>(k * stride));
            for (uint32_t u = 0; u * 64 < n; ++u) {
                units_s += u ? "," : "";
                units_s += "[" + std::to_string(cellId(bid, static_cast<int64_t>(u * 64 * stride))) + "," +
                           std::to_string(cellId(bid, static_cast<int64_t>((std::min<uint32_t>(n, (u + 1) * 64) - 1) * stride))) + "]";
            }
            for (int64_t s : set) {
                prealloc_s += fp ? "" : ",";
                fp = false;
                prealloc_s += std::to_string(cellId(bid, s));
            }
        } else {
            cells = set;
            for (int64_t c : extra_cells[bid]) cells.push_back(c % kCellMul);
            for (int64_t c : free_cells) if (c / kCellMul == bid) cells.push_back(c % kCellMul);
            std::sort(cells.begin(), cells.end());
            cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
        }
        units_s += "]";
        blocks_s += fb ? "" : ",";
        fb = false;
        blocks_s += "{\"b\":" + blkName(bid) + ",\"id\":" + std::to_string(bid) + ",\"mixed\":" +
                    (mixed ? "true" : "false") + ",\"live\":" + std::to_string(bt.meta(id).live_bytes / cb) +
                    ",\"swept\":" + (bt.meta(id).fully_swept ? "true" : "false") + ",\"cells\":[";
        for (size_t k = 0; k < cells.size(); ++k) blocks_s += (k ? "," : "") + std::to_string(cellId(bid, cells[k]));
        blocks_s += "],\"set\":[";
        for (size_t k = 0; k < set.size(); ++k) blocks_s += (k ? "," : "") + std::to_string(cellId(bid, set[k]));
        blocks_s += "],\"units\":" + units_s + "}";
        (void)b;
    }
    blocks_s += "]";
    prealloc_s += "]";
    std::string free_s = "[";
    for (size_t k = 0; k < free_cells.size(); ++k) free_s += (k ? "," : "") + std::to_string(free_cells[k]);
    free_s += "]";
    std::string partial_s = "[";
    bool fq = true;
    for (BlockId id : OldGenSpaceTestAccess::partialQueue(og, cls)) {
        if (!bt.isLive(id) || bt.info(id).is_large || bt.info(id).size_class != cls ||
            OldGenSpaceTestAccess::allocState(og, id) != 1 /* kAllocQueued */) continue;
        partial_s += (fq ? "" : ",") + blkName(id.v);
        fq = false;
    }
    partial_s += "]";
    const BlockId cur = OldGenSpaceTestAccess::cursorBlock(og, cls);
    if (cur.valid()) {
        std::fprintf(stderr, "promo trace: the mutator has a cursor in the class (not modelled)\n");
        std::exit(1);
    }
    std::string h = "{\"harness\":\"gc-heap-trace\",\"kind\":\"m4\",\"seed\":" + std::to_string(seed) +
        ",\"workers\":" + std::to_string(workers) + ",\"promos\":" + std::to_string(promos) +
        ",\"cb\":" + std::to_string(cb) + ",\"stride\":" + std::to_string(stride) +
        ",\"cpb\":" + std::to_string(4096 / cb) +   // cells of a fresh (virgin) block of the class
        ",\"phase\":" + std::to_string(static_cast<int>(OldGenSpaceTestAccess::gcPhase(og))) +
        ",\"shared\":{\"b\":\"none\",\"u\":0}" +
        ",\"blocks\":" + blocks_s + ",\"items\":" + items_s + ",\"free\":" + free_s +
        ",\"partial\":" + partial_s + ",\"prealloc\":" + prealloc_s +
        ",\"locinit\":{\"phase\":" + std::to_string(static_cast<int>(OldGenSpaceTestAccess::gcPhase(og))) +
        ",\"sh" + std::to_string(cls) + "\":0}}";
    return h;
}

}  // namespace

// A young tree of Tuple2 nodes (24 B, like the old population's cells), so
// the other workers steal and promote part of it: worker 0 alone copies what
// the roots point at before the gang starts.
HPointer youngTree(int depth, int64_t& next) {
    if (depth == 0) {
        const int64_t id = next++;
        return alloc::tuple2(alloc::unboxedInt(kTag + id), alloc::unboxedInt(id), 0x5);
    }
    HPointer l = youngTree(depth - 1, next);
    PRoot keep_l(Allocator::instance(), l, 0, 1);   // rooted while the right side allocates
    HPointer r = youngTree(depth - 1, next);
    return alloc::tuple2(alloc::boxed(keep_l.h), alloc::boxed(r), 0);
}

int promoTraceMain(int argc, char** argv) {
    const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 1;
    const unsigned workers = argc > 2 ? static_cast<unsigned>(std::atoi(argv[2])) : 3;
    const int trees = argc > 3 ? std::atoi(argv[3]) : 8;   // young trees of 15 nodes
    if (argc > 4) setenv("ECO_GC_HELPER_JITTER_US", argv[4], 1);
    HeapConfig cfg = promoConfig(workers);
    // Three gap-sweep iterations (a 24-byte gap and a 24-byte Tuple2 each) per
    // slice, one slice per ladder hold: a hold pushes three cells and pops one,
    // so cells accumulate on the list and later holds batch-pop them.
    cfg.sweep_work_budget = 144;
    cfg.initial_sweep_budget = 144;
    cfg.max_sweep_bytes_per_alloc = 144;
    cfg.max_sweep_bytes_hard = 144;
    cfg.panic_sweep_slice_bytes = 144;
    cfg.demote_live_fraction = 0.5;   // M (alternate cells live) is demoted to mixed
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen();
    std::mt19937_64 rng(seed);
    const size_t cls = OldGenSpaceTestAccess::sizeClass(sizeof(Tuple2));
    const size_t cb = OldGenSpaceTestAccess::classToSize(cls);
    // (1) An old population of Tuple2 leaves: about two blocks of the class.
    std::vector<std::unique_ptr<PRoot>> olds;
    int64_t next = 1;
    const int per_block = static_cast<int>(cfg.alloc_buffer_size / cb);
    for (int i = 0; i < 2 * per_block - 6; ++i) {
        olds.push_back(std::make_unique<PRoot>(a, makeObj(1, next, 0), next, 1));
        ++next;
    }
    a.minorGC();
    a.minorGC();
    // (2) The fullest block becomes M (alternate cells live: demoted to mixed,
    //     every gap one cell of the class); the others keep 9 cells in 10 (they
    //     stay uniform and are queued with a few free cells).
    std::map<uint32_t, int> per_blk;
    for (const auto& r : olds) per_blk[OldGenSpaceTestAccess::blockOf(og, a.resolve(r->h)).v]++;
    uint32_t m_blk = 0;
    int best = -1;
    for (const auto& [b, n] : per_blk) if (n > best) { best = n; m_blk = b; }
    std::vector<std::unique_ptr<PRoot>> keep;
    const BlockTable& bt = OldGenSpaceTestAccess::getBlockTable(og);
    for (auto& r : olds) {
        void* o = a.resolve(r->h);
        const BlockId id = OldGenSpaceTestAccess::blockOf(og, o);
        const int64_t k = (static_cast<char*>(o) - bt.info(id).start) / static_cast<int64_t>(cb);
        const bool live = id.v == m_blk ? (k % 2 == 0) : (k % 10 != 3);
        if (live) keep.push_back(std::move(r));
    }
    olds.swap(keep);
    keep.clear();   // the dropped roots die here, before the major
    // (3) A STW major: M is demoted and a lazy sweep is pending.
    a.majorGC();
    if (OldGenSpaceTestAccess::gcPhase(og) != GCPhase::Sweeping || std::getenv("M4_DEBUG")) {
        for (size_t pos = 0; pos < bt.size(); ++pos) {
            const BlockId id = bt.idAt(pos);
            std::fprintf(stderr, "  block %u cls %zu large %d live %zu swept %d cells %u (m %u)\n", id.v,
                         bt.info(id).size_class, bt.info(id).is_large, (size_t)bt.meta(id).live_bytes,
                         bt.meta(id).fully_swept, OldGenSpaceTestAccess::cellsIn(og, id), m_blk);
        }
    }
    if (OldGenSpaceTestAccess::gcPhase(og) != GCPhase::Sweeping) {
        std::fprintf(stderr, "promo trace: no sweep pending after the major\n");
        return 1;
    }
    // (4) Young trees, aged by one minor (it promotes nothing).
    std::vector<std::unique_ptr<PRoot>> young;
    for (int i = 0; i < trees; ++i) young.push_back(std::make_unique<PRoot>(a, youngTree(3, next), 0, 5));
    a.minorGC();
    // (5) The traced minor promotes them.
    tlatrace::nameThread("mut", -1);
    const std::string hdr = snapshotHeader(a, og, cls, workers, seed, trees * 15);
    tlatrace::begin(hdr, "m4.,gang.");
    ::Elm::tla_m4 = true;
    a.minorGC();
    ::Elm::tla_m4 = false;
    if (!tlatrace::end(nullptr)) {
        std::fprintf(stderr, "promo trace: writing the trace failed\n");
        return 1;
    }
    for (const auto& r : olds) check(a, *r);
    std::printf("promo trace seed %llu: %u workers, %d trees, PASS\n",
                static_cast<unsigned long long>(seed), workers, trees);
    return 0;
}
#endif
