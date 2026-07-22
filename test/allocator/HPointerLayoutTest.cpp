/**
 * Golden-word and round-trip tests for the HPointer representation.
 *
 * Validates the canonical constant/pointer words (plan D6):
 *   null = 0x0, False = 0x4, True = 0x5, Empty = 0x6, and a heap pointer's word
 *   equals its raw absolute address. Also checks the classifier helpers and the
 *   forwarding-pointer encode/decode (plan D8).
 */

#include "HPointerLayoutTest.hpp"

#include <cstdint>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

Testing::TestCase testHPointerGoldenWords(
    "HPointer constants encode to their canonical words", []() {
        TEST_ASSERT(hpBits(alloc::elmFalse()) == 0x4ULL);
        TEST_ASSERT(hpBits(alloc::elmTrue()) == 0x5ULL);
        TEST_ASSERT(hpBits(alloc::empty()) == 0x6ULL);
        // The five former empties all collapse to the one Empty word.
        TEST_ASSERT(hpBits(alloc::listNil()) == 0x6ULL);
        TEST_ASSERT(hpBits(alloc::unit()) == 0x6ULL);
        TEST_ASSERT(hpBits(alloc::nothing()) == 0x6ULL);
        TEST_ASSERT(hpBits(alloc::emptyString()) == 0x6ULL);
        TEST_ASSERT(hpBits(alloc::emptyRecord()) == 0x6ULL);
        // Null HPointer is the zero word and distinct from False.
        TEST_ASSERT(hpBits(hpFromBits(0)) == 0x0ULL);
    });

Testing::TestCase testHPointerConstantPredicates(
    "HPointer classifier helpers agree with the golden words", []() {
        uint64_t f = 0x4, t = 0x5, e = 0x6, nul = 0x0;

        // isConstantBits: True/False/Empty are constants; null and a pointer are not.
        TEST_ASSERT(isConstantBits(f));
        TEST_ASSERT(isConstantBits(t));
        TEST_ASSERT(isConstantBits(e));
        TEST_ASSERT(!isConstantBits(nul));

        // isEmptyBits: only Empty.
        TEST_ASSERT(isEmptyBits(e));
        TEST_ASSERT(!isEmptyBits(f));
        TEST_ASSERT(!isEmptyBits(t));
        TEST_ASSERT(!isEmptyBits(nul));

        // boolValueBits: bit 0.
        TEST_ASSERT(boolValueBits(t) == 1);
        TEST_ASSERT(boolValueBits(f) == 0);

        // alloc:: predicates.
        TEST_ASSERT(alloc::isConstant(alloc::elmTrue()));
        TEST_ASSERT(alloc::isBoolConst(alloc::elmTrue()));
        TEST_ASSERT(!alloc::isBoolConst(alloc::empty()));
        TEST_ASSERT(alloc::boolValue(alloc::elmTrue()));
        TEST_ASSERT(!alloc::boolValue(alloc::elmFalse()));
        TEST_ASSERT(alloc::isEmpty(alloc::empty()));
        TEST_ASSERT(alloc::isNil(alloc::listNil()));
        TEST_ASSERT(alloc::isEmptyString(alloc::emptyString()));
        TEST_ASSERT(!alloc::isEmpty(alloc::elmTrue()));
    });

Testing::TestCase testHPointerPointerRoundTrip(
    "a heap pointer's HPointer word equals its raw address", []() {
        // 8-byte-aligned addresses spanning the whole in-range space (< 2^43).
        for (uintptr_t a = 0x8; a < (1ULL << 43); a = (a << 1) | 0x8) {
            void* obj = reinterpret_cast<void*>(a);
            HPointer hp = AllocatorTestAccess::toPointer(obj);
            // The word IS the address.
            TEST_ASSERT(hpBits(hp) == static_cast<uint64_t>(a));
            // It is not classified as a constant.
            TEST_ASSERT(!isConstantBits(hpBits(hp)));
            // Decode round-trips.
            TEST_ASSERT(hpToAddr(hp) == obj);
            TEST_ASSERT(AllocatorTestAccess::fromPointer(hp) == obj);
        }
    });

Testing::TestCase testHPointerForwardPtrRoundTrip(
    "forwarding pointer encode/decode round-trips (no heap_base)", []() {
        // heap_base is irrelevant to the new forwarding encoding (plan D8); pass
        // an arbitrary value to confirm it is ignored.
        char* dummyBase = reinterpret_cast<char*>(0x123456000ULL);
        for (uintptr_t a = 0x8; a < (1ULL << 43); a = (a << 1) | 0x8) {
            void* obj = reinterpret_cast<void*>(a);
            u64 fwd = encodeForwardPtr(obj, dummyBase);
            TEST_ASSERT(decodeForwardPtr(fwd, dummyBase) == reinterpret_cast<char*>(a));
            // Independent of the heap_base argument.
            char* otherBase = reinterpret_cast<char*>(0x999ULL);
            TEST_ASSERT(decodeForwardPtr(fwd, otherBase) == reinterpret_cast<char*>(a));
        }
    });

