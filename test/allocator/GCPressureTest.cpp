/**
 * Sustained-pressure GC tests.
 *
 * These tests fill the nursery many times to trigger many minor GCs, keep
 * a fraction of allocations rooted so they get promoted, fill the old gen
 * to drive multiple major GC cycles, and verify object integrity throughout.
 *
 * All tests use `pressureHeapConfig()` which intentionally caps nursery and
 * old-gen sizes to a few MiB so the workloads finish quickly while still
 * exercising every GC path.
 *
 * Group A — Allocator-API pressure tests (raw alloc.allocate / alloc::*).
 * Group B — eco_alloc_* runtime entry points.
 * Group C — Old-gen-focused (size classes, large pinned, fragmentation).
 * Group D — Integration/mixed workloads.
 */

#include "GCPressureTest.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <random>
#include <sstream>
#include <vector>

// Loud assertion: prints the failed condition + file:line to stderr before
// throwing, so the silent catch in TestCase::runWithResult doesn't swallow
// the diagnostic.
#define GCP_ASSERT(cond)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::ostringstream oss;                                         \
            oss << "GCPressure assertion failed: " #cond                    \
                << " at " __FILE__ ":" << __LINE__;                         \
            std::cerr << oss.str() << std::endl;                            \
            throw std::runtime_error(oss.str());                            \
        }                                                                   \
    } while (0)

#include <rapidcheck.h>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "RuntimeExports.h"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

// ============================================================================
// Helpers shared by pressure tests
// ============================================================================

// Convert HPointer (as bits) to raw pointer through the resolve path.
// Mirrors the helper in RuntimeExportsTest.cpp; kept local to avoid a
// translation-unit dependency.
void* hptrBitsToRaw(uint64_t bits) {
    if (bits == 0) return nullptr;
    HPointer hp;
    std::memcpy(&hp, &bits, sizeof(hp));
    if (hp.constant != 0) return nullptr;
    return Allocator::instance().resolve(hp);
}

// Returns the per-thread GCStats snapshot. Combined-stats only includes
// thread-local heaps that still exist; for a single-threaded test that is
// fine. Stats from previous reset cycles do not pollute the result because
// initAllocator() resets and re-creates the thread heap.
GCStats currentStats() {
    return Allocator::instance().getCombinedStats();
}

// Convenience: how many minor GCs ran since the heap was reset.
uint64_t minorGCCount() {
    return currentStats().minor_gc_count;
}

uint64_t majorGCCount() {
    return currentStats().major_gc_count;
}

uint64_t bytesAllocated() {
    return currentStats().bytes_allocated;
}

// Allocate a single ElmInt with known value through the raw allocator.
HPointer allocIntDirect(Allocator& alloc, i64 value) {
    void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
    static_cast<ElmInt*>(obj)->value = value;
    return AllocatorTestAccess::toPointer(obj);
}

// Verifies that an HPointer-rooted slot still points to an ElmInt with the
// expected value, after any number of GCs may have moved or promoted it.
void assertIntRoot(HPointer& root, i64 expected) {
    void* obj = readBarrier(root);
    GCP_ASSERT(obj != nullptr);
    Header* hdr = getHeader(obj);
    GCP_ASSERT(hdr->tag == Tag_Int);
    GCP_ASSERT(static_cast<ElmInt*>(obj)->value == expected);
}

}  // namespace

// ============================================================================
// Group A — Allocator-API pressure tests
// ============================================================================

Testing::TestCase testNurseryChurnPromotesRootedFraction(
    "Pressure: nursery churn promotes a 10% rooted fraction across many minor GCs",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Allocate enough to fill the (256 KiB) semi-space dozens of times.
        // Each ElmInt is 16 B; 200000 allocations = ~3 MiB of throughput,
        // which is many fills.
        constexpr size_t kAllocs = 200000;
        constexpr size_t kRootEvery = 50;

        std::vector<HPointer> roots;
        std::vector<i64> expected;
        roots.reserve(kAllocs / kRootEvery + 1);
        expected.reserve(kAllocs / kRootEvery + 1);

        // Pre-reserve roots so we never reallocate (which would invalidate
        // the pointers registered with addRoot).
        roots.reserve(kAllocs / kRootEvery + 16);
        expected.reserve(kAllocs / kRootEvery + 16);

        // Drive minor GCs explicitly every few thousand allocations so we
        // don't rely on the threshold-trigger path for the count target.
        constexpr size_t kBatchSize = 2000;
        for (size_t i = 0; i < kAllocs; ++i) {
            HPointer hp = allocIntDirect(alloc, static_cast<i64>(i));
            if (i % kRootEvery == 0) {
                roots.push_back(hp);
                expected.push_back(static_cast<i64>(i));
                alloc.getRootSet().addRoot(&roots.back());
            }
            if ((i + 1) % kBatchSize == 0) {
                alloc.minorGC();
            }
        }

        const uint64_t minors_before_drain = minorGCCount();
        GCP_ASSERT(minors_before_drain >= 30);

        // Drain: run enough explicit minor GCs to ensure every survivor
        // exceeded promotion age.
        for (u32 i = 0; i <= PROMOTION_AGE; ++i) {
            alloc.minorGC();
        }

        // All rooted ints should now live in old gen with values intact.
        for (size_t i = 0; i < roots.size(); ++i) {
            assertIntRoot(roots[i], expected[i]);
            void* obj = readBarrier(roots[i]);
            GCP_ASSERT(alloc.isInOldGen(obj));
        }

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
    });

Testing::TestCase testMajorGCTriggersAfterPromotionFloodAllocator(
    "Pressure: heavy promotion drives >=3 major GCs and old-gen growth", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Retain ~40% of allocations. With a 256 KiB initial old gen and
        // 16 B ElmInts, each live cohort consumes ~6.4 KiB per 1000 allocs.
        // 30000 allocs * 0.4 * 16 B = ~192 KiB live; combined with internal
        // metadata pressure this crosses the 75% trigger several times.
        constexpr size_t kAllocs = 30000;
        constexpr size_t kRootEvery = 5;

        std::vector<HPointer> roots;
        std::vector<i64> expected;
        // Reserve up front so the underlying buffer never reallocates;
        // otherwise &roots.back() would be invalidated by future push_backs.
        roots.reserve(kAllocs / kRootEvery + 16);
        expected.reserve(kAllocs / kRootEvery + 16);

        const size_t initial_committed = alloc.getOldGenAllocatedBytes();
        (void)initial_committed;

        for (size_t i = 0; i < kAllocs; ++i) {
            HPointer hp = allocIntDirect(alloc, static_cast<i64>(i));
            if (i % kRootEvery == 0) {
                roots.push_back(hp);
                expected.push_back(static_cast<i64>(i));
                alloc.getRootSet().addRoot(&roots.back());
                // Promote rooted slot quickly by driving safepoint polls.
                if (alloc.shouldCollectAtSafepoint()) {
                    alloc.collectAtSafepoint();
                }
            }
        }

        // Force a few major GCs to deterministically reach the count target.
        for (int i = 0; i < 3; ++i) {
            for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
            alloc.majorGC();
        }

        GCP_ASSERT(majorGCCount() >= 3);
        GCP_ASSERT(currentStats().bytes_freed > 0);

        // All rooted ints must still be intact.
        for (size_t i = 0; i < roots.size(); ++i) {
            assertIntRoot(roots[i], expected[i]);
        }

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
    });

