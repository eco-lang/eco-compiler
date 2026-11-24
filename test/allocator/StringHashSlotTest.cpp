/**
 * Tests for String hash slots (HEAP_088, plans/hash-reuse-explicit-vs-cached.md Part B).
 *
 * Every allocation route gives a String whose object size is what `getObjectSize` computes and whose
 * hash slot, when its form has one, is 0 (and a flat String's whole tail word is 0). The nursery is
 * dirtied first with Strings whose slots are filled, so a route that leaves the slot unwritten reads
 * garbage rather than a lucky 0. The value hash fills a slot with `stringHashUncached`, reads it back,
 * and the slot survives minor and major collections. `checkStringHashSlot` rejects a wrong slot.
 */

#include "StringHashSlotTest.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/RootSet.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/ValueHash.hpp"
#include "TestHelpers.hpp"
#include <string>
#include <vector>
#include <cstring>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

constexpr u32 T = kStringHashSlotMinUnits;

// A fixed block of HPointer slots rooted as one range record.
struct Pool {
    static constexpr unsigned kMax = 64;
    HPointer slot[kMax];
    unsigned used = 0;
    EcoRootMark mark;
    Pool() {
        for (auto& s : slot) s = alloc::emptyString();
        mark = ecoRootMark();
        ecoRootRangePush(slot, kMax, ~0ULL);
    }
    ~Pool() { ecoRootRelease(mark); }
    Pool(const Pool&) = delete;
    Pool& operator=(const Pool&) = delete;
    unsigned put(HPointer h) {
        if (used >= kMax) TEST_FAIL("Pool full");
        slot[used] = h;
        return used++;
    }
    void* obj(unsigned i) { return Allocator::instance().resolve(slot[i]); }
};

HPointer hp(HPtr h) { return h.toHPointer(); }

std::string text(size_t n, char seed) {
    std::string s(n, 'a');
    for (size_t i = 0; i < n; ++i) s[i] = static_cast<char>('a' + (i * 7 + seed) % 26);
    return s;
}

std::u16string wide(const std::string& s) { return std::u16string(s.begin(), s.end()); }

// Fills the nursery with unrooted Strings of many lengths whose hash slots are filled, then collects,
// so that later allocations reuse memory holding filled slots and String units.
void dirtyNursery() {
    for (int round = 0; round < 4; ++round) {
        for (size_t n = 1; n < 400; n += 3) {
            std::string s = text(n, static_cast<char>(round));
            HPointer a = StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()),
                                                          static_cast<u32>(n));
            eco_hash_string(HPtr::fromHPointer(a));
            std::u16string w = wide(s);
            HPointer b = alloc::allocString(reinterpret_cast<const u16*>(w.data()), n);
            eco_hash_string(HPtr::fromHPointer(b));
        }
        Allocator::instance().minorGC();
    }
}

// Checks that the String `o` has the object size its header gives, that it has a slot exactly when
// `wantSlot`, and that the slot (and a flat String's whole tail word) is 0.
void checkFresh(void* o, bool wantSlot, const std::string& what) {
    Header* h = getHeader(o);
    u32* slot = stringHashSlot(o);
    if ((slot != nullptr) != wantSlot)
        TEST_FAIL(what + ": hash slot " + (slot ? "present" : "absent") + ", expected the opposite");
    if (!slot) return;
    if (*slot != 0) TEST_FAIL(what + ": hash slot of a new String is not 0");
    if ((h->tag == Tag_String || h->tag == Tag_StringUtf8Leaf) && slot[1] != 0)
        TEST_FAIL(what + ": high half of the tail word of a new String is not 0");
    if (h->tag == Tag_String || h->tag == Tag_StringUtf8Leaf) {
        const size_t unit = h->tag == Tag_String ? 2 : 1;
        if (getObjectSize(o) != flatStringByteSize(h->size, unit))
            TEST_FAIL(what + ": getObjectSize disagrees with flatStringByteSize");
        if (reinterpret_cast<char*>(slot) + 8 != static_cast<char*>(o) + getObjectSize(o))
            TEST_FAIL(what + ": the tail word is not the object's last word");
    }
    if (const char* bad = checkStringHashSlot(o)) TEST_FAIL(what + ": " + bad);
}