Testing::TestCase testHPointerBitsRoundTrip(
    "hpBits / hpFromBits are inverse", []() {
        uint64_t words[] = {0x0, 0x4, 0x5, 0x6, 0x8, 0x2468AC8, 0x7FFFFFFFFF8ULL};
        for (uint64_t w : words) {
            TEST_ASSERT(hpBits(hpFromBits(w)) == w);
        }
    });

// Compose a Header via the C++ bitfields and return its 64-bit word.
static uint64_t headerWordViaBitfields(Tag tag, uint32_t unboxed, uint32_t size) {
    Header h;
    memset(&h, 0, sizeof(h));
    h.tag = tag;
    h.unboxed = unboxed;
    h.size = size;
    uint64_t w;
    memcpy(&w, &h, sizeof(w));
    return w;
}

// The codegen inline-allocation formula (plans/inline-nursery-allocation.md
// §1.3, mirrored by value_enc::HeaderUnboxedShift/HeaderSizeShift in
// EcoToLLVMInternal.h). Bitfield packing is implementation-defined, so this
// equivalence CANNOT be a static_assert — same reason as the HPointer golden
// words above. Any compiler/ABI packing surprise fails here before it can
// miscompile a header store.
static constexpr uint64_t headerWordViaFormula(uint64_t tag, uint64_t unboxed,
                                               uint64_t size) {
    return tag | (unboxed << 10) | (size << 32);
}

Testing::TestCase testHeaderWordComposition(
    "inline-alloc header formula matches the Header bitfield layout (HEAP_034)",
    []() {
        // One case per inline-allocated class (plan §1.3 table).
        struct Case { Tag tag; uint32_t unboxed; uint32_t size; };
        Case cases[] = {
            {Tag_Int, 0, 16},          // box Int (sizeField = byte size)
            {Tag_Float, 0, 16},        // box Float
            {Tag_Char, 0, 16},         // box Char
            {Tag_Cons, 0x1, 24},       // cons, unboxed head kind (Int)
            {Tag_Cons, 0x0, 24},       // cons, boxed head
            {Tag_Tuple2, 0x9, 24},     // tuple2, mixed kinds
            {Tag_Tuple3, 0x2A, 32},    // tuple3, all-Float kinds
            {Tag_Record, 0, 5},        // record (sizeField = field count)
            {Tag_Custom, 0, 3},        // custom (sizeField = field count)
            {Tag_Closure, 0, 7},       // closure (sizeField = slot count)
        };
        for (const Case& c : cases) {
            TEST_ASSERT(headerWordViaBitfields(c.tag, c.unboxed, c.size) ==
                        headerWordViaFormula(c.tag, c.unboxed, c.size));
        }
        // Field-boundary probes: max values of each composed field must not
        // bleed into neighbours (tag 5 bits, unboxed 6 bits at shift 10,
        // size 32 bits at shift 32).
        TEST_ASSERT(headerWordViaBitfields(Tag_Forward, 0x3F, 0xFFFFFFFFu) ==
                    headerWordViaFormula(static_cast<uint64_t>(Tag_Forward),
                                         0x3F, 0xFFFFFFFFull));
        // Custom's second word: ctor (16 bits) | unboxed bitmap << 16.
        {
            Custom c2;
            memset(&c2, 0, sizeof(c2));
            c2.ctor = 0xABCD;
            c2.unboxed = 0x123456789ABCull;  // 48-bit bitmap
            uint64_t w;
            memcpy(&w, reinterpret_cast<char*>(&c2) + sizeof(Header), sizeof(w));
            TEST_ASSERT(w == (0xABCDull | (0x123456789ABCull << 16)));
        }
        // Closure's packed word: n_values | max_values<<6 | result_kind<<12 |
        // unboxed<<14 (the Phase-C layout papCreate already emits).
        {
            Closure cl;
            memset(&cl, 0, sizeof(cl));
            cl.n_values = 3;
            cl.max_values = 7;
            cl.result_kind = 2;
            cl.unboxed = 0x155ull;
            uint64_t w;
            memcpy(&w, reinterpret_cast<char*>(&cl) + sizeof(Header), sizeof(w));
            TEST_ASSERT(w == (3ull | (7ull << 6) | (2ull << 12) | (0x155ull << 14)));
        }
    });
