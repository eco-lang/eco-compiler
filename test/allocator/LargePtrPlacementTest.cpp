/**
 * threaded-gc-04b (plans/threaded-gc-04b-young-large-objects.md): large
 * pointer-bearing objects are placed in the nursery (up to a cap) or in the
 * young large-object space (YLOS), never born in the old gen. Configs are
 * built programmatically (unit tests do not see ECO_HEAP_CONFIG).
 */

#include "LargePtrPlacementTest.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <vector>

#if !defined(_WIN32)
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "Heap.hpp"
#include "HeapConfigJson.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "P1Census.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using LP = ThreadLocalHeap::LargePlacement;

constexpr size_t KiB = 1024;
constexpr size_t MiB = 1024 * 1024;

LP place(size_t size, uint32_t tag, size_t nursery, const HeapConfig& cfg) {
    return ThreadLocalHeap::placeLargeFor(size, tag, nursery, cfg);
}

// A 64 KiB-per-side nursery that does not grow. `divisor` sets the
// large-pointer nursery cap (2 = 32 KiB; 0 = always the YLOS).
HeapConfig smallConfig(uint32_t divisor) {
    HeapConfig cfg;
    cfg.alloc_buffer_size         = 32 * 1024;
    cfg.nursery_block_count       = 4;
    cfg.nursery_max_block_count   = 4;
    cfg.initial_old_gen_size      = 256 * 1024;
    cfg.max_heap_size             = 256ULL * 1024 * 1024;
    cfg.large_object_threshold    = 8 * 1024;
    cfg.large_ptr_nursery_divisor = divisor;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode            = 0;
    cfg.validate();
    return cfg;
}

i64 intValue(HPointer hp) {
    void* obj = Allocator::instance().resolve(hp);
    if (obj == nullptr || getHeader(obj)->tag != Tag_Int) {
        throw std::runtime_error("expected a heap Int");
    }
    return static_cast<ElmInt*>(obj)->value;
}

// Allocates garbage so the nursery is reused (overwrites dead cells).
void churn(size_t n) {
    for (size_t i = 0; i < n; ++i) (void)alloc::allocInt(static_cast<i64>(0x5A5A0000 + i));
}

// Allocates a large (n-slot) pointer array through Allocator::allocate and
// fills it with fresh Ints value(i) = i * mul, the kernel pattern: elements
// rooted across the array's allocation, then pushed with no allocation in
// between. Returns the array, rooted by the caller.
// An Int array of exactly 8 KiB: >= LOT (8 KiB) and at the nursery placement
// cap, the largest uniform class (plans/large-object-space.md D3).
constexpr size_t kArrayAtCap = (8 * 1024 - sizeof(ElmArray)) / sizeof(Unboxable);
static_assert((sizeof(ElmArray) + kArrayAtCap * sizeof(Unboxable)) == 8 * 1024,
              "kArrayAtCap must make an 8 KiB array");

HPointer makeLargeIntArray(Allocator& alloc, size_t n, i64 mul) {
    std::vector<HPointer> elems(n, alloc::listNil());
    StackRootRangeGuard guard(elems.data(), elems.size(), ~uint64_t{0});
    for (size_t i = 0; i < n; ++i) elems[i] = alloc::allocInt(static_cast<i64>(i) * mul);
    const size_t total = (sizeof(ElmArray) + n * sizeof(Unboxable) + 7) & ~size_t{7};
    ElmArray* a0 = static_cast<ElmArray*>(alloc.allocate(total, Tag_Array));
    a0->header.size = static_cast<u32>(n);
    a0->length = 0;
    a0->padding = 0;
    a0->header.unboxed = 0;
    for (size_t i = 0; i < n; ++i) alloc::arrayPush(a0, alloc::boxed(elems[i]), true);
    return alloc.wrap(a0);
}

void checkLargeIntArray(Allocator& alloc, HPointer arr, size_t n, i64 mul, const char* what) {
    ElmArray* a = static_cast<ElmArray*>(alloc.resolve(arr));
    if (a->length != n) throw std::runtime_error(std::string(what) + ": length");
    for (size_t i = 0; i < n; ++i) {
        if (intValue(a->elements[i].p) != static_cast<i64>(i) * mul) {
            throw std::runtime_error(std::string(what) + ": element " + std::to_string(i) +
                                     " lost");
        }
    }
}

}  // namespace