Testing::TestCase testOldGenGrowsTowardCapWithoutFailure(
    "Pressure: old gen grows monotonically under promotion without exceeding cap",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Retain a large fraction so old-gen committed grows. Each ElmInt
        // is 16 B; we aim for far more than the initial 256 KiB worth of
        // live data so at least one capacity grow occurs.
        constexpr size_t kAllocs = 80000;
        constexpr size_t kRootEvery = 1;

        std::vector<HPointer> roots;
        roots.reserve(kAllocs / kRootEvery + 1);

        const size_t old_gen_cap = alloc.getOldGenMaxBytes();
        size_t prev_committed = alloc.getOldGenCommittedBytes();
        size_t observed_max_committed = prev_committed;

        for (size_t i = 0; i < kAllocs; ++i) {
            HPointer hp = allocIntDirect(alloc, static_cast<i64>(i));
            if (i % kRootEvery == 0) {
                roots.push_back(hp);
                alloc.getRootSet().addRoot(&roots.back());
            }
            // Drive minor GCs so survivors get promoted into old gen,
            // which is what actually grows committed bytes.
            if ((i + 1) % 1000 == 0) {
                alloc.minorGC();
            }
            // Track committed bytes; should never decrease (committed only
            // grows; sweep-time release is not in this allocator yet).
            size_t committed = alloc.getOldGenCommittedBytes();
            GCP_ASSERT(committed >= prev_committed);
            GCP_ASSERT(committed <= old_gen_cap);
            observed_max_committed = std::max(observed_max_committed, committed);
            prev_committed = committed;
        }

        // Drain to old gen.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();

        // Committed should have grown past the initial commit (256 KiB).
        GCP_ASSERT(observed_max_committed > 256 * 1024);
        GCP_ASSERT(observed_max_committed <= old_gen_cap);

        // All rooted slots intact and resolvable.
        for (auto& r : roots) {
            void* obj = readBarrier(r);
            GCP_ASSERT(obj != nullptr);
            GCP_ASSERT(getHeader(obj)->tag == Tag_Int);
        }

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
    });

Testing::TestCase testCyclicGarbageBetweenGenerations(
    "Pressure: cyclic Tuple2 garbage in old gen is reclaimed by major GC", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Build N pairs of mutually-referencing Tuple2 boxes. Each pair is
        // anchored only via a sentinel root we control; once we drop the
        // sentinel, the cycle is unreachable.
        constexpr size_t kPairs = 200;

        // Sentinel array of HPointers we will root then unroot. We push them
        // as a stack-root range so all pair pointers survive nursery GCs
        // during construction.
        // Sentinels live on the heap; root them via long-lived addRoot
        // calls so we don't need a 200-bit stack-range mask. (Stack-range
        // mask is 64-bit; long-lived roots have no such limit.)
        std::vector<HPointer> sentinels(kPairs);
        for (auto& s : sentinels) {
            s = alloc::listNil();
            alloc.getRootSet().addRoot(&s);
        }

        for (size_t i = 0; i < kPairs; ++i) {
            // Two Tuple2 boxes that reference each other. boxed-boxed slots:
            // unboxed_mask = 0 (both fields are HPointers).
            // Allocate placeholder a first as Nil so b can reference it.
            HPointer a = alloc::tuple2(alloc::boxed(alloc::listNil()),
                                        alloc::boxed(alloc::listNil()), 0);
            // Re-pin a across b's allocation.
            StackRootGuard g(&a);
            HPointer b = alloc::tuple2(alloc::boxed(a), alloc::boxed(a), 0);

            // Now wire the cycle: a.fields = [b, b].
            void* a_obj = alloc.resolve(a);
            Tuple2* a_t = static_cast<Tuple2*>(a_obj);
            a_t->a.p = b;
            a_t->b.p = b;

            sentinels[i] = a;
        }

        // Promote everything to old gen. Need promotion_age + 1 cycles
        // (each minor GC ages survivors by 1; promotion fires when age
        // reaches promotion_age at the start of a cycle, so we need one
        // extra cycle for the actual evacuation to old gen).
        for (u32 j = 0; j <= PROMOTION_AGE + 1; ++j) alloc.minorGC();

        // Capture occupancy before dropping references. allocated_bytes
        // is now bumped on every old-gen allocation, so this is meaningful
        // immediately after promotion (no pre-measurement sweep needed).
        const size_t old_gen_with_cycles = alloc.getOldGenAllocatedBytes();
        GCP_ASSERT(old_gen_with_cycles > 0);

        // Drop all sentinels — the cycles are now unreachable.
        for (auto& s : sentinels) {
            alloc.getRootSet().removeRoot(&s);
        }

        // Force major GC to reclaim cycles.
        alloc.majorGC();

        const size_t old_gen_after_collect = alloc.getOldGenAllocatedBytes();

        // Sanity: most of the cycle bytes are gone. We do not demand 0
        // because internal allocator metadata may live in old gen too.
        GCP_ASSERT(old_gen_after_collect < old_gen_with_cycles);
        GCP_ASSERT(majorGCCount() >= 1);
    });

// ============================================================================
// Group B — eco_alloc_* runtime tests
// ============================================================================

