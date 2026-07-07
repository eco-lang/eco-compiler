#pragma once

#include "../TestSuite.hpp"

// Tests for reserveAddressSpaceBelow (PlatformVirtualMemory) — the low-address
// heap reservation required by the raw-absolute-address HPointer encoding.

extern Testing::TestCase testReserveBelowFitsUnderLimit;
extern Testing::TestCase testReserveBelowCommitRoundTrip;
extern Testing::TestCase testReserveBelowRejectsOversize;
