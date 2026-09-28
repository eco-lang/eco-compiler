/**
 * threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md): the region
 * nursery (HEAP_069) and its tenure job (HEAP_070). Every test pins its config
 * programmatically (unit tests ignore ECO_* after the first initialize).
 */

#include "RegionMinorTest.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>
#include <csignal>
#include <sys/wait.h>
#include <unistd.h>

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "HeapConfigJson.hpp"
#include "HeapHelpers.hpp"
#include "MinorWorkload.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using NTA = NurserySpaceTestAccess;

// 1 MiB extents (the phase 6 geometry), a roomy old gen, 4 KiB LABs.
HeapConfig regionConfig(uint32_t regions, uint32_t threads, uint32_t mode = 1) {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * 1024;
    cfg.nursery_block_count        = 64;
    cfg.nursery_max_block_count    = 64;
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 512ULL * 1024 * 1024;
    cfg.large_object_threshold     = 8 * 1024;
    // The region cap (P§3.13) is the largest size class (8 KiB here); pin the
    // legacy arm to it so both place the same objects in the YLOS.
    cfg.large_ptr_nursery_max_size = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc       = true;
    cfg.gc_thread_mode             = 0;
    cfg.gc_minor_threads           = threads;
    cfg.minor_lab_bytes            = 4096;
    cfg.minor_parallel_min_bytes   = 0;
    cfg.nursery_regions            = regions;
    cfg.tenure_mode                = mode;
    cfg.tenure_help_threads        = 1;
    cfg.validate();
    return cfg;
}

ThreadLocalHeap* heapOf(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
NurserySpace& nurseryOf(Allocator& a) { return heapOf(a)->getNursery(); }
OldGenSpace& oldgenOf(Allocator& a) { return heapOf(a)->getOldGen(); }

struct Counts {
    uint64_t checksum = 0, survived = 0, promoted = 0, minors = 0, grow = 0, cap = 0;
    uint64_t surv_by_tag = 0, prom_by_tag = 0, ylos_prom = 0;
};

Counts workloadCounts(const HeapConfig& cfg, uint64_t seed, size_t steps) {
    auto& a = initRegionAllocator(cfg);
    Counts c;
    {
        minortest::Workload w(a, 128, seed);
        w.run(steps);
        a.minorGC();
        c.checksum = w.checksum();
    }
    if (nurseryOf(a).regionMode()) NTA::tenureFlush(nurseryOf(a), oldgenOf(a));
#if ENABLE_GC_STATS
    const GCStats& st = nurseryOf(a).getStats();
    c.survived = st.objects_survived;
    c.promoted = st.objects_promoted;
    c.minors = st.minor_gc_count;
    c.grow = st.nursery_grow_events;
    c.cap = st.nursery_size_bytes;
    for (int i = 0; i < GCStats::NUM_ALLOC_TAGS; ++i) {
        c.surv_by_tag = c.surv_by_tag * 1000003 + st.survived_bytes_by_tag[i];
        c.prom_by_tag = c.prom_by_tag * 1000003 + st.promoted_bytes_by_tag[i];
    }
#endif
    return c;
}

int64_t sumIntList(HPointer l) {
    int64_t s = 0;
    while (l.ptr_ind == 0 && l.ptr != 0) {
        Cons* c = static_cast<Cons*>(AllocatorTestAccess::fromPointer(l));
        s += static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(c->head.p))->value;
        l = c->tail;
    }
    return s;
}

bool inRegionNursery(Allocator& a, HPointer hp) {
    return NTA::contains(nurseryOf(a), AllocatorTestAccess::fromPointer(hp));
}

}  // namespace

