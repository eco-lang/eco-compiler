// Register CR-019 (plans/threaded-gc-concurrency-register.md), legacy nursery:
// a young large object (YLOS) header written under ylos_mu_ and read by a
// sweep slice under promo_mu_, in one parallel minor.
//
// A pointer-bearing object whose size lies in (the largest size class,
// alloc_buffer_size) and that the placement sends to the YLOS lives in a MIXED
// block (allocateFromBagPage). A STW major marks it (it is reachable) and
// leaves a lazy sweep pending over every mixed block (prepareMetaForLazySweep).
// In the parallel minors that follow, a promotion worker whose ladder runs
// sweep-on-demand (ladderFrom2W -> sweepOnDemandAllocate -> lazySweep, under
// promo_mu_) steps over the live YLOS with getObjectSize (a read of its header
// word), and the validate-only V11 walk re-reads it at the block's end, while
// another worker that reaches the YLOS through a young parent ages it in place
// (reachYoungLargeP: h->age++) or promotes it (promoteYoungLarge: age = 0),
// under ylos_mu_. Two locks, one plain write.
//
//   gc-heap-tsan ylos-sweep [seed [rounds [workers [jitter_us [age [sweep_bytes]]]]]]
//
// (TSan build.) Defaults: seed 1, 12 rounds, 4 workers, no jitter, promotion
// age 2 (a family is aged in two minors after the major and promoted in place
// in the third: three racing minors), sweep slice 1024 bytes. A small old
// population (256 leaves of four size classes) is promoted once. Per round:
//   (1) the previous round's sweep is finished on the mutator and its families
//       and trees are dropped (at this round's major their blocks are all dead:
//       released under the low 64 KiB floor, so they are not swept); then
//       `age` minors age fresh cohorts of young trees (Tuple2 nodes over leaves
//       of every class), so the minors after the major promote from the first;
//   (2) 24 young large object families are built: an Array in the YLOS band
//       (2 KiB, 4 KiB) -- a mixed bag page each -- whose elements point at
//       eight young Ints and at old population leaves, under eight young Tuple2
//       parents joined by a Tuple2 tree under one root;
//   (3) a STW major: the Arrays are marked; a lazy sweep is pending over the
//       YLOS pages (and the population's blocks, if demoted);
//   (4) six parallel minors promote the tree cohorts while the sweep is
//       pending: the uniform blocks' free cells run out, so the workers sweep
//       on demand (no pre-drain slice, no virgin block first).
// Before each minor the driver counts the families whose Array is still young
// and still ahead of the sweep cursor ("exposed"); after it, those the sweep
// passed in that minor ("walked": the minor both aged and swept that YLOS --
// the race's precondition). Every family and tree is checked after each minor.
//
// Not part of the default `gc-heap-tsan` run: it is expected to fail under TSan
// until CR-019 is fixed (every run with 1024- or 4096-byte slices reports the
// pair above). The same parallel sweep-on-demand could also reach the promo
// races (CR-002, CR-028, CR-001), though none showed in this arm's runs; a
// report naming reachYoungLargeP or promoteYoungLarge against lazySweep is
// CR-019.
#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "ThreadLocalHeap.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <random>
#include <vector>

using namespace Elm;

