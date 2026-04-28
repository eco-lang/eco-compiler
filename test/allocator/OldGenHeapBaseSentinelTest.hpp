#pragma once

#include "../TestSuite.hpp"

// Heap-base sentinel discipline (plans/heap-base-sentinel-fix.md).
extern Testing::TestCase testInitialUnassignedBlocksAreFullPages;
extern Testing::TestCase testNoAllocationLandsAtHeapBase;
extern Testing::TestCase testReleaseLeavesCommittedPageAligned;
extern Testing::TestCase testHeapBaseBlockNotReleasedOnAllDeadReclaim;