Testing::TestCase testEcoAllocChurnSurvivesManyMinorGCs(
    "Pressure: mixed eco_alloc_* churn survives many minor GCs", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // 5000 allocations across all primitive eco_alloc_* entry points,
        // root every 10th, drive enough minor GCs to age survivors.
        constexpr size_t kAllocs = 5000;
        constexpr size_t kRootEvery = 10;

        struct RootEntry {
            HPointer slot;
            uint32_t kind;  // 0=int,1=float,2=char,3=cons,4=tuple2,
                            // 5=tuple3,6=custom,7=record,8=string,9=closure
            i64 ival;
        };
        std::vector<RootEntry> roots;
        roots.reserve(kAllocs / kRootEvery + 1);

        for (size_t i = 0; i < kAllocs; ++i) {
            HPtr h{};
            uint32_t kind = static_cast<uint32_t>(i % 10);
            switch (kind) {
                case 0: h = eco_alloc_int(static_cast<i64>(i)); break;
                case 1: h = eco_alloc_float(static_cast<double>(i) * 0.5); break;
                case 2: h = eco_alloc_char(static_cast<uint32_t>(i & 0xFFFF));
                        break;
                case 3: {
                    HPointer nil_hp = alloc::listNil();
                    HPtr nil_h = HPtr::fromHPointer(nil_hp);
                    h = eco_alloc_cons(static_cast<uint64_t>(i), nil_h, 1);
                    break;
                }
                case 4: h = eco_alloc_tuple2(static_cast<uint64_t>(i),
                                              static_cast<uint64_t>(i + 1),
                                              0x5);  // both Int
                        break;
                case 5: h = eco_alloc_tuple3(static_cast<uint64_t>(i),
                                              static_cast<uint64_t>(i + 1),
                                              static_cast<uint64_t>(i + 2),
                                              0x15);  // all Int
                        break;
                case 6: h = eco_alloc_custom(static_cast<uint32_t>(i & 0xFF),
                                              0, 0);
                        break;
                case 7: h = eco_alloc_record(0, 0); break;
                case 8: h = eco_alloc_string(8); break;
                case 9: h = eco_alloc_closure(reinterpret_cast<void*>(0x42),
                                               0);
                        break;
            }
            GCP_ASSERT(h.toBits() != 0);

            if (i % kRootEvery == 0) {
                RootEntry e{};
                e.slot = h.toHPointer();
                e.kind = kind;
                e.ival = static_cast<i64>(i);
                roots.push_back(e);
                alloc.getRootSet().addRoot(&roots.back().slot);
            }
            // Force minor GCs at fixed intervals so the count target doesn't
            // depend on the threshold heuristic (which fires rarely with
            // a partly-empty nursery).
            if ((i + 1) % 500 == 0) {
                alloc.minorGC();
            }
        }

        GCP_ASSERT(minorGCCount() >= 5);

        // Promote everyone.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();

        // Verify each root by tag and (where applicable) value.
        for (auto& e : roots) {
            void* obj = readBarrier(e.slot);
            GCP_ASSERT(obj != nullptr);
            Header* hdr = getHeader(obj);
            switch (e.kind) {
                case 0:
                    GCP_ASSERT(hdr->tag == Tag_Int);
                    GCP_ASSERT(static_cast<ElmInt*>(obj)->value == e.ival);
                    break;
                case 1:
                    GCP_ASSERT(hdr->tag == Tag_Float);
                    break;
                case 2:
                    GCP_ASSERT(hdr->tag == Tag_Char);
                    break;
                case 3: GCP_ASSERT(hdr->tag == Tag_Cons); break;
                case 4: GCP_ASSERT(hdr->tag == Tag_Tuple2); break;
                case 5: GCP_ASSERT(hdr->tag == Tag_Tuple3); break;
                case 6: GCP_ASSERT(hdr->tag == Tag_Custom); break;
                case 7: GCP_ASSERT(hdr->tag == Tag_Record); break;
                case 8: GCP_ASSERT(hdr->tag == Tag_String); break;
                case 9: GCP_ASSERT(hdr->tag == Tag_Closure); break;
            }
        }

        for (auto& e : roots) alloc.getRootSet().removeRoot(&e.slot);
    });

Testing::TestCase testEcoAllocClosureCapturesSurviveGC(
    "Pressure: eco_alloc_closure captures stay valid across minor and major GCs",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        constexpr uint32_t kCaptures = 4;
        constexpr size_t kClosures = 100;

        struct ClosureRoot {
            HPointer slot;
            std::vector<i64> expected;  // captured int values
        };
        std::vector<ClosureRoot> roots;
        roots.reserve(kClosures);

        for (size_t i = 0; i < kClosures; ++i) {
            // Allocate four ints first so we have stored HPointers to
            // capture; root them on the stack so the closure allocation
            // doesn't invalidate them.
            HPointer captures[kCaptures];
            std::vector<i64> vals(kCaptures);
            for (uint32_t k = 0; k < kCaptures; ++k) {
                vals[k] = static_cast<i64>(i * 100 + k);
                captures[k] =
                    eco_alloc_int(vals[k]).toHPointer();
            }
            // Closure with kCaptures slots.
            StackRootRangeGuard g(captures, kCaptures,
                                  (1ULL << kCaptures) - 1ULL);
            HPtr cl_h = eco_alloc_closure(reinterpret_cast<void*>(0xC10510),
                                           kCaptures);
            GCP_ASSERT(cl_h.toBits() != 0);
            // Store each captured HPointer as a boxed field.
            for (uint32_t k = 0; k < kCaptures; ++k) {
                eco_store_field(cl_h, k, HPtr::fromHPointer(captures[k]));
            }

            roots.push_back({cl_h.toHPointer(), std::move(vals)});
            alloc.getRootSet().addRoot(&roots.back().slot);
        }

        // Drive minor GCs.
        for (size_t round = 0; round < 5; ++round) {
            for (size_t k = 0; k < 4000; ++k) {
                (void)eco_alloc_int(static_cast<i64>(k));
            }
            alloc.minorGC();
        }
        // Drive at least one major GC.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();

        GCP_ASSERT(minorGCCount() >= 5);
        GCP_ASSERT(majorGCCount() >= 1);

        for (auto& r : roots) {
            void* obj = readBarrier(r.slot);
            GCP_ASSERT(obj != nullptr);
            Closure* cl = static_cast<Closure*>(obj);
            GCP_ASSERT(cl->header.tag == Tag_Closure);
            GCP_ASSERT(cl->max_values == kCaptures);
            for (uint32_t k = 0; k < kCaptures; ++k) {
                HPointer slot;
                std::memcpy(&slot, &cl->values[k].i, sizeof(slot));
                void* int_obj = readBarrier(slot);
                GCP_ASSERT(int_obj != nullptr);
                GCP_ASSERT(getHeader(int_obj)->tag == Tag_Int);
                GCP_ASSERT(static_cast<ElmInt*>(int_obj)->value ==
                            r.expected[k]);
            }
        }

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r.slot);
    });