namespace {

[[noreturn]] void failY(const char* w, long long v = -1) {
    std::fprintf(stderr, "ylos_sweep FAIL: %s %lld\n", w, v);
    std::exit(1);
}

struct YRoot {
    Allocator& a;
    HPointer h;
    YRoot(Allocator& al, HPointer v) : a(al), h(v) { a.getRootSet().addRoot(&h); }
    ~YRoot() { a.getRootSet().removeRoot(&h); }
};

constexpr int64_t kTag = 0x7110000;

HPointer leaf(int kind, int64_t id) {
    switch (kind) {
        case 0: return alloc::allocInt(kTag + id);
        case 1: return alloc::tuple2(alloc::unboxedInt(kTag + id), alloc::unboxedInt(id), 0x5);
        case 2: return alloc::tuple3(alloc::unboxedInt(kTag + id), alloc::unboxedInt(id),
                                     alloc::unboxedInt(-id), 0x15);
        default: {
            const size_t len = 1 + static_cast<size_t>(id % 13);
            std::vector<u16> buf(len, static_cast<u16>('a' + id % 26));
            return alloc::allocString(buf.data(), len);
        }
    }
}

bool leafOk(void* o) {
    const Header* h = getHeader(o);
    switch (h->tag) {
        case Tag_Int: return static_cast<ElmInt*>(o)->value >= kTag;
        case Tag_Tuple2: return static_cast<Tuple2*>(o)->a.i == kTag + static_cast<Tuple2*>(o)->b.i;
        case Tag_Tuple3: {
            const Tuple3* t = static_cast<Tuple3*>(o);
            return t->a.i == kTag + t->b.i && t->c.i == -t->b.i;
        }
        case Tag_String: return true;
        default: return false;
    }
}

// A young tree of Tuple2 nodes over leaves of every class (only its root is
// rooted: the gang's workers steal subtrees and promote them in parallel).
HPointer tree(int depth, int64_t& next, std::mt19937_64& rng) {
    if (depth == 0) return leaf(static_cast<int>(rng() % 4), next++);
    HPointer l = tree(depth - 1, next, rng);
    YRoot keep_l(Allocator::instance(), l);
    HPointer r = tree(depth - 1, next, rng);
    return alloc::tuple2(alloc::boxed(keep_l.h), alloc::boxed(r), 0);
}

void checkTree(Allocator& a, HPointer p, int depth) {
    void* o = a.resolve(p);
    if (!o) failY("a tree node vanished", depth);
    if (depth > 0) {
        if (getHeader(o)->tag != Tag_Tuple2) failY("a tree node changed", depth);
        checkTree(a, static_cast<Tuple2*>(o)->a.p, depth - 1);
        checkTree(a, static_cast<Tuple2*>(o)->b.p, depth - 1);
    } else if (!leafOk(o)) {
        failY("a tree leaf changed", getHeader(o)->tag);
    }
}

constexpr int kDepth = 3;   // eight parents per family
constexpr int kParents = 1 << kDepth;

struct Fam {
    std::unique_ptr<YRoot> root;
    int64_t serial = 0;
    size_t len = 0;
    int age = 0;   // minors since the family was built
};

i64 famInt(int64_t serial, size_t i) { return kTag + serial * 16 + static_cast<i64>(i % 8); }

HPointer buildFam(Allocator& a, int64_t serial, size_t len, const std::vector<std::unique_ptr<YRoot>>& olds) {
    std::vector<std::unique_ptr<YRoot>> young;
    for (size_t j = 0; j < 8; ++j) young.push_back(std::make_unique<YRoot>(a, alloc::allocInt(famInt(serial, j))));
    std::vector<HPointer> e(len);   // no allocation between the fill and the Array
    for (size_t i = 0; i < len; ++i)
        e[i] = (i % 3 == 0) ? olds[(static_cast<size_t>(serial) * 7919 + i) % olds.size()]->h : young[i % 8]->h;
    YRoot arr(a, alloc::arrayFromPointers(e));
    std::vector<std::unique_ptr<YRoot>> level;
    for (int p = 0; p < kParents; ++p) {
        YRoot n(a, alloc::allocInt(kTag + serial));
        level.push_back(std::make_unique<YRoot>(a, alloc::tuple2(alloc::boxed(arr.h), alloc::boxed(n.h), 0)));
    }
    while (level.size() > 1) {
        std::vector<std::unique_ptr<YRoot>> up;
        for (size_t k = 0; k + 1 < level.size(); k += 2)
            up.push_back(std::make_unique<YRoot>(
                a, alloc::tuple2(alloc::boxed(level[k]->h), alloc::boxed(level[k + 1]->h), 0)));
        level.swap(up);
    }
    return level[0]->h;
}

void famParents(Allocator& a, HPointer p, int depth, std::vector<Tuple2*>& out) {
    void* o = a.resolve(p);
    if (!o || getHeader(o)->tag != Tag_Tuple2) failY("a family node changed", depth);
    Tuple2* t = static_cast<Tuple2*>(o);
    if (depth == 0) { out.push_back(t); return; }
    famParents(a, t->a.p, depth - 1, out);
    famParents(a, t->b.p, depth - 1, out);
}

// The family's Array (resolved), after checking every parent agrees on it.
void* famArray(Allocator& a, const Fam& f, bool full) {
    std::vector<Tuple2*> ps;
    famParents(a, f.root->h, kDepth, ps);
    void* arr = nullptr;
    for (Tuple2* t : ps) {
        void* x = a.resolve(t->a.p);
        if (arr == nullptr) arr = x;
        if (x == nullptr || x != arr) failY("a family's parents disagree", f.serial);
        if (full && static_cast<ElmInt*>(a.resolve(t->b.p))->value != kTag + f.serial)
            failY("a family parent changed", f.serial);
    }
    if (!full) return arr;
    const ElmArray* A = static_cast<const ElmArray*>(arr);
    if (A->header.tag != Tag_Array || A->length != f.len) failY("a family Array changed", f.serial);
    for (size_t i = 0; i < f.len; ++i) {
        void* o = a.resolve(A->elements[i].p);
        if (o == nullptr) failY("a family element vanished", f.serial);
        if (i % 3 == 0) {
            if (!leafOk(o)) failY("a family's old element changed", f.serial);
        } else if (getHeader(o)->tag != Tag_Int || static_cast<ElmInt*>(o)->value != famInt(f.serial, i)) {
            failY("a family's young element changed", f.serial);
        }
    }
    return arr;
}

// The ylos-sweep geometry (shared with det-cr019).
HeapConfig ylosConfig(unsigned workers, unsigned age, size_t sweep_bytes) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 4096;              // small blocks: a bag page per YLOS
    cfg.large_object_threshold = 2048;         // largest size class 2 KiB: the YLOS band is (2 KiB, 4 KiB)
    cfg.large_ptr_nursery_divisor = 0;         // every pointer-bearing large object is a YLOS
    cfg.nursery_block_count = 64;              // 128 KiB per side: small, room for the LABs
    cfg.nursery_max_block_count = 64;
    cfg.gc_minor_threads = workers;
    cfg.minor_lab_bytes = 4096;
    cfg.minor_parallel_min_bytes = 0;          // every minor is parallel
    cfg.initial_old_gen_size = 64 * 1024;       // a low floor: dead blocks are released
    cfg.max_heap_size = 64ULL << 20;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = 0;
    cfg.incremental_mark = false;              // STW majors: the sweep starts at a known point
    cfg.nursery_regions = 0;                   // the legacy parallel minor (phase 6)
    cfg.promotion_age = age;
    cfg.small_class_heap_budget_bytes = 0;     // sweep-on-demand before a virgin block
    cfg.minor_sweep_divisor = 0;               // no pre-drain slice: the workers sweep
    cfg.demote_live_fraction = 0.5;
    cfg.sweep_work_budget = cfg.initial_sweep_budget = sweep_bytes;
    cfg.max_sweep_bytes_per_alloc = cfg.max_sweep_bytes_hard = sweep_bytes;
    cfg.panic_sweep_slice_bytes = sweep_bytes;
    return cfg;
}

}  // namespace