Testing::TestCase testRegionConfigValidation(
    "threaded-gc-07: region config parses (JSON, env) and validates",
    []() {
        HeapConfig c = regionConfig(1, 1);
        TEST_ASSERT(c.nursery_regions == 1 && c.tenure_mode == 1);
        applyRegionEnv(c, "0", "2", "1");
        TEST_ASSERT(c.nursery_regions == 0 && c.tenure_mode == 2 && c.nursery_region_eden_flip == 1);
        applyRegionEnv(c, nullptr, nullptr, "-1");
        TEST_ASSERT(c.nursery_regions == 0 && c.nursery_region_eden_flip == -1);
        bool threw = false;
        try { applyRegionEnv(c, "3", nullptr, nullptr); } catch (const std::invalid_argument&) { threw = true; }
        TEST_ASSERT(threw);
        applyRegionEnv(c, "2", nullptr, nullptr);
        TEST_ASSERT(c.nursery_regions == 2);
        // TG7d: auto (the default) resolves to regions on a compatible config
        // and to the legacy nursery on an incompatible one; it never throws.
        TEST_ASSERT(HeapConfig().nursery_regions == 2);
        HeapConfig autoc = regionConfig(1, 1);
        autoc.nursery_regions = 2;
        autoc.resolveNurseryRegions();
        TEST_ASSERT(autoc.nursery_regions == 1);
        autoc = regionConfig(1, 1);
        autoc.nursery_regions = 2;
        autoc.promotion_age = 2;
        autoc.validate();
        autoc.resolveNurseryRegions();
        TEST_ASSERT(autoc.nursery_regions == 0);
        autoc.validate();
        HeapConfig bad = regionConfig(1, 1);
        bad.promotion_age = 2;
        threw = false;
        try { bad.validate(); } catch (const std::invalid_argument& e) {
            threw = std::string(e.what()).find("P§12") != std::string::npos;
        }
        TEST_ASSERT(threw);
        bad = regionConfig(1, 1);
        bad.old_gen_bitmap_alloc = false;
        bad.incremental_mark = false;
        threw = false;
        try { bad.validate(); } catch (const std::invalid_argument& e) {
            threw = std::string(e.what()).find("old_gen_bitmap_alloc") != std::string::npos;
        }
        TEST_ASSERT(threw);
        bad = regionConfig(1, 1);
        bad.max_heap_size = 16ULL * 1024 * 1024;   // region 8 MiB < 4 x 1 MiB x ... still fits
        bad.nursery_max_block_count = 1024;        // X = 16 MiB: 4 x 16 MiB > 8 MiB
        threw = false;
        try { bad.validate(); } catch (const std::invalid_argument& e) {
            threw = std::string(e.what()).find("smaller than one heap slot") != std::string::npos;
        }
        TEST_ASSERT(threw);
        // The region cap on large pointer objects: the largest size class.
        TEST_ASSERT(ThreadLocalHeap::placeLargeFor(16 * 1024, Tag_Array, 1 << 20, regionConfig(1, 1), 8192) ==
                    ThreadLocalHeap::LargePlacement::Ylos);
        TEST_ASSERT(ThreadLocalHeap::placeLargeFor(8 * 1024, Tag_Array, 1 << 20, regionConfig(1, 1), 8192) ==
                    ThreadLocalHeap::LargePlacement::Nursery);
    });

Testing::TestCase testRegionGeometry(
    "threaded-gc-07: region slice sets: n extents at a power-of-two stride; retained commit reused",
    []() {
        for (int flip : {0, 1}) {
            HeapConfig cfg = regionConfig(1, 1);
            cfg.nursery_region_eden_flip = flip;
            auto& a = initRegionAllocator(cfg);
            RegionState* R = NTA::region(nurseryOf(a));
            TEST_ASSERT(R != nullptr);
            const unsigned n = flip ? 5u : 4u;
            TEST_ASSERT(R->n_ext == n);
            TEST_ASSERT((size_t{1} << R->stride_log2) == cfg.regionStrideBytes());
            TEST_ASSERT(AllocatorTestAccess::regionSlotCount(a) ==
                        AllocatorTestAccess::liveNurseryRegionBytes(a) / (n * cfg.regionStrideBytes()));
            for (int i = 0; i < 3; ++i) {
                TEST_ASSERT(R->x[i].base == R->set.slot_base + ((size_t)(n - 3 + i) << R->stride_log2));
                TEST_ASSERT(R->x[i].state == region::XState::Free);
            }
            TEST_ASSERT(R->eden_base == R->set.slot_base);
            // Acquire / release / re-acquire keeps the slot and its commit.
            NurserySliceSet s2 = AllocatorTestAccess::acquireSliceSet(a, 64 * 1024);
            TEST_ASSERT(s2.capacity == 64 * 1024 && s2.slot != R->set.slot);
            const size_t slot = s2.slot;
            AllocatorTestAccess::releaseSliceSet(a, s2);
            NurserySliceSet s3 = AllocatorTestAccess::acquireSliceSet(a, 32 * 1024);
            TEST_ASSERT(s3.slot == slot);
            TEST_ASSERT(AllocatorTestAccess::growSliceSet(a, s3, 32 * 1024) && s3.capacity == 64 * 1024);
            AllocatorTestAccess::releaseSliceSet(a, s3);
        }
    });

