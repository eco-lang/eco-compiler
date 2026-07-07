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