int ylosSweepMain(int argc, char** argv) {
    const uint64_t seed = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 1;
    const int rounds = argc > 2 ? std::atoi(argv[2]) : 12;
    const unsigned workers = argc > 3 ? static_cast<unsigned>(std::atoi(argv[3])) : 4;
    if (argc > 4 && std::strcmp(argv[4], "0") != 0) setenv("ECO_GC_HELPER_JITTER_US", argv[4], 1);
    const unsigned age = argc > 5 ? static_cast<unsigned>(std::atoi(argv[5])) : 2;
    const size_t sweep_bytes = argc > 6 ? std::strtoull(argv[6], nullptr, 10) : 1024;
    const int families = 24, trees = 24, minors = 6;

    HeapConfig cfg = ylosConfig(workers, age, sweep_bytes);
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen();
    std::mt19937_64 rng(seed);

    std::vector<std::unique_ptr<YRoot>> olds;       // the old population
    std::deque<std::pair<std::unique_ptr<YRoot>, int>> young;   // young trees and their depth
    std::vector<Fam> fams;
    int64_t next = 1, serial = 0;
    uint64_t sweeping_minors = 0, exposed = 0, walked = 0, walked_minors = 0, ylos_at_birth = 0;
    auto youngTrees = [&]() {
        for (int i = 0; i < trees; ++i) {
            const int d = 3 + static_cast<int>(rng() % 2);
            young.emplace_back(std::make_unique<YRoot>(a, tree(d, next, rng)), d);
        }
        // A cohort is promoted by the minor after its `age`-th one (it lives
        // through age + 1 minors; with the cohort added before the major, age
        // + 2 cohorts are live): every minor promotes about `trees` trees.
        while (young.size() > static_cast<size_t>(trees) * (age + 2)) young.pop_front();
    };
    auto checkAll = [&]() {
        for (const auto& [r, d] : young) checkTree(a, r->h, d);
        for (const Fam& f : fams) famArray(a, f, true);
        for (const auto& r : olds)
            if (!a.resolve(r->h) || !leafOk(a.resolve(r->h))) failY("an old value changed");
    };
    // A small old population (kept for good): the families' old elements.
    for (int i = 0; i < 256; ++i) olds.push_back(std::make_unique<YRoot>(a, leaf(static_cast<int>(rng() % 4), next++)));
    for (unsigned m = 0; m <= age; ++m) a.minorGC();
    for (int round = 0; round < rounds; ++round) {
        // (1) Finish the previous sweep (the mutator, no minor) and drop the
        //     previous round's families and trees: at this round's major their
        //     blocks are all dead (reclaimed, or queued empty), so the only
        //     unswept mixed blocks are the population's and the new YLOS pages.
        OldGenSpaceTestAccess::driveSweepToCompletion(og);
        fams.clear();
        young.clear();
        //     Tree cohorts aged so that the first minors after the major
        //     already promote (a cohort needs `age` minors before it).
        for (unsigned m = 0; m < age; ++m) {
            youngTrees();
            a.minorGC();
        }
        youngTrees();
        // (2) Young large object families (the Arrays in mixed bag pages).
        for (int k = 0; k < families; ++k) {
            ++serial;
            const size_t len = 260 + rng() % 240;   // 2096-4008 bytes
            Fam f;
            f.root = std::make_unique<YRoot>(a, buildFam(a, serial, len, olds));
            f.serial = serial;
            f.len = len;
            if (og.isYoungLarge(famArray(a, f, false))) ++ylos_at_birth;
            fams.push_back(std::move(f));
        }
        // (3) A STW major: the Arrays are marked; a lazy sweep is pending.
        a.majorGC();
        // (4) Parallel minors that promote young trees while the sweep is pending.
        for (int m = 0; m < minors; ++m) {
            youngTrees();
            const bool sweeping = OldGenSpaceTestAccess::gcPhase(og) == GCPhase::Sweeping;
            std::vector<void*> ahead;   // young Arrays the sweep has not reached yet
            if (sweeping) {
                ++sweeping_minors;
                for (const Fam& f : fams) {
                    void* arr = famArray(a, f, false);
                    const BlockId id = OldGenSpaceTestAccess::blockOf(og, arr);
                    if (og.isYoungLarge(arr) && id.valid() && OldGenSpaceTestAccess::sweepWillReach(og, id, arr))
                        ahead.push_back(arr);
                }
                exposed += ahead.size();
            }
            a.minorGC();
            uint64_t w = 0;
            for (void* arr : ahead) {
                const BlockId id = OldGenSpaceTestAccess::blockOf(og, arr);
                if (OldGenSpaceTestAccess::gcPhase(og) != GCPhase::Sweeping ||
                    !OldGenSpaceTestAccess::sweepWillReach(og, id, arr))
                    ++w;
            }
            walked += w;
            if (w > 0) ++walked_minors;
            checkAll();
        }
    }
    const LargePtrStats& lh = h->getStats().lp;
    const LargePtrStats& ln = h->getNursery().getStats().lp;
    const LargePtrStats& lo = og.getStats().lp;
    std::printf("ylos_sweep seed %llu: %d rounds, %u workers, age %u, sweep slice %zu: parallel minors %llu, "
                "minors with a pending sweep %llu; families %lld (YLOS at birth %llu); young YLOS ahead of the "
                "sweep at a minor's start %llu, of which the sweep walked in that minor %llu (in %llu minors); "
                "reach calls %llu, promoted in place %llu, YLOS allocs %llu, PASS\n",
                static_cast<unsigned long long>(seed), rounds, workers, age, sweep_bytes,
                static_cast<unsigned long long>(h->getNursery().getStats().pmin.minors_parallel),
                static_cast<unsigned long long>(sweeping_minors), static_cast<long long>(serial),
                static_cast<unsigned long long>(ylos_at_birth), static_cast<unsigned long long>(exposed),
                static_cast<unsigned long long>(walked), static_cast<unsigned long long>(walked_minors),
                static_cast<unsigned long long>(ln.ylos_reach_calls),
                static_cast<unsigned long long>(lo.ylos_promoted_in_place),
                static_cast<unsigned long long>(lh.ylos_allocs));
    return 0;
}