Testing::TestCase testRegionLegacyGeometryUnchanged(
    "threaded-gc-07: with regions off the slot table is the legacy table",
    []() {
        HeapConfig cfg = regionConfig(0, 1);
        auto& a = initRegionAllocator(cfg);
        TEST_ASSERT(!nurseryOf(a).regionMode());
        TEST_ASSERT(AllocatorTestAccess::regionSlotCount(a) == 0);
        TEST_ASSERT(AllocatorTestAccess::sliceBytes(a) == cfg.nurserySliceBytes());
        TEST_ASSERT(AllocatorTestAccess::sliceSlotCount(a) ==
                    (AllocatorTestAccess::liveNurseryRegionBytes(a) / 2) / cfg.nurserySliceBytes());
    });

Testing::TestCase testRegionObjectsMatchLegacy(
    "threaded-gc-07: E1 in a unit test: region mode 1 reproduces the legacy object counters (1, 4 workers)",
    []() {
        for (uint64_t seed : {21ull, 22ull}) {
            for (uint32_t n : {1u, 4u}) {
                const Counts ref = workloadCounts(regionConfig(0, n), seed, 60000);
                const Counts c = workloadCounts(regionConfig(1, n), seed, 60000);
                if (c.checksum != ref.checksum || c.survived != ref.survived ||
                    c.promoted != ref.promoted || c.minors != ref.minors ||
                    c.surv_by_tag != ref.surv_by_tag || c.prom_by_tag != ref.prom_by_tag ||
                    c.grow != ref.grow || c.cap != ref.cap) {
                    std::fprintf(stderr, "n=%u seed=%llu: survived %llu/%llu promoted %llu/%llu "
                                 "minors %llu/%llu grow %llu/%llu cap %llu/%llu checksum %d tags %d/%d\n",
                                 n, (unsigned long long)seed,
                                 (unsigned long long)c.survived, (unsigned long long)ref.survived,
                                 (unsigned long long)c.promoted, (unsigned long long)ref.promoted,
                                 (unsigned long long)c.minors, (unsigned long long)ref.minors,
                                 (unsigned long long)c.grow, (unsigned long long)ref.grow,
                                 (unsigned long long)c.cap, (unsigned long long)ref.cap,
                                 (int)(c.checksum == ref.checksum), (int)(c.surv_by_tag == ref.surv_by_tag),
                                 (int)(c.prom_by_tag == ref.prom_by_tag));
                    TEST_FAIL("region object counters differ from the legacy nursery");
                }
#if ENABLE_GC_STATS
                TEST_ASSERT(ref.minors > 10);
                TEST_ASSERT(ref.promoted > 0);
#endif
            }
        }
    });

Testing::TestCase testRegionLongListTenured(
    "threaded-gc-07: a 100,000-cell list is copied, handed over and tenured in spine runs",
    []() {
        for (uint32_t n : {1u, 4u}) {
            auto& a = initRegionAllocator(regionConfig(1, n));
            HPointer l = alloc::listNil();
            a.getRootSet().addRoot(&l);
            int64_t expect = 0;
            for (int64_t i = 0; i < 100000; ++i) {
                const HPointer x = alloc::allocInt(i);
                l = alloc::cons(alloc::boxed(x), l, true);
                expect += i;
            }
            a.minorGC();                    // Fresh
            TEST_ASSERT(sumIntList(l) == expect);
            TEST_ASSERT(inRegionNursery(a, l));
            a.minorGC();                    // hand-over: tenured by the job, root still young
            TEST_ASSERT(sumIntList(l) == expect);
            a.minorGC();                    // resolved: the root names the old copy
            TEST_ASSERT(sumIntList(l) == expect);
            TEST_ASSERT(!inRegionNursery(a, l));
            // Contiguity: consecutive cells' copies are adjacent in >= 95 % of pairs.
            size_t pairs = 0, adjacent = 0;
            HPointer p = l;
            while (p.ptr_ind == 0 && p.ptr != 0) {
                Cons* c = static_cast<Cons*>(AllocatorTestAccess::fromPointer(p));
                if (c->tail.ptr_ind == 0 && c->tail.ptr != 0) {
                    ++pairs;
                    const char* nx = static_cast<char*>(AllocatorTestAccess::fromPointer(c->tail));
                    if (nx == reinterpret_cast<char*>(c) + sizeof(Cons)) ++adjacent;
                }
                p = c->tail;
            }
            TEST_ASSERT(pairs == 99999);
            if (adjacent * 100 < pairs * 95) {
                std::fprintf(stderr, "n=%u: adjacent %zu of %zu\n", n, adjacent, pairs);
                TEST_FAIL("tenured spine is not contiguous");
            }
            a.getRootSet().removeRoot(&l);
        }
    });

