/**
 * Chunked-list representation tests (plans/chunked-list-representation.md
 * §6 L1.2, hybrid spines).
 *
 * Covers: backing/view allocation, ListCursor iteration order over
 * pure-chunk, multi-chunk, and mixed cell+chunk spines, boxed and unboxed
 * element kinds, and content survival across minor GCs and promotion.
 */

#include "ChunkedListTest.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "TestHelpers.hpp"
#include <rapidcheck.h>
#include <vector>

using namespace Elm;

namespace {

// Build a single-chunk list of unboxed Ints [v0, v1, ...] (kind 1).
HPointer chunkOfInts(const std::vector<i64>& vals) {
    HPointer backing = alloc::listBacking(static_cast<u32>(vals.size()), 1);
    ListBacking* lb = static_cast<ListBacking*>(
        Allocator::instance().resolve(backing));
    for (size_t i = 0; i < vals.size(); i++) lb->elems[i].i = vals[i];
    return alloc::consChunkView(backing, 0, static_cast<u32>(vals.size()),
                                alloc::listNil(), 1);
}

// Collect a list's Int elements via the cursor.
std::vector<i64> intsOf(HPointer list) {
    std::vector<i64> out;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        RC_ASSERT(c.currentKind() == 1u);
        out.push_back(c.current().i);
    }
    return out;
}

} // namespace

static void test_chunk_cursor_roundtrip() {
    rc::check("cursor yields a chunk's elements in order", []() {
        initAllocator();
        auto vals = *rc::gen::suchThat(
            rc::gen::container<std::vector<i64>>(rc::gen::arbitrary<i64>()),
            [](const std::vector<i64>& v) { return !v.empty() && v.size() <= 64; });
        HPointer list = chunkOfInts(vals);
        RC_ASSERT(intsOf(list) == vals);
    });
}

static void test_mixed_spine_cursor() {
    rc::check("cells consed onto a chunk iterate in order", []() {
        initAllocator();
        auto chunkVals = *rc::gen::suchThat(
            rc::gen::container<std::vector<i64>>(rc::gen::arbitrary<i64>()),
            [](const std::vector<i64>& v) { return !v.empty() && v.size() <= 32; });
        auto cellVals = *rc::gen::suchThat(
            rc::gen::container<std::vector<i64>>(rc::gen::arbitrary<i64>()),
            [](const std::vector<i64>& v) { return v.size() <= 8; });

        auto& rs = Allocator::instance().getRootSet();
        HPointer list = chunkOfInts(chunkVals);
        size_t saved = rs.stackRangePoint();
        rs.pushStackRootRange(&list, 1, 1);
        // Prepend cells (right-to-left) so the logical order is
        // cellVals ++ chunkVals.
        for (auto it = cellVals.rbegin(); it != cellVals.rend(); ++it) {
            list = alloc::cons(alloc::unboxedInt(*it), list, static_cast<u8>(1));
        }
        rs.restoreStackRangePoint(saved);

        std::vector<i64> expect = cellVals;
        expect.insert(expect.end(), chunkVals.begin(), chunkVals.end());
        RC_ASSERT(intsOf(list) == expect);
    });
}

static void test_multi_chunk_spine() {
    rc::check("view chaining via next preserves order and len invariant", []() {
        initAllocator();
        auto a = *rc::gen::suchThat(
            rc::gen::container<std::vector<i64>>(rc::gen::arbitrary<i64>()),
            [](const std::vector<i64>& v) { return !v.empty() && v.size() <= 16; });
        auto b = *rc::gen::suchThat(
            rc::gen::container<std::vector<i64>>(rc::gen::arbitrary<i64>()),
            [](const std::vector<i64>& v) { return !v.empty() && v.size() <= 16; });

        auto& rs = Allocator::instance().getRootSet();
        HPointer second = chunkOfInts(b);
        size_t saved = rs.stackRangePoint();
        rs.pushStackRootRange(&second, 1, 1);
        HPointer backing = alloc::listBacking(static_cast<u32>(a.size()), 1);
        ListBacking* lb = static_cast<ListBacking*>(
            Allocator::instance().resolve(backing));
        for (size_t i = 0; i < a.size(); i++) lb->elems[i].i = a[i];
        // len = own run + logical length of `next` (consistency invariant).
        HPointer list = alloc::consChunkView(
            backing, 0, static_cast<u32>(a.size() + b.size()), second, 1);
        rs.restoreStackRangePoint(saved);

        std::vector<i64> expect = a;
        expect.insert(expect.end(), b.begin(), b.end());
        RC_ASSERT(intsOf(list) == expect);
    });
}