// ============================================================================
// Register reproductions, Phase C Step 21 (plans/threaded-gc-register-repros-
// impl.md): CR-019 as a deterministic TSan pair.
//
//   gc-heap-tsan det-cr019 {t1first|t2first}
//
// A YLOS Array Y (3,088 B, its own mixed bag page) is marked by a STW major and
// the lazy sweep is pre-driven until Y is the next live object it reaches. Two
// promotion workers of one heap, ordered by relaxed atomics only: T1 promotes
// Y in place (promoteYoungLarge: large_body_index_ erase + the header's age = 0,
// no lock; the minor would hold ylos_mu_, which T2 never takes), T2 promotes a
// cell of an empty class, so its ladder sweeps on demand over Y (lazySweep's
// getObjectSize(Y), under promo_mu_, which T1 never takes). No value oracle
// (the header's tag and size are rewritten unchanged: undefined behaviour
// only). Exit 0 clean, 3 NOT REACHED, 66 (TSan) a report.
// ============================================================================
#include "DetHandshake.hpp"

#include <string>
#include <sys/mman.h>
#include <thread>

int ylosDetMain(int argc, char** argv) {
    using OA = OldGenSpaceTestAccess;
    const bool t1first = !(argc > 1 && std::strcmp(argv[1], "t2first") == 0);
    const std::string arm = std::string("det-cr019 ") + (t1first ? "t1first" : "t2first");
    auto notReached = [&](const char* why) {
        std::printf("%s: NOT REACHED: %s\n", arm.c_str(), why);
        std::fflush(stdout);
        return det::kNotReached;
    };
    HeapConfig cfg = ylosConfig(2, 2, 8);
    cfg.gc_minor_threads = 1;   // serial setup minors: deterministic placement
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen();
    // (1) An old population, promoted.
    std::vector<std::unique_ptr<YRoot>> olds;
    int64_t next = 1;
    for (int i = 0; i < 256; ++i) olds.push_back(std::make_unique<YRoot>(a, leaf(i % 4, next++)));
    for (int m = 0; m < 3; ++m) a.minorGC();
    // (2) D: a pointer-free large string (its own page; absorbs the major's initial slice).
    std::vector<u16> dchars(1450, u'd');
    YRoot D(a, alloc::allocString(dchars.data(), dchars.size()));
    // (3) Y: a YLOS Array of 384 old pointers (3,088 B) on its own page after D.
    std::vector<HPointer> e;
    for (size_t i = 0; i < 384; ++i) e.push_back(olds[i % olds.size()]->h);
    YRoot Yr(a, alloc::arrayFromPointers(e));
    void* Y = a.resolve(Yr.h);
    if (!og.isYoungLarge(Y)) return notReached("Y is not a YLOS object at birth");
    // (4) A STW major: Y is marked, a lazy sweep is pending over its page.
    a.majorGC();
    Y = a.resolve(Yr.h);
    const BlockId idY = OA::blockOf(og, Y);
    if (!og.isYoungLarge(Y)) return notReached("Y is not young after the major");
    if (OA::gcPhase(og) != GCPhase::Sweeping) return notReached("no sweep pending after the major");
    if (!idY.valid() || !OA::sweepWillReach(og, idY, Y)) return notReached("the sweep will not reach Y");
    // Pre-sweep until the next live object the sweep reaches is Y.
    const BlockTable& bt = OA::getBlockTable(og);
    auto nextLiveIsY = [&]() {
        const size_t pos0 = OA::getSweepBufferIndex(og);
        size_t pos = pos0;
        while (pos < bt.size() && bt.meta(bt.idAt(pos)).fully_swept) ++pos;
        if (pos >= bt.size() || bt.idAt(pos) != idY) return false;
        char* start = bt.info(idY).start;
        const char* cur = OA::getSweepCursor(og);
        const size_t from = static_cast<size_t>(((pos == pos0 && cur) ? cur : start) - start) / 8;
        size_t len = 0;
        const uint8_t* bits = OA::getMarkBitsForBlock(og, idY, &len);
        for (size_t b = from; (b >> 3) < len; ++b)
            if ((bits[b >> 3] >> (b & 7)) & 1u) return b == static_cast<size_t>(static_cast<char*>(Y) - start) / 8;
        return false;
    };
    for (int g = 0; !nextLiveIsY(); ++g) {
        if (g > 5000 || OA::gcPhase(og) != GCPhase::Sweeping || !OA::sweepWillReach(og, idY, Y))
            return notReached("the pre-sweep passed Y or never reached it");
        OA::lazySweep(og, NUM_SIZE_CLASSES, 8);
    }
    // An empty class: no free cell, no queued block, no cursor after the pre-sweep (2048 expected).
    size_t c = OA::numSizeClasses(og);
    while (c-- > 0) {
        if (OA::getFreeList(og, c) == nullptr && OA::partialQueueLength(og, c) == 0 &&
            !OA::cursorBlock(og, c).valid())
            break;
    }
    if (c >= OA::numSizeClasses(og)) return notReached("no empty size class");
    for (size_t k = OA::numSizeClasses(og); k < NUM_SIZE_CLASSES; ++k)
        if (OA::getFreeList(og, k)) return notReached("a mixed-only class has a free cell (split rung)");
    // TSan keeps four shadow slots per 8-byte granule and, when a new access
    // finds none free and none of its own, overwrites a pseudo-random one
    // (chosen by the thread's trace position, which a spin makes random). The
    // setup's many main-thread accesses fill Y's header granule, so in t2first
    // T2's size read or T1's read half of `age = 0` evicted T2's tag read in
    // about one run in five and the report was lost. Re-map Y's page in place
    // (MAP_FIXED: TSan's mmap interceptor resets the range's shadow) and copy
    // its bytes back: the main thread then holds ONE slot per granule, and
    // T2's two reads plus T1's read fit without an eviction. The page's
    // contents, protection and address are unchanged; no other thread exists.
    {
        const size_t pg = 4096;
        char* page = reinterpret_cast<char*>(reinterpret_cast<uintptr_t>(Y) & ~(uintptr_t)(pg - 1));
        std::vector<char> save(page, page + pg);
        if (mmap(page, pg, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) != page)
            return notReached("re-mapping Y's page failed");
        std::memcpy(page, save.data(), pg);
    }
    // (5) The pair.
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    std::atomic<int> step{0};
    void* p2 = nullptr;
    const size_t csz = OA::classToSize(c);
    std::thread t1([&] {
        if (!t1first) det::waitFor(step, 1);
        og.promoteYoungLarge(Y);   // no lock: large_body_index_ erase, header age = 0
        if (t1first) det::post(step, 1);
    });
    std::thread t2([&] {
        if (t1first) det::waitFor(step, 1);
        p2 = og.allocatePromotion(ctx.w[1], csz, false);   // ladder -> sweepOnDemandAllocate -> lazySweep over Y
        if (!t1first) det::post(step, 1);
    });
    t1.join();
    t2.join();
    if (p2) {
        std::memset(p2, 0, csz);
        getHeader(p2)->tag = Tag_ByteBuffer;
        getHeader(p2)->size = static_cast<u32>(csz - sizeof(ByteBuffer));
    }
    const bool promoted = !og.isYoungLarge(Y);
    const bool passed = !OA::sweepWillReach(og, idY, Y);
    og.endParallelPromotion(ctx);
    og.recomputeYoungLargeBounds();
    if (!p2) return notReached("T2's promotion failed");
    if (!promoted) return notReached("Y is still young");
    if (!passed) return notReached("T2's sweep did not pass Y");
    std::printf("%s: REACHED (T2's sweep stepped over Y while T1 promoted it in place, class %zu)\n",
                arm.c_str(), csz);
    return det::kClean;
}