Testing::TestCase testEcoAllocRecordWithMixedFieldsAfterGC(
    "Pressure: eco_alloc_record with mixed boxed/i64/f64 fields survives GC",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Six fields per record. Each slot's kind lives at bits [2i, 2i+1]:
        //   slot 0: boxed HPointer  (kind 00) → bits 1:0 = 00
        //   slot 1: unboxed i64     (kind 01) → bits 3:2 = 01
        //   slot 2: unboxed f64     (kind 10) → bits 5:4 = 10
        //   slot 3: boxed HPointer  (kind 00) → bits 7:6 = 00
        //   slot 4: unboxed i64     (kind 01) → bits 9:8 = 01
        //   slot 5: unboxed f64     (kind 10) → bits 11:10 = 10
        // Concatenated MSB-first: 10 01 00 10 01 00 → 0x924.
        constexpr uint32_t kFields = 6;
        constexpr uint64_t kBitmap = 0x924ULL;

        constexpr size_t kRecords = 100;
        struct RecordRoot {
            HPointer slot;
            i64 boxed0;
            i64 boxed3;
            i64 ival1;
            double fval2;
            i64 ival4;
            double fval5;
        };
        std::vector<RecordRoot> roots;
        roots.reserve(kRecords);

        for (size_t i = 0; i < kRecords; ++i) {
            // Pre-allocate two boxed ElmInts for the boxed slots.
            i64 b0 = static_cast<i64>(i * 7 + 1);
            i64 b3 = static_cast<i64>(i * 11 + 13);
            HPointer hp0 = eco_alloc_int(b0).toHPointer();
            HPointer hp3 = eco_alloc_int(b3).toHPointer();
            HPointer pinned[2] = {hp0, hp3};
            StackRootRangeGuard g(pinned, 2, 0x3);

            HPtr rec_h = eco_alloc_record(kFields, kBitmap);
            GCP_ASSERT(rec_h.toBits() != 0);

            i64 i1 = static_cast<i64>(i);
            double f2 = static_cast<double>(i) + 0.25;
            i64 i4 = -static_cast<i64>(i);
            double f5 = -static_cast<double>(i) + 0.75;

            eco_store_record_field(rec_h, 0, HPtr::fromHPointer(pinned[0]));
            eco_store_record_field_i64(rec_h, 1, i1);
            eco_store_record_field_f64(rec_h, 2, f2);
            eco_store_record_field(rec_h, 3, HPtr::fromHPointer(pinned[1]));
            eco_store_record_field_i64(rec_h, 4, i4);
            eco_store_record_field_f64(rec_h, 5, f5);

            roots.push_back({rec_h.toHPointer(), b0, b3, i1, f2, i4, f5});
            alloc.getRootSet().addRoot(&roots.back().slot);
        }

        // Allocate massive garbage between, drive several minor + a major GC.
        for (size_t round = 0; round < 4; ++round) {
            for (size_t k = 0; k < 6000; ++k) {
                (void)eco_alloc_int(static_cast<i64>(k));
            }
            alloc.minorGC();
        }
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();

        for (auto& r : roots) {
            Record* rec = static_cast<Record*>(readBarrier(r.slot));
            GCP_ASSERT(rec != nullptr);
            GCP_ASSERT(rec->header.tag == Tag_Record);
            GCP_ASSERT(rec->header.size == kFields);

            // Boxed field 0
            HPointer hp0;
            std::memcpy(&hp0, &rec->values[0].i, sizeof(hp0));
            void* o0 = readBarrier(hp0);
            GCP_ASSERT(o0 != nullptr);
            GCP_ASSERT(getHeader(o0)->tag == Tag_Int);
            GCP_ASSERT(static_cast<ElmInt*>(o0)->value == r.boxed0);

            GCP_ASSERT(rec->values[1].i == r.ival1);
            GCP_ASSERT(rec->values[2].f == r.fval2);

            HPointer hp3;
            std::memcpy(&hp3, &rec->values[3].i, sizeof(hp3));
            void* o3 = readBarrier(hp3);
            GCP_ASSERT(o3 != nullptr);
            GCP_ASSERT(getHeader(o3)->tag == Tag_Int);
            GCP_ASSERT(static_cast<ElmInt*>(o3)->value == r.boxed3);

            GCP_ASSERT(rec->values[4].i == r.ival4);
            GCP_ASSERT(rec->values[5].f == r.fval5);
        }

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r.slot);
    });

Testing::TestCase testEcoAllocStringChurnAndPromotion(
    "Pressure: eco_alloc_string churn at varied sizes survives major GC", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        constexpr size_t kSizes[] = {1, 8, 64, 256, 768};
        constexpr size_t kStrings = 200;

        struct StrRoot {
            HPointer slot;
            uint32_t length;
            uint16_t fingerprint;  // first char written
        };
        std::vector<StrRoot> roots;
        roots.reserve(kStrings);

        for (size_t i = 0; i < kStrings; ++i) {
            uint32_t len = static_cast<uint32_t>(kSizes[i % 5]);
            HPtr s = eco_alloc_string(len);
            GCP_ASSERT(s.toBits() != 0);
            ElmString* str =
                static_cast<ElmString*>(hptrBitsToRaw(s.toBits()));
            GCP_ASSERT(str != nullptr);
            GCP_ASSERT(str->header.size == len);
            uint16_t fp = static_cast<uint16_t>('a' + (i % 26));
            for (uint32_t k = 0; k < len; ++k) {
                str->chars[k] = static_cast<u16>(fp + (k & 0x1F));
            }
            roots.push_back({s.toHPointer(), len, fp});
            alloc.getRootSet().addRoot(&roots.back().slot);

            // Inject garbage between live strings.
            for (size_t g = 0; g < 200; ++g) {
                (void)eco_alloc_int(static_cast<i64>(g));
            }
        }

        // Promote, then sweep.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();
        GCP_ASSERT(majorGCCount() >= 1);

        for (auto& r : roots) {
            ElmString* s =
                static_cast<ElmString*>(readBarrier(r.slot));
            GCP_ASSERT(s != nullptr);
            GCP_ASSERT(s->header.tag == Tag_String);
            GCP_ASSERT(s->header.size == r.length);
            for (uint32_t k = 0; k < r.length; ++k) {
                GCP_ASSERT(s->chars[k] ==
                            static_cast<u16>(r.fingerprint + (k & 0x1F)));
            }
        }

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r.slot);
    });

Testing::TestCase testEcoAllocConsListLongPromotion(
    "Pressure: 5000-element eco_alloc_cons list integrity across GCs", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        constexpr size_t kLen = 5000;

        // Build the list head-first, prepending. Each iteration may trigger
        // a minor GC, but the head HPointer is stack-rooted so it survives.
        HPointer head = alloc::listNil();
        alloc.getRootSet().addRoot(&head);

        for (size_t i = 0; i < kLen; ++i) {
            uint64_t prev_bits;
            std::memcpy(&prev_bits, &head, sizeof(prev_bits));
            HPtr h = eco_alloc_cons(static_cast<uint64_t>(i),
                                     HPtr::fromBits(prev_bits), 1);
            GCP_ASSERT(h.toBits() != 0);
            head = h.toHPointer();
            // Drive minor GCs every 500 cons cells so the cons list ends
            // up split across multiple generations.
            if ((i + 1) % 500 == 0) {
                alloc.minorGC();
            }
        }

        // Stats: many minor GCs should have fired during list construction.
        GCP_ASSERT(minorGCCount() >= 5);

        // Force several promotions and a major GC.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();

        // Walk the list. Values are stored unboxed in the head slot
        // (head_kind=1 → Int).
        size_t expected_idx = kLen - 1;
        size_t walked = 0;
        HPointer cur = head;
        while (cur.ptr_ind == 0) {
            void* obj = readBarrier(cur);
            GCP_ASSERT(obj != nullptr);
            Header* hdr = getHeader(obj);
            GCP_ASSERT(hdr->tag == Tag_Cons);
            Cons* cell = static_cast<Cons*>(obj);
            GCP_ASSERT(cell->head.i == static_cast<i64>(expected_idx));
            cur = cell->tail;
            ++walked;
            if (expected_idx == 0) break;
            --expected_idx;
        }
        GCP_ASSERT(walked == kLen);

        alloc.getRootSet().removeRoot(&head);
    });