void test_every_route_writes_a_zero_slot() {
    initAllocator();
    dirtyNursery();
    Pool p;
    const size_t lens[] = {1, 8, T - 1, T, T + 1, 4 * T, 1000};
    for (size_t n : lens) {
        const std::string s = text(n, 3);
        const std::u16string w = wide(s);
        const std::string tagN = " n=" + std::to_string(n);
        const bool flatSlot = n >= T;

        checkFresh(p.obj(p.put(alloc::allocString(reinterpret_cast<const u16*>(w.data()), n))), flatSlot,
                   "allocString" + tagN);
        alloc::BlankString b = alloc::allocStringBlank(n);
        std::memcpy(b.chars, w.data(), n * 2);
        checkFresh(p.obj(p.put(b.hp)), flatSlot, "allocStringBlank" + tagN);
        checkFresh(p.obj(p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()),
                                                                static_cast<u32>(n)))),
                   flatSlot, "makeUtf8LeafFromBytes" + tagN);
        StringOps::AsciiOut ao = StringOps::allocAsciiOut(n);
        std::memcpy(ao.dst, s.data(), n);
        checkFresh(p.obj(p.put(StringOps::finishAsciiOut(ao))), flatSlot, "allocAsciiOut" + tagN);
        HPtr e = eco_alloc_string(static_cast<u32>(n));
        checkFresh(p.obj(p.put(hp(e))), flatSlot, "eco_alloc_string" + tagN);
        HPtr f = eco_alloc_string_fast(static_cast<u32>(n));
        if (f.toBits() != 0) checkFresh(p.obj(p.put(hp(f))), flatSlot, "eco_alloc_string_fast" + tagN);
        checkFresh(p.obj(p.put(hp(eco_alloc_string_slow(static_cast<u32>(n))))), flatSlot,
                   "eco_alloc_string_slow" + tagN);
        p.used = 0;
    }

    // Literals (interned by address, so each needs storage of its own that outlives the test) of at
    // least T units have their slot filled at intern, before they are published (B3).
    static std::u16string lit16 = wide(text(T + 5, 9));
    static std::string lit8 = text(T + 6, 10);
    for (void* o : {p.obj(p.put(hp(eco_alloc_string_literal(reinterpret_cast<const uint16_t*>(lit16.data()),
                                                            static_cast<u32>(lit16.size()))))),
                    p.obj(p.put(hp(eco_alloc_string_literal_utf8(reinterpret_cast<const uint8_t*>(lit8.data()),
                                                                 static_cast<u32>(lit8.size())))))}) {
        if (loadStringHashSlot(o) != stringHashUncached(o)) TEST_FAIL("a literal's slot is not filled at intern");
        if (const char* bad = checkStringHashSlot(o)) TEST_FAIL(std::string("literal: ") + bad);
    }

    // The forms that always have a slot: slice (of a UTF-16 leaf), UTF-8 view, rope, large String.
    const std::string big = text(600, 4);
    const std::u16string bigW = wide(big);
    unsigned base16 = p.put(alloc::allocString(reinterpret_cast<const u16*>(bigW.data()), bigW.size()));
    checkFresh(p.obj(p.put(StringOps::makeSlice(p.slot[base16], 3, 5))), true, "makeSlice");
    unsigned base8 = p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(big.data()), 600));
    checkFresh(p.obj(p.put(StringOps::makeUtf8View(p.slot[base8], 3, 5))), true, "makeUtf8View");
    checkFresh(p.obj(p.put(StringOps::makeRope(p.slot[base8], p.slot[base16]))), true, "makeRope");
    const size_t largeN = Allocator::instance().getLargeObjectThreshold();
    std::u16string largeW = wide(text(largeN, 5));
    unsigned large = p.put(alloc::allocString(reinterpret_cast<const u16*>(largeW.data()), largeN));
    if (getHeader(p.obj(large))->tag != Tag_LargeStringHeader) TEST_FAIL("precondition: not a large String");
    checkFresh(p.obj(large), true, "allocString (large)");
}

