#pragma once

#include "TestSuite.hpp"

// NurserySpace (minor GC) property-based tests
extern Testing::TestCase testMinorGCPreservesRoots;
extern Testing::TestCase testMultipleMinorGCCycles;
extern Testing::TestCase testContinuousGarbageAllocation;