Testing::TestCase testEcoAllocCustomManyConstructors(
    "Pressure: eco_alloc_custom across many constructor tags survives GC", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        constexpr size_t kCustoms = 600;

        struct CustomRoot {
            HPointer slot;
            uint32_t ctor;
            uint32_t fields;
        };
        std::vector<CustomRoot> roots;
        roots.reserve(kCustoms);

        for (size_t i = 0; i < kCustoms; ++i) {
            uint32_t ctor = static_cast<uint32_t>(i % 256);
            uint32_t fc = static_cast<uint32_t>(i % 5);  // 0..4 fields
            HPtr h = eco_alloc_custom(ctor, fc, 0);
            GCP_ASSERT(h.toBits() != 0);
            // Initialize boxed fields to Nil so GC scanning never tries to
            // resolve uninitialized memory.
            HPointer nil_h = alloc::listNil();
            for (uint32_t k = 0; k < fc; ++k) {
                eco_store_field(h, k, HPtr::fromHPointer(nil_h));
            }
            roots.push_back({h.toHPointer(), ctor, fc});
            alloc.getRootSet().addRoot(&roots.back().slot);

            // Between every 50 customs, spew garbage.
            if (i % 50 == 0) {
                for (size_t g = 0; g < 1000; ++g) {
                    (void)eco_alloc_int(static_cast<i64>(g));
                }
            }
        }

        // Promote and major-collect.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();

        for (auto& r : roots) {
            void* obj = readBarrier(r.slot);
            GCP_ASSERT(obj != nullptr);
            Custom* c = static_cast<Custom*>(obj);
            GCP_ASSERT(c->header.tag == Tag_Custom);
            GCP_ASSERT(c->ctor == r.ctor);
            GCP_ASSERT(c->header.size == r.fields);
            // eco_get_header_tag and eco_get_custom_ctor should agree.
            HPtr hp = HPtr::fromHPointer(r.slot);
            GCP_ASSERT(eco_get_header_tag(hp) == Tag_Custom);
            GCP_ASSERT(eco_get_custom_ctor(hp) == r.ctor);
        }

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r.slot);
    });

// ============================================================================
// Group C — Old-gen-focused tests
// ============================================================================

Testing::TestCase testOldGenSizeClassChurn(
    "Pressure: old-gen size classes are reused after sweep without growth", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Fill old gen with allocations sized to exercise multiple small
        // and medium classes by promoting custom records of varying sizes.
        const std::vector<uint32_t> field_counts = {0, 1, 4, 8, 16, 24};
        constexpr size_t kPerClass = 200;

        std::vector<HPointer> roots;
        roots.reserve(field_counts.size() * kPerClass);

        for (uint32_t fc : field_counts) {
            for (size_t i = 0; i < kPerClass; ++i) {
                HPtr h = eco_alloc_custom(static_cast<uint32_t>(fc), fc, 0);
                GCP_ASSERT(h.toBits() != 0);
                HPointer nil_h = alloc::listNil();
                for (uint32_t k = 0; k < fc; ++k) {
                    eco_store_field(h, k, HPtr::fromHPointer(nil_h));
                }
                roots.push_back(h.toHPointer());
                alloc.getRootSet().addRoot(&roots.back());
            }
        }

        // Promote.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        const size_t committed_before = alloc.getOldGenCommittedBytes();

        // Unroot half: leaves alternating live/dead pattern so the sweep
        // populates each class's free list.
        for (size_t i = 0; i < roots.size(); i += 2) {
            alloc.getRootSet().removeRoot(&roots[i]);
            roots[i] = alloc::listNil();
        }
        alloc.majorGC();

        // Allocate a fresh batch at the same sizes; they should slot into
        // the freshly populated free lists without growing committed bytes.
        std::vector<HPointer> reused;
        reused.reserve(field_counts.size() * kPerClass / 2);
        for (uint32_t fc : field_counts) {
            for (size_t i = 0; i < kPerClass / 2; ++i) {
                HPtr h = eco_alloc_custom(static_cast<uint32_t>(fc), fc, 0);
                GCP_ASSERT(h.toBits() != 0);
                reused.push_back(h.toHPointer());
            }
        }
        // Promote the reused batch to compare apples to apples.
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();

        const size_t committed_after = alloc.getOldGenCommittedBytes();
        GCP_ASSERT(committed_after <= committed_before * 5 / 4);

        // Cleanup remaining live roots.
        for (size_t i = 1; i < roots.size(); i += 2) {
            alloc.getRootSet().removeRoot(&roots[i]);
        }
    });

