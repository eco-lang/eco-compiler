/**
 * plans/jsonlargearray-nursery-oom-under-pressure.md: under
 * benchmarks/heap-config-gc-pressure.json the stress program JsonLargeArray
 * aborts with "out of memory: cannot allocate 8184 bytes for an object in
 * the nursery" while the old generation is nearly empty. 8,184 bytes is one
 * chunk of a chunked JSON array (makeJsonArrayFrom), sized to stay just
 * below the large-object threshold, so the largest object the nursery takes.
 *
 * The cause is the nursery's geometry. A minor copies eden's live objects
 * into the survivors (S_m), which with promotion_age 1 stay young until the
 * next minor, and eden may then hold only capacity - S_m. Eden fills to the
 * threshold (0.95 of the capacity) before a minor runs, so when nearly all
 * of it is live, eden is left about 5 % of the capacity: 6.5 KiB of a
 * 128 KiB per-heap nursery, too small for the chunk. The abort site was
 * ThreadLocalHeap::allocateSlow after its minor and its failSoftUnclamp.
 *
 * The scenario sets that state up exactly: an empty nursery, then rooted
 * Ints up to the minor threshold, then one 8,184-byte array through the
 * kernel's arrayFromPointers. Before HEAP_087 the survivors left eden 6,560
 * bytes and the child aborted; the threshold now holds back room for the
 * largest nursery object, so the array is placed, every Int reads back, and
 * no sub-threshold object goes to the young large-object space.
 *
 * Each arm runs in a forked child that initializes the allocator itself:
 * the first initialize in a process fixes the reservation and the region
 * geometry (HEAP_043), so initAllocator, which reserves with the default
 * config, would not run the pressure geometry.
 */

#include "NurseryLogJamTest.hpp"

#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#if !defined(_WIN32)
#include <sys/wait.h>
#endif

#include "../ForkedChild.hpp"
#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "HeapConfigJson.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using NTA = NurserySpaceTestAccess;

constexpr int kCorrect = 0;       // the array was placed and every Int read back
constexpr int kDefect = 10;       // an Int was lost or a small object went to the YLOS
constexpr int kNotReached = 11;   // the scenario's starting state did not hold

enum class Mode { Region, Legacy };

// benchmarks/heap-config-gc-pressure.json, the stress suite's GC-pressure config, as the stress
// run applies it; it has no nursery_regions key, so the Region arm is its auto setting.
HeapConfig pressureConfig(Mode mode) {
    HeapConfig cfg;
    applyHeapConfigJsonFile(cfg, REPO_ROOT "/benchmarks/heap-config-gc-pressure.json");
    cfg.nursery_regions = mode == Mode::Region ? 2 : 0;
    return cfg;
}

i64 intValue(size_t i) { return static_cast<i64>(i) * 7 + 1; }