Testing::TestCase testPlaceLargeDecisions(
    "threaded-gc-04b: placeLarge picks pointer-free / nursery / YLOS",
    []() {
        HeapConfig cfg;  // divisor 8, no fixed bound
        cfg.large_ptr_nursery_max_size = 0;
        const size_t nursery = 64 * MiB;  // divisor cap = 8 MiB

        // Pointer-free tags stay in the old gen, pinned.
        TEST_ASSERT(place(100 * KiB, Tag_String, nursery, cfg) == LP::PointerFree);
        TEST_ASSERT(place(100 * KiB, Tag_ByteBuffer, nursery, cfg) == LP::PointerFree);
        TEST_ASSERT(place(100 * KiB, Tag_Int, nursery, cfg) == LP::PointerFree);
        // Pointer-bearing: under the cap -> nursery, over it -> YLOS.
        TEST_ASSERT(place(100 * KiB, Tag_Array, nursery, cfg) == LP::Nursery);
        TEST_ASSERT(place(8 * MiB, Tag_Array, nursery, cfg) == LP::Nursery);
        TEST_ASSERT(place(8 * MiB + 8, Tag_Array, nursery, cfg) == LP::Ylos);
        TEST_ASSERT(place(100 * KiB, Tag_Closure, nursery, cfg) == LP::Nursery);
        TEST_ASSERT(place(100 * KiB, Tag_Custom, nursery, cfg) == LP::Nursery);
        // The divisor scales with the nursery.
        TEST_ASSERT(place(100 * KiB, Tag_Array, 512 * KiB, cfg) == LP::Ylos);

        // Divisor 0: never the nursery.
        HeapConfig d0 = cfg;
        d0.large_ptr_nursery_divisor = 0;
        TEST_ASSERT(place(9 * KiB, Tag_Array, nursery, d0) == LP::Ylos);
        TEST_ASSERT(place(9 * KiB, Tag_String, nursery, d0) == LP::PointerFree);

        // A fixed bound below the divisor's wins.
        HeapConfig m128 = cfg;
        m128.large_ptr_nursery_max_size = 128 * KiB;
        TEST_ASSERT(place(100 * KiB, Tag_Array, nursery, m128) == LP::Nursery);
        TEST_ASSERT(place(200 * KiB, Tag_Array, nursery, m128) == LP::Ylos);

        // A fixed bound above the divisor's does not.
        HeapConfig m64 = cfg;
        m64.large_ptr_nursery_max_size = 64 * MiB;
        TEST_ASSERT(place(8 * MiB, Tag_Array, nursery, m64) == LP::Nursery);
        TEST_ASSERT(place(9 * MiB, Tag_Array, nursery, m64) == LP::Ylos);

        // A fixed bound below the large-object threshold sends every large
        // pointer object to the YLOS.
        HeapConfig tiny = cfg;
        tiny.large_ptr_nursery_max_size = 4 * KiB;
        TEST_ASSERT(place(cfg.large_object_threshold, Tag_Array, nursery, tiny) == LP::Ylos);
    });

Testing::TestCase testLargePtrConfigJson(
    "threaded-gc-04b: large_ptr_nursery_* JSON keys and validation",
    []() {
        HeapConfig def;
        TEST_ASSERT(def.large_ptr_nursery_divisor == LARGE_PTR_NURSERY_DIVISOR);
        TEST_ASSERT(def.large_ptr_nursery_max_size == LARGE_PTR_NURSERY_MAX_SIZE);

#if !defined(_WIN32)
        auto load = [](const char* json, HeapConfig& out) {
            char path[] = "/tmp/eco-gc04b-cfg-XXXXXX";
            int fd = mkstemp(path);
            TEST_ASSERT(fd >= 0);
            TEST_ASSERT(write(fd, json, std::strlen(json)) ==
                        static_cast<ssize_t>(std::strlen(json)));
            close(fd);
            applyHeapConfigJsonFile(out, path);
            unlink(path);
        };

        HeapConfig a;
        load("{\"large_ptr_nursery_divisor\": 4, \"large_ptr_nursery_max_size\": \"1M\"}", a);
        TEST_ASSERT(a.large_ptr_nursery_divisor == 4);
        TEST_ASSERT(a.large_ptr_nursery_max_size == 1 * MiB);
        a.validate();

        HeapConfig b;
        load("{\"large_ptr_nursery_divisor\": 0, \"large_ptr_nursery_max_size\": 131072}", b);
        TEST_ASSERT(b.large_ptr_nursery_divisor == 0);
        TEST_ASSERT(b.large_ptr_nursery_max_size == 128 * KiB);
        b.validate();
#endif

        HeapConfig bad;
        bad.large_ptr_nursery_max_size = 1001;
        bool threw = false;
        try {
            bad.validate();
        } catch (const std::invalid_argument&) {
            threw = true;
        }
        TEST_ASSERT(threw);
    });