static void test_boxed_chunk_gc_survival() {
    rc::check("boxed-element chunks survive minor GC and promotion", []() {
        auto& alloc_ = initAllocator();
        auto vals = *rc::gen::suchThat(
            rc::gen::container<std::vector<i64>>(rc::gen::arbitrary<i64>()),
            [](const std::vector<i64>& v) { return !v.empty() && v.size() <= 32; });

        auto& rs = alloc_.getRootSet();
        // Boxed Int elements (kind 0): backing traces [hd, cap).
        HPointer backing = alloc::listBacking(static_cast<u32>(vals.size()), 0);
        size_t saved = rs.stackRangePoint();
        rs.pushStackRootRange(&backing, 1, 1);
        for (size_t i = 0; i < vals.size(); i++) {
            // allocInt may GC; backing is rooted and re-read via resolve.
            HPointer boxed = alloc::allocInt(vals[i]);
            ListBacking* lb = static_cast<ListBacking*>(
                Allocator::instance().resolve(backing));
            lb->elems[i].p = boxed;
        }
        HPointer list = alloc::consChunkView(
            backing, 0, static_cast<u32>(vals.size()), alloc::listNil(), 0);
        rs.restoreStackRangePoint(saved);

        saved = rs.stackRangePoint();
        rs.pushStackRootRange(&list, 1, 1);
        // Survive several minor GCs (past promotion age).
        for (u32 i = 0; i <= PROMOTION_AGE + 1; i++) {
            allocateGarbageInts(alloc_, 32);
            alloc_.minorGC();
        }
        // Verify content through the cursor: boxed heads resolve to the
        // original values.
        std::vector<i64> got;
        for (alloc::ListCursor c(list); !c.done(); c.next()) {
            RC_ASSERT(c.currentKind() == 0u);
            ElmInt* n = static_cast<ElmInt*>(
                Allocator::instance().resolve(c.current().p));
            RC_ASSERT(n != nullptr);
            got.push_back(n->value);
        }
        rs.restoreStackRangePoint(saved);
        RC_ASSERT(got == vals);
    });
}

static void test_unboxed_chunk_gc_survival() {
    rc::check("unboxed-element chunks survive minor GC unscanned", []() {
        auto& alloc_ = initAllocator();
        auto vals = *rc::gen::suchThat(
            rc::gen::container<std::vector<i64>>(rc::gen::arbitrary<i64>()),
            [](const std::vector<i64>& v) { return !v.empty() && v.size() <= 64; });

        auto& rs = alloc_.getRootSet();
        HPointer list = chunkOfInts(vals);
        size_t saved = rs.stackRangePoint();
        rs.pushStackRootRange(&list, 1, 1);
        for (u32 i = 0; i <= PROMOTION_AGE + 1; i++) {
            allocateGarbageInts(alloc_, 32);
            alloc_.minorGC();
        }
        std::vector<i64> got = intsOf(list);
        rs.restoreStackRangePoint(saved);
        RC_ASSERT(got == vals);
    });
}