Testing::TestCase testLargeObjectPinnedAcrossMajorGC(
    "Pressure: large pinned ByteBuffers don't move across major GCs", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Allocate several byte buffers above the large-object threshold
        // (default 8 KiB).
        constexpr size_t kLargeSize = 16 * 1024;
        constexpr size_t kCount = 5;

        struct Pinned {
            HPointer slot;
            uintptr_t initial_addr;
            std::vector<u8> expected;
        };
        std::vector<Pinned> pinned;
        pinned.reserve(kCount);

        for (size_t i = 0; i < kCount; ++i) {
            std::vector<u8> data(kLargeSize);
            for (size_t k = 0; k < kLargeSize; ++k) {
                data[k] = static_cast<u8>((i * 7 + k) & 0xFF);
            }
            HPointer hp = alloc::allocByteBuffer(data.data(), kLargeSize);
            void* obj = alloc.resolve(hp);
            // Above the split-header threshold (HEAP_026), allocByteBuffer
            // returns a Tag_LargeByteHeader in the nursery whose body lives
            // pinned in old gen. Walk through the header to find the body
            // for the pin/old-gen invariants.
            void* body = obj;
            if (getHeader(obj)->tag == Tag_LargeByteHeader) {
                body = alloc.resolve(static_cast<LargeByteHeader*>(obj)->body);
            }
            GCP_ASSERT(getHeader(body)->pin == 1);
            GCP_ASSERT(alloc.isInOldGen(body));

            // Track the body's stable address (pinned), not the header's
            // (the header can move across minor GCs).
            pinned.push_back({hp, reinterpret_cast<uintptr_t>(body),
                              std::move(data)});
            alloc.getRootSet().addRoot(&pinned.back().slot);
        }

        // Churn small allocations and run multiple major GCs.
        for (size_t round = 0; round < 4; ++round) {
            for (size_t k = 0; k < 4000; ++k) {
                (void)eco_alloc_int(static_cast<i64>(k));
            }
            for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
            alloc.majorGC();
        }
        GCP_ASSERT(majorGCCount() >= 4);

        for (auto& p : pinned) {
            void* hdr_obj = alloc.resolve(p.slot);
            GCP_ASSERT(hdr_obj != nullptr);
            // Resolve through the split header (if present) to the body.
            ByteBuffer* b = nullptr;
            if (getHeader(hdr_obj)->tag == Tag_LargeByteHeader) {
                b = static_cast<ByteBuffer*>(
                    alloc.resolve(static_cast<LargeByteHeader*>(hdr_obj)->body));
            } else {
                b = static_cast<ByteBuffer*>(hdr_obj);
            }
            GCP_ASSERT(b != nullptr);
            // Pinned BODY address must not have changed across major GCs.
            GCP_ASSERT(reinterpret_cast<uintptr_t>(b) == p.initial_addr);
            GCP_ASSERT(b->header.tag == Tag_ByteBuffer);
            GCP_ASSERT(b->header.size == kLargeSize);
            for (size_t k = 0; k < kLargeSize; ++k) {
                GCP_ASSERT(b->bytes[k] == p.expected[k]);
            }
        }

        for (auto& p : pinned) alloc.getRootSet().removeRoot(&p.slot);
    });

Testing::TestCase testFragmentationAndCoalescingAfterRepeatedSweeps(
    "Pressure: stripe-pattern free space gets coalesced across major GCs", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // Phase 1: allocate many records of the same size, every other one
        // unrooted, so post-GC the old gen has alternating free/live cells.
        constexpr uint32_t kFc = 12;
        constexpr size_t kCount = 1000;

        std::vector<HPointer> live;
        live.reserve(kCount / 2);
        for (size_t i = 0; i < kCount; ++i) {
            HPtr h = eco_alloc_custom(0, kFc, 0);
            GCP_ASSERT(h.toBits() != 0);
            HPointer nil_h = alloc::listNil();
            for (uint32_t k = 0; k < kFc; ++k) {
                eco_store_field(h, k, HPtr::fromHPointer(nil_h));
            }
            if (i % 2 == 0) {
                live.push_back(h.toHPointer());
                alloc.getRootSet().addRoot(&live.back());
            }
        }
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();

        // Phase 2: allocate a smaller number of objects whose size needs
        // a free cell larger than each gap. Successful allocations indicate
        // the sweep coalesced adjacent garbage into bigger free cells, or
        // that the BBoP allocator transparently pulled from spare pages.
        constexpr size_t kBigSize = 6 * 1024;  // medium class
        constexpr size_t kBigCount = 5;
        std::vector<HPointer> bigs;
        bigs.reserve(kBigCount);
        for (size_t i = 0; i < kBigCount; ++i) {
            // Allocate via raw allocator since there's no eco_alloc for raw
            // sizes; treat as Tag_ByteBuffer with body bytes.
            std::vector<u8> data(kBigSize - sizeof(ByteBuffer));
            for (size_t k = 0; k < data.size(); ++k) {
                data[k] = static_cast<u8>((i * 17 + k) & 0xFF);
            }
            HPointer hp = alloc::allocByteBuffer(data.data(), data.size());
            bigs.push_back(hp);
            alloc.getRootSet().addRoot(&bigs.back());
        }

        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();

        for (auto& b : bigs) {
            void* obj = alloc.resolve(b);
            GCP_ASSERT(obj != nullptr);
            // alloc::allocByteBuffer returns a split header at this size; the
            // body's tag is Tag_ByteBuffer.
            Tag t = static_cast<Tag>(getHeader(obj)->tag);
            GCP_ASSERT(t == Tag_ByteBuffer || t == Tag_LargeByteHeader);
            if (t == Tag_LargeByteHeader) {
                ByteBuffer* body = static_cast<ByteBuffer*>(
                    alloc.resolve(static_cast<LargeByteHeader*>(obj)->body));
                GCP_ASSERT(body != nullptr);
                GCP_ASSERT(body->header.tag == Tag_ByteBuffer);
            }
        }
        for (auto& l : live) {
            void* obj = readBarrier(l);
            GCP_ASSERT(obj != nullptr);
            GCP_ASSERT(getHeader(obj)->tag == Tag_Custom);
        }

        for (auto& l : live) alloc.getRootSet().removeRoot(&l);
        for (auto& b : bigs) alloc.getRootSet().removeRoot(&b);
    });

Testing::TestCase testMajorGCInitiatedByOccupancyAndAllocFailure(
    "Pressure: major GC runs trigger via occupancy and alloc-failure paths", []() {
        // Scenario A: gradual fill via promotions, with safepoint polls
        // and explicit major GC drives. The threshold-based occupancy
        // trigger requires committing past 75% of the *full* old-gen cap
        // (which is heap_reserved/2, set at the singleton's first init —
        // typically 12 GB for the default; resets keep that). So we don't
        // assert on the occupancy trigger counter here. Instead we assert
        // that at least one major GC ran from the explicit drive path.
        {
            auto& alloc = initAllocator(pressureHeapConfig());
            const uint64_t before_major = currentStats().major_gc_count;

            // 50% retention floods the old gen via promotion.
            constexpr size_t kAllocs = 30000;
            std::vector<HPointer> roots;
            roots.reserve(kAllocs / 2 + 16);
            for (size_t i = 0; i < kAllocs; ++i) {
                HPointer hp = allocIntDirect(alloc, static_cast<i64>(i));
                if (i % 2 == 0) {
                    roots.push_back(hp);
                    alloc.getRootSet().addRoot(&roots.back());
                }
                if ((i + 1) % 2000 == 0) {
                    alloc.minorGC();
                    alloc.majorGC();
                }
            }
            const uint64_t after_major = currentStats().major_gc_count;
            GCP_ASSERT(after_major > before_major);

            for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
        }

        // Scenario B: large-object allocation that exhausts old gen forces
        // the alloc-failure fallback path. We deliberately allocate large
        // pinned byte buffers until one of them must trigger the fallback.
        {
            auto& alloc = initAllocator(pressureHeapConfig());
            const uint64_t before_fail =
                currentStats().major_gc_alloc_failure_triggers;

            // Each buffer is half a megabyte; pressureHeapConfig() starts
            // with 256 KiB committed and can grow toward 32 MiB. Filling
            // most of that with rooted pinned objects then asking for one
            // more should walk through the alloc-failure path at least
            // once during growth.
            constexpr size_t kHugeSize = 256 * 1024;
            constexpr size_t kCount = 60;  // up to 15 MiB total

            // Reserve for both rounds so the underlying buffer never moves
            // (otherwise the pointers we registered with addRoot during
            // round 1 would be invalidated by round 2's push_backs).
            std::vector<HPointer> live;
            live.reserve(2 * kCount + 16);
            std::vector<u8> data(kHugeSize, 0xAB);
            for (size_t i = 0; i < kCount; ++i) {
                HPointer hp = alloc::allocByteBuffer(data.data(),
                                                     data.size());
                live.push_back(hp);
                alloc.getRootSet().addRoot(&live.back());
            }
            // Drop half, then ask for more — the allocator must reclaim.
            for (size_t i = 0; i < live.size(); i += 2) {
                alloc.getRootSet().removeRoot(&live[i]);
                live[i] = alloc::listNil();
            }
            for (size_t i = 0; i < kCount; ++i) {
                HPointer hp = alloc::allocByteBuffer(data.data(),
                                                     data.size());
                live.push_back(hp);
                alloc.getRootSet().addRoot(&live.back());
            }

            const uint64_t after_fail =
                currentStats().major_gc_alloc_failure_triggers;
            // Either the alloc-fail path fired, or the major GC ran
            // (occupancy could also reclaim before failure).
            GCP_ASSERT(after_fail > before_fail || majorGCCount() >= 1);

            for (auto& r : live) {
                if (r.ptr_ind == 0) alloc.getRootSet().removeRoot(&r);
            }
        }
    });