// The scenario, run in a fresh forked child: initializes the allocator with `cfg`, empties the
// nursery, fills eden with rooted Ints up to the minor threshold, then allocates one array of the
// kernel's chunk size, the largest object below the large-object threshold.
int logJamScenario(const HeapConfig& cfg) {
    Allocator& a = Allocator::instance();
    a.initialize(cfg);
    a.initThread();
    NurserySpace& ns = AllocatorTestAccess::getThreadHeap(a)->getNursery();
    const size_t F = (a.getLargeObjectThreshold() - 1 - sizeof(ElmArray)) / sizeof(Unboxable);
    const size_t big = sizeof(ElmArray) + F * sizeof(Unboxable);
    const size_t capacity = ns.capacityBytes();
    const size_t threshold = ns.minorThresholdBytes();
    std::fprintf(stderr, "  region=%d capacity=%zu threshold=%zu array=%zu\n", (int)ns.regionMode(),
                 capacity, threshold, big);

    // Nothing is rooted, so two minors leave no survivors.
    a.minorGC();
    a.minorGC();
    if (NTA::bytesAllocated(ns) != 0) {
        std::fprintf(stderr, "  the nursery is not empty after two minors: %zu bytes\n",
                     NTA::bytesAllocated(ns));
        return kNotReached;
    }

    std::vector<HPointer> ints(capacity / sizeof(ElmInt), alloc::listNil());
    StackRootRangeGuard ig(ints.data(), ints.size(), ~uint64_t{0});
    const uint64_t seq = ns.minorSeq();
    size_t n = 0;
    while (n < ints.size() && NTA::bytesAllocated(ns) + sizeof(ElmInt) < threshold) {
        ints[n] = alloc::allocInt(intValue(n));
        ++n;
    }
    const size_t filled = NTA::bytesAllocated(ns);
    if (ns.minorSeq() != seq) {
        std::fprintf(stderr, "  a minor ran during the fill\n");
        return kNotReached;
    }
    std::fprintf(stderr, "  filled %zu bytes with %zu live Ints; eden after a minor: %zu\n", filled, n,
                 capacity - filled);

    std::vector<HPointer> slots(F, alloc::listNil());
    HPointer arr = alloc::arrayFromPointers(slots);
    StackRootRangeGuard ag(&arr, 1, ~uint64_t{0});
    auto* placed = static_cast<ElmArray*>(a.resolve(arr));
    if (placed->length != F) return kDefect;
    for (size_t i = 0; i < n; ++i) {
        auto* v = static_cast<ElmInt*>(a.resolve(ints[i]));
        if (getHeader(v)->tag != Tag_Int || v->value != intValue(i)) {
            std::fprintf(stderr, "  Int %zu of %zu lost\n", i, n);
            return kDefect;
        }
    }
#if ENABLE_GC_STATS
    // Every object here is below the threshold, so any YLOS placement is a small object's.
    if (a.getCombinedStats().lp.ylos_allocs != 0) {
        std::fprintf(stderr, "  a sub-threshold object was placed in the YLOS\n");
        return kDefect;
    }
#endif
    return kCorrect;
}

// Runs the scenario in a forked child; it must exit having placed the array.
void runLogJam(Mode mode) {
#if !defined(_WIN32)
    const HeapConfig cfg = pressureConfig(mode);
    const ForkedChild::ChildResult r = ForkedChild::runInChild([&] { return logJamScenario(cfg); });
    std::fputs(r.stderrText.c_str(), stdout);
    if (WIFEXITED(r.status) && WEXITSTATUS(r.status) == kCorrect) return;
    if (WIFEXITED(r.status) && WEXITSTATUS(r.status) == kDefect) {
        TEST_FAIL("the scenario's check failed: " + r.stderrText);
    }
    if (WIFEXITED(r.status) && WEXITSTATUS(r.status) == kNotReached) {
        TEST_FAIL("the scenario did not reach its starting state: " + r.stderrText);
    }
    TEST_FAIL("the child died (wait status " + std::to_string(r.status) + "): " +
              r.stderrText.substr(0, 600));
#else
    (void)mode;   // fork-based; POSIX only
#endif
}

// A per-side nursery 8 bytes short of three reserves is rejected; one of exactly three is accepted.
void checkReserveRule() {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 16 * 1024;
    cfg.large_object_threshold = 8 * 1024;
    cfg.initial_old_gen_size = 1024 * 1024;
    cfg.nursery_block_count = 4;
    cfg.nursery_max_block_count = 4;
    TEST_ASSERT(cfg.nurseryReserveBytes() == 8184);
    cfg.validate();   // 32 KiB per side >= 3 x 8,184

    HeapConfig small = cfg;
    small.alloc_buffer_size = 8 * 1024;   // 16 KiB per side
    bool rejected = false;
    try {
        small.validate();
    } catch (const std::invalid_argument& e) {
        rejected = std::string(e.what()).find("HEAP_087") != std::string::npos;
    }
    TEST_ASSERT(rejected);

    HeapConfig tiny_threshold = cfg;
    tiny_threshold.large_object_threshold = 1024;   // the 4 KiB inline bound is the reserve
    TEST_ASSERT(tiny_threshold.nurseryReserveBytes() == 4096);
}

}  // namespace

Testing::TestCase testNurseryLogJamRegion(
    "Nursery log jam (region): survivors at the threshold leave eden room for the largest nursery object",
    [] { runLogJam(Mode::Region); });

Testing::TestCase testNurseryLogJamLegacy(
    "Nursery log jam (legacy): survivors at the threshold leave eden room for the largest nursery object",
    [] { runLogJam(Mode::Legacy); });

Testing::TestCase testNurseryReserveRule(
    "HEAP_087: validate requires a per-side nursery of three reserves; the reserve's size",
    [] { checkReserveRule(); });