Testing::TestCase testRegionRootResolve(
    "threaded-gc-07: a root holding a hand-over object ends up at its old copy; heals from Fresh",
    []() {
        auto& a = initRegionAllocator(regionConfig(1, 1));
        HPointer old_obj = alloc::allocInt(4242);
        HPointer holder = alloc::listNil();
        a.getRootSet().addRoot(&old_obj);
        a.getRootSet().addRoot(&holder);
        a.minorGC();                                     // old_obj: G_1 (Fresh)
        TEST_ASSERT(inRegionNursery(a, old_obj));
        // Epoch 1: a new object points at the G_1 object.
        holder = alloc::tuple2(alloc::boxed(old_obj), alloc::boxed(alloc::allocInt(7)), 0);
        a.minorGC();                                     // holder: G_2; its slot -> H; old_obj tenured
        TEST_ASSERT(inRegionNursery(a, old_obj));        // the root still names the original
        a.minorGC();                                     // merge: heal; roots into Retire resolved
        TEST_ASSERT(!inRegionNursery(a, old_obj));
        Tuple2* t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(holder));
        TEST_ASSERT(t->a.p.ptr == old_obj.ptr);          // healed to the same copy
        TEST_ASSERT(static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(old_obj))->value == 4242);
        a.minorGC();
        TEST_ASSERT(!inRegionNursery(a, holder));
        a.getRootSet().removeRoot(&old_obj);
        a.getRootSet().removeRoot(&holder);
    });

Testing::TestCase testRegionEveryTagTenured(
    "threaded-gc-07: every shape survives fill -> hand-over -> tenured -> old with its contents",
    []() {
        for (uint32_t n : {1u, 4u}) {
            auto& a = initRegionAllocator(regionConfig(1, n));
            minortest::Workload w(a, 64, 7 + n);
            w.run(3000);
            uint64_t sum = w.checksum();
            for (int g = 0; g < 5; ++g) {
                a.minorGC();
                TEST_ASSERT(w.checksum() == sum);   // contents read back through the heap
            }
            // Everything is old after the fill, hand-over and merge minors.
            size_t young = 0;
            for (const HPointer& s : w.slots)
                if (s.ptr_ind == 0 && s.ptr != 0 && inRegionNursery(a, s)) ++young;
            TEST_ASSERT(young == 0);
        }
    });

Testing::TestCase testRegionBuilderStaysInArea(
    "threaded-gc-07: a builder lives in builder areas at age 0, then ages and tenures once cleared",
    []() {
        auto& a = initRegionAllocator(regionConfig(1, 4));
        HPointer b = alloc::allocArrayBuilder(16);
        a.getRootSet().addRoot(&b);
        for (int g = 0; g < 5; ++g) {
            for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);
            a.minorGC();
            char* o = static_cast<char*>(AllocatorTestAccess::fromPointer(b));
            RegionState* R = NTA::region(nurseryOf(a));
            bool in_area = false;
            for (int i = 0; i < 3; ++i)
                if (R->x[i].state == region::XState::Fresh && o >= R->x[i].bld_lo && o < R->x[i].bld_hi) in_area = true;
            TEST_ASSERT(in_area);
            TEST_ASSERT(getHeader(o)->builder == 1 && getHeader(o)->age == 0);
        }
        alloc::clear_builder(getHeader(AllocatorTestAccess::fromPointer(b)));
        a.minorGC();                       // copied into the fill's survivor part, age 1
        TEST_ASSERT(inRegionNursery(a, b));
        TEST_ASSERT(getHeader(AllocatorTestAccess::fromPointer(b))->age == 1);
        a.minorGC();                       // hand-over: tenured by the job
        a.minorGC();                       // resolved
        TEST_ASSERT(!inRegionNursery(a, b));
        a.getRootSet().removeRoot(&b);
    });