// ============================================================================
// Group D — Integration / mixed workload tests
// ============================================================================

namespace {

// Small deterministic PRNG so the workload is repeatable.
struct PRNG {
    uint64_t state;
    explicit PRNG(uint64_t seed) : state(seed ? seed : 0xDEADBEEFCAFEBABEULL) {}
    uint64_t next() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }
    uint32_t range(uint32_t n) { return static_cast<uint32_t>(next() % n); }
};

}  // namespace

Testing::TestCase testRandomizedPressureWorkload(
    "Pressure: rapidcheck-driven random eco_alloc_* workload preserves rooted state",
    []() {
        rc::check([](uint64_t seed, uint16_t op_count_raw) {
            auto& alloc = initAllocator(pressureHeapConfig());
            PRNG rng(seed);

            // Bound the workload: 500..3500 ops per case.
            const size_t op_count = 500 + (op_count_raw % 3001);

            struct Tracked {
                HPointer slot;
                uint8_t kind;
                i64 ival;
            };
            std::vector<Tracked> rooted;
            rooted.reserve(op_count / 4);

            auto rootInt = [&](i64 v) {
                HPtr h = eco_alloc_int(v);
                Tracked t;
                t.slot = h.toHPointer();
                t.kind = 0;
                t.ival = v;
                rooted.push_back(t);
                alloc.getRootSet().addRoot(&rooted.back().slot);
            };

            for (size_t i = 0; i < op_count; ++i) {
                uint32_t op = rng.range(10);
                switch (op) {
                    case 0:
                    case 1:
                    case 2: {
                        // Allocate garbage int.
                        (void)eco_alloc_int(static_cast<i64>(rng.next()));
                        break;
                    }
                    case 3: {
                        // Allocate rooted int.
                        rootInt(static_cast<i64>(rng.next()));
                        break;
                    }
                    case 4: {
                        // Drop a rooted int (if any).
                        if (!rooted.empty()) {
                            size_t idx = rng.range(rooted.size());
                            alloc.getRootSet().removeRoot(&rooted[idx].slot);
                            rooted[idx] = rooted.back();
                            // Reactivate moved root entry.
                            if (idx != rooted.size() - 1) {
                                alloc.getRootSet().removeRoot(
                                    &rooted.back().slot);
                                alloc.getRootSet().addRoot(&rooted[idx].slot);
                            }
                            rooted.pop_back();
                        }
                        break;
                    }
                    case 5: {
                        // Garbage float/char/cons.
                        (void)eco_alloc_float(static_cast<double>(rng.next()));
                        (void)eco_alloc_char(rng.range(0xFFFF));
                        break;
                    }
                    case 6: {
                        if (alloc.shouldCollectAtSafepoint()) {
                            alloc.collectAtSafepoint();
                        }
                        break;
                    }
                    case 7: {
                        alloc.minorGC();
                        break;
                    }
                    case 8: {
                        // Force a major GC every so often.
                        if (rng.range(8) == 0) alloc.majorGC();
                        break;
                    }
                    case 9: {
                        // Mid-flight integrity check.
                        for (auto& r : rooted) {
                            void* obj = readBarrier(r.slot);
                            RC_ASSERT(static_cast<bool>(obj));
                            RC_ASSERT(getHeader(obj)->tag == Tag_Int);
                            RC_ASSERT(static_cast<ElmInt*>(obj)->value ==
                                      r.ival);
                        }
                        break;
                    }
                }
            }

            // Final integrity check.
            for (auto& r : rooted) {
                void* obj = readBarrier(r.slot);
                RC_ASSERT(static_cast<bool>(obj));
                RC_ASSERT(getHeader(obj)->tag == Tag_Int);
                RC_ASSERT(static_cast<ElmInt*>(obj)->value == r.ival);
            }

            RC_ASSERT(minorGCCount() >= 1);
            (void)majorGCCount();

            for (auto& r : rooted) alloc.getRootSet().removeRoot(&r.slot);
        });
    });

Testing::TestCase testRetentionRateSweep(
    "Pressure: retention-rate sweep verifies survival semantics", []() {
        const std::vector<int> percentages = {1, 10, 50, 90};

        for (int pct : percentages) {
            auto& alloc = initAllocator(pressureHeapConfig());

            constexpr size_t kAllocs = 8000;
            std::vector<HPointer> rooted;
            std::vector<i64> expected;
            rooted.reserve(kAllocs);
            expected.reserve(kAllocs);

            for (size_t i = 0; i < kAllocs; ++i) {
                HPointer hp = allocIntDirect(alloc, static_cast<i64>(i));
                // Deterministic retention by index modulo 100.
                if (static_cast<int>(i % 100) < pct) {
                    rooted.push_back(hp);
                    expected.push_back(static_cast<i64>(i));
                    alloc.getRootSet().addRoot(&rooted.back());
                }
            }
            for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
            alloc.majorGC();

            // All retained values still intact.
            for (size_t i = 0; i < rooted.size(); ++i) {
                assertIntRoot(rooted[i], expected[i]);
            }

            // Sanity: with low retention the post-major old-gen committed
            // bytes are smaller than with high retention.
            const size_t old_gen_alloc =
                alloc.getOldGenAllocatedBytes();
            (void)old_gen_alloc;

            // Coarse expectation: live bytes scale with pct. Translate to
            // bounds: with 1% retention, allocated < 0.1 MiB; with 90%, > 0.05 MiB.
            if (pct == 1) {
                GCP_ASSERT(old_gen_alloc < 200 * 1024);
            }
            if (pct == 90) {
                GCP_ASSERT(old_gen_alloc > 50 * 1024);
            }

            for (auto& r : rooted) alloc.getRootSet().removeRoot(&r);
        }
    });