static void test_over_cap_chain() {
    rc::check("over-cap batches build multi-backing chains (§6 L2)", []() {
        initAllocator();
        bool savedFlag = eco_g_list_chunks;
        eco_g_list_chunks = true;

        // Comfortably over one backing's capacity so the chain has >= 3
        // links, with a remainder-sized tail link.
        u32 maxElems = alloc::listBackingMaxElems();
        u32 n = maxElems * 2 + maxElems / 3 + 1;
        std::vector<std::pair<Unboxable, bool>> elems(n);
        for (u32 i = 0; i < n; i++) {
            elems[i].first.i = static_cast<i64>(i) * 7 - 3;
            elems[i].second = false;
        }
        HPointer list = alloc::listFromUnboxables(elems);

        // Every link's backing stays under the large-object threshold, lens
        // telescope, and the logical length is exact.
        RC_ASSERT(alloc::listLogicalLen(list) == n);
        auto& allocator = Allocator::instance();
        u32 seen = 0;
        HPointer v = list;
        while (seen < n) {
            ConsChunk* cv = static_cast<ConsChunk*>(allocator.resolve(v));
            RC_ASSERT(getHeader(cv)->tag == Tag_ConsChunk);
            RC_ASSERT(cv->len == n - seen);
            ListBacking* lb = static_cast<ListBacking*>(
                allocator.resolve(cv->backing));
            RC_ASSERT(sizeof(ListBacking) +
                          lb->header.size * sizeof(Unboxable) <
                      allocator.getLargeObjectThreshold());
            seen += lb->header.size;
            v = cv->next;
        }
        RC_ASSERT(seen == n);
        RC_ASSERT(alloc::isNil(v));

        std::vector<i64> got = intsOf(list);
        for (u32 i = 0; i < n; i++) {
            RC_ASSERT(got[i] == static_cast<i64>(i) * 7 - 3);
        }
        eco_g_list_chunks = savedFlag;
    });
}

static void test_over_cap_reversed_and_scratch() {
    rc::check("reversed chain fills and scratch finish agree (§6 L2)", []() {
        initAllocator();
        bool savedFlag = eco_g_list_chunks;
        eco_g_list_chunks = true;

        u32 n = alloc::listBackingMaxElems() + 17;
        std::vector<std::pair<Unboxable, bool>> elems(n);
        for (u32 i = 0; i < n; i++) {
            elems[i].first.i = static_cast<i64>(i);
            elems[i].second = false;
        }
        HPointer rev =
            alloc::listFromUnboxables(elems, alloc::listNil(), true);
        RC_ASSERT(alloc::listLogicalLen(rev) == n);
        std::vector<i64> got = intsOf(rev);
        for (u32 i = 0; i < n; i++) {
            RC_ASSERT(got[i] == static_cast<i64>(n - 1 - i));
        }

        // Scratch finish over the same values: pushes 0..n-1, finish
        // reverses, so the result must equal `rev`.
        int64_t mark = eco_scratch_mark();
        for (u32 i = 0; i < n; i++) {
            eco_scratch_push_scalar(static_cast<uint64_t>(i), 1);
        }
        HPtr fin = eco_scratch_finish(mark, HPtr::fromBits(hpBits(alloc::listNil())), 1);
        std::vector<i64> got2 = intsOf(fin.toHPointer());
        RC_ASSERT(got2 == got);
        eco_g_list_chunks = savedFlag;
    });
}

void registerChunkedListTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("Over-cap chunk chain structure",
                                test_over_cap_chain));
    suite.add(Testing::TestCase("Over-cap reversed + scratch finish",
                                test_over_cap_reversed_and_scratch));
    suite.add(Testing::TestCase("Chunk cursor round-trip",
                                test_chunk_cursor_roundtrip));
    suite.add(Testing::TestCase("Mixed cell+chunk spine cursor",
                                test_mixed_spine_cursor));
    suite.add(Testing::TestCase("Multi-chunk spine via next",
                                test_multi_chunk_spine));
    suite.add(Testing::TestCase("Boxed chunk GC survival + promotion",
                                test_boxed_chunk_gc_survival));
    suite.add(Testing::TestCase("Unboxed chunk GC survival",
                                test_unboxed_chunk_gc_survival));
}
