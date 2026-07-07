#pragma once

#include "../TestSuite.hpp"

// Golden-word and round-trip tests for the HPointer representation (plan D1/D6).
// These replace compile-time static_asserts (std::bit_cast of a bit-field struct
// is not constexpr) and catch any ABI/compiler bitfield-layout surprise.

extern Testing::TestCase testHPointerGoldenWords;
extern Testing::TestCase testHPointerConstantPredicates;
extern Testing::TestCase testHPointerPointerRoundTrip;
extern Testing::TestCase testHPointerForwardPtrRoundTrip;
extern Testing::TestCase testHPointerBitsRoundTrip;