namespace {
std::u16string readU16R(HPointer hp) {
    void* o = AllocatorTestAccess::fromPointer(hp);
    Header* h = getHeader(o);
    if (h->tag == Tag_LargeStringHeader) {
        o = AllocatorTestAccess::fromPointer(static_cast<LargeStringHeader*>(o)->body);
        h = getHeader(o);
    }
    TEST_ASSERT(h->tag == Tag_String);
    const ElmString* s = static_cast<const ElmString*>(o);
    return std::u16string(reinterpret_cast<const char16_t*>(s->chars), h->size);
}
}  // namespace

Testing::TestCase testRegionLargeBodies(
    "threaded-gc-07: split-header bodies follow their headers through hand-over and tenure",
    []() {
        for (uint32_t n : {1u, 4u}) {
            auto& a = initRegionAllocator(regionConfig(1, n));
            std::u16string big(40000, u'x');
            for (size_t i = 0; i < big.size(); i += 97) big[i] = static_cast<char16_t>(u'a' + (i % 26));
            HPointer s1 = alloc::allocString(big);
            HPointer s2 = alloc::allocString(big + u"y");
            HPointer dead = alloc::allocString(big + u"z");
            a.getRootSet().addRoot(&s1);
            a.getRootSet().addRoot(&s2);
            a.getRootSet().addRoot(&dead);
            const uint32_t tag0 = getHeader(AllocatorTestAccess::fromPointer(s1))->tag;
            TEST_ASSERT(tag0 == Tag_LargeStringHeader);
            for (int g = 0; g < 6; ++g) {
                for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);
                if (g == 1) dead = alloc::listNil();   // its header dies in a Fresh / Tenuring extent
                a.minorGC();
                TEST_ASSERT(readU16R(s1) == big);
                TEST_ASSERT(readU16R(s2) == big + u"y");
            }
            TEST_ASSERT(!inRegionNursery(a, s1));
            a.getRootSet().removeRoot(&s1);
            a.getRootSet().removeRoot(&s2);
            a.getRootSet().removeRoot(&dead);
        }
    });

Testing::TestCase testRegionYlosGenerations(
    "threaded-gc-07: YLOS generations: reached from a root, only through a tenuring object, or not at all",
    []() {
        auto& a = initRegionAllocator(regionConfig(1, 1));
        OldGenSpace& og = oldgenOf(a);
        auto makeArray = [&](size_t len, i64 base) {
            std::vector<HPointer> elems(len, alloc::listNil());
            HPointer arr = alloc::listNil();
            StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
            for (size_t i = 0; i < len; ++i) elems[i] = alloc::allocInt(base + static_cast<i64>(i));
            arr = alloc::arrayFromPointers(elems);
            return arr;
        };
        auto checkArray = [&](HPointer arr, size_t len, i64 base) {
            ElmArray* ar = static_cast<ElmArray*>(AllocatorTestAccess::fromPointer(arr));
            TEST_ASSERT(ar->length == len);
            for (u32 i = 0; i < len; ++i)
                TEST_ASSERT(static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(ar->elements[i].p))->value ==
                            base + static_cast<i64>(i));
        };
        HPointer ra = makeArray(3000, 0);          // (a) from a root
        a.getRootSet().addRoot(&ra);
        HPointer holder = alloc::listNil();
        a.getRootSet().addRoot(&holder);
        {
            HPointer rb = makeArray(3000, 100000);  // (b) only through a tuple
            holder = alloc::tuple2(alloc::boxed(rb), alloc::boxed(alloc::allocInt(9)), 0);
        }
        HPointer rc = makeArray(3000, 200000);     // (c) reachable at minor 1 only
        a.getRootSet().addRoot(&rc);
        void* pa = AllocatorTestAccess::fromPointer(ra);
        void* pc = AllocatorTestAccess::fromPointer(rc);
        TEST_ASSERT(og.isYoungLarge(pa) && og.isYoungLarge(pc));
        a.minorGC();                                // first reach: generation 1
        a.getRootSet().removeRoot(&rc);
        rc = alloc::listNil();
        a.minorGC();                                // hand-over: (a) by the pause, (b) by the job
        TEST_ASSERT(og.isYoungLarge(pa));
        a.minorGC();                                // merge: (a), (b) promoted in place; (c) freed
        TEST_ASSERT(!og.isYoungLarge(pa));
        TEST_ASSERT(!og.isYoungLarge(pc));
        checkArray(ra, 3000, 0);
        Tuple2* t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(holder));
        TEST_ASSERT(!og.isYoungLarge(AllocatorTestAccess::fromPointer(t->a.p)));
        checkArray(t->a.p, 3000, 100000);
        // Every element is old now (the merge resolved the promoted arrays' slots).
        ElmArray* ar = static_cast<ElmArray*>(pa);
        for (u32 i = 0; i < ar->length; ++i) TEST_ASSERT(!inRegionNursery(a, ar->elements[i].p));
        for (int g = 0; g < 3; ++g) a.minorGC();
        checkArray(ra, 3000, 0);
        a.getRootSet().removeRoot(&ra);
        a.getRootSet().removeRoot(&holder);
    });