// The value hash fills a slot with the uncached hash, reads it back, and the same units in another
// form hash alike; the slot survives a minor and a major collection.
void test_fill_and_survive_gc() {
    initAllocator();
    dirtyNursery();
    Pool p;
    const std::string s = text(300, 6);
    const std::u16string w = wide(s);
    std::vector<unsigned> ids = {
        p.put(alloc::allocString(reinterpret_cast<const u16*>(w.data()), w.size())),
        p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()), 300)),
    };
    // The same 300 units as a rope of two leaves, a slice and a view of longer Strings.
    unsigned l = p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()), 100));
    unsigned r = p.put(alloc::allocString(reinterpret_cast<const u16*>(w.data()) + 100, 200));
    ids.push_back(p.put(StringOps::makeRope(p.slot[l], p.slot[r])));
    const std::string longer = "xy" + s + "z";
    const std::u16string longerW = wide(longer);
    unsigned b16 = p.put(alloc::allocString(reinterpret_cast<const u16*>(longerW.data()), longerW.size()));
    ids.push_back(p.put(StringOps::makeSlice(p.slot[b16], 2, 300)));
    unsigned b8 = p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(longer.data()),
                                                         static_cast<u32>(longer.size())));
    ids.push_back(p.put(StringOps::makeUtf8View(p.slot[b8], 2, 300)));

    const u32 want = stringHashUncached(p.obj(ids[0]));
    int64_t first = 0;
    for (unsigned i : ids) {
        void* o = p.obj(i);
        if (loadStringHashSlot(o) != 0) TEST_FAIL("slot filled before any hash");
        int64_t h = eco_hash_string(HPtr::fromHPointer(p.slot[i]));
        if (first == 0) first = h;
        if (h != first) TEST_FAIL("equal units in two forms hash differently");
        if (loadStringHashSlot(p.obj(i)) != want) TEST_FAIL("slot not filled with stringHashUncached");
        if (eco_hash_string(HPtr::fromHPointer(p.slot[i])) != h) TEST_FAIL("a slot hit gives another hash");
    }
    // A String nested in a tuple fills through the walker.
    std::u16string w2 = wide(text(T, 7));
    unsigned nested = p.put(alloc::allocString(reinterpret_cast<const u16*>(w2.data()), w2.size()));
    Unboxable a, b;
    a.p = p.slot[nested];
    b.i = 7;
    unsigned tup = p.put(alloc::tuple2(a, b, 1u << 2));  // slot 1 holds an unboxed Int (kind 1)
    eco_hash_value(HPtr::fromHPointer(p.slot[tup]));
    if (loadStringHashSlot(p.obj(nested)) != stringHashUncached(p.obj(nested)))
        TEST_FAIL("a String nested in a tuple did not fill its slot");

    for (int gc = 0; gc < 3; ++gc) {
        if (gc == 2) Allocator::instance().majorGC();
        else Allocator::instance().minorGC();
        for (unsigned i : ids) {
            void* o = p.obj(i);
            if (loadStringHashSlot(o) != want) TEST_FAIL("slot lost or changed by a collection");
            if (const char* bad = checkStringHashSlot(o)) TEST_FAIL(bad);
            if (eco_hash_string(HPtr::fromHPointer(p.slot[i])) != first)
                TEST_FAIL("hash changed after a collection");
        }
    }
}

// A literal of at least T units has its slot filled (at intern, in PermanentSpace).
void test_literal_fills() {
    initAllocator();
    static std::string lit = text(T * 3, 11);
    HPtr h = eco_alloc_string_literal_utf8(reinterpret_cast<const uint8_t*>(lit.data()),
                                           static_cast<u32>(lit.size()));
    void* o = Allocator::instance().resolve(h.toHPointer());
    eco_hash_string(h);
    if (loadStringHashSlot(o) != stringHashUncached(o)) TEST_FAIL("literal's slot not filled");
}

// A rope's height saturates at kRopeHeightMax instead of overflowing header.unboxed.
void test_rope_height_saturates() {
    initAllocator();
    Pool p;
    const std::string s = text(10, 1);
    unsigned leaf = p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()), 10));
    unsigned acc = p.put(p.slot[leaf]);
    for (u32 i = 1; i <= kRopeHeightMax + 10; ++i) {
        p.slot[acc] = StringOps::makeRope(p.slot[acc], p.slot[leaf]);
        const u32 want = std::min<u32>(i, kRopeHeightMax);
        if (StringOps::heightOf(p.obj(acc)) != want)
            TEST_FAIL("rope height " + std::to_string(StringOps::heightOf(p.obj(acc))) + " at depth " +
                      std::to_string(i));
    }
    if (StringOps::length(p.obj(acc)) != 10 * (kRopeHeightMax + 11)) TEST_FAIL("rope length wrong");
}