// ============================================================================
// Step 2: nursery placement
// ============================================================================

Testing::TestCase testLargeArrayInNurseryKeepsChildren(
    "threaded-gc-04b: a nursery-placed large array keeps its children (S2)",
    []() {
        auto& alloc = initAllocator(smallConfig(2));      // cap 32 KiB
        // plans/large-object-space.md D3: nursery placement is capped at the
        // largest uniform class (8 KiB); an 8 KiB array is >= LOT and fits it.
        const size_t n = kArrayAtCap;
        HPointer arr = makeLargeIntArray(alloc, n, 7);
        alloc.getRootSet().addRoot(&arr);
        TEST_ASSERT(alloc.isInNursery(alloc.resolve(arr)));
        for (int k = 0; k < 3; ++k) {
            churn(3000);
            alloc.minorGC();
            checkLargeIntArray(alloc, arr, n, 7, "after minor");
        }
        alloc.majorGC();
        checkLargeIntArray(alloc, arr, n, 7, "after major");
        alloc.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testLargeArrayPromotesByCopy(
    "threaded-gc-04b: a nursery-placed large array promotes by copy, unpinned",
    []() {
        auto& alloc = initAllocator(smallConfig(2));
        const size_t n = kArrayAtCap;                     // 8 KiB (D3 cap)
        HPointer arr = makeLargeIntArray(alloc, n, 3);
        alloc.getRootSet().addRoot(&arr);
        alloc.minorGC();
        TEST_ASSERT(alloc.isInNursery(alloc.resolve(arr)));   // age 0 -> 1
        alloc.minorGC();                                       // promoted (region: tenured)
        tenureMerge(alloc);
        ElmArray* a = static_cast<ElmArray*>(alloc.resolve(arr));
        TEST_ASSERT(!alloc.isInNursery(a));
        TEST_ASSERT(a->header.pin == 0);
        for (size_t i = 0; i < n; ++i) {
            TEST_ASSERT(!alloc.isInNursery(alloc.resolve(a->elements[i].p)));
        }
        checkLargeIntArray(alloc, arr, n, 3, "promoted");
        alloc.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testLargeRegionInNursery(
    "threaded-gc-04b: a large closure-group region is carved from the nursery",
    []() {
        auto& alloc = initAllocator(smallConfig(8));      // cap 8 KiB: region still fits
        const size_t count = 700;                         // 700 x 16 B = 11,200 B
        char* region = static_cast<char*>(alloc.allocateRegionSlow(count * sizeof(ElmInt)));
        TEST_ASSERT(alloc.isInNursery(region));
        std::vector<HPointer> keep;
        for (size_t i = 0; i < count; ++i) {
            ElmInt* e = reinterpret_cast<ElmInt*>(region + i * sizeof(ElmInt));
            std::memset(e, 0, sizeof(ElmInt));
            initHeaderForTag(&e->header, Tag_Int, sizeof(ElmInt));
            e->value = static_cast<i64>(i);
            if (i % 100 == 0) keep.push_back(alloc.wrap(e));
        }
        for (auto& h : keep) alloc.getRootSet().addRoot(&h);
        alloc.minorGC();
        alloc.minorGC();
        alloc.majorGC();
        for (size_t k = 0; k < keep.size(); ++k) {
            TEST_ASSERT(intValue(keep[k]) == static_cast<i64>(k * 100));
            alloc.getRootSet().removeRoot(&keep[k]);
        }
    });

// ============================================================================
// Step 3: the young large-object space (divisor 0 forces every large pointer
// object into it)
// ============================================================================

namespace {

OldGenSpace& oldGen(Allocator& alloc) {
    return AllocatorTestAccess::getThreadHeap(alloc)->getOldGen();
}

#if ENABLE_GC_STATS
const LargePtrStats& ogLp(Allocator& alloc) { return oldGen(alloc).getStats().lp; }
const LargePtrStats& nurseryLp(Allocator& alloc) {
    return AllocatorTestAccess::getThreadHeap(alloc)->getNursery().getStats().lp;
}
#endif

}  // namespace

Testing::TestCase testYlosChildrenSurviveMinors(
    "threaded-gc-04b: a YLOS array's young children survive minors and a major",
    []() {
        auto& alloc = initAllocator(smallConfig(0));
        const size_t n = 2000;
        HPointer arr = makeLargeIntArray(alloc, n, 7);
        alloc.getRootSet().addRoot(&arr);
        void* a0 = alloc.resolve(arr);
        TEST_ASSERT(!alloc.isInNursery(a0));
        TEST_ASSERT(oldGen(alloc).isYoungLarge(a0));
        for (int k = 0; k < 3; ++k) {
            churn(3000);
            alloc.minorGC();
            TEST_ASSERT(alloc.resolve(arr) == a0);        // never moves
            checkLargeIntArray(alloc, arr, n, 7, "YLOS after minor");
        }
        alloc.majorGC();
        checkLargeIntArray(alloc, arr, n, 7, "YLOS after major");
        alloc.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testYlosAgesAndPromotesInPlace(
    "threaded-gc-04b: a YLOS object ages 0 -> 1 and promotes in place at minor 2",
    []() {
        auto& alloc = initAllocator(smallConfig(0));
        auto& og = oldGen(alloc);
        HPointer arr = makeLargeIntArray(alloc, 1500, 3);
        alloc.getRootSet().addRoot(&arr);
        void* a0 = alloc.resolve(arr);
        TEST_ASSERT(getHeader(a0)->age == 0);
        TEST_ASSERT(og.youngLargeCount() == 1);
#if ENABLE_GC_STATS
        const uint64_t promoted0 = ogLp(alloc).ylos_promoted_in_place;
#endif
        alloc.minorGC();
        TEST_ASSERT(og.isYoungLarge(a0));
        TEST_ASSERT(getHeader(a0)->age == 1);
        // Its elements were copied to to-space (age 1), not promoted.
        ElmArray* a = static_cast<ElmArray*>(a0);
        TEST_ASSERT(alloc.isInNursery(alloc.resolve(a->elements[0].p)));
        alloc.minorGC();
        tenureMerge(alloc);
        TEST_ASSERT(alloc.resolve(arr) == a0);           // same address
        TEST_ASSERT(!og.isYoungLarge(a0));
        TEST_ASSERT(og.youngLargeCount() == 0);
        TEST_ASSERT(!og.mayBeYoungLarge(a0));              // bounding box empty
        TEST_ASSERT(getHeader(a0)->pin == 1);
        for (u32 i = 0; i < a->length; ++i) {            // children promoted too
            TEST_ASSERT(!alloc.isInNursery(alloc.resolve(a->elements[i].p)));
        }
#if ENABLE_GC_STATS
        TEST_ASSERT(ogLp(alloc).ylos_promoted_in_place == promoted0 + 1);
#endif
        checkLargeIntArray(alloc, arr, 1500, 3, "promoted in place");
        alloc.majorGC();
        checkLargeIntArray(alloc, arr, 1500, 3, "promoted in place, after major");
        alloc.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testYlosUnreachableFreedAtMinor(
    "threaded-gc-04b: an unreachable YLOS object is freed at the next minor",
    []() {
        auto& alloc = initAllocator(smallConfig(0));
        auto& og = oldGen(alloc);
        void* a0 = alloc.resolve(makeLargeIntArray(alloc, 1500, 1));   // unrooted
        TEST_ASSERT(og.isYoungLarge(a0));
#if ENABLE_GC_STATS
        const uint64_t freed0 = ogLp(alloc).ylos_freed_minor;
#endif
        alloc.minorGC();
        TEST_ASSERT(!og.isYoungLarge(a0));
        TEST_ASSERT(og.youngLargeCount() == 0);
#if ENABLE_GC_STATS
        TEST_ASSERT(ogLp(alloc).ylos_freed_minor == freed0 + 1);
#endif
        // The cell is reusable: allocations of the same size keep working and
        // the heap stays consistent through a major.
        HPointer again = makeLargeIntArray(alloc, 1500, 2);
        alloc.getRootSet().addRoot(&again);
        alloc.minorGC();
        alloc.majorGC();
        checkLargeIntArray(alloc, again, 1500, 2, "after reuse");
        alloc.getRootSet().removeRoot(&again);
    });

Testing::TestCase testYlosUnreachableFreedAtMajor(
    "threaded-gc-04b: an unreachable YLOS object is retired by a major with no minor",
    []() {
        auto& alloc = initAllocator(smallConfig(0));
        auto& og = oldGen(alloc);
        HPointer keep = makeLargeIntArray(alloc, 1200, 5);
        alloc.getRootSet().addRoot(&keep);
        void* dead = alloc.resolve(makeLargeIntArray(alloc, 1500, 1));   // unrooted
        TEST_ASSERT(og.isYoungLarge(dead));
#if ENABLE_GC_STATS
        const uint64_t retired0 = ogLp(alloc).ylos_retired_major;
#endif
        alloc.majorGC();
        TEST_ASSERT(!og.isYoungLarge(dead));
        TEST_ASSERT(og.isYoungLarge(alloc.resolve(keep)));   // reachable: still young
        TEST_ASSERT(og.youngLargeCount() == 1);
#if ENABLE_GC_STATS
        TEST_ASSERT(ogLp(alloc).ylos_retired_major == retired0 + 1);
#endif
        alloc.minorGC();
        alloc.minorGC();
        checkLargeIntArray(alloc, keep, 1200, 5, "survivor");
        alloc.getRootSet().removeRoot(&keep);
    });

Testing::TestCase testYlosReachedOnlyThroughNurseryObject(
    "threaded-gc-04b: a YLOS object reachable only through a young tuple survives",
    []() {
        auto& alloc = initAllocator(smallConfig(0));
        auto& og = oldGen(alloc);
        HPointer arr = makeLargeIntArray(alloc, 1500, 9);
        HPointer tup;
        {
            StackRootRangeGuard g(&arr, 1, 1);
            tup = alloc::tuple2(alloc::boxed(arr), alloc::unboxedInt(42), 0x4);   // b: Int
        }
        alloc.getRootSet().addRoot(&tup);
        auto arrOf = [&]() {
            return static_cast<Tuple2*>(alloc.resolve(tup))->a.p;
        };
        // Allocating the tuple may itself run a minor, so the age at each
        // step is not pinned here (testYlosAgesAndPromotesInPlace pins it):
        // the array must survive every step and end up promoted in place.
        void* a0 = alloc.resolve(arrOf());
        TEST_ASSERT(!alloc.isInNursery(a0));
        churn(3000);
        alloc.minorGC();
        TEST_ASSERT(alloc.resolve(arrOf()) == a0);
        checkLargeIntArray(alloc, arrOf(), 1500, 9, "through tuple, minor");
        alloc.majorGC();                                  // marked through the nursery
        checkLargeIntArray(alloc, arrOf(), 1500, 9, "through tuple, major");
        for (int k = 0; k < 3; ++k) {
            churn(3000);
            alloc.minorGC();
        }
        TEST_ASSERT(!og.isYoungLarge(a0));                // promoted in place
        TEST_ASSERT(!alloc.isInNursery(alloc.resolve(tup)));
        TEST_ASSERT(alloc.resolve(arrOf()) == a0);
        checkLargeIntArray(alloc, arrOf(), 1500, 9, "through tuple, promoted");
        alloc.getRootSet().removeRoot(&tup);
    });

Testing::TestCase testYlosBuilderNeverAges(
    "threaded-gc-04b: a YLOS builder stays age 0 while filled across minors",
    []() {
        auto& alloc = initAllocator(smallConfig(0));
        auto& og = oldGen(alloc);
        const size_t n = 1500;
        HPointer arr = alloc::allocArrayBuilder(n);
        alloc.getRootSet().addRoot(&arr);
        void* a0 = alloc.resolve(arr);
        TEST_ASSERT(og.isYoungLarge(a0));
        TEST_ASSERT(getHeader(a0)->builder == 1);
        // Fill in three rounds with a minor between each: every element is
        // allocated AFTER the array (a builder may hold younger children).
        for (int round = 0; round < 3; ++round) {
            for (size_t i = round * (n / 3); i < (round + 1) * (n / 3); ++i) {
                HPointer e = alloc::allocInt(static_cast<i64>(i) * 11);
                alloc::arrayPush(static_cast<ElmArray*>(alloc.resolve(arr)), alloc::boxed(e), true);
            }
            churn(3000);
            alloc.minorGC();
            TEST_ASSERT(og.isYoungLarge(a0));
            TEST_ASSERT(getHeader(a0)->age == 0);
        }
        checkLargeIntArray(alloc, arr, n, 11, "builder filled");
        alloc::clear_builder(getHeader(a0));
        alloc.minorGC();                                  // age 0 -> 1
        TEST_ASSERT(og.isYoungLarge(a0));
        alloc.minorGC();                                  // promoted in place
        tenureMerge(alloc);
        TEST_ASSERT(!og.isYoungLarge(a0));
        checkLargeIntArray(alloc, arr, n, 11, "builder promoted");
        alloc.majorGC();
        checkLargeIntArray(alloc, arr, n, 11, "builder after major");
        alloc.getRootSet().removeRoot(&arr);
    });

Testing::TestCase testYlosReachedTwiceScannedOnce(
    "threaded-gc-04b: a YLOS object with two roots is scanned once per minor",
    []() {
        auto& alloc = initAllocator(smallConfig(0));
        HPointer r1 = makeLargeIntArray(alloc, 1500, 4);
        HPointer r2 = r1;
        alloc.getRootSet().addRoot(&r1);
        alloc.getRootSet().addRoot(&r2);
#if ENABLE_GC_STATS
        const uint64_t reach0 = nurseryLp(alloc).ylos_reach_calls;
        const uint64_t scans0 = nurseryLp(alloc).ylos_scans;
#endif
        alloc.minorGC();
#if ENABLE_GC_STATS
        TEST_ASSERT(nurseryLp(alloc).ylos_reach_calls == reach0 + 2);
        TEST_ASSERT(nurseryLp(alloc).ylos_scans == scans0 + 1);
#endif
        TEST_ASSERT(alloc.resolve(r1) == alloc.resolve(r2));
        checkLargeIntArray(alloc, r1, 1500, 4, "two roots");
        alloc.getRootSet().removeRoot(&r2);
        alloc.getRootSet().removeRoot(&r1);
    });

// ============================================================================
// Step 6: the P1 census covers the YLOS (census and validate builds)
// ============================================================================

#if P1_CENSUS_COMPILED
namespace {
struct YlosCensusMode {
    explicit YlosCensusMode(int m) {
        p1::setModeForTesting(m);
        p1::setSampleForTesting(1);
        p1::resetForTesting();
        NurserySpaceTestAccess::resetSurvivorWriteCensus();
    }
    ~YlosCensusMode() {
        p1::resetForTesting();
        p1::setSampleForTesting(0);
        p1::setModeForTesting(-1);
    }
};
}  // namespace
#endif

Testing::TestCase testYlosCensusWriteSiteCaught(
    "threaded-gc-04b: detector W judges a YLOS object like a nursery object",
    []() {
#if P1_CENSUS_COMPILED
        YlosCensusMode cm(1);
        auto& alloc = initAllocator(smallConfig(0));
        const size_t n = 1500;
        HPointer arr = alloc::allocArray(n);              // YLOS, age 0, not a builder
        alloc.getRootSet().addRoot(&arr);
        TEST_ASSERT(oldGen(alloc).isYoungLarge(alloc.resolve(arr)));
        HPointer e = alloc::allocInt(1);
        alloc::arrayPush(static_cast<ElmArray*>(alloc.resolve(arr)), alloc::boxed(e), true);
        TEST_ASSERT(p1::countsForTesting().w_violations == 0);   // fresh: legal
        alloc.minorGC();                                  // age 1: survived
        TEST_ASSERT(oldGen(alloc).isYoungLarge(alloc.resolve(arr)));
        e = alloc::allocInt(2);
        alloc::arrayPush(static_cast<ElmArray*>(alloc.resolve(arr)), alloc::boxed(e), true);
        TEST_ASSERT(p1::countsForTesting().w_violations == 1);
        alloc.getRootSet().removeRoot(&arr);
#endif
    });

Testing::TestCase testYlosCensusPromotedInPlaceRecorded(
    "threaded-gc-04b: detector O watches a YLOS object promoted in place",
    []() {
#if P1_CENSUS_COMPILED
        YlosCensusMode cm(1);
        auto& alloc = initAllocator(smallConfig(0));
        HPointer arr = makeLargeIntArray(alloc, 1500, 1);
        alloc.getRootSet().addRoot(&arr);
        alloc.minorGC();
        const uint64_t rec0 = p1::countsForTesting().o_recorded;
        alloc.minorGC();                                  // promoted in place
        tenureMerge(alloc);
        void* a0 = alloc.resolve(arr);
        TEST_ASSERT(!oldGen(alloc).isYoungLarge(a0));
        TEST_ASSERT(p1::countsForTesting().o_recorded > rec0);
        // A raw write after promotion is what O exists to catch.
        static_cast<ElmArray*>(a0)->elements[7].p = static_cast<ElmArray*>(a0)->elements[8].p;
        alloc.majorGC();
        TEST_ASSERT(p1::countsForTesting().o_mismatched >= 1);
        alloc.getRootSet().removeRoot(&arr);
#endif
    });

Testing::TestCase testYlosCensusSurvivorChecked(
    "threaded-gc-04b: detector N re-hashes YLOS survivors at the next minor",
    []() {
#if P1_CENSUS_COMPILED
        YlosCensusMode cm(1);
        auto& alloc = initAllocator(smallConfig(0));
        auto& nursery = AllocatorTestAccess::getThreadHeap(alloc)->getNursery();
        NurserySpaceTestAccess::setSurvivorWriteCensus(nursery, true);
        // Region nursery: detector N re-hashes a minor's census in the NEXT
        // minor's tenure join, which needs a running job; on a fresh heap the
        // first minor has none. A rooted survivor and one minor start the
        // pipeline, so the minors below are the steady state.
        HPointer warm = alloc::listNil();
        alloc.getRootSet().addRoot(&warm);
        if (alloc.getConfig().nursery_regions == 1) { warm = alloc::allocInt(1); alloc.minorGC(); }
        HPointer arr = makeLargeIntArray(alloc, 1500, 1);
        alloc.getRootSet().addRoot(&arr);
        alloc.minorGC();                                  // recorded: young survivor
        alloc.minorGC();                                  // checked, clean
        auto c1 = NurserySpaceTestAccess::survivorWriteCensusCounts();
        TEST_ASSERT(c1.ylos_checked >= 1);
        TEST_ASSERT(c1.mismatched == 0);
        NurserySpaceTestAccess::setSurvivorWriteCensus(nursery, false);
        alloc.getRootSet().removeRoot(&arr);
        alloc.getRootSet().removeRoot(&warm);

        // A survivor that is written: the next minor's check catches it.
        auto& alloc2 = initAllocator(smallConfig(0));
        auto& nursery2 = AllocatorTestAccess::getThreadHeap(alloc2)->getNursery();
        NurserySpaceTestAccess::resetSurvivorWriteCensus();
        NurserySpaceTestAccess::setSurvivorWriteCensus(nursery2, true);
        HPointer warm2 = alloc::listNil();
        alloc2.getRootSet().addRoot(&warm2);
        if (alloc2.getConfig().nursery_regions == 1) { warm2 = alloc::allocInt(2); alloc2.minorGC(); }
        HPointer arr2 = makeLargeIntArray(alloc2, 1500, 1);
        alloc2.getRootSet().addRoot(&arr2);
        alloc2.minorGC();                                 // recorded (age 1, young)
        ElmArray* a = static_cast<ElmArray*>(alloc2.resolve(arr2));
        TEST_ASSERT(oldGen(alloc2).isYoungLarge(a));
        a->elements[3].p = a->elements[4].p;               // write after survival
        alloc2.minorGC();
        auto c2 = NurserySpaceTestAccess::survivorWriteCensusCounts();
        TEST_ASSERT(c2.ylos_checked >= 1);
        TEST_ASSERT(c2.mismatched >= 1);
        NurserySpaceTestAccess::setSurvivorWriteCensus(nursery2, false);
        alloc2.getRootSet().removeRoot(&arr2);
        alloc2.getRootSet().removeRoot(&warm2);
#endif
    });

// ============================================================================
// Experiment E1 (P§5a): large-array placement microbenchmark. Does nothing
// unless ECO_E1_BENCH=1. Arms are set in the HeapConfig (unit tests ignore
// ECO_HEAP_CONFIG), so every arm runs in one binary and one environment.
// ============================================================================

Testing::TestCase testE1LargeArrayPlacementBench(
    "threaded-gc-04b: E1 large-array placement bench (ECO_E1_BENCH=1 to run)",
    []() {
#if ENABLE_GC_STATS
        const char* on = std::getenv("ECO_E1_BENCH");
        if (on == nullptr || on[0] != '1') return;
        const size_t arms[] = {0, 4 * MiB, 1 * MiB, 128 * KiB, 16 * KiB};
        const char* armName[] = {"A 0", "B 4M", "C 1M", "D 128K", "E 16K"};
        const size_t sizes[] = {10000, 100000, 1000000};
        const size_t kTotalElems = 24000000;   // per (arm, size)
        const size_t kLive = 4;                // arrays kept alive (a ring)
        std::fprintf(stderr, "E1 arm     elems   wall_ms  minor_n minor_ms  minor_max_ms major_n major_ms "
                             "promoted_MB survived_MB nursery_n ylos_n ylos_promo ylos_reach\n");
        for (size_t s : sizes) {
            for (size_t a = 0; a < sizeof(arms) / sizeof(arms[0]); ++a) {
                HeapConfig cfg;                           // production defaults
                cfg.large_ptr_nursery_max_size = arms[a];
                cfg.gc_thread_mode = 0;
                cfg.validate();
                auto& alloc = initAllocator(cfg);
                std::vector<HPointer> ring(kLive, alloc::listNil());
                StackRootRangeGuard ring_guard(ring.data(), ring.size(), ~uint64_t{0});
                const auto t0 = std::chrono::steady_clock::now();
                const size_t rounds = kTotalElems / s;
                for (size_t r = 0; r < rounds; ++r) {
                    HPointer arr = alloc::allocArrayBuilder(s);
                    StackRootRangeGuard g(&arr, 1, 1);
                    // Filled across allocations, like JsArray.initialize.
                    for (size_t i = 0; i < s; ++i) {
                        HPointer e = alloc::allocInt(static_cast<i64>(i));
                        alloc::arrayPush(static_cast<ElmArray*>(alloc.resolve(arr)),
                                         alloc::boxed(e), true);
                    }
                    alloc::clear_builder(getHeader(alloc.resolve(arr)));
                    ring[r % kLive] = arr;
                }
                const double wall_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - t0).count();
                ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(alloc);
                GCStats st;
                st.combine(h->getNursery().getStats());
                st.combine(h->getOldGen().getStats());
                st.combine(h->getStats());
                uint64_t prom = 0, surv = 0;
                for (int t = 0; t < GCStats::NUM_ALLOC_TAGS; ++t) {
                    prom += st.promoted_bytes_by_tag[t];
                    surv += st.survived_bytes_by_tag[t];
                }
                std::fprintf(stderr,
                    "E1 %-6s %8zu %9.1f %8llu %8.1f %12.2f %7llu %8.1f %11.1f %11.1f %9llu %6llu %10llu %10llu\n",
                    armName[a], s, wall_ms,
                    (unsigned long long)st.minor_gc_count, st.total_minor_gc_time_ns / 1e6,
                    st.max_minor_gc_time_ns / 1e6,
                    (unsigned long long)st.major_gc_count, st.total_major_gc_time_ns / 1e6,
                    prom / 1e6, surv / 1e6,
                    (unsigned long long)st.lp.nursery_allocs, (unsigned long long)st.lp.ylos_allocs,
                    (unsigned long long)st.lp.ylos_promoted_in_place,
                    (unsigned long long)st.lp.ylos_reach_calls);
            }
        }
#endif
    });