Testing::TestCase testRegionRetentionBound(
    "threaded-gc-07: at most two survivor extents are in use between minors (200+ minors)",
    []() {
        auto& a = initRegionAllocator(regionConfig(1, 4));
        {
            minortest::Workload w(a, 256, 99);
            w.run(200000);
            const uint64_t sum = w.checksum();
            a.minorGC();
            TEST_ASSERT(w.checksum() == sum);
        }
        RegionState* R = NTA::region(nurseryOf(a));
        TEST_ASSERT(R->rs.minors >= 200);
        TEST_ASSERT(R->rs.max_nonfree == 2);
        TEST_ASSERT(R->rs.tenured > 0 && R->rs.merges + 1 >= R->rs.jobs);
    });

Testing::TestCase testRegionStwMajorBetweenMinors(
    "threaded-gc-07: a STW major between minors merges the job and keeps the tenured copies",
    []() {
        HeapConfig cfg = regionConfig(1, 1);
        cfg.incremental_mark = false;
        auto& a = initRegionAllocator(cfg);
        HPointer l = alloc::listNil();
        a.getRootSet().addRoot(&l);
        int64_t expect = 0;
        for (int64_t i = 0; i < 20000; ++i) {
            const HPointer x = alloc::allocInt(i);
            l = alloc::cons(alloc::boxed(x), l, true);
            expect += i;
        }
        a.minorGC();                     // Fresh
        a.minorGC();                     // hand-over: job built (mode 1: done, unmerged)
        TEST_ASSERT(inRegionNursery(a, l));
        a.majorGC();                     // joins + merges; greys the copies of tenured objects
        TEST_ASSERT(sumIntList(l) == expect);
        for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);
        a.minorGC();                     // the root resolves to the (marked, kept) copy
        TEST_ASSERT(!inRegionNursery(a, l));
        TEST_ASSERT(sumIntList(l) == expect);
        a.majorGC();
        TEST_ASSERT(sumIntList(l) == expect);
        a.getRootSet().removeRoot(&l);
    });

Testing::TestCase testParallelTenureObjectsEqualExact(
    "threaded-gc-07: the parallel tenure engine (sync, 4 threads) matches the exact engine's objects",
    []() {
        for (uint64_t seed : {23ull, 24ull}) {
            HeapConfig ex = regionConfig(1, 4);
            HeapConfig par = regionConfig(1, 4);
            par.tenure_sync_threads = 4;
            par.validate();
            const Counts a = workloadCounts(ex, seed, 60000);
            const Counts b = workloadCounts(par, seed, 60000);
            if (a.checksum != b.checksum || a.survived != b.survived || a.promoted != b.promoted ||
                a.minors != b.minors || a.surv_by_tag != b.surv_by_tag || a.prom_by_tag != b.prom_by_tag) {
                std::fprintf(stderr, "seed %llu: promoted %llu/%llu survived %llu/%llu minors %llu/%llu\n",
                             (unsigned long long)seed, (unsigned long long)b.promoted,
                             (unsigned long long)a.promoted, (unsigned long long)b.survived,
                             (unsigned long long)a.survived, (unsigned long long)b.minors,
                             (unsigned long long)a.minors);
                TEST_FAIL("parallel tenure engine object counters differ from the exact engine");
            }
        }
        // And against the legacy nursery.
        const Counts ref = workloadCounts(regionConfig(0, 4), 23, 60000);
        HeapConfig par = regionConfig(1, 4);
        par.tenure_sync_threads = 0;   // the minor's worker count
        par.validate();
        const Counts c = workloadCounts(par, 23, 60000);
        TEST_ASSERT(c.checksum == ref.checksum && c.promoted == ref.promoted && c.survived == ref.survived);
    });