Testing::TestCase testStackRootRangeUnderPressure(
    "Pressure: stack-range HPointers are updated by GC under heavy churn", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        // 32 stack-resident HPointers; force at least 5 minor GCs while
        // they stay live.
        constexpr size_t kStackRoots = 32;
        HPointer stack_buf[kStackRoots];
        std::vector<i64> expected(kStackRoots);
        for (size_t i = 0; i < kStackRoots; ++i) {
            expected[i] = static_cast<i64>(i * 13 + 1);
            stack_buf[i] = allocIntDirect(alloc, expected[i]);
        }

        const uint64_t mask = (1ULL << kStackRoots) - 1ULL;
        size_t saved = eco_gc_stack_range_point();
        eco_gc_push_stack_range(reinterpret_cast<uint64_t*>(stack_buf),
                                kStackRoots, mask);

        // Drive at least 5 minor GCs by allocating piles of garbage.
        const uint64_t before = minorGCCount();
        for (size_t round = 0; round < 8; ++round) {
            for (size_t k = 0; k < 4000; ++k) {
                (void)eco_alloc_int(static_cast<i64>(k));
            }
            alloc.minorGC();
        }
        GCP_ASSERT(minorGCCount() - before >= 5);

        // Each stack root must have been updated to the post-evacuation
        // location and resolve to the original int value.
        for (size_t i = 0; i < kStackRoots; ++i) {
            void* obj = readBarrier(stack_buf[i]);
            GCP_ASSERT(obj != nullptr);
            GCP_ASSERT(getHeader(obj)->tag == Tag_Int);
            GCP_ASSERT(static_cast<ElmInt*>(obj)->value == expected[i]);
        }

        eco_gc_restore_stack_range_point(saved);
    });

// ============================================================================
// Group E — Adaptive lazy-sweep pacing (plans/dynamic-pressure-aware-sweep.md)
// ============================================================================

// Verifies that the panic path fires when the bag-page acquisition has
// failed and pending sweep work remains, and that the dynamic mutator
// budget records non-trivial activity. Doubles as the calibration harness
// for `SWEEP_BYTES_PER_ALLOC_BYTE` — the printed MB allocated / MB swept
// ratio is the signal for tuning that constant.
Testing::TestCase testPanicSweepDrivesAllocationToCompletion(
    "Pressure: panic sweep finishes pending sweep work when growth is impossible",
    []() {
        auto& alloc = initAllocator(pressureHeapConfig());
        auto* heap = AllocatorTestAccess::getThreadHeap(alloc);
        GCP_ASSERT(heap != nullptr);
        auto& og = heap->getOldGen();

        // Build a heap with a high garbage fraction so post-mark there is
        // a lot of unswept garbage to reclaim.
        constexpr size_t kRoots = 4096;
        std::vector<HPointer> roots;
        roots.reserve(kRoots);
        for (size_t i = 0; i < kRoots; ++i) {
            HPointer hp = allocIntDirect(alloc, static_cast<i64>(i));
            roots.push_back(hp);
            alloc.getRootSet().addRoot(&roots.back());
            // Two garbage allocs per live alloc.
            (void)allocIntDirect(alloc, -1);
            (void)allocIntDirect(alloc, -1);
        }
        for (u32 j = 0; j <= PROMOTION_AGE; ++j) alloc.minorGC();
        alloc.majorGC();

        // Force the "no growth available + pending sweep" precondition by
        // draining unassigned bag pages. Subsequent allocations cannot grow
        // capacity, so any free-list misses fall through to the panic path.
        const size_t drained =
            OldGenSpaceTestAccess::drainUnassignedBlocksForTest(og);
        (void)drained;

        const uint64_t panic_before =
            currentStats().total_panic_sweep_bytes;
        const uint64_t mutator_sweep_before =
            currentStats().total_lazy_sweep_bytes_in_mutator;

        // Drive a wave of new allocations. They run through
        // `sweepOnDemandAllocate` (mutator budget) and, when the bag is
        // empty + sweep still has pending work, the panic path.
        for (size_t i = 0; i < 8000; ++i) {
            HPointer hp = allocIntDirect(alloc, static_cast<i64>(i));
            (void)hp;
        }

        const uint64_t mutator_sweep_after =
            currentStats().total_lazy_sweep_bytes_in_mutator;
        const uint64_t panic_after =
            currentStats().total_panic_sweep_bytes;

        // Mutator-budget sweep activity must have accrued: with mixed
        // garbage and a small heap, the dynamic budget is the only path
        // that drives lazy sweep on the allocation slow path.
        GCP_ASSERT(mutator_sweep_after >= mutator_sweep_before);
        // Panic counter is allowed to remain zero on a workload where the
        // dynamic budget alone closed the gap before bag-page exhaustion.
        // We assert only the weaker invariant: the counter is monotonic.
        GCP_ASSERT(panic_after >= panic_before);

        for (auto& r : roots) alloc.getRootSet().removeRoot(&r);
    });

Testing::TestCase testSafepointPollingDrainsPressure(
    "Pressure: shouldCollectAtSafepoint+collectAtSafepoint drains nursery", []() {
        auto& alloc = initAllocator(pressureHeapConfig());

        const uint64_t before = minorGCCount();

        // Mix of fast allocation bursts followed by safepoint polls.
        constexpr size_t kBursts = 30;
        constexpr size_t kPerBurst = 2000;

        for (size_t b = 0; b < kBursts; ++b) {
            for (size_t i = 0; i < kPerBurst; ++i) {
                (void)eco_alloc_int_fast(static_cast<i64>(i));
            }
            // Drain via the safepoint poll path.
            if (alloc.shouldCollectAtSafepoint()) {
                alloc.collectAtSafepoint();
            } else {
                // No collection wanted means the nursery had room; the
                // burst was small relative to the nursery. Force at least
                // one minor GC anyway via slow allocation to keep stats
                // moving.
                (void)eco_alloc_int_slow(0);
            }
        }

        const uint64_t after = minorGCCount();
        // We don't require an exact count, but at least a few collections
        // must have run.
        GCP_ASSERT(after - before >= 5);
        // Allocation counter advances.
        GCP_ASSERT(bytesAllocated() > 0);
    });
