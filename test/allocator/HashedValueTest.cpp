/**
 * Tests for eco/system's `Hash.Hashed` heap object (`Tag_Hashed`, HEAP_089) and value-hash definition v5
 * (plans/hashed-values-and-hash-consing.md H2, H5).
 *
 * HEAP_089: a Hashed made by the kernel survives minor and major collections with its value and hash, and
 * `==` compares two Hashed by hash, then value. v5: a Hashed hashes as its stored hash and its value is not
 * walked; a very deep value hashes (the walk stops at its bounds); equal Bytes in different forms hash
 * alike.
 */

#include "HashedValueTest.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/RootSet.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/ValueHash.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "TestHelpers.hpp"
#include <cstring>
#include <vector>

extern "C" Elm::HPtr Eco_Kernel_FNV_hashed(Elm::HPtr value);
extern "C" Elm::HPtr Eco_Kernel_FNV_value(Elm::HPtr hashedValue);
extern "C" int64_t Eco_Kernel_FNV_hashOf(Elm::HPtr hashedValue);

using namespace Elm;

namespace {

HPtr hp(HPointer p) { return HPtr::fromHPointer(p); }
HPointer ptr(HPtr h) { return h.toHPointer(); }

int64_t hashOf(HPointer p) { return eco_hash_value(hp(p)); }

bool equal(HPointer a, HPointer b) { return boolValueBits(Elm_Kernel_Utils_equal(hp(a), hp(b)).toBits()) != 0; }

// A list of the Ints `from` .. `to`, unboxed in its cells.
HPointer intList(i64 from, i64 to) {
    HPointer list = alloc::listNil();
    RootSet& roots = Allocator::instance().getRootSet();
    roots.addRoot(&list);
    for (i64 i = to; i >= from; --i) list = alloc::cons(alloc::unboxedInt(i), list, u8{1});
    roots.removeRoot(&list);
    return list;
}

// A Hashed built by hand with any hash, to test that the hash is what counts (a real one has hash = W(value)).
HPointer handHashed(u32 hash, HPointer value) {
    uint64_t roots[1];
    std::memcpy(&roots[0], &value, sizeof(value));
    void* obj = eco_alloc_with_roots(Tag_Hashed, sizeof(ElmHashed), roots, 1, 0x1);
    auto* h = static_cast<ElmHashed*>(obj);
    h->hash = hash;
    h->reserved = 0;
    std::memcpy(&h->value, &roots[0], sizeof(h->value));
    return Allocator::instance().wrap(h);
}

// Sum of the Ints of a list built by `intList`, read through the heap.
i64 sumList(HPointer list) {
    i64 sum = 0;
    for (alloc::ListCursor c(list); !c.done(); c.next()) sum += c.current().i;
    return sum;
}

// ---- HEAP_089

void test_hashed_survives_collections() {
    Allocator& a = initAllocator();
    RootSet& roots = a.getRootSet();
    HPointer list = intList(1, 1000);
    roots.addRoot(&list);
    const int64_t expected = hashOf(list);
    HPointer h = ptr(Eco_Kernel_FNV_hashed(hp(list)));
    roots.removeRoot(&list); // only the Hashed keeps the list alive now
    roots.addRoot(&h);
    TEST_ASSERT(getHeader(a.resolve(h))->tag == Tag_Hashed);
    TEST_ASSERT(Eco_Kernel_FNV_hashOf(hp(h)) == expected);
    for (int round = 0; round < 3; ++round) {
        for (int i = 0; i < 4; ++i) {
            intList(1, 200); // garbage, so the minors have work
            a.minorGC();
        }
        a.majorGC();
        auto* obj = static_cast<ElmHashed*>(a.resolve(h));
        TEST_ASSERT(obj->header.tag == Tag_Hashed);
        TEST_ASSERT(static_cast<int64_t>(obj->hash) == expected);
        TEST_ASSERT(obj->reserved == 0);
        HPointer v = ptr(Eco_Kernel_FNV_value(hp(h)));
        TEST_ASSERT(sumList(v) == 1000 * 1001 / 2);
        TEST_ASSERT(hashOf(v) == expected);
    }
    roots.removeRoot(&h);
}

void test_hashed_equality() {
    Allocator& a = initAllocator();
    RootSet& roots = a.getRootSet();
    HPointer l1 = intList(1, 50);
    roots.addRoot(&l1);
    HPointer l2 = intList(1, 50);
    roots.addRoot(&l2);
    HPointer l3 = intList(2, 51);
    roots.addRoot(&l3);
    HPointer h1 = ptr(Eco_Kernel_FNV_hashed(hp(l1)));
    roots.addRoot(&h1);
    HPointer h2 = ptr(Eco_Kernel_FNV_hashed(hp(l2)));
    roots.addRoot(&h2);
    HPointer h3 = ptr(Eco_Kernel_FNV_hashed(hp(l3)));
    roots.addRoot(&h3);
    TEST_ASSERT(equal(h1, h2));  // separately built, equal values
    TEST_ASSERT(!equal(h1, h3)); // different values
    // The hash is compared first: equal values under different (impossible) hashes are unequal, and the
    // same hash over different values is decided by the values.
    HPointer fakeDiffHash = handHashed(static_cast<u32>(hashOf(l1)) ^ 1u, l1);
    roots.addRoot(&fakeDiffHash);
    TEST_ASSERT(!equal(h1, fakeDiffHash));
    HPointer fakeSameHash = handHashed(static_cast<u32>(hashOf(l1)), l3);
    roots.addRoot(&fakeSameHash);
    TEST_ASSERT(!equal(h1, fakeSameHash));
    for (HPointer* r : {&fakeSameHash, &fakeDiffHash, &h3, &h2, &h1, &l3, &l2, &l1}) roots.removeRoot(r);
}

// ---- definition v5

void test_hashed_stands_for_its_value() {
    Allocator& a = initAllocator();
    RootSet& roots = a.getRootSet();
    HPointer list = intList(1, 30);
    roots.addRoot(&list);
    HPointer other = intList(5, 9);
    roots.addRoot(&other);
    HPointer h = ptr(Eco_Kernel_FNV_hashed(hp(list)));
    roots.addRoot(&h);
    // On its own a Hashed is its stored hash, which is the value's hash.
    TEST_ASSERT(hashOf(h) == hashOf(list));
    // Nested, it contributes its stored hash: a hand-made Hashed with the same hash over another value
    // hashes alike (the value is not walked), and the pair differs from the pair holding the plain value.
    HPointer fake = handHashed(static_cast<u32>(hashOf(list)), other);
    roots.addRoot(&fake);
    HPointer t1 = alloc::tuple2(alloc::boxed(h), alloc::unboxedInt(1), 0x4);
    roots.addRoot(&t1);
    HPointer t2 = alloc::tuple2(alloc::boxed(fake), alloc::unboxedInt(1), 0x4);
    roots.addRoot(&t2);
    HPointer t3 = alloc::tuple2(alloc::boxed(list), alloc::unboxedInt(1), 0x4);
    roots.addRoot(&t3);
    TEST_ASSERT(hashOf(t1) == hashOf(t2));
    TEST_ASSERT(hashOf(t1) != hashOf(t3));
    // And its stored hash counts: a pair holding the Hashed of another value hashes differently.
    HPointer hOther = ptr(Eco_Kernel_FNV_hashed(hp(other)));
    roots.addRoot(&hOther);
    HPointer t4 = alloc::tuple2(alloc::boxed(hOther), alloc::unboxedInt(1), 0x4);
    roots.addRoot(&t4);
    TEST_ASSERT(hashOf(t1) != hashOf(t4));
    for (HPointer* r : {&t4, &hOther, &t3, &t2, &t1, &fake, &h, &other, &list}) roots.removeRoot(r);
}

// A chain of `n` Customs `Link i next`, ending in the empty constant.
HPointer chain(i64 n) {
    HPointer c = alloc::listNil();
    RootSet& roots = Allocator::instance().getRootSet();
    roots.addRoot(&c);
    for (i64 i = 0; i < n; ++i) c = alloc::custom(1, {alloc::unboxedInt(i), alloc::boxed(c)}, std::vector<u8>{1, 0});
    roots.removeRoot(&c);
    return c;
}

void test_deep_values_hash() {
    Allocator& a = initAllocator();
    RootSet& roots = a.getRootSet();
    HPointer c1 = chain(1000000);
    roots.addRoot(&c1);
    HPointer c2 = chain(1000000);
    roots.addRoot(&c2);
    const int64_t h1 = hashOf(c1);
    TEST_ASSERT(h1 == hashOf(c1));
    TEST_ASSERT(h1 == hashOf(c2));
    roots.removeRoot(&c2);
    roots.removeRoot(&c1);
}

void test_bytes_by_content() {
    Allocator& a = initAllocator();
    RootSet& roots = a.getRootSet();
    std::vector<u8> big(80);
    for (size_t i = 0; i < big.size(); ++i) big[i] = static_cast<u8>(i * 37 + 5);
    HPointer whole = alloc::allocByteBuffer(big.data() + 8, 64);
    roots.addRoot(&whole);
    HPointer larger = alloc::allocByteBuffer(big.data(), big.size());
    roots.addRoot(&larger);
    HPointer slice = alloc::makeByteBufferSlice(larger, 8, 64);
    roots.addRoot(&slice);
    TEST_ASSERT(getHeader(a.resolve(slice))->tag == Tag_ByteBufferSlice);
    TEST_ASSERT(equal(whole, slice));
    TEST_ASSERT(hashOf(whole) == hashOf(slice));
    HPointer other = alloc::makeByteBufferSlice(larger, 9, 64);
    roots.addRoot(&other);
    TEST_ASSERT(hashOf(whole) != hashOf(other));
    for (HPointer* r : {&other, &slice, &larger, &whole}) roots.removeRoot(r);
}

} // namespace

void registerHashedValueTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("HEAP_089 a Hashed keeps its value and hash across minors and majors",
                                test_hashed_survives_collections));
    suite.add(Testing::TestCase("HEAP_089 == compares two Hashed by hash, then value", test_hashed_equality));
    suite.add(Testing::TestCase("Hash v5 a Hashed stands for its value by its stored hash",
                                test_hashed_stands_for_its_value));
    suite.add(Testing::TestCase("Hash v5 a 1,000,000-deep value hashes, twice alike", test_deep_values_hash));
    suite.add(Testing::TestCase("Hash v5 equal Bytes hash alike in every form", test_bytes_by_content));
}