Testing::TestCase testRegionParallelSuite(
    "threaded-gc-07: the long-list, root, YLOS and body scripts with the parallel tenure engine",
    []() {
        for (uint32_t sync : {0u, 4u}) {
            HeapConfig cfg = regionConfig(1, 4);
            cfg.tenure_sync_threads = sync;
            cfg.validate();
            auto& a = initRegionAllocator(cfg);
            minortest::Workload w(a, 128, 5 + sync);
            for (int g = 0; g < 40; ++g) {
                w.run(3000);
                const uint64_t s = w.checksum();
                a.minorGC();
                TEST_ASSERT(w.checksum() == s);
            }
            HPointer l = alloc::listNil();
            a.getRootSet().addRoot(&l);
            int64_t expect = 0;
            for (int64_t i = 0; i < 50000; ++i) {
                const HPointer x = alloc::allocInt(i);
                l = alloc::cons(alloc::boxed(x), l, true);
                expect += i;
            }
            for (int g = 0; g < 3; ++g) {
                a.minorGC();
                TEST_ASSERT(sumIntList(l) == expect);
            }
            TEST_ASSERT(!inRegionNursery(a, l));
            a.getRootSet().removeRoot(&l);
#if ENABLE_GC_STATS
            TEST_ASSERT(nurseryOf(a).getStats().rg.sync_parallel_jobs > 0);
#endif
        }
    });

namespace {
// P§3.16 / trap 7: an old object referenced ONLY by a tenuring object at t0
// must be marked by the cycle (the t0 young walk covers the Tenuring extent).
// Returns the value read back through the tenured copy after the handoff.
i64 t0CoversTenuringScript(bool skip_young_walk) {
    HeapConfig cfg = regionConfig(1, 1);
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = 4;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.conc_mark = 1;
    cfg.validate();
    auto& a = initRegionAllocator(cfg);
    ThreadLocalHeap* h = heapOf(a);
    HPointer o = alloc::allocInt(4242);
    a.getRootSet().addRoot(&o);
    for (int g = 0; g < 3; ++g) a.minorGC();          // o: old
    TEST_ASSERT(!inRegionNursery(a, o));
    HPointer y = alloc::tuple2(alloc::boxed(o), alloc::boxed(alloc::allocInt(1)), 0);
    a.getRootSet().addRoot(&y);
    a.getRootSet().removeRoot(&o);
    o = alloc::listNil();
    a.minorGC();                                       // y: Fresh
    h->test_snapshot_skip_young_walk_ = skip_young_walk;
    h->test_force_major_trigger_ = true;
    a.minorGC();                                       // y: Tenuring at this t0
    h->test_snapshot_skip_young_walk_ = false;
    for (int g = 0; g < 12 && h->getOldGen().cycleActive(); ++g) {
        for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);
        a.minorGC();
    }
    for (int g = 0; g < 3; ++g) {
        for (int i = 0; i < 20000; ++i) (void)alloc::allocInt(i);
        a.minorGC();
    }
    Tuple2* t = static_cast<Tuple2*>(AllocatorTestAccess::fromPointer(y));
    const i64 v = static_cast<ElmInt*>(AllocatorTestAccess::fromPointer(t->a.p))->value;
    a.getRootSet().removeRoot(&y);
    return v;
}
}  // namespace

Testing::TestCase testRegionT0CoversTenuring(
    "threaded-gc-07: the t0 young walk covers the Tenuring extent (an old object reachable only from it survives)",
    []() {
        TEST_ASSERT(t0CoversTenuringScript(false) == 4242);
#if ECO_HEAP_VALIDATE
        // Negative control: without the young walk IM1 must fire.
        const pid_t pid = fork();
        if (pid == 0) {
            (void)t0CoversTenuringScript(true);
            _exit(0);
        }
        int status = 0;
        TEST_ASSERT(waitpid(pid, &status, 0) == pid);
        TEST_ASSERT(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
#endif
    });