// Negative control: checkStringHashSlot rejects a wrong number and a dirty tail word.
void test_check_rejects_wrong_slot() {
    initAllocator();
    Pool p;
    const std::string s = text(T + 3, 2);
    unsigned i = p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()),
                                                        static_cast<u32>(s.size())));
    u32* slot = stringHashSlot(p.obj(i));
    eco_hash_string(HPtr::fromHPointer(p.slot[i]));
    if (checkStringHashSlot(p.obj(i)) != nullptr) TEST_FAIL("a correct slot was rejected");
    slot[0] += 1;
    if (checkStringHashSlot(p.obj(i)) == nullptr) TEST_FAIL("a wrong hash was accepted");
    slot[0] = 0;
    slot[1] = 0xD8D8D8D8u;
    if (checkStringHashSlot(p.obj(i)) == nullptr) TEST_FAIL("a dirty tail word was accepted");
    slot[1] = 0;
}

// `StringOps::equal` answers from two filled, different slots without reading units; equal units in
// different forms with filled slots still compare equal.
void test_equal_fast_reject() {
    initAllocator();
    Pool p;
    const std::string x = text(T + 20, 1);
    std::string y = x;
    y[T + 10] = (y[T + 10] == 'q') ? 'r' : 'q';
    unsigned ax = p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(x.data()),
                                                         static_cast<u32>(x.size())));
    const std::u16string xw = wide(x);
    unsigned bx = p.put(alloc::allocString(reinterpret_cast<const u16*>(xw.data()), xw.size()));
    unsigned ay = p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(y.data()),
                                                         static_cast<u32>(y.size())));
    for (unsigned i : {ax, bx, ay}) eco_hash_string(HPtr::fromHPointer(p.slot[i]));
    if (!StringOps::equal(p.obj(ax), p.obj(bx))) TEST_FAIL("equal units in two forms compare unequal");
    if (StringOps::equal(p.obj(ax), p.obj(ay))) TEST_FAIL("different units compare equal");
    // Overwrite y's units with x's, keeping y's (now stale) slot: only the fast path answers False.
    std::memcpy(static_cast<ElmStringUtf8Leaf*>(p.obj(ay))->bytes, x.data(), x.size());
    if (StringOps::equal(p.obj(ax), p.obj(ay))) TEST_FAIL("equal did not use the filled, different slots");
    // With one slot empty, equal reads the units.
    *stringHashSlot(p.obj(ay)) = 0;
    if (!StringOps::equal(p.obj(ax), p.obj(ay))) TEST_FAIL("equal with an empty slot did not read units");
}

// A slot filled after its String survived collections (in the nursery and promoted) is a write the P1
// census must ignore: in validate builds (census mode 2 aborts) this test dies if the masking is missing.
void test_fill_after_survival() {
    initAllocator();
    Pool p;
    std::vector<unsigned> ids;
    for (int i = 0; i < 40; ++i) {
        const std::string s = text(T + 40 + i, static_cast<char>(i));
        ids.push_back(p.put(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()),
                                                             static_cast<u32>(s.size()))));
    }
    Allocator::instance().minorGC();
    for (unsigned k = 0; k < ids.size(); k += 2) eco_hash_string(HPtr::fromHPointer(p.slot[ids[k]]));
    Allocator::instance().minorGC();
    Allocator::instance().minorGC();
    for (unsigned k = 1; k < ids.size(); k += 2) eco_hash_string(HPtr::fromHPointer(p.slot[ids[k]]));
    Allocator::instance().majorGC();
    Allocator::instance().minorGC();
    for (unsigned i : ids) {
        if (loadStringHashSlot(p.obj(i)) != stringHashUncached(p.obj(i))) TEST_FAIL("slot lost after survival");
        if (const char* bad = checkStringHashSlot(p.obj(i))) TEST_FAIL(bad);
    }
}

} // namespace

void registerStringHashSlotTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("HEAP_088 every String allocation route writes a zero hash slot",
                                test_every_route_writes_a_zero_slot));
    suite.add(Testing::TestCase("HEAP_088 the value hash fills the slot and collections keep it",
                                test_fill_and_survive_gc));
    suite.add(Testing::TestCase("HEAP_088 a PermanentSpace literal fills its slot", test_literal_fills));
    suite.add(Testing::TestCase("HEAP_088 rope height saturates in header.unboxed",
                                test_rope_height_saturates));
    suite.add(Testing::TestCase("HEAP_088 checkStringHashSlot rejects a wrong slot",
                                test_check_rejects_wrong_slot));
    suite.add(Testing::TestCase("HEAP_088 StringOps::equal rejects on two different filled slots",
                                test_equal_fast_reject));
    suite.add(Testing::TestCase("HEAP_088 a slot filled after its String survived is not a P1 violation",
                                test_fill_after_survival));
}
